@tool
class_name NetPredictor extends Node


# Editor-time validation. Called by Godot whenever this node is selected /
# any of its properties change. Returns a list of warning strings shown on
# the red triangle in the scene tree. Runtime is a no-op (tool-only).
func _get_configuration_warnings() -> PackedStringArray:
	var warnings: PackedStringArray = PackedStringArray()
	if schema == null:
		warnings.append("NetPredictor.schema is unset — drag a NetSchema .tres into the Schema slot.")
		return warnings
	# Surface ERROR + WARNING; INFO suppressed in scene-tree warnings to keep
	# the red triangle meaningful.
	warnings.append_array(schema.validate_strings(ValidationIssue.Severity.WARNING))
	# Body export: if set, the resolved node must be a Node3D-derived type the
	# framework knows how to rewind. Mismatched configurations would silently
	# skip rewind at runtime; flag them at edit time.
	if not body.is_empty():
		_resolve_body()
		if _body == null:
			warnings.append(
					"NetPredictor.body path '%s' does not resolve to a CharacterBody3D / RigidBody3D / AnimatableBody3D / Node3D — rewind will be a no-op."
					% body)
	return warnings

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
#   _seed_state(state: NetState) -> void
#       Populate scene-derived defaults (spawn pos, initial SM ids) into
#       shadow_state + render_state at _ready. Without this, fields default to
#       the state_template's zero values until tick 1's _simulate overwrites
#       them — fine for code that never reads shadow before tick 1, but any
#       early hook (debug, lag-comp signal) sees garbage.
#   _gather_command(delta: float) -> Resource
#       (REQUIRED on authority) returns the wire packet for this tick. Host
#       reads predictor.input_sequence + .last_received_tick to stamp the cmd.
#   _simulate(state: NetState, cmd: Resource, delta: float) -> void
#       (REQUIRED) advance state in place from cmd. Used in live ticks AND
#       in replay after snapshot ack — must be idempotent for a (state, cmd).
#   _load_simulation_state(state: NetState) -> void
#       Snap host's sim representation from state. Called before replay.
#       When `body` (NodePath export) is set, the framework rewinds the body
#       BEFORE this hook runs — host only needs to restore non-body sim
#       state (state machines, animation progress, etc.). When `body` is
#       unset (default), the host is responsible for body rewind too.
#   _apply_state(state: NetState) -> void
#       Write scene from state. Camera, visual SM ids, non-smoothed fields.
#   _visualize(delta: float, state: NetState) -> void
#       Animation/SFX advance. Runs after _apply_state, before _apply_corrections.
#   _apply_corrections(delta: float) -> void
#       Lerp scene-graph toward shadow_state. Host-owned in Sprint 1; future
#       sprint moves the schema-driven loop into the framework.
#   _proxy_apply(from_state, to_state, alpha, extrapolation_s, segment_s, delta) -> void
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
# Phase 6: server-side signal fired after we decode an incoming NetCommandPacket
# for this entity. Carries the decoded typed cmd + the packet's infra fields
# (sequence_id / timestamp_us / last_received_tick) so game-side hit detection,
# lag-comp pivots, etc. can read them without re-decoding the packet themselves.
signal command_received(cmd: NetCommand, sequence_id: int, timestamp_us: int, last_received_tick: int)

# Phase 10c: fires whenever shadow_state is mutated externally and the scene
# graph should re-sync to it. Currently emitted by NetLagCompensator after
# rewinding to a historical state and again on restore. Subscribers push
# relevant fields onto scene-graph nodes (e.g. CharacterBody3D.position) so
# collision queries see the rewound pose. Entities not participating in
# lag-comp can ignore the signal.
signal shadow_state_applied()

## Schema describing this entity's state + command shape, tick rates, codec
## metadata, and reconcile channels. Required: drag a NetSchema .tres into
## this slot. The predictor walks the schema in _ready to allocate
## shadow_state, register with NetReplication, and resolve child_refs.
@export var schema: NetSchema

## Optional path (relative to this predictor) to the simulated body. When set,
## the framework owns rewind discipline around replay and reconciliation:
## transform + velocity reset, physics-interpolation reset, and (for
## CharacterBody3D) cached floor-flag refresh via a zero-motion move_and_slide.
## Leave empty to keep the host responsible for body state — current behavior,
## used by the player's dual-CharacterBody3D setup. See netcode-synchronizer.md
## for the body-shape catalog and migration plan.
@export var body: NodePath = ^"":
	set(v):
		body = v
		# update_configuration_warnings is only available in @tool scripts;
		# this script is @tool so the call is safe at both edit and runtime.
		update_configuration_warnings()

# Body-shape dispatch keys. Resolved once at _ready (runtime) or on demand by
# _get_configuration_warnings (editor). NONE = body unset, body unresolvable,
# or body is not a supported type — rewind is a no-op in that case.
enum BodyKind { NONE, CHAR_BODY, RIGID_BODY, ANIMATABLE_BODY, NODE3D }

var _body: Node = null
var _body_kind: BodyKind = BodyKind.NONE

# Template accessors. The actual state/command instances (shadow_state etc.)
# are constructed in _ready via duplicate(true), so the schema's templates
# stay pristine for future clones.
var state_template: NetState:
	get: return schema.state_template if schema else null

var command_template: NetCommand:
	get: return schema.command_template if schema else null

var shadow_state: NetState
var render_state: NetState

# Discovered user-authored @export fields (excludes Resource-base properties).
var state_field_names: PackedStringArray = PackedStringArray()
var command_field_names: PackedStringArray = PackedStringArray()

# Sprint 6: parallel array of NetStateField entries for each state_field_name.
# Populated at _ready by walking schema.find_state_field; null entries fall back
# to AUTO (put_var/get_var) so unconfigured fields keep working. Cached so the
# encode/decode hot loops don't pay a linear search per field per snapshot.
var _state_field_cfgs: Array[NetStateField] = []

# Phase 6: same shape, command side. Indexed by command_field_names order.
var _command_field_cfgs: Array[NetStateField] = []

# Phase 6b: indices (into *_field_names) of TYPE_BOOL fields. Codec emits these
# as a packed bitset trailing the inline block (1 bit each) instead of going
# through put_var (~8 bytes per bool). Resolved at config time; null/missing
# template falls back to empty array (codec then walks zero bools — no-op).
var _state_bool_indices: PackedInt32Array = PackedInt32Array()
var _command_bool_indices: PackedInt32Array = PackedInt32Array()

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
	# @tool causes this script to load in the editor for _get_configuration_warnings;
	# skip the runtime setup so the editor doesn't try to register schemas
	# against autoloads that aren't running.
	if Engine.is_editor_hint():
		return
	if state_template:
		shadow_state = state_template.duplicate(true) as NetState
		render_state = state_template.duplicate(true) as NetState
		state_field_names = _user_field_names(shadow_state)
	if command_template:
		command_field_names = _user_field_names(command_template)

	if schema:
		NetReplication.register_schema(schema.id, schema)
		if entity_id >= 0:
			NetReplication.register_entity(schema.id, entity_id, self)
		_resolve_children()
		_cache_state_field_cfgs()
		_cache_command_field_cfgs()
		# Per-schema proxy buffer scaling. Takes effect on the next ring buffer
		# auto-tune (i.e., when the second snapshot arrives).
		if player_state_buffer.has_method(&"set_buffer_delay_multiplier"):
			player_state_buffer.set_buffer_delay_multiplier(schema.buffer_segments)
		# Per-entity server tick rate: schema declares tick_hz, predictor gates
		# _server_tick every (physics_hz / tick_hz) physics frames. tick_hz=120
		# (player default) → fire every frame; tick_hz=60 → every 2nd; etc.
		var physics_hz: int = ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 120)
		_server_tick_every = maxi(1, physics_hz / maxi(1, schema.tick_hz))

	# Body resolution runs independently of schema so a misconfigured schema
	# doesn't drop the body wiring on the floor. NONE kind = no-op rewind.
	_resolve_body()

	# Hosts that need to seed scene-derived defaults into shadow/render (spawn
	# position, initial state-machine ids, etc.) implement _seed_state(state).
	# Called after schema registration so the field set is finalized but before
	# the first physics tick, ensuring any early shadow_state read sees
	# scene-consistent values rather than template zeros.
	if shadow_state != null and host != null and host.has_method(&"_seed_state"):
		host._seed_state(shadow_state)
		host._seed_state(render_state)

	# Auto-subscribe to the server's input fan-out when this predictor has a
	# command_template. Server fans NetCommandPacket to all predictors; each
	# filters by (schema_id, entity_id, peer_id == owner_id), decodes payload
	# into a typed NetCommand, and enqueues for the next _server_tick. Clients
	# never see the signal so the connect is a no-op for them.
	if command_template != null and NetSession.is_server:
		NetServer.handle_net_command.connect(_on_server_net_command)
		_subscribed_to_input = true


