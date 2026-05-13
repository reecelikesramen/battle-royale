class_name NetCorrection extends Resource

# One reconcile channel: which fields to compare, the snap threshold above
# which we hard-set the visual to the shadow state, the exponential smoothing
# rate below threshold, and a deadband under which we leave the visual alone.

@export var name: StringName

## Sub-axis paths into the state Resource (e.g. "pos.xz", "pos.y",
## "velocity.xz"). Multiple axes share one error magnitude.
@export var fields: PackedStringArray

@export var snap_threshold: float = 1.0
@export var smooth_rate: float = 8.0
@export var deadband: float = 0.05

## Force snap on every reconcile (useful for state-index or progress channels).
@export var always_snap: bool = false
