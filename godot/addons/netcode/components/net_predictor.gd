class_name NetPredictor extends Node

# Sprint 1: hook-driven tick dispatcher. NetPredictor owns _physics_process and
# routes per-role into host-implemented callbacks defined on its parent (the
# entity controller). Per-role flow follows netcode-design.md §2:
#
#   AUTHORITY:  gather -> simulate -> apply_state -> visualize -> corrections
#   SERVER:     consume queue -> simulate per frame -> apply_state -> broadcast
#   PROXY:      interp from buffer -> proxy_apply
#   SNAPSHOT:   decode shadow -> prune+replay (authority) | buffer (proxy)
#
# Host hooks (all duck-typed via has_method; absent hooks are no-ops unless
# noted):
#   _gather_command(delta: float) -> Resource
#       (REQUIRED on authority) returns the wire packet for this tick. Host
#       reads predictor.input_sequence + .last_received_tick to stamp the cmd.
#   _simulate(state: NetState, cmd: Resource, delta: float) -> void
#       (REQUIRED) advance state in place from cmd. Used in live ticks AND
#       in replay after snapshot ack — must be idempotent for a (state, cmd).
#   _load_simulation_state(state: NetState) -> void
#       Snap host's sim representation from state. Called before replay.
#   _apply_state(state: NetState) -> void
#       Write scene from state. Camera, visual SM ids, non-smoothed fields.
#   _visualize(delta: float, state: NetState) -> void
#       Animation/SFX advance. Runs after _apply_state, before _apply_corrections.
#   _apply_corrections(delta: float) -> void
#       Lerp scene-graph toward shadow_state. Host-owned in Sprint 1; future
#       sprint moves the schema-driven loop into the framework.
#   _proxy_apply(from_state, to_state, alpha, extrapolation_s, delta) -> void
#       Proxy interp + scene write. Host owns the field interpolation today.

# Identity. Set by the owning controller before/while adding as child.
# owner_id = the peer that owns the entity (player). entity_id is the routing
# key on the wire; for the player it equals owner_id, but in general entities
# don't have an owning peer (e.g. doors, AI) so the two are separate.
var owner_id: int = -1
var entity_id: int = -1

# Authority + replay flags read by states & systems.
var is_replaying_inputs: bool = false

# Most recent command applied via _simulate. Hosts that need edge detection
# (just-pressed semantics) read this inside their _simulate body to compare
# against the new cmd. Framework updates it after each successful _simulate
# call. Set by _reconcile_replay to inputs[0] before stepping unacked inputs
# so the replay's first step sees the ack-point as its predecessor.
var previous_cmd: Variant = null


# Convenience accessor: the entity script that owns this NetPredictor. Hooks
# dispatch against this node by has_method() duck typing.
var host: Node:
	get: return get_parent()


# True when this peer is the local authority for the entity (owns the input
# stream + runs prediction). False on the server and on remote-proxy clients.
var is_local_authority: bool:
	get: return not NetSession.is_server and owner_id == NetClient.id

# Server tick we last received a state snapshot for. Echoed in every outbound
# input so the server can advance its per-client baseline and delta-encode the
# next NetStatePacket against it. 0 = no snapshot acked yet -> server sends
# full snapshot.
var last_received_tick: int = 0

# Sequence id of the latest input the server confirmed it had applied when it
# built this snapshot. Drives input ack-and-replay on the authority client and
# enables prune-up-to on unacked_inputs. Was previously carried by
# PlayerStatePacket.last_input_sequence_id; now sourced from NetStatePacket.
var last_input_seq: int = -1

# Fires after handle_net_state_packet has decoded an inbound snapshot into
# shadow_state. Subscribers (player controller, debug overlays) react to a
# fresh server view. Passes (shadow_state, last_input_seq, new_tick).
signal state_snapshot_received(state: NetState, last_input_seq: int, new_tick: int)