# Sprint 6: cache schema.find_state_field() per name so the snapshot codec can
# dispatch on Quant without re-walking schema.state_fields each field per tick.
# Fields not declared in the schema get a null cfg → AUTO fallback.
func _cache_state_field_cfgs() -> void:
	_state_field_cfgs.clear()
	_state_bool_indices = PackedInt32Array()
	if schema == null:
		return
	var template := state_template
	for i in state_field_names.size():
		var fname := state_field_names[i]
		_state_field_cfgs.append(schema.find_state_field(fname))
		# Cache bool indices so the codec doesn't typeof() every encode/decode.
		if template != null and typeof(template.get(fname)) == TYPE_BOOL:
			_state_bool_indices.append(i)


# Phase 6: same shape as _cache_state_field_cfgs but for command fields.
func _cache_command_field_cfgs() -> void:
	_command_field_cfgs.clear()
	_command_bool_indices = PackedInt32Array()
	if schema == null:
		return
	var template := command_template
	for i in command_field_names.size():
		var fname := command_field_names[i]
		_command_field_cfgs.append(schema.find_command_field(fname))
		if template != null and typeof(template.get(fname)) == TYPE_BOOL:
			_command_bool_indices.append(i)


# Phase 6: encode a typed NetCommand to bytes using command_field_names order
# + per-field quant config. Always emits a full snapshot (commands aren't
# delta-encoded — they're tiny, lossy, and client-redundant).
#
# Phase 6b bool packing: TYPE_BOOL fields are extracted from the inline stream
# and emitted as a trailing bitset (1 bit each, LSB-first, packed into
# ceil(bool_count/8) bytes). Eliminates put_var's ~8-byte-per-bool Variant
# header. The per-field Quant config on bool fields is ignored — packing is
# unconditional. Wire layout: [non_bool_field_values..., bool_bitset_bytes...].
# Field order on the wire matches command_field_names declaration order for
# the non-bool block; bool bits go in command_field_names order too (skipping
# non-bool indices).
func encode_command_payload(cmd: NetCommand) -> PackedByteArray:
	if cmd == null:
		return PackedByteArray()
	var sp := StreamPeerBuffer.new()
	var bool_bits: int = 0
	var bool_idx: int = 0
	for i in command_field_names.size():
		var fname := command_field_names[i]
		var value = cmd.get(fname)
		if typeof(value) == TYPE_BOOL:
			if value:
				bool_bits |= (1 << bool_idx)
			bool_idx += 1
		else:
			_encode_command_field(sp, i, value)
	_write_bool_bitset(sp, bool_bits, bool_idx)
	return sp.data_array


# Phase 6: in-place decode of a payload into a typed NetCommand. Caller
# pre-allocates via command_template.duplicate(true).
func decode_command_payload_into(cmd: NetCommand, payload: PackedByteArray) -> void:
	if cmd == null or payload.is_empty():
		return
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	# Pass 1: inline non-bools. Record bool field indices for the second pass.
	for i in command_field_names.size():
		var fname := command_field_names[i]
		var template_value = command_template.get(fname) if command_template != null else cmd.get(fname)
		if typeof(template_value) == TYPE_BOOL:
			continue
		cmd.set(fname, _decode_command_field(sp, i, template_value))
	# Pass 2: read trailing bitset and unpack into the cached bool indices.
	var bool_count := _command_bool_indices.size()
	var bool_bits := _read_bool_bitset(sp, bool_count)
	for bi in bool_count:
		var fname := command_field_names[_command_bool_indices[bi]]
		cmd.set(fname, (bool_bits >> bi) & 1 != 0)


# Pack `bool_count` LSB-first bits of `bool_bits` into ceil(bool_count/8) bytes
# at the tail of `sp`. Caller is responsible for ordering (must be the final
# write before returning the buffer; readers expect bits to live at the tail).
func _write_bool_bitset(sp: StreamPeerBuffer, bool_bits: int, bool_count: int) -> void:
	if bool_count <= 0:
		return
	var byte_count := (bool_count + 7) / 8
	for b in byte_count:
		sp.put_u8((bool_bits >> (b * 8)) & 0xFF)


# Read ceil(bool_count/8) bytes from the current position and reconstruct
# the original int. GDScript int is 64-bit; we accept up to 64 bools without
# overflow. If more are needed in the future, split across multiple int slots.
func _read_bool_bitset(sp: StreamPeerBuffer, bool_count: int) -> int:
	if bool_count <= 0:
		return 0
	var byte_count := (bool_count + 7) / 8
	var bits: int = 0
	for b in byte_count:
		bits |= sp.get_u8() << (b * 8)
	return bits


# Phase 6: command-field codec. Reuses the same _put_quantized / _put_float32 /
# _put_quat32 helpers as the state codec — same quantization semantics, just
# different cfg list.
func _encode_command_field(sp: StreamPeerBuffer, field_idx: int, value: Variant) -> void:
	var cfg: NetStateField = _command_field_cfgs[field_idx] if field_idx < _command_field_cfgs.size() else null
	if cfg == null or cfg.quant == NetStateField.Quant.AUTO:
		sp.put_var(value)
		return
	match cfg.quant:
		NetStateField.Quant.FLOAT32:
			_put_float32(sp, value)
		NetStateField.Quant.QUANT8:
			_put_quantized(sp, value, cfg.min_value, cfg.max_value, 255)
		NetStateField.Quant.QUANT16:
			_put_quantized(sp, value, cfg.min_value, cfg.max_value, 65535)
		NetStateField.Quant.QUAT32:
			_put_quat32(sp, value)
		_:
			sp.put_var(value)


func _decode_command_field(sp: StreamPeerBuffer, field_idx: int, type_hint: Variant) -> Variant:
	var cfg: NetStateField = _command_field_cfgs[field_idx] if field_idx < _command_field_cfgs.size() else null
	if cfg == null or cfg.quant == NetStateField.Quant.AUTO:
		return sp.get_var()
	match cfg.quant:
		NetStateField.Quant.FLOAT32:
			return _get_float32(sp, type_hint)
		NetStateField.Quant.QUANT8:
			return _get_quantized(sp, type_hint, cfg.min_value, cfg.max_value, 255)
		NetStateField.Quant.QUANT16:
			return _get_quantized(sp, type_hint, cfg.min_value, cfg.max_value, 65535)
		NetStateField.Quant.QUAT32:
			return _get_quat32(sp)
		_:
			return sp.get_var()


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
		# Sprint 2: stash the originating NetChildRef so the decoder can consult
		# its proxy_only flag without re-walking schema.child_refs each packet.
		_resolved_children.append([node, cref.fields, cref])
		_last_child_values.append({})


func _exit_tree() -> void:
	if Engine.is_editor_hint():
		return
	if schema and entity_id >= 0:
		NetReplication.unregister_entity(schema.id, entity_id)
	if _subscribed_to_input:
		NetServer.handle_net_command.disconnect(_on_server_net_command)
		_subscribed_to_input = false


