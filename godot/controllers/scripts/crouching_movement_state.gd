extends MovementState

@export var SPEED := 3.0
@export var ACCELERATION := 0.15
@export var DECELERATION := 0.3
@export var TOGGLE_CROUCH := false
@export_range(1, 6, 0.1) var CROUCH_SPEED := 4.0
@export_range(1, 6, 0.1) var UNCROUCH_SPEED := 6.0

const STATE_IDLE := &"IdleMovementState"
const STATE_WALK := &"WalkingMovementState"
const STATE_SPRINT := &"SprintingMovementState"
const STATE_JUMP := &"JumpingMovementState"
const CROUCH_ANIM := &"Crouch"
const RESET_ANIM := &"RESET"

var _wants_to_uncrouch := false
var _progress := 0.0
var _crouch_anim_length := 0.0
var _last_toggle_time := 0

var _crouch_shapecast: ShapeCast3D:
	get: return player.crouch_shapecast

func _ready() -> void:
	await owner.ready
	var anim := animation_player.get_animation(CROUCH_ANIM)
	if anim:
		_crouch_anim_length = anim.length

func logic_enter() -> void:
	player.set_parameters(SPEED, ACCELERATION, DECELERATION)
	_wants_to_uncrouch = false
	_progress = 0.0

func logic_exit() -> void:
	_wants_to_uncrouch = false

func visual_enter() -> void:
	if is_remote_player:
		animation_player.play(CROUCH_ANIM)

func logic_physics(delta: float) -> void:
	player.update_gravity(delta, Enums.IntegrationContext.GAME)
	player.update_movement(Enums.IntegrationContext.GAME)
	player.update_velocity(Enums.IntegrationContext.GAME)
	
	if _wants_to_uncrouch and not _crouch_shapecast.is_colliding():
		_progress -= delta * UNCROUCH_SPEED
	else:
		_progress += delta * CROUCH_SPEED
	
	_progress = clampf(_progress, 0.0, _crouch_anim_length)

func logic_transitions() -> void:
	if TOGGLE_CROUCH:
		if player.input.is_crouch_just_pressed() and _toggle_debounce_us() > 50_000:
			_last_toggle_time = Time.get_ticks_usec()
			_wants_to_uncrouch = !_wants_to_uncrouch
	else:
		_wants_to_uncrouch = !player.input.is_crouching()

	if _wants_to_uncrouch and _progress <= 0.0:
		# Block uncrouch if hitting ceiling
		if _crouch_shapecast and _crouch_shapecast.is_colliding():
			return
			
		var horizontal_speed_sq := Vector2(player.game_velocity.x, player.game_velocity.z).length_squared()
		if horizontal_speed_sq < 0.01:
			transition.emit(STATE_IDLE)
		elif player.input.is_sprinting():
			transition.emit(STATE_SPRINT)
		else:
			transition.emit(STATE_WALK)

func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
		
		# Sync animation to logic progress
		if animation_player.current_animation != CROUCH_ANIM:
			animation_player.play(CROUCH_ANIM)
		animation_player.seek(_progress, true)

func visual_exit() -> void:
	if animation_player.has_animation(RESET_ANIM):
		animation_player.play(RESET_ANIM)
	else:
		animation_player.stop()
	animation_player.speed_scale = 1.0


func _toggle_debounce_us() -> int:
	return Time.get_ticks_usec() - _last_toggle_time
