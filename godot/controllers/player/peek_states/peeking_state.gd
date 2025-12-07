extends PeekState

const LEFT_ANIM := &"PeekLeft"
const RIGHT_ANIM := &"PeekRight"
const RESET_ANIM := &"RESET"

## Negative = left peek, positive = right peek, 0 = centered
## Range: [-anim_length, +anim_length]
var progress := 0.0

var _peek_anim_length := 0.0
var _force_unpeak := false


func _ready() -> void:
	await player.ready
	var anim := animation_player.get_animation(LEFT_ANIM)
	if anim:
		_peek_anim_length = anim.length


func logic_enter() -> void:
	if not player.is_replaying_inputs:
		progress = 0.0
		_force_unpeak = false


func visual_enter() -> void:
	animation_tree.set("parameters/Peeking/transition_request", "Peek")


func logic_physics(delta: float) -> void:
	if player.is_replaying_inputs:
		return
	
	# If forced to unpeak, always move toward center
	if _force_unpeak:
		_move_toward_center(delta)
		progress = clampf(progress, -_peek_anim_length, _peek_anim_length)
		return
	
	var target := _target_direction()
	var current_dir := signi(int(progress * 1000))  # sign with small epsilon handling
	
	# Determine if we should move toward target or back to center
	if target == 0:
		# No input - move toward center
		_move_toward_center(delta)
	elif current_dir == 0:
		# At center - move toward target
		_move_toward_target(delta, target)
	elif current_dir == target:
		# Same direction - continue peeking
		_move_toward_target(delta, target)
	else:
		# Opposite direction - must return to center first
		_move_toward_center(delta)
	
	progress = clampf(progress, -_peek_anim_length, _peek_anim_length)


func _move_toward_center(delta: float) -> void:
	if progress > 0:
		progress -= delta * UNPEEK_SPEED
		if progress < 0: progress = 0.0
	elif progress < 0:
		progress += delta * UNPEEK_SPEED
		if progress > 0: progress = 0.0


func _move_toward_target(delta: float, target: int) -> void:
	progress += delta * PEEK_SPEED * target


func logic_transitions() -> void:
	# Check if we need to force unpeak due to movement state or velocity
	if %MovementStateMachine.current_state not in [&"IdleMovementState", &"CrouchMovementState", &"WalkMovementState"]:
		_force_unpeak = true
	elif player.game_velocity.length() > MAX_VELOCITY:
		_force_unpeak = true
	elif _target_direction() == 0:
		_force_unpeak = true
	
	# Only transition when progress has wound down to center
	if _force_unpeak and absf(progress) < 0.001:
		transition.emit(&"NotPeekState")


func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(delta, Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
	
	# Set peek direction: -1.0 for left, 1.0 for right
	var add_amount := -1.0 if progress < 0 else 1.0
	animation_tree.set("parameters/Add Peek/add_amount", add_amount)
	animation_tree.set("parameters/PeekTimeSeek/seek_request", absf(progress))


func _target_direction() -> int:
	if player.input.is_peeking_left():
		return -1
	if player.input.is_peeking_right():
		return 1
	return 0