# Phase 10c: fires whenever shadow_state is mutated externally and the scene
# graph should re-sync to it. Currently emitted by NetLagCompensator after
# rewinding to a historical state and again on restore. Subscribers push
# relevant fields onto scene-graph nodes (e.g. CharacterBody3D.position) so
# collision queries see the rewound pose. Entities not participating in
# lag-comp can ignore the signal.
signal shadow_state_applied()

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

# Phase 11: optional Callable(peer_id: int, predictor: NetPredictor) -> bool.
# When set, server_broadcast_snapshot iterates connected peers and sends only
# to those the filter accepts. Default (empty Callable) keeps the broadcast-
# to-all behavior. Filters typically range-check the receiving player's
# position against the entity's pos / AOI radius, or apply role-based rules
# (don't send team-A inventory to team-B clients, etc).
var interest_filter: Callable = Callable()


# Phase 11: convenience predicate exposed for tests / debug overlays. Returns
# true if the next snapshot should reach `peer_id`. Internally consulted by
# server_broadcast_snapshot when a filter is installed.
func should_replicate_to(peer_id: int) -> bool:
	if interest_filter.is_null():
		return true
	return interest_filter.call(peer_id, self)


# Phase 8: child nodes the schema asked us to replicate alongside shadow_state.
# Each entry is [Node, PackedStringArray fields]; resolved at _ready from the
# schema's child_refs against the predictor's parent. Encode/decode iterates
# this list after the state_fields block.
var _resolved_children: Array = []

# Phase 8c: per-child baseline values for delta encoding. Parallel to
# _resolved_children: entry i is a Dictionary{field_name: last_broadcast_value}.
# Populated/updated by server_broadcast_snapshot alongside _last_broadcasted_state.
var _last_child_values: Array = []


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
		_resolve_children()


# Walks schema.child_refs, resolves each NodePath relative to the predictor's
# parent (the entity root), and caches (node, fields). Paths that don't
# resolve emit a warning and are skipped — the framework continues with the
# rest so a broken NetChildRef doesn't take the whole entity offline.
func _resolve_children() -> void:
	_resolved_children.clear()
	_last_child_values.clear()
	if schema == null or get_parent() == null:
		return
	for cref in schema.child_refs:
		var node := get_parent().get_node_or_null(cref.path)
		if node == null:
			push_warning("NetChildRef '%s' path '%s' did not resolve" % [cref.name, cref.path])
			continue
		_resolved_children.append([node, cref.fields])
		_last_child_values.append({})


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

# Frames between forced full snapshots. A delta is encoded against the last
# state we broadcast; on packet loss the client diverges until the next
# keyframe corrects it. 10 at 30Hz snapshot = ~333ms worst case resync.
const KEYFRAME_INTERVAL: int = 10

# Server-side delta baseline: the shadow_state contents at the moment of the
# previous broadcast. duplicate()'d each broadcast so subsequent mutations to
# shadow_state don't bleed into the baseline. null until first broadcast.
var _last_broadcasted_state: NetState = null
var _ticks_since_keyframe: int = 0

# Phase 10: server-side historical state ring for lag-comp rewind. Keyed by
# the server tick the snapshot was authoritative at. Bounded so memory stays
# flat (32 entries @ 120Hz physics = 266ms rewind window). LagCompensator
# (later commit) reads from this when verifying client-perspective hit
# detection: rewind to client_tick, run intersect, restore.
const HISTORY_TICK_CAPACITY: int = 32
var _history_states: Dictionary = {}   # int (tick) -> NetState (duplicate)
var _history_ticks: Array[int] = []    # insertion order, used for FIFO prune