# Server-side handler installed in _ready when command_template is set. Filters
# by (schema_id, entity_id, peer_id == owner_id), decodes the schema-driven
# payload into a fresh typed NetCommand, and enqueues for the next _server_tick.
# Decoded cmd carries only user fields; infra (sequence_id/timestamp_us/
# last_received_tick) is consumed off the packet here and used to key the
# JitterBuffer + later sent back via NetStatePacket.last_input_seq.
func _on_server_net_command(peer_id: int, packet) -> void:
	if peer_id != owner_id:
		return
	if schema == null or packet.schema_id != schema.id or packet.entity_id != entity_id:
		return
	var cmd: NetCommand = command_template.duplicate(true) as NetCommand
	decode_command_payload_into(cmd, packet.payload)
	# Frame entries store (sequence_id, arrival_us, server_us, cmd). The
	# server_tick loop reads frame.packet for replay — we keep that field name
	# but it now references the typed NetCommand directly (host._simulate takes
	# typed cmd, not Rust packet).
	server_input_queue.enqueue(packet.sequence_id, packet.timestamp_us, cmd)
	command_received.emit(cmd, packet.sequence_id, packet.timestamp_us, packet.last_received_tick)


# True once we've connected NetServer.handle_net_command in _ready. Guards
# _exit_tree against disconnecting a signal we never bound (test harnesses that
# skip _ready, predictors without a command_template).
var _subscribed_to_input: bool = false


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
		# Per-Resource metadata storage props (`metadata/_custom_script_type` on
		# default-init NetState, etc). Always present on a script-less base
		# Resource; never user state.
		if (prop.name as String).begins_with("metadata/"):
			continue
		out.append(prop.name)
	return out

# Networking data structures.
var server_input_queue := JitterBuffer.new()
var player_state_buffer := SequenceRingBuffer.new()
# Per-predictor mutable state owned by NetProxyBlender. Holds last rendered
# values for PREDICTED-mode fields so correction lerp survives across ticks.
# Empty unless this schema declares field_interp.
var _proxy_correction_state: Dictionary = {}
# Per-entity tick-rate gating. Server-side _server_tick fires once every
# `_server_tick_every` physics ticks (derived from physics_hz / schema.tick_hz
# at register time). Higher physics rates with lower-priority entities means
# the server skips most work for cheap props / ambient objects while keeping
# players running hot.
var _server_tick_every: int = 1
var _server_tick_ctr: int = 0
var input_sequence := PacketSequence.new()
var unacked_inputs := SequenceRingBuffer.new()

# Input redundancy: client sends the last N inputs each tick so a single
# packet loss is recovered by the next tick's send. Server JitterBuffer
# dedupes by sequence_id. Stores NetCommandPacket so retransmits are the
# exact same bytes the original send used.
const INPUT_REDUNDANCY: int = 3
var input_redundancy_ring: Array = []

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
#
# Sprint 6: this remains the shared/legacy baseline used by snapshot_payload()
# (tests + external callers) and by the history ring. Per-peer broadcasts use
# _peer_baselines below and never touch this field.
var _last_broadcasted_state: NetState = null
var _ticks_since_keyframe: int = 0

# Sprint 6: per-peer delta baselines. Each entry tracks the state, child-field
# values, and tick-since-keyframe counter that the server most recently sent
# to that peer. Avoids the problem where one client's packet loss forces a
# keyframe for everyone, and lets the keyframe schedule stagger naturally
# across peers. Entries are created lazily on first send to a peer and are
# pruned when the peer disconnects (see _on_peer_disconnected hook).
#
# Shape: { peer_id: int -> {
#     state: NetState (duplicate),
#     child_values: Array[Dictionary],
#     ticks_since_kf: int,
# } }
var _peer_baselines: Dictionary = {}

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
#   keyframe:  encode_field per state_field_name, then per child-ref field, in order
#   delta:     ceil(N_total/8) bytes of dirty_mask covering [state_fields...,
#              child_0_fields..., child_1_fields..., ...]; then encode_field for
#              each set bit, in the same order.
#
# Phase 8c: child-ref fields share the dirty mask with state_fields so unchanged
# child properties (e.g. an idle AnimationTree blend) cost only a bit per tick.
#
# Sprint 6: per-field encoding consults NetStateField.quant to optionally
# replace put_var/get_var with a tighter scalar codec (u8/u16/float32/quat32).
# Unconfigured fields and child-ref fields stay on AUTO Variant. Decoders need
# the receiver's `state` to already have a value of the right type for the
# field so typeof() can pick the matching scalar reader.
func snapshot_payload(force_keyframe: bool = false) -> PackedByteArray:
	return _encode_payload(force_keyframe, _last_broadcasted_state, _last_child_values, _ticks_since_keyframe)


# Internal encode used by both the shared-baseline path (snapshot_payload) and
# the per-peer path (server_broadcast_snapshot). Callers pass the baseline they
# want diffed against; null baseline forces a keyframe regardless of `force`.
func _encode_payload(
		force_keyframe: bool,
		baseline_state: NetState,
		baseline_child_values: Array,
		ticks_since_keyframe: int) -> PackedByteArray:
	if shadow_state == null:
		return PackedByteArray()
	var sp := StreamPeerBuffer.new()
	var is_keyframe := force_keyframe \
			or baseline_state == null \
			or ticks_since_keyframe >= KEYFRAME_INTERVAL
	if is_keyframe:
		sp.put_u8(1)
		# Phase 6b: bool fields skip inline emit, accumulate into a trailing bitset.
		var kf_bool_bits: int = 0
		var kf_bool_idx: int = 0
		for i in state_field_names.size():
			var fname := state_field_names[i]
			var value = shadow_state.get(fname)
			if typeof(value) == TYPE_BOOL:
				if value:
					kf_bool_bits |= (1 << kf_bool_idx)
				kf_bool_idx += 1
			else:
				_encode_state_field(sp, i, value)
		# Child fields go between non-bool state fields and the state-bool bitset.
		# Per-child bool packing is a future-phase concern; for now child fields
		# remain put_var inline.
		for entry in _resolved_children:
			var node: Node = entry[0]
			for f in entry[1]:
				sp.put_var(node.get(f))
		_write_bool_bitset(sp, kf_bool_bits, kf_bool_idx)
		return sp.data_array

	sp.put_u8(0)
	var n_state := state_field_names.size()
	var n_total := n_state
	for entry in _resolved_children:
		n_total += entry[1].size()
	var mask_bytes := (n_total + 7) / 8
	var mask := PackedByteArray()
	mask.resize(mask_bytes)
	for i in n_state:
		if shadow_state.get(state_field_names[i]) != baseline_state.get(state_field_names[i]):
			mask[i / 8] = mask[i / 8] | (1 << (i % 8))
	var bit_idx := n_state
	for child_i in _resolved_children.size():
		var node: Node = _resolved_children[child_i][0]
		var fields: PackedStringArray = _resolved_children[child_i][1]
		var last: Dictionary = baseline_child_values[child_i] if child_i < baseline_child_values.size() else {}
		for f in fields:
			var cur = node.get(f)
			if not last.has(f) or last[f] != cur:
				mask[bit_idx / 8] = mask[bit_idx / 8] | (1 << (bit_idx % 8))
			bit_idx += 1
	sp.put_data(mask)
	# Phase 6b: dirty bool values pack into a trailing bitset. Counter advances
	# only when the field is bool AND its dirty mask bit is set, so the bitset
	# is exactly sized to the dirty-bool count for this delta.
	var dlt_bool_bits: int = 0
	var dlt_bool_idx: int = 0
	for i in n_state:
		if mask[i / 8] & (1 << (i % 8)) == 0:
			continue
		var fname := state_field_names[i]
		var value = shadow_state.get(fname)
		if typeof(value) == TYPE_BOOL:
			if value:
				dlt_bool_bits |= (1 << dlt_bool_idx)
			dlt_bool_idx += 1
		else:
			_encode_state_field(sp, i, value)
	bit_idx = n_state
	for child_i in _resolved_children.size():
		var node: Node = _resolved_children[child_i][0]
		var fields: PackedStringArray = _resolved_children[child_i][1]
		for f in fields:
			if mask[bit_idx / 8] & (1 << (bit_idx % 8)):
				sp.put_var(node.get(f))
			bit_idx += 1
	_write_bool_bitset(sp, dlt_bool_bits, dlt_bool_idx)
	return sp.data_array


