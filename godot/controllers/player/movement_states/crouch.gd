extends MovementState

@export var SPEED := 3.0
@export var CROUCH_RUN_SPEED := 4.0
@export var ACCELERATION := 50.0
@export_range(1, 6, 0.1) var CROUCH_SPEED := 4.0
@export_range(1, 6, 0.1) var UNCROUCH_SPEED := 6.0

const CROUCH_ANIM := &"Crouch"
const RESET_ANIM := &"RESET"
const UNCROUCH_FALL_DISTANCE := 2.0

var progress := 0.0

var _wants_to_uncrouch := false
var _prev_wants_to_uncrouch := false
var _crouch_anim_length := 0.0

# Debug: track progress observed by logic vs visual sides to spot rubber-band.
var _dbg_last_logic_progress := -1.0
var _dbg_last_visual_progress := -1.0

var _crouch_shapecast: ShapeCast3D:
	get: return player.crouch_shapecast

func _ready() -> void:
	await owner.ready
	var anim := animation_player.get_animation(CROUCH_ANIM)
	if anim:
		_crouch_anim_length = anim.length


func logic_enter() -> void:
	player.set_parameters(SPEED, ACCELERATION)
	# Reset on fresh entry. During replay (is_replaying_inputs=true), skip so a
	# replayed transition can resume mid-crouch from the snapshot's progress —
	# which _load_simulation_state restored on the state node before replay started.
	if not player.is_replaying_inputs:
		# Coming from prone, you're already below crouch height — skip the
		# crouch-down anim and start at full crouch so the visual blends prone->crouch
		# directly via AnimationTree's Movement transition.
		if previous_state != null and previous_state.name == &"ProneMovementState":
			progress = _crouch_anim_length
		else:
			progress = 0.0
		_wants_to_uncrouch = false
		_prev_wants_to_uncrouch = false
		# Fresh crouch (not a replay) — bump tiredness for the down-transition.
		# Standing-up edge in logic_transitions bumps again for the up-transition.
		player.bump_tiredness("crouch_enter")
	#if player.is_authority:
		#print("[CR-ENTER f=%d] replay=%s progress=%.4f wants_uncrouch=%s" % [
				#Engine.get_physics_frames(), player.is_replaying_inputs, progress, _wants_to_uncrouch])


func visual_enter() -> void:
	animation_tree.set("parameters/Movement/transition_request", "Crouch")
	camera_animation_player.stop()


func visual_exit() -> void:
	# Crouch's last visual_physics fires one frame before the Idle transition,
	# leaving TimeSeek at ~0.05. Reset here so the Crouch→Idle AnimationTree
	# blend starts from the standing pose, not a mid-uncrouch frame.
	animation_tree.set("parameters/CrouchTimeSeek/seek_request", 0.0)
	_dbg_last_visual_progress = 0.0
	_dbg_last_logic_progress = -1.0


