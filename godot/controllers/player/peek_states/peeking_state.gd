extends PeekState

const LEFT_ANIM := &"PeekLeft"
const RIGHT_ANIM := &"PeekRight"
const RESET_ANIM := &"RESET"

## Negative = left peek, positive = right peek, 0 = centered
## Range: [-anim_length, +anim_length]
var progress := 0.0

var _peek_anim_length := 0.0


func _ready() -> void:
	await player.ready
	var anim := animation_player.get_animation(LEFT_ANIM)
	if anim:
		_peek_anim_length = anim.length


func logic_enter() -> void:
	if not player.is_replaying_inputs:
		progress = 0.0


func visual_exit() -> void:
	if animation_player.has_animation(RESET_ANIM):
		animation_player.play(RESET_ANIM)
	else:
		animation_player.stop()
	animation_player.speed_scale = 1.0


func logic_physics(delta: float) -> void:
	if player.is_replaying_inputs:
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
	if %MovementStateMachine.current_state not in [&"IdleMovementState", &"CrouchMovementState", &"WalkMovementState"]:
		transition.emit(&"NotPeekState")
		return
	
	if player.game_velocity.length() > MAX_VELOCITY:
		transition.emit(&"NotPeekState")
		return
	
	# Only exit when centered and no input
	if absf(progress) < 0.001 and _target_direction() == 0:
		transition.emit(&"NotPeekState")


func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(delta, Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
	
	# Direction derived from progress sign - works for remote clients
	var anim_name := LEFT_ANIM if progress < 0 else RIGHT_ANIM
	if animation_player.current_animation != anim_name:
		animation_player.play(anim_name)
	animation_player.seek(absf(progress), true)


func _target_direction() -> int:
	if player.input.is_peeking_left():
		return -1
	if player.input.is_peeking_right():
		return 1
	return 0
