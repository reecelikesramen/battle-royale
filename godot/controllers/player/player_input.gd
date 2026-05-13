class_name PlayerInput extends NetCommand

# Per-tick player input. Mirrors the field shape of PlayerInputPacket so Phase
# 5/6 can swap to a schema-driven codec without changing the input-gathering
# surface. Edge helpers (`is_jump_just_pressed` etc.) live on
# PlayerInputContext, which wraps two consecutive frames.

@export var sequence_id: int = 0
@export var timestamp_us: int = 0

@export var move_forward_backward: float = 0.0
@export var move_left_right: float = 0.0
@export var look_abs: Vector2 = Vector2.ZERO

@export var jump: bool = false
@export var crouch: bool = false
@export var sprint: bool = false
@export var prone: bool = false

@export var peek_left_right: float = 0.0