# Mutates `state` in-place. Keyframe payloads overwrite every field; delta
# payloads only touch fields (state or child) with their dirty bit set.
func decode_payload_into(state: NetState, payload: PackedByteArray) -> void:
	if state == null or payload.is_empty():
		return
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var is_keyframe := sp.get_u8() == 1
	# Sprint 2: NetChildRef.proxy_only is honored here. On the local authority
	# and on the server, bytes for proxy_only refs are still consumed from the
	# stream (the wire format isn't conditional) but the node.set() is
	# suppressed so the host's locally-driven values aren't clobbered.
	var suppress_child_writes: bool = NetSession.is_server or is_local_authority
	if is_keyframe:
		# Phase 6b: pass 1 reads non-bool fields inline. Bools skipped here.
		for i in state_field_names.size():
			var fname := state_field_names[i]
			var current = state.get(fname)
			if typeof(current) == TYPE_BOOL:
				continue
			state.set(fname, _decode_state_field(sp, i, current))
		for entry in _resolved_children:
			var node: Node = entry[0]
			var fields: PackedStringArray = entry[1]
			var cref: NetChildRef = entry[2] if entry.size() > 2 else null
			var skip: bool = suppress_child_writes and cref != null and cref.proxy_only
			for f in fields:
				var v = sp.get_var()
				if not skip:
					node.set(f, v)
		# Pass 2: trailing bool bitset. Size known from cached indices populated
		# at config time — receiver's schema must match sender's (hash drift
		# detection enforces this at register time).
		var kf_bool_count := _state_bool_indices.size()
		var kf_bool_bits := _read_bool_bitset(sp, kf_bool_count)
		for bi in kf_bool_count:
			state.set(state_field_names[_state_bool_indices[bi]],
					(kf_bool_bits >> bi) & 1 != 0)
	else:
		var n_state := state_field_names.size()
		var n_total := n_state
		for entry in _resolved_children:
			n_total += entry[1].size()
		var mask_bytes := (n_total + 7) / 8
		var mask_pair: Array = sp.get_data(mask_bytes)
		var mask: PackedByteArray = mask_pair[1]
		# Phase 6b: track which dirty fields were bools so the trailing
		# dirty-bool bitset can be sized + applied. dlt_bool_targets holds
		# field indices in order they appear in the dirty pass.
		var dlt_bool_targets: Array[int] = []
		for i in n_state:
			if mask[i / 8] & (1 << (i % 8)) == 0:
				continue
			var fname := state_field_names[i]
			var current = state.get(fname)
			if typeof(current) == TYPE_BOOL:
				dlt_bool_targets.append(i)
			else:
				state.set(fname, _decode_state_field(sp, i, current))
		var bit_idx := n_state
		for entry in _resolved_children:
			var node: Node = entry[0]
			var fields: PackedStringArray = entry[1]
			var cref: NetChildRef = entry[2] if entry.size() > 2 else null
			var skip: bool = suppress_child_writes and cref != null and cref.proxy_only
			for f in fields:
				if mask[bit_idx / 8] & (1 << (bit_idx % 8)):
					var v = sp.get_var()
					if not skip:
						node.set(f, v)
				bit_idx += 1
		var dlt_bool_count := dlt_bool_targets.size()
		var dlt_bool_bits := _read_bool_bitset(sp, dlt_bool_count)
		for bi in dlt_bool_count:
			state.set(state_field_names[dlt_bool_targets[bi]],
					(dlt_bool_bits >> bi) & 1 != 0)


# Sprint 6: per-field quantized codecs. `field_idx` indexes _state_field_cfgs;
# null/missing cfg or Quant.AUTO falls back to put_var so unconfigured fields
# keep working byte-for-byte identical to pre-Sprint-6 wire format.
func _encode_state_field(sp: StreamPeerBuffer, field_idx: int, value: Variant) -> void:
	var cfg: NetStateField = _state_field_cfgs[field_idx] if field_idx < _state_field_cfgs.size() else null
	if cfg == null or cfg.quant == NetStateField.Quant.AUTO:
		sp.put_var(value)
		return
	match cfg.quant:
		NetStateField.Quant.FLOAT32:
			_put_float32(sp, value)
		NetStateField.Quant.QUANT8:
			_put_quantized(sp, value, cfg.min_value, cfg.max_value, 255)
		NetStateField.Quant.QUANT16:
			_put_quantized(sp, value, cfg.min_value, cfg.max_value, 65535)
		NetStateField.Quant.QUAT32:
			_put_quat32(sp, value)
		_:
			sp.put_var(value)


func _decode_state_field(sp: StreamPeerBuffer, field_idx: int, type_hint: Variant) -> Variant:
	var cfg: NetStateField = _state_field_cfgs[field_idx] if field_idx < _state_field_cfgs.size() else null
	if cfg == null or cfg.quant == NetStateField.Quant.AUTO:
		return sp.get_var()
	match cfg.quant:
		NetStateField.Quant.FLOAT32:
			return _get_float32(sp, type_hint)
		NetStateField.Quant.QUANT8:
			return _get_quantized(sp, type_hint, cfg.min_value, cfg.max_value, 255)
		NetStateField.Quant.QUANT16:
			return _get_quantized(sp, type_hint, cfg.min_value, cfg.max_value, 65535)
		NetStateField.Quant.QUAT32:
			return _get_quat32(sp)
		_:
			return sp.get_var()


# FLOAT32: emit each scalar as IEEE-754 4-byte float. Saves ~5+ bytes/field vs
# put_var on Vector3/Vector4. Type comes from the value being encoded; decode
# side reads back from the receiver state's current value's type.
func _put_float32(sp: StreamPeerBuffer, value: Variant) -> void:
	match typeof(value):
		TYPE_FLOAT, TYPE_INT:
			sp.put_float(float(value))
		TYPE_VECTOR2:
			var v2: Vector2 = value
			sp.put_float(v2.x); sp.put_float(v2.y)
		TYPE_VECTOR3:
			var v3: Vector3 = value
			sp.put_float(v3.x); sp.put_float(v3.y); sp.put_float(v3.z)
		TYPE_VECTOR4:
			var v4: Vector4 = value
			sp.put_float(v4.x); sp.put_float(v4.y); sp.put_float(v4.z); sp.put_float(v4.w)
		_:
			push_warning("FLOAT32 quant unsupported for type %d, falling back to put_var" % typeof(value))
			sp.put_var(value)


func _get_float32(sp: StreamPeerBuffer, type_hint: Variant) -> Variant:
	match typeof(type_hint):
		TYPE_FLOAT, TYPE_INT:
			return sp.get_float()
		TYPE_VECTOR2:
			return Vector2(sp.get_float(), sp.get_float())
		TYPE_VECTOR3:
			return Vector3(sp.get_float(), sp.get_float(), sp.get_float())
		TYPE_VECTOR4:
			return Vector4(sp.get_float(), sp.get_float(), sp.get_float(), sp.get_float())
		_:
			return sp.get_var()


