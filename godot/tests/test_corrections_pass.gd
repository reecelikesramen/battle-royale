extends TestBase

# NetPredictor._corrections_pass: framework now owns the render-state smoothing
# that used to live on PlayerController. Tests exercise the four behaviors that
# distinguish the schema-driven loop from a plain put-shadow-into-render:
#   - snap when err > snap_threshold,
#   - lerp when deadband < err <= snap_threshold,
#   - hold render put when err <= deadband,
#   - always_smooth keeps lerping even when err > snap_threshold,
# plus the catch-all snap for fields not claimed by any correction channel.


# Minimal state for tests — pos is the only field exercised. Untouched fields
# still go through the catch-all snap which we test separately.
class _CorrState extends NetState:
	@export var pos: Vector3 = Vector3.ZERO
	@export var velocity: Vector3 = Vector3.ZERO
	@export var tag: int = 0


func _make_predictor(channels: Array) -> NetPredictor:
	var schema := NetSchema.new()
	schema.id = 9001
	schema.state_template = _CorrState.new()
	for c in channels:
		schema.corrections.append(c)
	var p := NetPredictor.new()
	p.schema = schema
	p.shadow_state = _CorrState.new()
	p.render_state = _CorrState.new()
	p.state_field_names = NetPredictor._user_field_names(p.shadow_state)
	return p


func _channel(name_: StringName, fields: PackedStringArray, snap_thr: float, smooth_rate: float, deadband: float, always_smooth: bool = false) -> NetCorrection:
	var c := NetCorrection.new()
	c.name = name_
	c.fields = fields
	c.snap_threshold = snap_thr
	c.smooth_rate = smooth_rate
	c.deadband = deadband
	c.always_smooth = always_smooth
	return c


func test_snap_when_error_exceeds_threshold() -> void:
	# err mag = 5.0, snap_threshold = 1.5 → render snaps to shadow.xz.
	var horiz := _channel(&"horizontal", PackedStringArray(["pos.xz"]), 1.5, 8.0, 0.07)
	var p := _make_predictor([horiz])
	(p.shadow_state as _CorrState).pos = Vector3(5.0, 0.0, 0.0)
	(p.render_state as _CorrState).pos = Vector3.ZERO
	p._corrections_pass(1.0 / 60.0)
	assert_vec3_approx((p.render_state as _CorrState).pos, Vector3(5.0, 0.0, 0.0), 0.0001,
			"render.pos.xz should snap to shadow.pos.xz when err > snap_threshold")


func test_lerp_when_error_inside_window() -> void:
	# err = 0.5 (inside deadband-to-threshold range), expect a smoothing alpha
	# between 0 and 1 — render moves toward shadow but doesn't reach it in one
	# tick.
	var horiz := _channel(&"horizontal", PackedStringArray(["pos.xz"]), 1.5, 8.0, 0.07)
	var p := _make_predictor([horiz])
	(p.shadow_state as _CorrState).pos = Vector3(0.5, 0.0, 0.0)
	(p.render_state as _CorrState).pos = Vector3.ZERO
	p._corrections_pass(1.0 / 60.0)
	var rpos := (p.render_state as _CorrState).pos
	assert_true(rpos.x > 0.0 and rpos.x < 0.5,
			"render.pos.x should lerp toward 0.5 but not snap; got %f" % rpos.x)


func test_hold_when_error_inside_deadband() -> void:
	# err = 0.04, deadband = 0.07 — render must NOT move (deadband suppresses
	# micro-corrections). Catch-all must also leave the touched axes alone so
	# the held value survives the snap-untouched-axes pass.
	var horiz := _channel(&"horizontal", PackedStringArray(["pos.xz"]), 1.5, 8.0, 0.07)
	var p := _make_predictor([horiz])
	(p.shadow_state as _CorrState).pos = Vector3(0.04, 0.0, 0.0)
	(p.render_state as _CorrState).pos = Vector3.ZERO
	p._corrections_pass(1.0 / 60.0)
	assert_vec3_approx((p.render_state as _CorrState).pos, Vector3.ZERO, 0.0001,
			"render.pos.xz should hold inside deadband; got %s" % (p.render_state as _CorrState).pos)


