@tool
class_name NetCorrection extends Resource

# One reconcile channel: which fields to compare, the snap threshold above
# which we hard-set the visual to the shadow state, the exponential smoothing
# rate below threshold, and a deadband under which we leave the visual alone.

# Phase 4: how the channel is consumed by NetPredictor.
#   RENDER_LERP — each tick computes a fresh err = shadow - render and lerps
#     render toward shadow with magnitude-scaled alpha. No state carried
#     between ticks. Default mode; correct for animation-progress scalars and
#     server-state-only entities.
#   SMOOTHED_OFFSET — framework owns a persistent visible-vs-canonical offset
#     on the predicted body. Offset is captured once on reconcile from the
#     pre-rewind visible pos, then exponentially decayed each tick at
#     smooth_rate. snap_threshold zeros the offset hard when exceeded.
#     Only valid on schemas with command_template (predicted entities) and
#     on field 'pos' for now. See netcode-synchronizer.md §8 / §9.1.
enum Mode { RENDER_LERP, SMOOTHED_OFFSET }


# Godot's engine writes @export vars directly to the script var — _set is only
# called for *dynamic* (unknown-to-the-class) properties, so we can't intercept
# inspector writes via _set. Each @export var has its own setter that calls
# _schedule_emit_changed, which coalesces multiple setter fires in the same
# frame (e.g. during .tres deserialization) into one emit_changed on the next
# idle frame. NetSchema subscribes to each NetCorrection's `changed` signal
# and re-emits its own — so correction edits propagate to validation +
# warning-triangle refresh.
var _emit_scheduled: bool = false


func _schedule_emit_changed() -> void:
	if not Engine.is_editor_hint() or _emit_scheduled:
		return
	_emit_scheduled = true
	_do_deferred_emit_changed.call_deferred()


func _do_deferred_emit_changed() -> void:
	_emit_scheduled = false
	emit_changed()


## Channel name (for debug + lookup via NetSchema.find_correction). Must be
## unique within the schema. Pure label; not on the wire.
@export var name: StringName:
	set(v):
		name = v
		_schedule_emit_changed()

## Sub-axis paths into the state Resource (e.g. "pos.xz", "pos.y",
## "velocity.xz"). Multiple axes share one error magnitude. Field name must
## match an entry in state_fields; axis suffix selects components.
@export var fields: PackedStringArray:
	set(v):
		fields = v
		_schedule_emit_changed()

## Above this error magnitude the channel hard-snaps render to shadow (unless
## always_smooth). Units match the field — meters for positions, m/s for
## velocity, radians for rotations.
@export var snap_threshold: float = 1.0:
	set(v):
		snap_threshold = v
		_schedule_emit_changed()
## Exponential smoothing rate (1/sec). Higher = faster catch-up. Per-tick
## alpha is derived as 1 - exp(-rate * delta) and additionally scaled by
## err/snap_threshold so larger errors close faster.
@export var smooth_rate: float = 8.0:
	set(v):
		smooth_rate = v
		_schedule_emit_changed()
## Below this error magnitude the channel emits alpha=0 (no movement) —
## visual holds its current position. Prevents jitter from sub-perceptible
## noise.
@export var deadband: float = 0.05:
	set(v):
		deadband = v
		_schedule_emit_changed()

## Force snap on every reconcile (useful for state-index or progress channels).
@export var always_snap: bool = false:
	set(v):
		always_snap = v
		_schedule_emit_changed()

## Inverse of always_snap: never let the snap-threshold breach kick alpha to 1.
## When true the channel always uses the smoothed alpha from correction_alpha,
## even when err > snap_threshold. snap_threshold still bounds the normalize
## ramp. Useful for velocity channels where snapping introduces a visible jerk.
@export var always_smooth: bool = false:
	set(v):
		always_smooth = v
		_schedule_emit_changed()

## Phase 4: consumption mode. RENDER_LERP (default) lerps render_state toward
## shadow_state every tick. SMOOTHED_OFFSET hands the channel to the framework's
## visible-offset path (predicted body only; pos field only — see Mode enum).
## Schema validation enforces the restrictions; runtime _corrections_pass skips
## SMOOTHED_OFFSET channels so the per-tick lerp doesn't erase the offset.
@export var mode: Mode = Mode.RENDER_LERP:
	set(v):
		mode = v
		_schedule_emit_changed()