# QUANT8 / QUANT16: scale each scalar into [min_value, max_value] and write as
# u8 or u16. Out-of-range values clamp at the endpoints (preferable to silent
# wraparound). min == max is a degenerate config; encode emits midpoint to
# avoid a divide-by-zero and decode returns the midpoint scalar.
func _put_quantized(sp: StreamPeerBuffer, value: Variant, lo: float, hi: float, max_int: int) -> void:
	match typeof(value):
		TYPE_INT:
			# Lossless int path: write the integer directly as u8/u16. Float
			# scaling would round 5 → 4.988 → 4 (state-id corruption). Clamp
			# to the configured [lo, hi] range so out-of-band values are
			# detectable rather than silently wrapping.
			var iv := clampi(int(value), int(lo), int(hi))
			if max_int <= 255:
				sp.put_u8(iv)
			else:
				sp.put_u16(iv)
		TYPE_FLOAT:
			_put_scalar_quantized(sp, float(value), lo, hi, max_int)
		TYPE_VECTOR2:
			var v2: Vector2 = value
			_put_scalar_quantized(sp, v2.x, lo, hi, max_int)
			_put_scalar_quantized(sp, v2.y, lo, hi, max_int)
		TYPE_VECTOR3:
			var v3: Vector3 = value
			_put_scalar_quantized(sp, v3.x, lo, hi, max_int)
			_put_scalar_quantized(sp, v3.y, lo, hi, max_int)
			_put_scalar_quantized(sp, v3.z, lo, hi, max_int)
		TYPE_VECTOR4:
			var v4: Vector4 = value
			_put_scalar_quantized(sp, v4.x, lo, hi, max_int)
			_put_scalar_quantized(sp, v4.y, lo, hi, max_int)
			_put_scalar_quantized(sp, v4.z, lo, hi, max_int)
			_put_scalar_quantized(sp, v4.w, lo, hi, max_int)
		_:
			push_warning("QUANT8/QUANT16 unsupported for type %d, falling back to put_var" % typeof(value))
			sp.put_var(value)


func _get_quantized(sp: StreamPeerBuffer, type_hint: Variant, lo: float, hi: float, max_int: int) -> Variant:
	match typeof(type_hint):
		TYPE_FLOAT:
			return _get_scalar_quantized(sp, lo, hi, max_int)
		TYPE_INT:
			return sp.get_u8() if max_int <= 255 else sp.get_u16()
		TYPE_VECTOR2:
			var x := _get_scalar_quantized(sp, lo, hi, max_int)
			var y := _get_scalar_quantized(sp, lo, hi, max_int)
			return Vector2(x, y)
		TYPE_VECTOR3:
			var x := _get_scalar_quantized(sp, lo, hi, max_int)
			var y := _get_scalar_quantized(sp, lo, hi, max_int)
			var z := _get_scalar_quantized(sp, lo, hi, max_int)
			return Vector3(x, y, z)
		TYPE_VECTOR4:
			var x := _get_scalar_quantized(sp, lo, hi, max_int)
			var y := _get_scalar_quantized(sp, lo, hi, max_int)
			var z := _get_scalar_quantized(sp, lo, hi, max_int)
			var w := _get_scalar_quantized(sp, lo, hi, max_int)
			return Vector4(x, y, z, w)
		_:
			return sp.get_var()


func _put_scalar_quantized(sp: StreamPeerBuffer, value: float, lo: float, hi: float, max_int: int) -> void:
	# Symmetric range (hi == -lo): encode signed. q=0 maps to value 0.0 exactly,
	# so consumers like Vector*.normalized() and `> 0` / `< 0` checks see clean
	# zero on idle input. Uses 2 * max_q + 1 quant slots (e.g. 255 of 256 for
	# QUANT8) — one slot is unused, but the gain is exact zero round-trip with
	# no per-field config. See _get_scalar_quantized for the decode path.
	if _is_symmetric_range(lo, hi):
		var max_q := max_int / 2
		var q := clampi(int(round((value / hi) * float(max_q))), -max_q, max_q)
		if max_int <= 255:
			sp.put_8(q)
		else:
			sp.put_16(q)
		return
	# Asymmetric path: unsigned u8/u16 mapping over [lo, hi] -> [0, max_int].
	var range_: float = hi - lo
	var t: float
	if range_ <= 0.0:
		t = 0.5
	else:
		t = clamp((value - lo) / range_, 0.0, 1.0)
	var q: int = int(round(t * float(max_int)))
	if max_int <= 255:
		sp.put_u8(q)
	else:
		sp.put_u16(q)


func _get_scalar_quantized(sp: StreamPeerBuffer, lo: float, hi: float, max_int: int) -> float:
	# Symmetric range: signed decode, exact zero at q=0.
	if _is_symmetric_range(lo, hi):
		var max_q := max_int / 2
		var q_signed: int
		if max_int <= 255:
			q_signed = sp.get_8()
		else:
			q_signed = sp.get_16()
		return float(q_signed) / float(max_q) * hi
	# Asymmetric path: unsigned decode + half-LSB zero-snap when the range
	# straddles zero (e.g. [-5, 1]). Without the snap, q values either side of
	# the true-zero quant slot decode to ±half-LSB; consumers doing sign tests
	# would see noise. The snap is a no-op for ranges that don't straddle zero.
	var q_unsigned: int
	if max_int <= 255:
		q_unsigned = sp.get_u8()
	else:
		q_unsigned = sp.get_u16()
	var range_: float = hi - lo
	if range_ <= 0.0:
		return lo
	var v: float = lo + (float(q_unsigned) / float(max_int)) * range_
	if lo <= 0.0 and hi >= 0.0:
		var half_lsb: float = range_ / float(max_int) * 0.5
		if absf(v) < half_lsb:
			return 0.0
	return v


# Range is symmetric around zero when hi == -lo and hi > 0. Float comparison
# tolerant of inspector rounding noise (1e-6 covers any practical setting).
static func _is_symmetric_range(lo: float, hi: float) -> bool:
	return hi > 0.0 and absf(hi + lo) < 1e-6


# QUAT32: smallest-three quaternion compression. 2 bits encode which of x/y/z/w
# has the largest absolute value; the other three components encode as 10-bit
# unsigned ints over the [-1/sqrt(2), 1/sqrt(2)] range. Sign of the largest is
# absorbed by flipping the whole quaternion before packing (q and -q represent
# the same rotation). 32 bits total vs ~20 bytes for put_var(Quaternion).
const _QUAT32_RANGE: float = 1.4142135  # sqrt(2)
const _QUAT32_HALF: float = 0.70710677   # sqrt(2)/2

func _put_quat32(sp: StreamPeerBuffer, value: Variant) -> void:
	if typeof(value) != TYPE_QUATERNION:
		push_warning("QUAT32 quant requires Quaternion, got type %d" % typeof(value))
		sp.put_var(value)
		return
	var q: Quaternion = value
	var comps: Array[float] = [q.x, q.y, q.z, q.w]
	var li: int = 0
	var lm: float = abs(comps[0])
	for i in range(1, 4):
		if abs(comps[i]) > lm:
			lm = abs(comps[i])
			li = i
	var sign_: float = -1.0 if comps[li] < 0.0 else 1.0
	var packed: int = li & 0x3
	var bit_off: int = 2
	for i in range(4):
		if i == li:
			continue
		var n: float = comps[i] * sign_
		var t: float = clamp((n + _QUAT32_HALF) / _QUAT32_RANGE, 0.0, 1.0)
		var q10: int = int(round(t * 1023.0)) & 0x3FF
		packed |= q10 << bit_off
		bit_off += 10
	sp.put_u32(packed)


func _get_quat32(sp: StreamPeerBuffer) -> Quaternion:
	var packed: int = sp.get_u32()
	var li: int = packed & 0x3
	var bit_off: int = 2
	var vals: Array[float] = [0.0, 0.0, 0.0, 0.0]
	var sq: float = 0.0
	for i in range(4):
		if i == li:
			continue
		var q10: int = (packed >> bit_off) & 0x3FF
		var n: float = (float(q10) / 1023.0) * _QUAT32_RANGE - _QUAT32_HALF
		vals[i] = n
		sq += n * n
		bit_off += 10
	vals[li] = sqrt(max(1.0 - sq, 0.0))
	return Quaternion(vals[0], vals[1], vals[2], vals[3])


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


