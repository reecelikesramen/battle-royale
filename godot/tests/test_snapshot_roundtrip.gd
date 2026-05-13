extends TestBase

# Phase 6b: shadow_state -> NetStatePacket.payload -> back to fields must
# preserve every @export. NetPredictor.snapshot_payload() uses StreamPeerBuffer
# put_var over discovered field names; decode must read them in the same order.

func test_full_snapshot_roundtrip() -> void:
	var predictor: NetPredictor = _make_predictor()
	var src: PlayerState = predictor.shadow_state
	src.pos = Vector3(1.5, 2.5, -3.5)
	src.velocity = Vector3(10.0, 0.0, -5.5)
	src.look = Vector2(0.4, -1.2)
	src.movement_state = 3
	src.peek_state = 1
	src.crouch_progress = 0.75
	src.prone_progress = 0.0
	src.peek_progress = 0.42

	var payload: PackedByteArray = predictor.snapshot_payload()
	assert_true(payload.size() > 0, "payload empty")

	var decoded: PlayerState = _decode(payload, predictor.state_field_names)
	assert_vec3_approx(decoded.pos, src.pos)
	assert_vec3_approx(decoded.velocity, src.velocity)
	assert_eq(decoded.look, src.look)
	assert_eq(decoded.movement_state, src.movement_state)
	assert_eq(decoded.peek_state, src.peek_state)
	assert_approx(decoded.crouch_progress, src.crouch_progress)
	assert_approx(decoded.prone_progress, src.prone_progress)
	assert_approx(decoded.peek_progress, src.peek_progress)


func test_default_state_roundtrip() -> void:
	var predictor: NetPredictor = _make_predictor()
	# Defaults: zero everywhere. Round-trip should still preserve types.
	var payload: PackedByteArray = predictor.snapshot_payload()
	var decoded: PlayerState = _decode(payload, predictor.state_field_names)
	assert_vec3_approx(decoded.pos, Vector3.ZERO)
	assert_vec3_approx(decoded.velocity, Vector3.ZERO)
	assert_eq(decoded.look, Vector2.ZERO)
	assert_eq(decoded.movement_state, 0)


func test_decode_payload_into_mutates_in_place() -> void:
	# Phase 6b.2: handle_net_state_packet uses decode_payload_into to populate
	# the predictor's own shadow_state. Verify it overwrites in place rather
	# than allocating a new Resource.
	var src_predictor: NetPredictor = _make_predictor()
	var src: PlayerState = src_predictor.shadow_state
	src.pos = Vector3(7.0, 8.0, 9.0)
	src.velocity = Vector3(-1.0, 2.0, -3.0)
	src.movement_state = 5

	var dst_predictor: NetPredictor = _make_predictor()
	var dst_ref: PlayerState = dst_predictor.shadow_state
	var payload: PackedByteArray = src_predictor.snapshot_payload()
	dst_predictor.decode_payload_into(dst_ref, payload)

	# Same Resource instance, mutated.
	assert_true(dst_ref == dst_predictor.shadow_state, "expected in-place mutation")
	assert_vec3_approx(dst_ref.pos, src.pos)
	assert_vec3_approx(dst_ref.velocity, src.velocity)
	assert_eq(dst_ref.movement_state, src.movement_state)


func test_handle_net_state_packet_updates_predictor_state() -> void:
	# End-to-end: build a NetStatePacket from a source predictor's snapshot
	# and hand it to a destination predictor. shadow_state, last_received_tick,
	# and last_input_seq must all reflect the packet.
	var src_predictor: NetPredictor = _make_predictor()
	var src: PlayerState = src_predictor.shadow_state
	src.pos = Vector3(1.0, 2.0, 3.0)
	src.look = Vector2(0.1, 0.2)
	src.movement_state = 2

	var packet := NetStatePacket.new()
	packet.schema_id = src_predictor.schema.id
	packet.entity_id = 42
	packet.last_input_seq = 1337
	packet.baseline_tick = 0
	packet.new_tick = 9999
	packet.payload = src_predictor.snapshot_payload()

	var dst_predictor: NetPredictor = _make_predictor()
	dst_predictor.handle_net_state_packet(packet)

	assert_eq(dst_predictor.last_received_tick, 9999)
	assert_eq(dst_predictor.last_input_seq, 1337)
	assert_vec3_approx((dst_predictor.shadow_state as PlayerState).pos, src.pos)
	assert_eq((dst_predictor.shadow_state as PlayerState).movement_state, 2)


# Helper: build a NetPredictor without registering against the NetReplication
# autoload (we don't want test side-effects). Allocates shadow_state via the
# schema's state_class and populates state_field_names.
func _make_predictor() -> NetPredictor:
	var p := NetPredictor.new()
	p.schema = PlayerSchema.build()
	# Trigger the part of _ready that allocates shadow_state + names. Calling
	# add_child would register with NetReplication, which we want to avoid.
	p.shadow_state = p.state_class.new()
	p.render_state = p.state_class.new()
	p.state_field_names = NetPredictor._user_field_names(p.shadow_state)
	return p


func _decode(payload: PackedByteArray, field_names: PackedStringArray) -> PlayerState:
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var out := PlayerState.new()
	for fname in field_names:
		out.set(fname, sp.get_var())
	return out