# Wire format for snapshot_payload / decode_payload_into:
#   byte 0:  is_keyframe (1 = full snapshot, 0 = delta)
#   keyframe:  put_var per state_field_name, then per child-ref field, in order
#   delta:     ceil(N_total/8) bytes of dirty_mask covering [state_fields...,
#              child_0_fields..., child_1_fields..., ...]; then put_var for each
#              set bit, in the same order.
#
# Phase 8c: child-ref fields share the dirty mask with state_fields so unchanged
# child properties (e.g. an idle AnimationTree blend) cost only a bit per tick.
# Per-field quantization will land in a follow-on commit; AUTO Variant encoding
# is used everywhere for now.
func snapshot_payload(force_keyframe: bool = false) -> PackedByteArray:
	if shadow_state == null:
		return PackedByteArray()
	var sp := StreamPeerBuffer.new()
	var is_keyframe := force_keyframe \
			or _last_broadcasted_state == null \
			or _ticks_since_keyframe >= KEYFRAME_INTERVAL
	if is_keyframe:
		sp.put_u8(1)
		for fname in state_field_names:
			sp.put_var(shadow_state.get(fname))
		for entry in _resolved_children:
			var node: Node = entry[0]
			for f in entry[1]:
				sp.put_var(node.get(f))
	else:
		sp.put_u8(0)
		var n_state := state_field_names.size()
		var n_total := n_state
		for entry in _resolved_children:
			n_total += entry[1].size()
		var mask_bytes := (n_total + 7) / 8
		var mask := PackedByteArray()
		mask.resize(mask_bytes)
		for i in n_state:
			if shadow_state.get(state_field_names[i]) != _last_broadcasted_state.get(state_field_names[i]):
				mask[i / 8] = mask[i / 8] | (1 << (i % 8))
		var bit_idx := n_state
		for child_i in _resolved_children.size():
			var node: Node = _resolved_children[child_i][0]
			var fields: PackedStringArray = _resolved_children[child_i][1]
			var last: Dictionary = _last_child_values[child_i] if child_i < _last_child_values.size() else {}
			for f in fields:
				var cur = node.get(f)
				if not last.has(f) or last[f] != cur:
					mask[bit_idx / 8] = mask[bit_idx / 8] | (1 << (bit_idx % 8))
				bit_idx += 1
		sp.put_data(mask)
		for i in n_state:
			if mask[i / 8] & (1 << (i % 8)):
				sp.put_var(shadow_state.get(state_field_names[i]))
		bit_idx = n_state
		for child_i in _resolved_children.size():
			var node: Node = _resolved_children[child_i][0]
			var fields: PackedStringArray = _resolved_children[child_i][1]
			for f in fields:
				if mask[bit_idx / 8] & (1 << (bit_idx % 8)):
					sp.put_var(node.get(f))
				bit_idx += 1
	return sp.data_array


# Mutates `state` in-place. Keyframe payloads overwrite every field; delta
# payloads only touch fields (state or child) with their dirty bit set.
func decode_payload_into(state: NetState, payload: PackedByteArray) -> void:
	if state == null or payload.is_empty():
		return
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var is_keyframe := sp.get_u8() == 1
	if is_keyframe:
		for fname in state_field_names:
			state.set(fname, sp.get_var())
		for entry in _resolved_children:
			var node: Node = entry[0]
			for f in entry[1]:
				node.set(f, sp.get_var())
	else:
		var n_state := state_field_names.size()
		var n_total := n_state
		for entry in _resolved_children:
			n_total += entry[1].size()
		var mask_bytes := (n_total + 7) / 8
		var mask_pair: Array = sp.get_data(mask_bytes)
		var mask: PackedByteArray = mask_pair[1]
		for i in n_state:
			if mask[i / 8] & (1 << (i % 8)):
				state.set(state_field_names[i], sp.get_var())
		var bit_idx := n_state
		for entry in _resolved_children:
			var node: Node = entry[0]
			var fields: PackedStringArray = entry[1]
			for f in fields:
				if mask[bit_idx / 8] & (1 << (bit_idx % 8)):
					node.set(f, sp.get_var())
				bit_idx += 1