func test_always_smooth_never_snaps() -> void:
	# err = 5.0 (well above snap_threshold) but always_smooth = true. Render
	# must lerp at the natural correction_alpha (~0.18 at rate=12, dt=1/60),
	# not snap to shadow. The pre-Sprint refactor preserved this for the
	# velocity_horizontal channel; we keep it as an explicit schema flag.
	var vel_h := _channel(&"velocity_horizontal",
			PackedStringArray(["velocity.xz"]), 1.5, 12.0, 0.2, true)
	var p := _make_predictor([vel_h])
	(p.shadow_state as _CorrState).velocity = Vector3(5.0, 0.0, 0.0)
	(p.render_state as _CorrState).velocity = Vector3.ZERO
	p._corrections_pass(1.0 / 60.0)
	var rvel := (p.render_state as _CorrState).velocity
	assert_true(rvel.x > 0.0 and rvel.x < 5.0,
			"always_smooth channel should not snap; got %f" % rvel.x)
	# Quick sanity on the plateau alpha: 1 - exp(-12 * 1/60) ≈ 0.181
	assert_true(rvel.x < 1.5,
			"first-tick alpha at rate=12, dt=1/60 should be ~0.18, got %f for shadow=5.0" % rvel.x)


func test_untouched_field_snaps_to_shadow() -> void:
	# tag is a scalar with no correction channel — catch-all should snap it
	# from render_prev to shadow every tick.
	var horiz := _channel(&"horizontal", PackedStringArray(["pos.xz"]), 1.5, 8.0, 0.07)
	var p := _make_predictor([horiz])
	(p.shadow_state as _CorrState).tag = 7
	(p.render_state as _CorrState).tag = 0
	p._corrections_pass(1.0 / 60.0)
	assert_eq((p.render_state as _CorrState).tag, 7,
			"untouched scalar should snap to shadow")


func test_partial_axes_leaves_unclaimed_axes_to_catchall() -> void:
	# horizontal claims pos.xz; pos.y is not in any channel. err.xz < deadband
	# (so xz holds), err.y is huge. The catch-all should snap pos.y while
	# leaving pos.x and pos.z at their render_prev values.
	var horiz := _channel(&"horizontal", PackedStringArray(["pos.xz"]), 1.5, 8.0, 0.07)
	var p := _make_predictor([horiz])
	(p.shadow_state as _CorrState).pos = Vector3(0.0, 9.0, 0.0)
	(p.render_state as _CorrState).pos = Vector3(0.0, 0.0, 0.0)
	p._corrections_pass(1.0 / 60.0)
	var rpos := (p.render_state as _CorrState).pos
	assert_approx(rpos.y, 9.0, 0.0001, "pos.y should snap via catch-all")
	assert_approx(rpos.x, 0.0, 0.0001, "pos.x held by xz channel")
	assert_approx(rpos.z, 0.0, 0.0001, "pos.z held by xz channel")


func test_multi_field_channel_uses_first_field_for_error() -> void:
	# vertical = [pos.y, velocity.y]. err magnitude comes from pos.y only;
	# velocity.y should snap/lerp with the same alpha so the pair stays
	# coherent (otherwise pos.y snaps but velocity.y stays large -> player
	# falls through floor on next tick).
	var vertical := _channel(&"vertical",
			PackedStringArray(["pos.y", "velocity.y"]), 2.5, 4.0, 0.15)
	var p := _make_predictor([vertical])
	(p.shadow_state as _CorrState).pos = Vector3(0.0, 5.0, 0.0)
	(p.shadow_state as _CorrState).velocity = Vector3(0.0, -10.0, 0.0)
	(p.render_state as _CorrState).pos = Vector3.ZERO
	(p.render_state as _CorrState).velocity = Vector3.ZERO
	p._corrections_pass(1.0 / 60.0)
	# err = 5.0 > snap_threshold 2.5 → snap both fields.
	assert_approx((p.render_state as _CorrState).pos.y, 5.0, 0.0001,
			"pos.y snap from vertical channel")
	assert_approx((p.render_state as _CorrState).velocity.y, -10.0, 0.0001,
			"velocity.y snaps with pos.y when bundled in same channel")


func test_field_path_parser_with_no_axis() -> void:
	# Schema may list a whole field with no axis suffix (e.g. "look"). The
	# parser yields axes="" which downstream treats as "whole value".
	var p := _make_predictor([])
	var parsed: Dictionary = p._parse_field_path("look")
	assert_eq(parsed.field, "look")
	assert_eq(parsed.axes, "")
	var parsed2: Dictionary = p._parse_field_path("pos.xz")
	assert_eq(parsed2.field, "pos")
	assert_eq(parsed2.axes, "xz")
