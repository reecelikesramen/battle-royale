class_name NetPredictor extends Node

# Phase 3: pure data container for prediction state. Player controller still
# drives physics + reconcile; this just owns the queues, shadow state, and
# tunables so the player script can shrink. Phase 4 introduces typed Resources
# and pulls the simulate/apply hooks into here.

# Identity. Set by the owning controller before/while adding as child.
var owner_id: int = -1

# Authority + replay flags read by states & systems.
var is_replaying_inputs: bool = false

# Networking data structures.
var server_input_queue := JitterBuffer.new()
var player_state_buffer := SequenceRingBuffer.new()
var input_sequence := PacketSequence.new()
var unacked_inputs := SequenceRingBuffer.new()

# Input redundancy: client sends the last N inputs each tick so a single
# packet loss is recovered by the next tick's send. Server JitterBuffer
# dedupes by sequence_id.
const INPUT_REDUNDANCY: int = 3
var input_redundancy_ring: Array[PlayerInputPacket] = []

# Server-authoritative shadow state. Player simulates two parallel
# integrations: VISUAL (smoothed for camera) and GAME (authoritative).
var game_transform: Transform3D = Transform3D()
var game_position: Vector3:
	get: return game_transform.origin
	set(value): game_transform.origin = value
var game_velocity := Vector3.ZERO
var game_movement_state_id: int = 0
var game_sequence_id: int = 65535

# Reconciliation tunables. Phase 5 will move these to a NetSchema .tres.
var SNAP_THRESHOLD_HORIZONTAL: float = 1.5
var SNAP_THRESHOLD_VERTICAL: float = 2.5
var CORRECTION_RATE_HORIZONTAL: float = 8.0
var CORRECTION_RATE_VERTICAL: float = 4.0
var POSITION_CORRECTION_DEADBAND_HORIZONTAL: float = 0.07
var POSITION_CORRECTION_DEADBAND_VERTICAL: float = 0.15
var VELOCITY_CORRECTION_THRESHOLD: float = 1.5
var VELOCITY_CORRECTION_RATE: float = 12.0
var VELOCITY_CORRECTION_DEADBAND: float = 0.2


## Framerate-independent correction alpha:
## error scaled to [0, 1] within (deadband, snap_threshold], then run through
## the exponential smoothing 1 - exp(-rate * dt * scaled_error).
func correction_alpha(
	delta: float,
	error_mag: float,
	snap_threshold: float,
	rate: float,
	deadband: float) -> float:
	if error_mag <= deadband:
		return 0.0

	var normalized: float = clamp(
		(error_mag - deadband) / max(snap_threshold - deadband, 0.001),
		0.0,
		1.0
	)
	return 1.0 - exp(-rate * delta * normalized)
