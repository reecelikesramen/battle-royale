extends MovementState

@export var SPEED := 3.0
@export var ACCELERATION := 0.15
@export var DECELERATION := 0.3
@export var TOGGLE_CROUCH := false
@export_range(1, 6, 0.1) var CROUCH_SPEED := 4.0
@export_range(1, 6, 0.1) var UNCROUCH_SPEED := 6.0

var _crouch_shapecast: ShapeCast3D:
	get: return player.crouch_shapecast

var _wants_uncrouch := false

func logic_enter() -> void:
	player.set_parameters(SPEED, ACCELERATION, DECELERATION)
	_wants_uncrouch = false


func visual_enter() -> void:
	animation_player.speed_scale = 1.0
	animation_player.play("Crouch", -1, CROUCH_SPEED)


func visual_exit() -> void:
	animation_player.speed_scale = 1.0
	animation_player.play("Crouch", -1, -UNCROUCH_SPEED, true)
	await animation_player.animation_finished


func logic_physics(delta: float) -> void:
	player.update_gravity(delta, Enums.IntegrationContext.GAME)
	player.update_movement(Enums.IntegrationContext.GAME)
	player.update_velocity(Enums.IntegrationContext.GAME)


func logic_transitions() -> void:
	if TOGGLE_CROUCH and player.input.is_crouch_just_pressed():
		_wants_uncrouch = !_wants_uncrouch
	elif !TOGGLE_CROUCH:
		_wants_uncrouch = !player.input.is_crouching()

	if !_wants_uncrouch or _crouch_shapecast.is_colliding():
		return
	
	transition.emit("IdleMovementState")


func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
