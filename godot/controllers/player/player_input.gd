@tool
class_name PlayerInput extends NetCommand

# Per-tick player input. Schema-driven; NetPredictor encodes/decodes via
# reflection against these @export fields. Infrastructure fields (sequence_id,
# timestamp_us, last_received_tick) live on NetCommandPacket and are stamped
# by the predictor — game code never touches them.
# Edge helpers (`is_jump_just_pressed` etc.) live on PlayerInputContext, which
# wraps two consecutive frames.

@export var move_forward_backward: float = 0.0
@export var move_left_right: float = 0.0
@export var look_abs: Vector2 = Vector2.ZERO

@export var jump: bool = false
@export var crouch: bool = false
@export var sprint: bool = false
@export var walk_mode: bool = false
@export var prone: bool = false

@export var peek_left_right: float = 0.0

@export var shoot: bool = false
@export var scope: bool = false
