extends TestBase

# Sprint 6: per-field quantization. NetStateField.quant chooses the wire codec
# applied to each state_field. AUTO keeps the legacy put_var/get_var path so
# unconfigured fields stay byte-for-byte identical with pre-Sprint-6 payloads.
# The tighter codecs (FLOAT32/QUANT8/QUANT16/QUAT32) are lossy in known,
# bounded ways: tests check both round-trip correctness within tolerance and
# that the wire actually shrinks.


func test_auto_quant_matches_put_var_baseline() -> void:
	# AUTO is the default; encoding a non-trivial state with AUTO must produce
	# the same payload as bypassing the cfg entirely. Guards against accidental
	# behavior changes for fields users haven't configured.
	var p := _make_predictor_with_quants([NetStateField.Quant.AUTO])
	var state: _SmallState = p.shadow_state
	state.scalar = 3.14159
	var with_cfg: PackedByteArray = p.snapshot_payload()

	# Same predictor, blow away the cached cfg so the encoder falls back to AUTO
	# via the null branch — should match byte-for-byte.
	p._state_field_cfgs.clear()
	var no_cfg: PackedByteArray = p.snapshot_payload()
	assert_eq(with_cfg, no_cfg, "AUTO cfg must match no-cfg encoding")


func test_float32_round_trip_vector3() -> void:
	var p := _make_predictor_with_quants([NetStateField.Quant.AUTO, NetStateField.Quant.FLOAT32])
	var src: _SmallState = p.shadow_state
	src.scalar = 0.0
	src.vec = Vector3(1.5, -2.25, 3.125)

	var payload: PackedByteArray = p.snapshot_payload()
	var receiver := _make_predictor_with_quants([NetStateField.Quant.AUTO, NetStateField.Quant.FLOAT32])
	receiver.decode_payload_into(receiver.shadow_state, payload)
	assert_vec3_approx((receiver.shadow_state as _SmallState).vec, Vector3(1.5, -2.25, 3.125), 1e-6)


func test_quant8_round_trip_scalar_within_tolerance() -> void:
	# QUANT8 over [0, 1] has step ~0.004. A value of 0.5 should round-trip to
	# within half a step.
	var p := _quant_predictor(NetStateField.Quant.QUANT8, 0.0, 1.0)
	(p.shadow_state as _SmallState).scalar = 0.5
	var payload: PackedByteArray = p.snapshot_payload()

	var rx := _quant_predictor(NetStateField.Quant.QUANT8, 0.0, 1.0)
	rx.decode_payload_into(rx.shadow_state, payload)
	assert_approx((rx.shadow_state as _SmallState).scalar, 0.5, 0.005)


func test_quant16_round_trip_scalar_tighter_tolerance() -> void:
	# QUANT16 over [0, 1000] has step ~0.015. Expect error < 0.02.
	var p := _quant_predictor(NetStateField.Quant.QUANT16, 0.0, 1000.0)
	(p.shadow_state as _SmallState).scalar = 123.456
	var payload: PackedByteArray = p.snapshot_payload()

	var rx := _quant_predictor(NetStateField.Quant.QUANT16, 0.0, 1000.0)
	rx.decode_payload_into(rx.shadow_state, payload)
	assert_approx((rx.shadow_state as _SmallState).scalar, 123.456, 0.02)


func test_quant8_clamps_out_of_range() -> void:
	# Values outside [min_value, max_value] must clamp to the endpoint, not wrap.
	var p := _quant_predictor(NetStateField.Quant.QUANT8, 0.0, 10.0)
	(p.shadow_state as _SmallState).scalar = 99.0
	var payload: PackedByteArray = p.snapshot_payload()

	var rx := _quant_predictor(NetStateField.Quant.QUANT8, 0.0, 10.0)
	rx.decode_payload_into(rx.shadow_state, payload)
	assert_approx((rx.shadow_state as _SmallState).scalar, 10.0, 0.05, "value above max should clamp at max")


