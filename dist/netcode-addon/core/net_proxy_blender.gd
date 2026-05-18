class_name NetProxyBlender extends RefCounted

# Schema-driven per-field interpolation. NetPredictor calls `blend()` each
# proxy tick when the schema declares field_interp; produces a fresh blended
# NetState the host writes to the scene.
#
# Stateless except for `correction_state`, which the caller (NetPredictor)
# owns and threads through. correction_state is a Dictionary keyed by field
# name; PREDICTED fields stash their last-rendered value here so the next
# tick can lerp toward the new dead-reckoning target without snapping on
# snapshot arrival.


# Produces a new instance of state_template with each field blended per its
# NetFieldInterp config. Fields not in field_interp are left at default.
#
# Args:
#   state_template:   the NetState subclass used by this schema (any instance
#                     — we duplicate() to get a fresh blank). Templating off
#                     an existing instance keeps the typed @export shape.
#   field_interp:     dict[StringName, NetFieldInterp] from NetSchema.
#   from_state:       older snapshot (always valid when blend is called).
#   to_state:         newer snapshot (null if buffer has only one sample).
#   alpha:            [0, 1] interp parameter along the segment.
#   segment_s:        wall-time covered by the segment (0 when to_state null).
#   extrapolation_s:  seconds past `to_state` when target_time has overshot
#                     the buffer end. 0 in normal interp mode.
#   correction_state: per-predictor mutable dict — see file header.
#   delta:            physics dt for correction lerp time-step.
static func blend(
		state_template: NetState,
		field_interp: Dictionary,
		from_state: NetState,
		to_state: NetState,
		alpha: float,
		segment_s: float,
		extrapolation_s: float,
		correction_state: Dictionary,
		delta: float,
) -> NetState:
	var blended: NetState = state_template.duplicate()

	for field_name in field_interp:
		var cfg: NetFieldInterp = field_interp[field_name]
		var from_v: Variant = from_state.get(field_name)
		var to_v: Variant = to_state.get(field_name) if to_state != null else null

		match cfg.mode:
			NetFieldInterp.Mode.LERP:
				blended.set(field_name, _lerp_any(from_v, to_v, alpha))

			NetFieldInterp.Mode.SLERP:
				if to_v == null:
					blended.set(field_name, from_v)
				else:
					blended.set(field_name, (from_v as Quaternion).slerp(to_v as Quaternion, alpha))

			NetFieldInterp.Mode.DISCRETE:
				blended.set(field_name, to_v if (to_v != null and alpha >= 0.5) else from_v)

			NetFieldInterp.Mode.HERMITE:
				blended.set(field_name, _blend_hermite(from_state, to_state, field_name, cfg, alpha, segment_s))

			NetFieldInterp.Mode.PREDICTED:
				blended.set(field_name, _blend_predicted(
						from_state, to_state, field_name, cfg, alpha, segment_s,
						extrapolation_s, correction_state, delta))

	return blended


# Linear blend for any field type LERP supports (Vector3, float, int, etc.).
# Falls back to `from` when `to` is missing.
static func _lerp_any(from_v: Variant, to_v: Variant, alpha: float) -> Variant:
	if to_v == null:
		return from_v
	if from_v is Vector3:
		return (from_v as Vector3).lerp(to_v as Vector3, alpha)
	if from_v is Vector2:
		return (from_v as Vector2).lerp(to_v as Vector2, alpha)
	if from_v is float:
		return lerpf(from_v, to_v, alpha)
	if from_v is int:
		# Continuous lerp on ints then round — usually fine for HUD-style fields.
		return int(round(lerpf(float(from_v), float(to_v), alpha)))
	# Anything else (bools, colors, strings) — fall back to discrete.
	return to_v if alpha >= 0.5 else from_v


# Cubic Hermite between pos+vel at each endpoint. Renders behind real-time
# but smoother than LERP under packet loss because the tangent weights soak
# up the velocity at each end of the segment.
static func _blend_hermite(
		from_state: NetState,
		to_state: NetState,
		field_name: StringName,
		cfg: NetFieldInterp,
		alpha: float,
		segment_s: float,
) -> Variant:
	var p0: Vector3 = from_state.get(field_name)
	if to_state == null:
		return p0
	var p1: Vector3 = to_state.get(field_name)
	var v0: Vector3 = from_state.get(cfg.velocity_field) if cfg.velocity_field != &"" else Vector3.ZERO
	var v1: Vector3 = to_state.get(cfg.velocity_field) if cfg.velocity_field != &"" else Vector3.ZERO
	return NetInterp.hermite_vec3(p0, v0, p1, v1, alpha, segment_s)


# Real-time render: pick the latest sample we have, dead-reckon forward with
# velocity + constant acceleration to "now", then exponentially-lerp the
# previously rendered position toward that target so snapshot arrivals don't
# pop. Correction state stores the rendered value across ticks.
static func _blend_predicted(
		from_state: NetState,
		to_state: NetState,
		field_name: StringName,
		cfg: NetFieldInterp,
		alpha: float,
		segment_s: float,
		extrapolation_s: float,
		correction_state: Dictionary,
		delta: float,
) -> Variant:
	# Pick the freshest sample available as the anchor. With both samples
	# present, `to` is newer; otherwise fall back to `from`.
	var anchor_pos: Vector3
	var anchor_vel: Vector3
	var elapsed_s: float
	if to_state != null:
		anchor_pos = to_state.get(field_name)
		anchor_vel = to_state.get(cfg.velocity_field) if cfg.velocity_field != &"" else Vector3.ZERO
		# Under the auto-tuned ring buffer (buffer_delay ≈ segment), wall-time
		# since `to.arrival` is alpha * segment_s while in interp mode, plus
		# any overshoot once the buffer drains. Stays continuous across the
		# alpha=1 → next-pair boundary.
		elapsed_s = alpha * segment_s + extrapolation_s
	else:
		anchor_pos = from_state.get(field_name)
		anchor_vel = from_state.get(cfg.velocity_field) if cfg.velocity_field != &"" else Vector3.ZERO
		elapsed_s = 0.0

	var target_pos: Vector3 = anchor_pos + anchor_vel * elapsed_s \
			+ 0.5 * cfg.acceleration * elapsed_s * elapsed_s

	# Correction lerp: smooth the rendered position toward the target so
	# fresh snapshots don't pop the entity. First call seeds from target.
	var rendered: Vector3 = correction_state.get(field_name, target_pos)
	if cfg.correction_rate > 0.0:
		var k: float = 1.0 - exp(-cfg.correction_rate * delta)
		rendered = rendered.lerp(target_pos, k)
	else:
		rendered = target_pos
	correction_state[field_name] = rendered
	return rendered
