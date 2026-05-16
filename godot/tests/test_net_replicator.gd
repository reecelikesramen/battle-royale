extends TestBase

# Phase 6.1: NetReplicator folded into NetPredictor. A schema's archetype =
# REPLICATED routes _physics_process through _replicator_server_tick on the
# server (host._capture_state hook) and skips the authority branch on every
# client (no inputs, always buffer for proxy interp). Tests bypass the scene
# tree via direct method calls.

class FakeHost:
	extends Node
	var captured_count: int = 0
	var proxy_calls: int = 0
	var last_from = null
	var last_to = null
	var last_alpha: float = 0.0

	func _capture_state(state: NetState, _delta: float) -> void:
		captured_count += 1
		(state as GrenadeState).pos = Vector3(captured_count, 0.0, 0.0)

	func _proxy_apply(from_state, to_state, alpha: float, _ext: float, _segment_s: float, _delta: float) -> void:
		proxy_calls += 1
		last_from = from_state
		last_to = to_state
		last_alpha = alpha


func test_replicated_inherits_predictor_snapshot_codec() -> void:
	# Round-trip a snapshot through a REPLICATED predictor pair. The codec
	# does the work; this verifies REPLICATED schemas decode the same payload
	# bytes PREDICTED ones produce.
	var sender: NetPredictor = _make_replicated()
	var src: GrenadeState = sender.shadow_state
	src.pos = Vector3(11.0, 22.0, 33.0)
	src.velocity = Vector3(1.0, 2.0, 3.0)

	var payload: PackedByteArray = sender.snapshot_payload()
	var receiver: NetPredictor = _make_replicated()
	receiver.decode_payload_into(receiver.shadow_state, payload)

	assert_vec3_approx((receiver.shadow_state as GrenadeState).pos, src.pos)
	assert_vec3_approx((receiver.shadow_state as GrenadeState).velocity, src.velocity)


func test_handle_net_state_packet_buffers_on_proxy() -> void:
	# REPLICATED has no authority client — every non-server peer buffers for
	# proxy interp. handle_net_state_packet must skip the unacked-prune path.
	var replicator: NetPredictor = _make_replicated()
	var src: GrenadeState = replicator.shadow_state
	src.pos = Vector3(7.0, 0.0, 0.0)

	var packet := NetStatePacket.new()
	packet.schema_id = replicator.schema.id
	packet.entity_id = 1
	packet.last_input_seq = 0
	packet.baseline_tick = 0
	packet.new_tick = 50
	packet.payload = replicator.snapshot_payload()

	# Spin up a separate receiver so the packet decode isn't a no-op.
	var receiver: NetPredictor = _make_replicated()
	receiver.handle_net_state_packet(packet)

	assert_eq(receiver.last_received_tick, 50, "tick not recorded")
	assert_eq(receiver.player_state_buffer.size(), 1, "expected one buffered snapshot")


func _make_replicated() -> NetPredictor:
	# Same trick as test_snapshot_roundtrip._make_predictor: bypass _ready by
	# poking the framework's fields directly so we don't need a SceneTree.
	# grenade_schema is REPLICATED (archetype = 1), so behavior diverges from
	# the PREDICTED player schema on dispatch + ack pruning.
	var r := NetPredictor.new()
	r.schema = load("res://entities/grenade/grenade_schema.tres") as NetSchema
	r.shadow_state = r.state_template.duplicate(true) as NetState
	r.state_field_names = NetPredictor._user_field_names(r.shadow_state)
	return r
