extends State

@export var player: FPSController
@export var animation_player: AnimationPlayer
@export var TOP_ANIM_SPEED: float = 2.2

func enter():
	animation_player.play("Walking", -1, 1.0)

func physics_update(_delta: float):
	set_animation_speed(player.velocity.length())
	if is_zero_approx(player.velocity.length_squared()):
		transition.emit("IdleMovementState")

func set_animation_speed(speed: float):
	var alpha = remap(speed, 0.0, player.SPEED, 0.0, 1.0)
	animation_player.speed_scale = lerp(0.0, TOP_ANIM_SPEED, alpha)