func test_float32_is_smaller_than_put_var_for_vector3() -> void:
	# Vector3 via put_var is ~16 bytes; FLOAT32 packs it as 3*4 = 12. Header byte
	# is the same. Empty-state payload differs only on the vec field's encoding.
	var auto_p := _quant_predictor_full([NetStateField.Quant.AUTO, NetStateField.Quant.AUTO], 0.0, 0.0)
	(auto_p.shadow_state as _SmallState).vec = Vector3(1.0, 2.0, 3.0)
	var auto_payload: PackedByteArray = auto_p.snapshot_payload()

	var f32_p := _quant_predictor_full([NetStateField.Quant.AUTO, NetStateField.Quant.FLOAT32], 0.0, 0.0)
	(f32_p.shadow_state as _SmallState).vec = Vector3(1.0, 2.0, 3.0)
	var f32_payload: PackedByteArray = f32_p.snapshot_payload()

	assert_true(f32_payload.size() < auto_payload.size(),
			"FLOAT32 vec3 payload (%d) should be smaller than AUTO put_var (%d)" % [f32_payload.size(), auto_payload.size()])


func test_quat32_round_trip_within_tolerance() -> void:
	# Smallest-three at 10 bits per component is good to ~0.001 per axis on a
	# normalized quaternion. Test a 45deg yaw rotation.
	var p := _make_quat_predictor()
	var q := Quaternion(Vector3.UP, PI / 4.0)
	(p.shadow_state as _QuatState).rot = q
	var payload: PackedByteArray = p.snapshot_payload()

	var rx := _make_quat_predictor()
	rx.decode_payload_into(rx.shadow_state, payload)
	var got: Quaternion = (rx.shadow_state as _QuatState).rot
	# Sign of largest component is intentionally absorbed; compare both q and -q.
	var pos_err: float = absf(q.x - got.x) + absf(q.y - got.y) + absf(q.z - got.z) + absf(q.w - got.w)
	var neg_err: float = absf(q.x + got.x) + absf(q.y + got.y) + absf(q.z + got.z) + absf(q.w + got.w)
	var err: float = minf(pos_err, neg_err)
	assert_true(err < 0.005, "quat32 round-trip error %f too large" % err)


# ----- Test scaffolding -----

class _SmallState extends NetState:
	@export var scalar: float = 0.0
	@export var vec: Vector3 = Vector3.ZERO


class _QuatState extends NetState:
	@export var rot: Quaternion = Quaternion.IDENTITY


func _make_predictor_with_quants(quants: Array) -> NetPredictor:
	# quants[i] sets the quant for the i-th declared field on _SmallState
	# (scalar, vec). Uses zero min/max so any QUANT* would clamp to zero; tests
	# that need QUANT* should use _quant_predictor() with explicit ranges.
	var schema := NetSchema.new()
	schema.id = 7001
	schema.state_template = _SmallState.new()

	var p := NetPredictor.new()
	p.schema = schema
	p.shadow_state = _SmallState.new()
	p.render_state = _SmallState.new()
	p.state_field_names = NetPredictor._user_field_names(p.shadow_state)
	# Build state_fields dict keyed by field name (declaration order) with
	# the requested quants. Field names come from the script via introspection
	# so the encoder + this dict agree.
	var fields: Dictionary[StringName, NetStateField] = {}
	for i in p.state_field_names.size():
		if i >= quants.size():
			break
		var fname := StringName(p.state_field_names[i])
		var cfg := NetStateField.new()
		cfg.quant = quants[i]
		fields[fname] = cfg
	schema.state_fields = fields
	p._cache_state_field_cfgs()
	return p


func _quant_predictor(q: int, lo: float, hi: float) -> NetPredictor:
	# scalar field gets the requested quant; vec field stays AUTO.
	return _quant_predictor_full([q, NetStateField.Quant.AUTO], lo, hi)


func _quant_predictor_full(quants: Array, lo: float, hi: float) -> NetPredictor:
	var p := _make_predictor_with_quants(quants)
	for cfg in p.schema.state_fields.values():
		cfg.min_value = lo
		cfg.max_value = hi
	return p


func _make_quat_predictor() -> NetPredictor:
	var schema := NetSchema.new()
	schema.id = 7002
	schema.state_template = _QuatState.new()
	var cfg := NetStateField.new()
	cfg.quant = NetStateField.Quant.QUAT32
	schema.state_fields = {&"rot": cfg}

	var p := NetPredictor.new()
	p.schema = schema
	p.shadow_state = _QuatState.new()
	p.render_state = _QuatState.new()
	p.state_field_names = NetPredictor._user_field_names(p.shadow_state)
	p._cache_state_field_cfgs()
	return p
