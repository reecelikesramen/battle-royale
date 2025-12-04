extends MovementState

@export var SPEED := 1.8
@export var ACCELERATION := 0.3
@export var DECELERATION := 0.5
@export_range(0.5, 6, 0.1) var PRONE_SPEED := 1.5
@export_range(0.5, 6, 0.1) var UNPRONE_SPEED := 0.8

const PRONE_ANIM := &"Prone2"
const RESET_ANIM := &"RESET"

var _wants_to_unprone := false
var _progress := 0.0
var _prone_anim_length := 0.0
var _last_toggle_time := 0

var _crouch_shapecast: ShapeCast3D:
	get: return player.crouch_shapecast

func _ready() -> void:
	await player.ready
	var anim := animation_player.get_animation(PRONE_ANIM)
	if anim:
		_prone_anim_length = anim.length


func logic_enter() -> void:
	player.set_parameters(SPEED, ACCELERATION, DECELERATION)
	if not player._test_is_replaying:
		_last_toggle_time = Time.get_ticks_usec()
		_wants_to_unprone = false
		_progress = 0.0


func visual_enter() -> void:
	if is_remote_player:
		animation_player.play(PRONE_ANIM, -1, PRONE_SPEED)


func logic_physics(delta: float) -> void:
	player.update_gravity(delta, Enums.IntegrationContext.GAME)
	player.update_movement(Enums.IntegrationContext.GAME)
	player.update_velocity(Enums.IntegrationContext.GAME)
	
	if player._test_is_replaying:
		return
	
	if _wants_to_unprone and not _crouch_shapecast.is_colliding():
		_progress -= delta * UNPRONE_SPEED
	else:
		_progress += delta * PRONE_SPEED
	
	_progress = clampf(_progress, 0.0, _prone_anim_length)
	if player.is_authority: print("progress: ", _progress, " ", _wants_to_unprone)


func logic_transitions() -> void:
	if player.input.is_prone_just_pressed() and _toggle_debounce_us() > 50_000:
		_last_toggle_time = Time.get_ticks_usec()
		_wants_to_unprone = !_wants_to_unprone
		if player.is_authority: print("test")

	if _wants_to_unprone and _progress <= 0.0:
		# Block uncrouch if hitting ceiling
		if _crouch_shapecast and _crouch_shapecast.is_colliding():
			return
			
		transition.emit(&"IdleMovementState")


func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
		
		# Sync animation to logic progress
		if animation_player.current_animation != PRONE_ANIM:
			animation_player.play(PRONE_ANIM)
		animation_player.seek(_progress, true)


func visual_exit() -> void:
	if animation_player.has_animation(RESET_ANIM):
		animation_player.play(RESET_ANIM)
	else:
		animation_player.stop()
	animation_player.speed_scale = 1.0


func _toggle_debounce_us() -> int:
	return Time.get_ticks_usec() - _last_toggle_time
