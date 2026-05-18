@tool
class_name NetFieldInterp extends Resource

# Per-field interpolation declaration. Lives in NetSchema.field_interp keyed by
# field name. NetPredictor uses these to drive automatic blending in
# _proxy_tick — host's _proxy_apply receives a pre-blended state instead of
# raw (from, to, alpha).
#
# If a schema has any entries here, ALL fields the host cares about for proxy
# rendering should be declared (omitted fields stay at default-init values on
# the blended state). If field_interp is empty, NetPredictor falls back to the
# old host-driven signature for back-compat.

enum Mode {
	LERP,       ## Linear blend from→to at alpha. Default. Use for scalars, progress, secondary continuous fields.
	SLERP,      ## Sphere blend on Quaternion (rotation_quat fields).
	DISCRETE,   ## Snap to `to` value at alpha >= 0.5. For enums / state IDs.
	HERMITE,    ## Tangent-aware via velocity_field at each endpoint. Smoother under packet loss than LERP. Still renders at interp time (~1 segment behind real-time).
	PREDICTED,  ## Dead-reckon from latest sample to real-time using velocity_field + constant `acceleration`. Zero render lag. Snapshot arrivals smooth-corrected at `correction_rate` per second. Best for projectiles, missiles, vehicles.
}

@export var mode: Mode = Mode.LERP

## HERMITE / PREDICTED only: name of the companion velocity field on the same
## schema. Must be a Vector3 field. Predictor reads from_state.<velocity_field>
## and to_state.<velocity_field> at runtime.
@export var velocity_field: StringName = &""

## PREDICTED only: constant world-space acceleration applied during dead-reckon.
##   Vector3(0, -9.8, 0) → ballistic projectile (grenade, dropped item).
##   Vector3.ZERO → vehicle / drone / anything player-controlled.
## Ignored by other modes.
@export var acceleration: Vector3 = Vector3.ZERO

## PREDICTED only: exponential lerp rate (per second) when correcting the
## rendered position toward freshly arrived snapshots. ~8.0 = half-life 87 ms,
## softer corrections — good for ballistic where prediction is close to truth.
## ~12–16 → snappier — better for player-controlled vehicles where direction
## can change mid-segment. Ignored by other modes.
@export var correction_rate: float = 8.0