# Resolve the `body` NodePath into a typed reference + cached BodyKind for
# dispatch. Idempotent + side-effect free; safe to call from editor context
# (no autoload access). Unsupported types or unresolvable paths leave _body
# null + _body_kind = NONE, which makes _rewind_body a no-op.
func _resolve_body() -> void:
	_body = null
	_body_kind = BodyKind.NONE
	if body.is_empty():
		return
	var node := get_node_or_null(body)
	if node == null:
		return
	# Specific-to-general type check: CharacterBody3D + RigidBody3D before the
	# generic Node3D fallback. AnimatableBody3D is treated like a Node3D for
	# rewind (only transform is meaningful; engine doesn't integrate it).
	if node is CharacterBody3D:
		_body = node
		_body_kind = BodyKind.CHAR_BODY
	elif node is RigidBody3D:
		_body = node
		_body_kind = BodyKind.RIGID_BODY
	elif node is AnimatableBody3D:
		_body = node
		_body_kind = BodyKind.ANIMATABLE_BODY
	elif node is Node3D:
		_body = node
		_body_kind = BodyKind.NODE3D


# Snap the simulated body to the pose in `state`. Called by _reconcile_replay
# before host code runs so the first replay step sees post-rewind body state
# rather than the live frame's stale value.
#
# Field access is tolerant: missing rotation / angular_velocity / velocity on
# the state schema is fine (capsule-style players whose rotation is
# camera-driven and not replicated, projectiles with linear-only motion, etc.)
# — those fields are left at the body's current value when absent from state.
#
# Per-body-kind details:
#   CharacterBody3D: writes pos/velocity directly; runs a zero-motion
#     move_and_slide to refresh cached is_on_floor / floor_normal /
#     last_motion BEFORE the replay loop reads them.
#   RigidBody3D: goes through PhysicsServer3D.body_set_state so Jolt's
#     internal contact cache is properly invalidated (direct property writes
#     during a physics step are a known footgun on rigid bodies).
#   AnimatableBody3D / Node3D: transform-only; engine doesn't integrate so
#     no flag refresh is needed.
func _rewind_body(state: NetState) -> void:
	if _body == null or state == null:
		return
	var has_pos: bool = state_field_names.has(&"pos")
	var has_velocity: bool = state_field_names.has(&"velocity")
	var has_rotation: bool = state_field_names.has(&"rotation_quat")
	var has_angular: bool = state_field_names.has(&"angular_velocity")
	match _body_kind:
		BodyKind.CHAR_BODY:
			var cb := _body as CharacterBody3D
			if has_pos:
				cb.global_position = state.get(&"pos")
			if has_rotation:
				cb.global_basis = Basis(state.get(&"rotation_quat"))
			if has_velocity:
				cb.velocity = state.get(&"velocity")
			cb.reset_physics_interpolation()
			# Zero-motion move_and_slide refreshes is_on_floor / get_floor_normal
			# so the first replay step doesn't read stale flags. Velocity is
			# preserved across the dummy call.
			var saved_v: Vector3 = cb.velocity
			cb.velocity = Vector3.ZERO
			cb.move_and_slide()
			cb.velocity = saved_v
		BodyKind.RIGID_BODY:
			var rb := _body as RigidBody3D
			var rid := rb.get_rid()
			var basis: Basis = Basis(state.get(&"rotation_quat")) if has_rotation else rb.global_basis
			var origin: Vector3 = state.get(&"pos") if has_pos else rb.global_position
			PhysicsServer3D.body_set_state(rid,
					PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(basis, origin))
			if has_velocity:
				PhysicsServer3D.body_set_state(rid,
						PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, state.get(&"velocity"))
			if has_angular:
				PhysicsServer3D.body_set_state(rid,
						PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, state.get(&"angular_velocity"))
			rb.reset_physics_interpolation()
		BodyKind.ANIMATABLE_BODY, BodyKind.NODE3D:
			var n3 := _body as Node3D
			if has_pos:
				n3.global_position = state.get(&"pos")
			if has_rotation:
				n3.global_basis = Basis(state.get(&"rotation_quat"))
			n3.reset_physics_interpolation()
		BodyKind.NONE:
			pass


# Authority-side reconcile: snap host's sim representation to shadow_state,
# then replay any inputs the server hasn't acked yet so the predicted view
# resumes from the authoritative tick instead of the last predicted tick.
# previous_cmd is anchored to inputs[0] (the acked input) so the first replay
# step sees the correct predecessor for edge detection.
#
# is_replaying_inputs is flipped *before* _load_simulation_state so that any
# logic_enter callbacks fired by set_logic_state_by_id (inside _load) see the
# replay flag set. Otherwise stateful states like Crouch/Prone whose
# logic_enter does `if not is_replaying_inputs: progress = 0` would reset
# their animation progress on every snapshot ack, causing a visible snap-back.
func _reconcile_replay(new_sequence_id: int) -> void:
	game_sequence_id = new_sequence_id
	is_replaying_inputs = true
	# Framework-owned body rewind: snap body transform/velocity to shadow
	# before host code runs. No-op when `body` is unset (current behavior;
	# host still owns body management via _load_simulation_state).
	if _body != null:
		_rewind_body(shadow_state)
	if host and host.has_method(&"_load_simulation_state"):
		host._load_simulation_state(shadow_state)
	var inputs := unacked_inputs.get_starting_at(game_sequence_id)
	if not inputs.is_empty():
		previous_cmd = inputs[0]
	var dt := NetTimeline.tick_delta()
	if host and host.has_method(&"_simulate"):
		for i in range(1, inputs.size()):
			host._simulate(shadow_state, inputs[i], dt)
			previous_cmd = inputs[i]
	is_replaying_inputs = false
	#if is_local_authority:
		#var dbg_shadow_crouch_post: float = shadow_state.get(&"crouch_progress") if &"crouch_progress" in state_field_names else -1.0
		#var dbg_shadow_move_post: int = shadow_state.get(&"movement_state") if &"movement_state" in state_field_names else -1
		#if dbg_shadow_move_pre != dbg_shadow_move_post or absf(dbg_shadow_crouch_pre - dbg_shadow_crouch_post) > 0.01:
			#print("[RECON f=%d] seq=%d replays=%d shadow.move=%d->%d shadow.crouch=%.4f->%.4f" % [
					#Engine.get_physics_frames(), new_sequence_id, maxi(inputs.size() - 1, 0),
					#dbg_shadow_move_pre, dbg_shadow_move_post,
					#dbg_shadow_crouch_pre, dbg_shadow_crouch_post])


# Broadcast this entity's current shadow state. Server-side; called from the
# entity controller's _server_physics_step.
#
# Sprint 6: switched from a single shared baseline + broadcast-once to per-peer
# baselines + per-peer encode. Each recipient sees a delta against the last
# snapshot we sent specifically to them, which means:
#   - keyframe cadence staggers naturally across peers (no global resync storm),
#   - a single client's packet loss only forces *that* client to wait for its
#     own next keyframe, not the whole lobby,
#   - interest-filter ramp-up sends a keyframe automatically on first send to a
#     newly-eligible peer (their baseline is null until then).
# The shared `_last_broadcasted_state` is still updated for the history ring +
# legacy snapshot_payload() callers; the wire stops using it directly.
func server_broadcast_snapshot(last_input_seq: int) -> void:
	if schema == null or entity_id < 0:
		return
	var target_peers: Array = _select_target_peers()
	for peer_id in target_peers:
		var record: Dictionary = _peer_baselines.get(peer_id, {})
		var baseline_state: NetState = record.get("state", null)
		var baseline_children: Array = record.get("child_values", [])
		var ticks_since_kf: int = record.get("ticks_since_kf", KEYFRAME_INTERVAL)
		var is_keyframe_now: bool = baseline_state == null \
				or ticks_since_kf >= KEYFRAME_INTERVAL
		var packet := NetStatePacket.new()
		packet.schema_id = schema.id
		packet.entity_id = entity_id
		packet.last_input_seq = last_input_seq
		# baseline_tick = the tick of the snapshot this delta anchors against;
		# 0 on a keyframe. Per-peer because peers may have different baselines.
		packet.baseline_tick = 0 if is_keyframe_now else (NetServer.server_tick - ticks_since_kf)
		packet.new_tick = NetServer.server_tick
		packet.payload = _encode_payload(is_keyframe_now, baseline_state, baseline_children, ticks_since_kf)
		NetSession.send_packet_to_peer(peer_id, packet.to_payload())
		_update_peer_baseline(peer_id, is_keyframe_now)
	# Maintain shared baseline + history ring even when no peers are connected
	# yet. tests + lag-comp rewind read from the shared baseline; snapshot_payload()
	# without arguments still works for callers that haven't migrated.
	_last_broadcasted_state = shadow_state.duplicate()
	for child_i in _resolved_children.size():
		var node: Node = _resolved_children[child_i][0]
		var fields: PackedStringArray = _resolved_children[child_i][1]
		while _last_child_values.size() <= child_i:
			_last_child_values.append({})
		var baseline: Dictionary = _last_child_values[child_i]
		for f in fields:
			baseline[f] = node.get(f)
	_record_history(NetServer.server_tick, _last_broadcasted_state)
	# Shared keyframe counter advances per tick so callers that still use
	# snapshot_payload() (no per-peer state) maintain their old cadence. The
	# wire is no longer keyed off this counter when peers are connected.
	if _last_broadcasted_state != null and _ticks_since_keyframe < KEYFRAME_INTERVAL:
		_ticks_since_keyframe += 1
	else:
		_ticks_since_keyframe = 1


