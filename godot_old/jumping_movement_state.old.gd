extends MovementState

@export var SPEED := 5.0
@export var ACCELERATION := 0.05
@export var DECELERATION := 0.025
@export var JUMP_VELOCITY := 4.5

func enter():
	player.set_parameters(SPEED, ACCELERATION, DECELERATION)
	if ctx == Enums.IntegrationContext.VISUAL:
		player.velocity.y += JUMP_VELOCITY
		animation_player.pause()
	else:
		player.game_velocity.y += JUMP_VELOCITY


func exit():
	if ctx == Enums.IntegrationContext.VISUAL:
		animation_player.speed_scale = 1.0


# TODO: on floor for game state as well
func physics_update(delta: float):
	player.update_gravity(delta, ctx)
	player.update_movement(ctx)
	player.update_velocity(ctx)
	
	if player.on_floor(ctx):
		transition.emit("IdleMovementState")