# Decode an inbound NetStatePacket and route by role:
#   authority -> prune acked, load sim state, replay unacked via host._simulate
#   proxy     -> append duplicate to interp ring
#   server    -> ignored (shouldn't receive own snapshots)
# Still emits state_snapshot_received for subscribers that want raw notification
# (debug overlays etc).
func handle_net_state_packet(packet) -> void:
	last_received_tick = packet.new_tick
	last_input_seq = packet.last_input_seq
	decode_payload_into(shadow_state, packet.payload)
	state_snapshot_received.emit(shadow_state, last_input_seq, last_received_tick)

	if NetSession.is_server:
		return
	if is_local_authority:
		unacked_inputs.prune_up_to(last_input_seq)
		if PacketSequence.is_newer(last_input_seq, game_sequence_id):
			_reconcile_replay(last_input_seq)
	else:
		# duplicate() so subsequent in-place decode doesn't clobber buffered entries.
		player_state_buffer.insert(
			last_input_seq,
			Time.get_ticks_usec(),
			NetTimeline.server_now_us(),
			shadow_state.duplicate())


# Authority-side reconcile: snap host's sim representation to shadow_state,
# then replay any inputs the server hasn't acked yet so the predicted view
# resumes from the authoritative tick instead of the last predicted tick.
# previous_cmd is anchored to inputs[0] (the acked input) so the first replay
# step sees the correct predecessor for edge detection.
func _reconcile_replay(new_sequence_id: int) -> void:
	game_sequence_id = new_sequence_id
	if host and host.has_method(&"_load_simulation_state"):
		host._load_simulation_state(shadow_state)
	is_replaying_inputs = true
	var inputs := unacked_inputs.get_starting_at(game_sequence_id)
	if not inputs.is_empty():
		previous_cmd = inputs[0]
	var dt := NetTimeline.tick_delta()
	if host and host.has_method(&"_simulate"):
		for i in range(1, inputs.size()):
			host._simulate(shadow_state, inputs[i], dt)
			previous_cmd = inputs[i]
	is_replaying_inputs = false


# Broadcast this entity's current shadow state. Server-side; called from the
# entity controller's _server_physics_step. Phase 6b runs alongside the
# entity's pre-existing per-type packet (PlayerStatePacket); Phase 6b.2 retires
# the per-type packets.
func server_broadcast_snapshot(last_input_seq: int) -> void:
	if schema == null or entity_id < 0:
		return
	var is_keyframe_now := _last_broadcasted_state == null \
			or _ticks_since_keyframe >= KEYFRAME_INTERVAL
	var packet := NetStatePacket.new()
	packet.schema_id = schema.id
	packet.entity_id = entity_id
	packet.last_input_seq = last_input_seq
	# baseline_tick = the prior keyframe tick this delta is anchored against;
	# 0 on a keyframe itself. Phase 6b.4 may use it for per-client baseline
	# selection once we send per-peer instead of broadcast.
	packet.baseline_tick = 0 if is_keyframe_now else (NetServer.server_tick - _ticks_since_keyframe)
	packet.new_tick = NetServer.server_tick
	packet.payload = snapshot_payload(is_keyframe_now)
	# Phase 11: when an interest_filter is installed, switch from broadcast to
	# targeted per-peer send. Same encoded payload is reused across recipients
	# (per-peer deltas / per-peer baselines remain a follow-up optimization).
	var gd_packet := packet.to_payload()
	if interest_filter.is_null():
		NetSession.broadcast_packet(gd_packet)
	else:
		for peer_id in NetServer.peer_ids:
			if interest_filter.call(peer_id, self):
				NetSession.send_packet_to_peer(peer_id, gd_packet)
	# duplicate() snapshots shadow_state so subsequent in-place mutation by the
	# sim doesn't poison the baseline mid-tick.
	_last_broadcasted_state = shadow_state.duplicate()
	# Phase 8c: child baselines mirror the state baseline so the next snapshot's
	# dirty mask correctly identifies child-field changes.
	for child_i in _resolved_children.size():
		var node: Node = _resolved_children[child_i][0]
		var fields: PackedStringArray = _resolved_children[child_i][1]
		while _last_child_values.size() <= child_i:
			_last_child_values.append({})
		var baseline: Dictionary = _last_child_values[child_i]
		for f in fields:
			baseline[f] = node.get(f)
	_record_history(packet.new_tick, _last_broadcasted_state)
	if is_keyframe_now:
		_ticks_since_keyframe = 1
	else:
		_ticks_since_keyframe += 1


