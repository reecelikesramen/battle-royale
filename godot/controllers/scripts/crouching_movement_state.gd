extends MovementState

@export var SPEED := 3.0
@export var ACCELERATION := 0.15
@export var DECELERATION := 0.3
@export var TOGGLE_CROUCH := false
@export_range(1, 6, 0.1) var CROUCH_SPEED := 4.0
@export_range(1, 6, 0.1) var UNCROUCH_SPEED := 6.0

@onready var CROUCH_SHAPECAST := %CrouchShapeCast3D

var _prev_crouch_input: bool = true
var _do_uncrouch := false


func enter():
	player.set_parameters(SPEED, ACCELERATION, DECELERATION)
	_prev_crouch_input = true
	_do_uncrouch = false
	if ctx == Enums.IntegrationContext.VISUAL:
		animation_player.speed_scale = 1.0
		animation_player.play("Crouch", -1, CROUCH_SPEED)


func exit():
	if is_remote_player:
		animation_player.speed_scale = 1.0
		print("exiting crouch state for remote player %s" % player.name)
		animation_player.play("Crouch", -1, -UNCROUCH_SPEED, true)
		await animation_player.animation_finished
		print("crouch state exited successfully")
		

func physics_update(delta: float):
	player.update_gravity(delta, ctx)
	player.update_movement(ctx)
	player.update_velocity(ctx)

	if TOGGLE_CROUCH and player.current_frame_input.crouch and !_prev_crouch_input:
		_do_uncrouch = !_do_uncrouch
	elif !TOGGLE_CROUCH:
		_do_uncrouch = !player.current_frame_input.crouch

	_prev_crouch_input = player.current_frame_input.crouch
	
	# TODO: crouch shapecast for game state as well
	if !_do_uncrouch or CROUCH_SHAPECAST.is_colliding():
		return
	
	if ctx == Enums.IntegrationContext.VISUAL:
		animation_player.play("Crouch", -1, -UNCROUCH_SPEED, true)
		if !animation_player.is_playing():
			return

	await animation_player.animation_finished

	transition.emit("IdleMovementState")
