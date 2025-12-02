extends MovementState

@export var SPEED := 5.0
@export var ACCELERATION := 0.1
@export var DECELERATION := 0.25
@export var TOP_ANIM_SPEED := 2.2

var TOP_SPEED_SQ: float:
	get: return SPEED * SPEED

func logic_enter() -> void:
	player.set_parameters(SPEED, ACCELERATION, DECELERATION)


func visual_enter() -> void:
	animation_player.play(&"Walk", -1, 1.0)


func logic_physics(delta: float) -> void:
	player.update_gravity(delta, Enums.IntegrationContext.GAME)
	player.update_movement(Enums.IntegrationContext.GAME)
	player.update_velocity(Enums.IntegrationContext.GAME)


func logic_transitions() -> void:
	#print("w x: %f, z: %f" % [player.game_velocity.x, player.game_velocity.z])
	if is_zero_approx(player.game_velocity.x) and is_zero_approx(player.game_velocity.z):
		transition.emit("IdleMovementState")

	if player.input.is_sprinting():
		transition.emit("SprintMovementState")

	if player.input.is_crouching():
		transition.emit("CrouchMovementState")

	if player.input.is_jump_just_pressed() and player.on_floor(Enums.IntegrationContext.GAME):
		transition.emit("JumpMovementState")


func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
	_set_animation_speed(player.velocity.length_squared())


func _set_animation_speed(speed_sq: float) -> void:
	var alpha = remap(speed_sq, 0.0, TOP_SPEED_SQ, 0.0, 1.0)
	animation_player.speed_scale = lerp(0.0, TOP_ANIM_SPEED, alpha)
