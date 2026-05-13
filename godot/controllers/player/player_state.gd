class_name PlayerState extends NetState

# Predicted state snapshot for a player. Mirrors the field shape of
# PlayerStatePacket (the current Rust wire packet) so Phase 5/6 can swap to a
# schema-driven codec without changing the simulation surface.

@export var pos: Vector3 = Vector3.ZERO
@export var velocity: Vector3 = Vector3.ZERO
@export var look: Vector2 = Vector2.ZERO

@export var movement_state: int = 0
@export var peek_state: int = 0

@export var crouch_progress: float = 0.0
@export var prone_progress: float = 0.0
@export var peek_progress: float = 0.0
