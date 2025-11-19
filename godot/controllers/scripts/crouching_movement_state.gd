extends MovementState

@export var SPEED := 3.0
@export var ACCELERATION := 0.15
@export var DECELERATION := 0.3
@export var TOGGLE_CROUCH := false
@export_range(1, 6, 0.1) var CROUCH_SPEED := 4.0
@export_range(1, 6, 0.1) var UNCROUCH_SPEED := 6.0

@onready var CROUCH_SHAPECAST := %CrouchShapeCast3D

var _prev_crouch_input: bool = true
var _wants_uncrouch := false

func logic_enter() -> void:
	player.set_parameters(SPEED, ACCELERATION, DECELERATION)
	_prev_crouch_input = true
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
	if TOGGLE_CROUCH and player.current_frame_input.crouch and !_prev_crouch_input:
		_wants_uncrouch = !_wants_uncrouch
	elif !TOGGLE_CROUCH:
		_wants_uncrouch = !player.current_frame_input.crouch
	_prev_crouch_input = player.current_frame_input.crouch

	if !_wants_uncrouch or CROUCH_SHAPECAST.is_colliding():
		return
	
	transition.emit("IdleMovementState")


func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