# Records the just-broadcast state at `tick` in the history ring, evicting
# the oldest entry when capacity is exceeded. The _last_broadcasted_state
# duplicate is reused to avoid allocating twice per tick.
func _record_history(tick: int, state: NetState) -> void:
	_history_states[tick] = state
	_history_ticks.append(tick)
	while _history_ticks.size() > HISTORY_TICK_CAPACITY:
		var oldest: int = _history_ticks.pop_front()
		_history_states.erase(oldest)


# Returns the historical shadow_state authoritative at `tick`, or null if the
# tick is outside the retained window. Tick wraparound (u32 mod) isn't
# special-cased yet — at 120Hz wrap happens every ~414 days, well past lag
# comp horizons.
func rewind_to(tick: int) -> NetState:
	return _history_states.get(tick, null)


# True if the history ring still has an entry for `tick`.
func has_history_at(tick: int) -> bool:
	return _history_states.has(tick)


# Oldest tick currently retained. Useful for lag-comp clamps: clients can't
# request rewinds older than this. Returns -1 if history is empty.
func oldest_history_tick() -> int:
	if _history_ticks.is_empty():
		return -1
	return _history_ticks[0]


# Phase 10c: emits shadow_state_applied so subscribers can push relevant
# shadow_state fields onto the scene graph. Called by NetLagCompensator after
# rewind/restore mutate shadow_state in-place.
func apply_shadow_state_to_scene() -> void:
	shadow_state_applied.emit()


# Sprint 1: framework owns the physics tick. Per-role dispatcher; per-role
# tick fns invoke host hooks. Hooks are has_method() duck-typed so an entity
# script can omit any callback it doesn't need.
func _physics_process(delta: float) -> void:
	if schema == null or shadow_state == null:
		return
	if NetSession.is_server:
		_server_tick(delta)
	elif is_local_authority:
		_authority_tick(delta)
	else:
		_proxy_tick(delta)


# Local authority: gather an input, store + send redundancy, simulate the
# shadow forward, then apply + visualize + correct on the visual scene.
func _authority_tick(delta: float) -> void:
	if host == null or not host.has_method(&"_gather_command"):
		return
	var cmd = host._gather_command(delta)
	if cmd == null:
		return
	unacked_inputs.insert(cmd.sequence_id, -1, cmd.timestamp_us, cmd)
	input_redundancy_ring.append(cmd)
	while input_redundancy_ring.size() > INPUT_REDUNDANCY:
		input_redundancy_ring.pop_front()
	for redundant in input_redundancy_ring:
		NetSession.send_packet(redundant.to_payload())

	if host.has_method(&"_simulate"):
		host._simulate(shadow_state, cmd, delta)
		previous_cmd = cmd
	if host.has_method(&"_apply_state"):
		host._apply_state(shadow_state)
	if host.has_method(&"_visualize"):
		host._visualize(delta, shadow_state)
	if host.has_method(&"_apply_corrections"):
		host._apply_corrections(delta)


# Server: drain the per-tick input jitter buffer, run sim per frame, then
# broadcast the new authoritative shadow. No visual pass on the server; the
# scene exists only to provide collision queries for the game body.
func _server_tick(_delta: float) -> void:
	if host == null:
		return
	var frames := server_input_queue.consume()
	if frames.is_empty():
		return
	if host.has_method(&"_simulate"):
		for frame in frames:
			host._simulate(shadow_state, frame.packet, frame.delta)
			previous_cmd = frame.packet
	if host.has_method(&"_apply_state"):
		host._apply_state(shadow_state)
	server_broadcast_snapshot(frames[-1].packet.sequence_id)


# Remote proxy: interpolate two ring entries, hand off to host for scene write.
# No simulate, no reconcile.
func _proxy_tick(delta: float) -> void:
	if host == null or not host.has_method(&"_proxy_apply"):
		return
	var now_us := Time.get_ticks_usec()
	var pair := player_state_buffer.get_interpolation_pair(now_us)
	if not pair.is_valid:
		return
	host._proxy_apply(pair.from, pair.to, pair.alpha, pair.extrapolation_s, delta)


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
