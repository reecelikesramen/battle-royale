class_name NetInterp extends RefCounted

# Interpolation helpers for snapshot-driven entity rendering.
#
# Performance: hermite_vec3 is ~21 float ops per call. Run on a few hundred
# entities per frame at 60Hz this is well under a millisecond — keeping it in
# GDScript is fine. Only worth porting to Rust if it appears in a per-vertex /
# per-particle hot path, which isn't the case for snapshot interpolation.


# Cubic Hermite interpolation between two endpoints with explicit velocities.
#   p0, p1: endpoint positions (m)
#   v0, v1: endpoint velocities (m/s) at the same instants as p0 / p1
#   t:      [0, 1] alpha along the segment
#   dt:     wall-time the segment covers (s) — the real arrival delta between
#           the two samples (`InterpolationPair.segment_s` from the ring buffer)
#
# Tangents are weighted by `dt` so velocity contributes in correct units.
# Reduces visual jaggedness on ballistic / accelerating proxies vs naive lerp,
# because the curve carries the actual instantaneous direction at each end.
static func hermite_vec3(p0: Vector3, v0: Vector3, p1: Vector3, v1: Vector3, t: float, dt: float) -> Vector3:
	var t2: float = t * t
	var t3: float = t2 * t
	var h00: float = 2.0 * t3 - 3.0 * t2 + 1.0
	var h10: float = t3 - 2.0 * t2 + t
	var h01: float = -2.0 * t3 + 3.0 * t2
	var h11: float = t3 - t2
	return h00 * p0 + h10 * (v0 * dt) + h01 * p1 + h11 * (v1 * dt)
