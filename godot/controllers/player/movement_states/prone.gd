extends MovementState

@export var SPEED := 1.8
@export var ACCELERATION := 20.0
@export_range(0.5, 6, 0.1) var PRONE_SPEED := 1.5
@export_range(0.5, 6, 0.1) var UNPRONE_SPEED := 0.8

const PRONE_ANIM := &"Prone2"
const RESET_ANIM := &"RESET"
const JUMP_PRONE_MODIFIER := 2.0
const UNPRONE_FALL_DISTANCE := 2.0

var progress := 0.0

var _wants_to_unprone := false
var _prev_wants_to_unprone := false
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
	_modifier = JUMP_PRONE_MODIFIER if previous_state != null and previous_state.name == &"JumpMovementState" else 1.0
	if not player.is_replaying_inputs:
		_last_toggle_time = Time.get_ticks_usec()
		_wants_to_unprone = false
		_prev_wants_to_unprone = false
		# Coming from crouch, snap to full prone — player is already low.
		if previous_state != null and previous_state.name == &"CrouchMovementState":
			progress = _prone_anim_length
		else:
			progress = 0.0
		# Fresh prone (not a replay) — shares the tiredness pool with crouch.
		# Standing-up edge in logic_transitions bumps again for the up-transition.
		player.bump_tiredness("prone_enter")


func visual_enter() -> void:
	animation_tree.set("parameters/Movement/transition_request", "Prone")
	camera_animation_player.stop()


func logic_physics(delta: float) -> void:
	player.update_gravity(delta)
	player.update_movement(delta)
	player.update_velocity()

	if player.is_replaying_inputs:
		return
	
	var slowdown: float = player.tiredness_slowdown()
	var step: float
	if _wants_to_unprone and not _crouch_shapecast.is_colliding():
		step = -delta * UNPRONE_SPEED / slowdown
	else:
		step = delta * PRONE_SPEED * _modifier / slowdown
	var prev_progress: float = progress
	progress += step
	progress = clampf(progress, 0.0, _prone_anim_length)
	if not player.is_replaying_inputs:
		# Only freeze while actively animating. At terminal, let the 0.25s hold
		# from hold_peak expire so decay can resume.
		var animating: bool = progress > 0.0 and progress < _prone_anim_length
		if animating:
			player.tiredness_refresh_hold()
		if step > 0.0 and prev_progress < _prone_anim_length and progress >= _prone_anim_length:
			player.tiredness_hold_peak("full_prone")
		elif step < 0.0 and prev_progress > 0.0 and progress <= 0.0:
			player.tiredness_hold_peak("prone_stood_up")
	if player.TIREDNESS_DEBUG and player.is_local_view:
		print("[TIRED prone ] tired=%.3f  slowdown=%.2fx  step=%+.4f  progress=%.3f  want_un=%s" % [
				player.current_tiredness(), slowdown, step, progress, _wants_to_unprone])
	
	progress = clampf(progress, 0.0, _prone_anim_length)
	#if player.is_local_view`: print("progress: ", progress, " ", _wants_to_unprone)


func logic_transitions() -> void:
	# Direct prone -> crouch (skip going fully upright first).
	if player.input.is_crouch_just_pressed():
		transition.emit(&"CrouchMovementState")
		return

	if player.input.is_prone_just_pressed() and _toggle_debounce_us() > 50_000:
		_last_toggle_time = Time.get_ticks_usec()
		_wants_to_unprone = !_wants_to_unprone
		if player.TIREDNESS_DEBUG and player.is_local_view:
			print("[TIRED prone toggle] _wants_to_unprone=%s  prev=%s  progress=%.3f" % [
					_wants_to_unprone, _prev_wants_to_unprone, progress])

	# Jump from prone: doesn't actually jump, just unprones (stand up).
	if player.input.is_jump_just_pressed():
		_wants_to_unprone = true

	# TODO: make work with jump prone
	if not player.on_floor() and player.global_position.y < player.last_grounded_height - UNPRONE_FALL_DISTANCE:
		_wants_to_unprone = true

	# Rising-edge bump on starting to stand up (shared crouch/prone tiredness).
	if _wants_to_unprone and not _prev_wants_to_unprone and not player.is_replaying_inputs:
		player.bump_tiredness("unprone_edge")
	_prev_wants_to_unprone = _wants_to_unprone

	if _wants_to_unprone and progress <= 0.0:
		# Block uncrouch if hitting ceiling
		if _crouch_shapecast and _crouch_shapecast.is_colliding():
			return

		transition.emit(&"IdleMovementState")


func visual_physics(_delta: float) -> void:
	# Sync animation to logic progress via TimeSeek
	animation_tree.set("parameters/ProneTimeSeek/seek_request", progress)


func _toggle_debounce_us() -> int:
	return Time.get_ticks_usec() - _last_toggle_time
