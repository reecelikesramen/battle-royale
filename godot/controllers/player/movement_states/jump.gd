extends MovementState

@export var SPEED := 5.0
@export var ACCELERATION := 0.05
@export var DECELERATION := 0.025
@export var JUMP_VELOCITY := 4.5

var _enter_time := -1

func logic_enter() -> void:
	player.set_parameters(SPEED, ACCELERATION, DECELERATION)
	player.game_velocity.y += JUMP_VELOCITY
	_enter_time = Time.get_ticks_usec()


func visual_enter() -> void:
	if !is_remote_player and player.input.is_jump_just_pressed():
		player.velocity.y += JUMP_VELOCITY
	animation_player.pause()


func visual_exit() -> void:
	animation_player.speed_scale = 1.0


func logic_physics(delta: float) -> void:
	player.update_gravity(delta, Enums.IntegrationContext.GAME)
	player.update_movement(Enums.IntegrationContext.GAME)
	player.update_velocity(Enums.IntegrationContext.GAME)


func logic_transitions() -> void:
	var enough_time := Time.get_ticks_usec() - _enter_time > 100_000
	if enough_time and player.on_floor(Enums.IntegrationContext.GAME):
		transition.emit("IdleMovementState")
	

func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
