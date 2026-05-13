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
