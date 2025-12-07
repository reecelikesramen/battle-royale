extends MovementState

@export var SPEED := 1.8
@export var ACCELERATION := 20.0
@export_range(0.5, 6, 0.1) var PRONE_SPEED := 1.5
@export_range(0.5, 6, 0.1) var UNPRONE_SPEED := 0.8

const PRONE_ANIM := &"Prone2"
const RESET_ANIM := &"RESET"
const JUMP_PRONE_MODIFIER := 2.0

var progress := 0.0

var _wants_to_unprone := false
var _prone_anim_length := 0.0
var _last_toggle_time := 0
var _modifier := 1.0

var _crouch_shapecast: ShapeCast3D:
	get: return player.crouch_shapecast

func _ready() -> void:
	await player.ready
	var anim := animation_player.get_animation(PRONE_ANIM)
	if anim:
		_prone_anim_length = anim.length


func logic_enter() -> void:
	player.set_parameters(SPEED, ACCELERATION)
	_modifier = JUMP_PRONE_MODIFIER if previous_state.name == &"JumpMovementState" else 1.0
	if not player.is_replaying_inputs:
		_last_toggle_time = Time.get_ticks_usec()
		_wants_to_unprone = false
		progress = 0.0


func visual_enter() -> void:
	animation_tree.set("parameters/Movement/transition_request", "Prone")
	camera_animation_player.stop()


func logic_physics(delta: float) -> void:
	player.update_gravity(delta, Enums.IntegrationContext.GAME)
	player.update_movement(delta, Enums.IntegrationContext.GAME)
	player.update_velocity(Enums.IntegrationContext.GAME)
	
	if player.is_replaying_inputs:
		return
	
	if _wants_to_unprone and not _crouch_shapecast.is_colliding():
		progress -= delta * UNPRONE_SPEED
	else:
		progress += delta * PRONE_SPEED * _modifier
	
	progress = clampf(progress, 0.0, _prone_anim_length)
	#if player.is_authority`: print("progress: ", progress, " ", _wants_to_unprone)


func logic_transitions() -> void:
	if player.input.is_prone_just_pressed() and _toggle_debounce_us() > 50_000:
		_last_toggle_time = Time.get_ticks_usec()
		_wants_to_unprone = !_wants_to_unprone
	
	# TODO: make work with jump prone
	if not player.on_floor(Enums.IntegrationContext.GAME):
		_wants_to_unprone = true

	if _wants_to_unprone and progress <= 0.0:
		# Block uncrouch if hitting ceiling
		if _crouch_shapecast and _crouch_shapecast.is_colliding():
			return
			
		transition.emit(&"IdleMovementState")


func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(delta, Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
		
	# Sync animation to logic progress via TimeSeek
	animation_tree.set("parameters/ProneTimeSeek/seek_request", progress)


func _toggle_debounce_us() -> int:
	return Time.get_ticks_usec() - _last_toggle_time