# Sprint 6: returns the peer set this broadcast should target. Honors the
# interest_filter if installed; otherwise covers every connected peer.
func _select_target_peers() -> Array:
	if interest_filter.is_null():
		return NetServer.peer_ids
	var out: Array = []
	for peer_id in NetServer.peer_ids:
		if interest_filter.call(peer_id, self):
			out.append(peer_id)
	return out


# Sprint 6: bookkeeping after sending a packet to one peer. Records the just-
# sent shadow_state + child values as that peer's baseline and advances its
# keyframe counter (resets on a keyframe send, increments on a delta).
func _update_peer_baseline(peer_id: int, was_keyframe: bool) -> void:
	var record: Dictionary = _peer_baselines.get(peer_id, {})
	record["state"] = shadow_state.duplicate()
	var child_snap: Array = []
	for child_i in _resolved_children.size():
		var node: Node = _resolved_children[child_i][0]
		var fields: PackedStringArray = _resolved_children[child_i][1]
		var d: Dictionary = {}
		for f in fields:
			d[f] = node.get(f)
		child_snap.append(d)
	record["child_values"] = child_snap
	if was_keyframe:
		record["ticks_since_kf"] = 1
	else:
		record["ticks_since_kf"] = int(record.get("ticks_since_kf", 0)) + 1
	_peer_baselines[peer_id] = record


# Sprint 6: drop a peer's baseline when it disconnects. Server controllers
# should call this from their peer-disconnect handler so the dictionary doesn't
# grow unbounded across a long server lifetime.
func forget_peer_baseline(peer_id: int) -> void:
	_peer_baselines.erase(peer_id)


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
		# Per-entity tick-rate gate. Skip _server_tick on intermediate ticks so
		# low-priority entities (props, projectiles) cost a fraction of what
		# players cost. Effective dt scales with the gate so time-based fields
		# advance correctly.
		_server_tick_ctr += 1
		if _server_tick_ctr < _server_tick_every:
			return
		_server_tick_ctr = 0
		_server_tick(delta * float(_server_tick_every))
	elif is_local_authority:
		_authority_tick(delta)
	else:
		_proxy_tick(delta)


# Local authority: gather input, advance shadow, sync visuals, run visual
# physics, then lerp the scene back toward shadow per schema.corrections.
#
# Order matters because the player has *two* physics integrators — game (in
# _simulate via the GAME integration context) and visual (in _visualize via
# the VISUAL context's move_and_slide). The visual integrator mutates the
# CharacterBody3D's pos/velocity directly each tick. To smooth scene toward
# shadow without the visual integrator stomping the lerp, we let visual
# physics run *first*, capture the resulting scene state into render_state,
# lerp render_state toward shadow_state on the configured channels, then call
# back into _apply_corrections so the host writes the smoothed values to
# scene. This matches the pre-refactor behavior: visual physics is allowed to
# drift each tick, and corrections pull it back.
#
# Hosts that don't have separate visual physics (replicate-only entities,
# pure-state predictors) can skip the _capture_render_state / _apply_corrections
# pair; render_state then defaults to a shadow snapshot and no scene write
# happens via the corrections path.
func _authority_tick(delta: float) -> void:
	if host == null or not host.has_method(&"_gather_command"):
		return
	var cmd = host._gather_command(delta)
	if cmd == null:
		return
	# Phase 6: predictor owns the infra fields (sequence_id, timestamp_us,
	# last_received_tick). Host-returned cmd is a typed NetCommand carrying only
	# user-authored @export fields; we wrap it in a NetCommandPacket with
	# schema-driven encoded payload.
	var packet := NetCommandPacket.new()
	packet.schema_id = schema.id if schema else 0
	packet.entity_id = entity_id
	packet.sequence_id = input_sequence.next()
	packet.timestamp_us = Time.get_ticks_usec()
	packet.last_received_tick = last_received_tick
	packet.payload = encode_command_payload(cmd)
	unacked_inputs.insert(packet.sequence_id, -1, packet.timestamp_us, cmd)
	input_redundancy_ring.append(packet)
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
	# Seed render_state from the post-visualize scene state. Hosts that own a
	# scene-graph (player CharacterBody, etc.) implement _capture_render_state
	# to copy node properties into the typed Resource. Hosts without that
	# bridge fall through to a shadow snapshot, which makes the corrections
	# pass a no-op snap.
	if host.has_method(&"_capture_render_state"):
		host._capture_render_state(render_state)
	else:
		_copy_state(shadow_state, render_state)
	_corrections_pass(delta)
	if host.has_method(&"_apply_corrections"):
		host._apply_corrections(render_state)


# Field-wise copy of a NetState. duplicate() would also work but bypasses
# typed-field reflection — if state_field_names is the canonical list, copying
# only those keeps the framework's view of "what's networked" authoritative.
func _copy_state(src: NetState, dst: NetState) -> void:
	for fname in state_field_names:
		dst.set(fname, src.get(fname))


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
	# Phase 6: TimestampedPacket exposes sequence_id directly now that frame.packet
	# is a typed NetCommand without an infrastructure sequence_id field.
	server_broadcast_snapshot(frames[-1].sequence_id)


# Remote proxy: interpolate two ring entries, hand off to host for scene write.
# No simulate, no reconcile.
#
# Two host signatures depending on schema.field_interp:
#   - empty (host-driven, default): host._proxy_apply(from, to, alpha, ext_s, seg_s, delta)
#   - non-empty (schema-driven blending): host._proxy_apply(blended, from, to, delta)
# NetProxyBlender does the math; host just writes blended fields into the scene.
func _proxy_tick(delta: float) -> void:
	if host == null or not host.has_method(&"_proxy_apply"):
		return
	var now_us := Time.get_ticks_usec()
	var pair := player_state_buffer.get_interpolation_pair(now_us)
	if not pair.is_valid:
		return
	if schema != null and not schema.field_interp.is_empty():
		var blended: NetState = NetProxyBlender.blend(
				state_template, schema.field_interp,
				pair.from, pair.to, pair.alpha, pair.segment_s,
				pair.extrapolation_s, _proxy_correction_state, delta)
		host._proxy_apply(blended, pair.from, pair.to, delta)
	else:
		host._proxy_apply(pair.from, pair.to, pair.alpha, pair.extrapolation_s, pair.segment_s, delta)


const _AXIS_INDEX := {"x": 0, "y": 1, "z": 2, "w": 3}


