class_name NetReplicator extends NetPredictor

# Sprint 4: server-authoritative replication for entities that don't take
# inputs (doors, AI-controlled NPCs, world props, dynamic lights). Inherits
# the snapshot codec, broadcast path, history ring, and proxy interp from
# NetPredictor; overrides _physics_process to drop the authority + replay
# branches that only make sense for input-driven entities.
#
# Lifecycle (server):
#   per physics tick:
#     host._capture_state(shadow_state)   read scene -> state
#     server_broadcast_snapshot()         encode + send
#
# Lifecycle (client):
#   handle_net_state_packet decodes into shadow_state + buffers via the
#   parent class. Per physics tick, _proxy_tick lerps from/to states and
#   hands to host._proxy_apply.
#
# Host hooks expected (duck-typed):
#   _capture_state(state)               write scene -> state (SERVER only)
#   _proxy_apply(from, to, alpha, ext, dt)  client-side interp + scene write
#
# Schemas for replicators omit command_template (no inputs). The parent's
# _ready already guards that case.

# Replicators have no input-side prediction, so authority/replay paths are
# unreachable. _physics_process branches only on server vs client.
func _physics_process(delta: float) -> void:
	if schema == null or shadow_state == null:
		return
	if NetSession.is_server:
		_replicator_server_tick(delta)
	else:
		_proxy_tick(delta)


# Server tick: capture current scene -> state, then broadcast. No input queue
# to drain; the entity's own _process / _physics_process drives whatever local
# logic the host wants (NPC AI, door interpolation, etc.) and _capture_state
# just snapshots the result.
func _replicator_server_tick(_delta: float) -> void:
	if host and host.has_method(&"_capture_state"):
		host._capture_state(shadow_state)
	# last_input_seq is unused for replicators; use 0 as a stable sentinel so
	# the wire packet stays well-formed.
	server_broadcast_snapshot(0)


# Override: replicators never run authority replay because there is no input
# stream. handle_net_state_packet still decodes into shadow_state + emits the
# signal via the parent class; we just block the authority routing that would
# otherwise prune unacked inputs the framework never had.
func handle_net_state_packet(packet) -> void:
	last_received_tick = packet.new_tick
	last_input_seq = packet.last_input_seq
	decode_payload_into(shadow_state, packet.payload)
	state_snapshot_received.emit(shadow_state, last_input_seq, last_received_tick)
	if NetSession.is_server:
		return
	# All non-server peers buffer for interp — no client is the "authority" of
	# a replicated entity, so the proxy branch always runs.
	player_state_buffer.insert(
		last_input_seq,
		Time.get_ticks_usec(),
		NetTimeline.server_now_us(),
		shadow_state.duplicate())
