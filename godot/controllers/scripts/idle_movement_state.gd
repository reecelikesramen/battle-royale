extends State

@export var player: FPSController
@export var animation_player: AnimationPlayer

func enter():
	animation_player.pause()

func physics_update(_delta: float):
	if !is_zero_approx(player.velocity.length_squared()) and player.is_on_floor():
		transition.emit("WalkingMovementState")