# Schema-driven authority-side smoothing. Walks schema.corrections, computes
# per-channel error magnitude over the fields listed in NetCorrection.fields,
# then either snaps (err > snap_threshold and not always_smooth) or lerps
# render_state toward shadow_state on the matching axes. Fields not claimed by
# any correction snap render_state to shadow_state every tick — that's the
# "instant" path for booleans / state ids / anything you don't want eased.
#
# Multi-field channels (e.g. vertical = [pos.y, velocity.y]) compute err from
# the first field and apply the same alpha to all entries. Lets a single
# channel keep coupled fields (pos + vel) coherent through the smoothing pass.
func _corrections_pass(delta: float) -> void:
	if render_state == null or shadow_state == null:
		return
	# touched[field] = Dict{axis_char: true}. Field-level presence (touched.has)
	# means "some correction channel claimed at least some axes of this field";
	# the inner dict's keys list which specific axes (xyzw chars) were claimed.
	# Scalars have empty axis dicts but still register field-level presence so
	# the catch-all skips them. The alpha=0 deadband path also marks the field
	# touched so untouched-axis snapping doesn't override the held value.
	var touched: Dictionary = {}
	if schema != null:
		for c in schema.corrections:
			_apply_correction_channel(c, delta, touched)
	for fname in state_field_names:
		if not touched.has(fname):
			render_state.set(fname, shadow_state.get(fname))
			continue
		var rv = render_state.get(fname)
		var sv = shadow_state.get(fname)
		var all_axes := _axes_for_value(rv)
		if all_axes.is_empty():
			continue  # scalar fully owned by a correction channel — nothing left to snap
		var t: Dictionary = touched[fname]
		var snap_axes := ""
		for ch in all_axes:
			if not t.has(ch):
				snap_axes += ch
		if snap_axes != "":
			render_state.set(fname, _write_axes(rv, sv, snap_axes))


func _apply_correction_channel(c: NetCorrection, delta: float, touched: Dictionary) -> void:
	if c.fields.is_empty():
		return
	var first := _parse_field_path(c.fields[0])
	var err_mag := _field_error_mag(shadow_state, render_state, first.field, first.axes)
	var alpha: float
	if c.always_snap:
		alpha = 1.0
	elif err_mag <= c.deadband:
		alpha = 0.0
	elif err_mag > c.snap_threshold and not c.always_smooth:
		alpha = 1.0
	else:
		alpha = correction_alpha(delta, err_mag, c.snap_threshold, c.smooth_rate, c.deadband)
	if alpha <= 0.0:
		# Still record axes as "touched" so the snap-untouched pass leaves them
		# alone — deadband means "hold render where it is", not "snap to shadow".
		for path in c.fields:
			var parsed := _parse_field_path(path)
			var axes: String = parsed.axes if parsed.axes != "" else _axes_for_value(render_state.get(parsed.field))
			if not touched.has(parsed.field):
				touched[parsed.field] = {}
			for ch in axes:
				touched[parsed.field][ch] = true
		return
	for path in c.fields:
		var parsed := _parse_field_path(path)
		var field: String = parsed.field
		var rv = render_state.get(field)
		var sv = shadow_state.get(field)
		var axes: String = parsed.axes if parsed.axes != "" else _axes_for_value(rv)
		if alpha >= 1.0:
			render_state.set(field, _write_axes(rv, sv, axes))
		else:
			render_state.set(field, _lerp_axes(rv, sv, axes, alpha))
		if not touched.has(field):
			touched[field] = {}
		for ch in axes:
			touched[field][ch] = true


# "pos.xz" -> {field: "pos", axes: "xz"}. Whole-field path with no dot returns
# axes = "" — the caller substitutes the full axis set for that value's type.
func _parse_field_path(path: String) -> Dictionary:
	var dot := path.find(".")
	if dot < 0:
		return {"field": path, "axes": ""}
	return {"field": path.substr(0, dot), "axes": path.substr(dot + 1)}


# Default axis set for a value's type: Vector2 -> "xy", Vector3 -> "xyz", etc.
# Scalars return "" — _field_error_mag and _write_axes treat that as "whole
# value", scalar diff / whole assignment.
func _axes_for_value(value: Variant) -> String:
	match typeof(value):
		TYPE_VECTOR2:
			return "xy"
		TYPE_VECTOR3:
			return "xyz"
		TYPE_VECTOR4, TYPE_QUATERNION:
			return "xyzw"
	return ""


# L2 norm of (shadow.<field> - render.<field>) projected to axes. Scalar fields
# return absf(diff) regardless of axes. Unknown types return 0 — the channel
# then takes the "no error" path and skips.
func _field_error_mag(shadow: NetState, render: NetState, field: String, axes: String) -> float:
	var s = shadow.get(field)
	var r = render.get(field)
	if s == null:
		return 0.0
	match typeof(s):
		TYPE_FLOAT, TYPE_INT:
			return absf(float(s) - float(r))
		TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4:
			var use_axes := axes if axes != "" else _axes_for_value(s)
			var sum := 0.0
			for ch in use_axes:
				var idx: int = _AXIS_INDEX.get(ch, -1)
				if idx < 0:
					continue
				var d: float = float(s[idx]) - float(r[idx])
				sum += d * d
			return sqrt(sum)
		TYPE_QUATERNION:
			var qs: Quaternion = s
			var qr: Quaternion = r
			var dot := qs.dot(qr)
			return absf(1.0 - absf(dot))
	return 0.0


# Returns a new Variant with the specified axes overwritten from `source`.
# Scalar values return source directly when axes == "". Other types preserve
# untouched axes from `target`.
func _write_axes(target: Variant, source: Variant, axes: String) -> Variant:
	if axes == "":
		return source
	match typeof(target):
		TYPE_VECTOR2:
			var v: Vector2 = target
			var sv: Vector2 = source
			for ch in axes:
				var idx: int = _AXIS_INDEX.get(ch, -1)
				if idx >= 0 and idx < 2:
					v[idx] = sv[idx]
			return v
		TYPE_VECTOR3:
			var v: Vector3 = target
			var sv: Vector3 = source
			for ch in axes:
				var idx: int = _AXIS_INDEX.get(ch, -1)
				if idx >= 0 and idx < 3:
					v[idx] = sv[idx]
			return v
		TYPE_VECTOR4:
			var v: Vector4 = target
			var sv: Vector4 = source
			for ch in axes:
				var idx: int = _AXIS_INDEX.get(ch, -1)
				if idx >= 0 and idx < 4:
					v[idx] = sv[idx]
			return v
		TYPE_QUATERNION:
			# Quaternion partial writes are nonsensical mathematically (changing
			# one component without renormalizing breaks the rotation). Treat
			# any axis subset as "whole quaternion".
			return source
	return source


# Lerps the listed axes of `target` toward `source`. Same axis semantics as
# _write_axes — empty axes returns the full lerp.
func _lerp_axes(target: Variant, source: Variant, axes: String, alpha: float) -> Variant:
	match typeof(target):
		TYPE_FLOAT, TYPE_INT:
			return lerp(float(target), float(source), alpha)
		TYPE_VECTOR2:
			var v: Vector2 = target
			var sv: Vector2 = source
			var use_axes := axes if axes != "" else "xy"
			for ch in use_axes:
				var idx: int = _AXIS_INDEX.get(ch, -1)
				if idx >= 0 and idx < 2:
					v[idx] = lerp(v[idx], sv[idx], alpha)
			return v
		TYPE_VECTOR3:
			var v: Vector3 = target
			var sv: Vector3 = source
			var use_axes := axes if axes != "" else "xyz"
			for ch in use_axes:
				var idx: int = _AXIS_INDEX.get(ch, -1)
				if idx >= 0 and idx < 3:
					v[idx] = lerp(v[idx], sv[idx], alpha)
			return v
		TYPE_VECTOR4:
			var v: Vector4 = target
			var sv: Vector4 = source
			var use_axes := axes if axes != "" else "xyzw"
			for ch in use_axes:
				var idx: int = _AXIS_INDEX.get(ch, -1)
				if idx >= 0 and idx < 4:
					v[idx] = lerp(v[idx], sv[idx], alpha)
			return v
		TYPE_QUATERNION:
			var qt: Quaternion = target
			var qs: Quaternion = source
			return qt.slerp(qs, alpha)
	return target


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
