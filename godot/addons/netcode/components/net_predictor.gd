class_name NetPredictor extends Node

# Phase 3: pure data container for prediction state. Player controller still
# drives physics + reconcile; this just owns the queues, shadow state, and
# tunables so the player script can shrink. Phase 4 introduces typed Resources
# and pulls the simulate/apply hooks into here.

# Identity. Set by the owning controller before/while adding as child.
# owner_id = the peer that owns the entity (player). entity_id is the routing
# key on the wire; for the player it equals owner_id, but in general entities
# don't have an owning peer (e.g. doors, AI) so the two are separate.
var owner_id: int = -1
var entity_id: int = -1

# Authority + replay flags read by states & systems.
var is_replaying_inputs: bool = false

# Server tick we last received a state snapshot for. Echoed in every outbound
# input so the server can advance its per-client baseline and delta-encode the
# next NetStatePacket against it. 0 = no snapshot acked yet -> server sends
# full snapshot.
var last_received_tick: int = 0

# Inspector-authored schema describing this entity's state + command shape,
# tick rates, codec metadata, and reconcile channels. Set externally before
# _ready. state_class and command_class accessors below pull from the schema.
@export var schema: NetSchema

var state_class: Script:
	get: return schema.state_class if schema else null

var command_class: Script:
	get: return schema.command_class if schema else null

var shadow_state: NetState
var render_state: NetState

# Discovered user-authored @export fields (excludes Resource-base properties).
var state_field_names: PackedStringArray = PackedStringArray()
var command_field_names: PackedStringArray = PackedStringArray()


func _ready() -> void:
	if state_class:
		shadow_state = state_class.new()
		render_state = state_class.new()
		state_field_names = _user_field_names(shadow_state)
	if command_class:
		var probe: NetCommand = command_class.new()
		command_field_names = _user_field_names(probe)

	if schema:
		NetReplication.register_schema(schema.id, schema)
		if entity_id >= 0:
			NetReplication.register_entity(schema.id, entity_id, self)


func _exit_tree() -> void:
	if schema and entity_id >= 0:
		NetReplication.unregister_entity(schema.id, entity_id)


# Returns the names of user-declared @export fields on a Resource, skipping
# Resource-base properties so reflection only sees what the user wrote.
static func _user_field_names(res: Resource) -> PackedStringArray:
	var out := PackedStringArray()
	const SKIP := [
		&"resource_local_to_scene",
		&"resource_path",
		&"resource_name",
		&"resource_scene_unique_id",
		&"script",
	]
	for prop in res.get_property_list():
		if (prop.usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		if (prop.usage & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		if (prop.usage & PROPERTY_USAGE_GROUP) != 0:
			continue
		if prop.name in SKIP:
			continue
		out.append(prop.name)
	return out

# Networking data structures.
var server_input_queue := JitterBuffer.new()
var player_state_buffer := SequenceRingBuffer.new()
var input_sequence := PacketSequence.new()
var unacked_inputs := SequenceRingBuffer.new()

# Input redundancy: client sends the last N inputs each tick so a single
# packet loss is recovered by the next tick's send. Server JitterBuffer
# dedupes by sequence_id.
const INPUT_REDUNDANCY: int = 3
var input_redundancy_ring: Array[PlayerInputPacket] = []

# Server-authoritative shadow state. Player simulates two parallel
# integrations: VISUAL (smoothed for camera) and GAME (authoritative).
var game_transform: Transform3D = Transform3D()
var game_position: Vector3:
	get: return game_transform.origin
	set(value): game_transform.origin = value
var game_velocity := Vector3.ZERO
var game_movement_state_id: int = 0
var game_sequence_id: int = 65535

# Last NetStatePacket payload received from the server. Phase 6b stops here:
# the snapshot round-trips end-to-end via NetStatePacket so the wire format is
# proven, but the predictor still reconciles off the per-entity packets the
# controller already wires (e.g. PlayerStatePacket). Phase 6b.2 swaps the
# reconcile source onto this payload.
var last_net_state_payload: PackedByteArray = PackedByteArray()


# Serialize shadow_state into a payload via per-field reflection over the
# discovered state_field_names. Phase 6b: full snapshot, self-describing Variant
# encoding. Phase 6b.3 swaps in dirty-mask + delta against the per-client
# baseline, plus quantization per NetFieldConfig.
func snapshot_payload() -> PackedByteArray:
	if shadow_state == null:
		return PackedByteArray()
	var sp := StreamPeerBuffer.new()
	for fname in state_field_names:
		sp.put_var(shadow_state.get(fname))
	return sp.data_array


# Decode an inbound NetStatePacket. Currently just stashes the payload; Phase
# 6b.2 wires it into the reconcile path. Server tick comes from the packet's
# new_tick field (replaces the NetTimeline.server_tick proxy from 6a).
func handle_net_state_packet(packet) -> void:
	last_net_state_payload = packet.payload
	last_received_tick = packet.new_tick


# Broadcast this entity's current shadow state. Server-side; called from the
# entity controller's _server_physics_step. Phase 6b runs alongside the
# entity's pre-existing per-type packet (PlayerStatePacket); Phase 6b.2 retires
# the per-type packets.
func server_broadcast_snapshot(last_input_seq: int) -> void:
	if schema == null or entity_id < 0:
		return
	var packet := NetStatePacket.new()
	packet.schema_id = schema.id
	packet.entity_id = entity_id
	packet.last_input_seq = last_input_seq
	packet.baseline_tick = 0  # full snapshot until 6b.3 wires per-client baselines
	packet.new_tick = NetworkServer.server_tick
	packet.payload = snapshot_payload()
	NetworkTransport.broadcast_packet(packet.to_payload())


## Framerate-independent correction alpha:
## error scaled to [0, 1] within (deadband, snap_threshold], then run through
## the exponential smoothing 1 - exp(-rate * dt * scaled_error).
func correction_alpha(
	delta: float,
	error_mag: float,
	snap_threshold: float,
	rate: float,
	deadband: float) -> float:
	if error_mag <= deadband:
		return 0.0

	var normalized: float = clamp(
		(error_mag - deadband) / max(snap_threshold - deadband, 0.001),
		0.0,
		1.0
	)
	return 1.0 - exp(-rate * delta * normalized)