func logic_physics(delta: float) -> void:
	# Speed gate: holding sprint while crouched = crouch-run (PUBG-style).
	# Set BEFORE update_movement so the new top speed applies this tick.
	var target_speed := CROUCH_RUN_SPEED if player.input.is_sprinting() else SPEED
	player.set_parameters(target_speed, ACCELERATION)

	player.update_gravity(delta)
	player.update_movement(delta)
	player.update_velocity()

	if player.is_replaying_inputs:
		return
	
	var slowdown: float = player.tiredness_slowdown()
	var step: float
	if _wants_to_uncrouch and not _crouch_shapecast.is_colliding():
		step = -delta * UNCROUCH_SPEED / slowdown
	else:
		step = delta * CROUCH_SPEED / slowdown
	var prev_progress: float = progress
	progress += step
	progress = clampf(progress, 0.0, _crouch_anim_length)
	# Freeze tiredness throughout the crouch state so the peak slowdown
	# actually persists through the transition. State-exit + 0.25s lets decay
	# resume after stood-up.
	if not player.is_replaying_inputs:
		# Only freeze tiredness while actively animating (progress strictly between
		# 0 and max). At either terminal we let the 0.25s hold from tiredness_hold_peak
		# expire so decay can start.
		var animating: bool = progress > 0.0 and progress < _crouch_anim_length
		if animating:
			player.tiredness_refresh_hold()
		# Loud markers at exact peak boundaries — these push a fresh 0.25s hold
		# that runs out and lets decay take over at the terminal pose.
		if step > 0.0 and prev_progress < _crouch_anim_length and progress >= _crouch_anim_length:
			player.tiredness_hold_peak("full_crouch")
		elif step < 0.0 and prev_progress > 0.0 and progress <= 0.0:
			player.tiredness_hold_peak("crouch_stood_up")
	if player.TIREDNESS_DEBUG and player.is_authority:
		print("[TIRED crouch] tired=%.3f  slowdown=%.2fx  step=%+.4f  progress=%.3f  want_un=%s" % [
				player.current_tiredness(), slowdown, step, progress, _wants_to_uncrouch])
		
	
	progress = clampf(progress, 0.0, _crouch_anim_length)
	#if player.is_authority:
		## Backward jump while crouching (shouldn't happen).
		#if _dbg_last_logic_progress > 0.001 and progress < _dbg_last_logic_progress - 0.001 and not _wants_to_uncrouch:
			#print("[CR-LOG-BACK f=%d] %.4f -> %.4f (uncrouch=%s)" % [
					#Engine.get_physics_frames(), _dbg_last_logic_progress, progress, _wants_to_uncrouch])
		## Forward jump while uncrouching = shapecast blocked the uncrouch step.
		## This causes visible oscillation because progress yo-yos around the blocked point.
		#if _dbg_last_logic_progress >= 0.0 and _wants_to_uncrouch and progress > _dbg_last_logic_progress + 0.001:
			#print("[CR-LOG-BLOCKED f=%d] shapecast blocked uncrouch: %.4f -> %.4f (colliding=%s)" % [
					#Engine.get_physics_frames(), _dbg_last_logic_progress, progress,
					#_crouch_shapecast.is_colliding() if _crouch_shapecast else "null"])
		#_dbg_last_logic_progress = progress


func logic_transitions() -> void:
	_wants_to_uncrouch = !player.input.is_crouching()

	# TODO: make work with crouch jump
	if not player.on_floor() and player.global_position.y < player.last_grounded_height - UNCROUCH_FALL_DISTANCE:
		_wants_to_uncrouch = true

	# Rising-edge bump: when the player commits to standing back up, fatigue
	# accumulates again so the up-transition slows down too. Suppressed during
	# replay so the bump stays deterministic with the original tick.
	if _wants_to_uncrouch and not _prev_wants_to_uncrouch and not player.is_replaying_inputs:
		player.bump_tiredness("uncrouch_edge")
	_prev_wants_to_uncrouch = _wants_to_uncrouch

	# Direct crouch -> prone (skip uncrouch path).
	if player.input.is_prone_just_pressed():
		transition.emit(&"ProneMovementState")
		return

	# Jump from crouch: ceiling-blocked stays blocked, otherwise jump and
	# auto-stand on landing (Jump._land_target gates on is_crouching()).
	if player.input.is_jump_just_pressed() and player.on_floor():
		if not (_crouch_shapecast and _crouch_shapecast.is_colliding()):
			transition.emit(&"JumpMovementState")
			return

	if _wants_to_uncrouch and progress <= 0.0:
		# Block uncrouch if hitting ceiling
		if _crouch_shapecast and _crouch_shapecast.is_colliding():
			return

		transition.emit(&"IdleMovementState")


func visual_physics(_delta: float) -> void:
	# Sync animation to logic progress via TimeSeek
	animation_tree.set("parameters/CrouchTimeSeek/seek_request", progress)
	#if player.is_authority:
		## Detect visual reading a smaller progress than last visual tick (rubber-band).
		#if _dbg_last_visual_progress > 0.001 and progress < _dbg_last_visual_progress - 0.001 and not _wants_to_uncrouch:
			#print("[CR-VIS-BACK f=%d] visual progress went %.4f -> %.4f (uncrouch=%s)" % [
					#Engine.get_physics_frames(), _dbg_last_visual_progress, progress, _wants_to_uncrouch])
		## Detect divergence between visual.progress and logic.progress within same frame.
		#if absf(progress - _dbg_last_logic_progress) > 0.0005:
			#print("[CR-DIV f=%d] visual.progress=%.4f differs from logic.progress=%.4f (delta=%.4f)" % [
					#Engine.get_physics_frames(), progress, _dbg_last_logic_progress, progress - _dbg_last_logic_progress])
		#_dbg_last_visual_progress = progress
