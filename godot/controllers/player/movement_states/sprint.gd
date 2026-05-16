extends MovementState

@export var SPEED := 9.0
@export var ACCELERATION := 50.0
@export var TOP_ANIM_SPEED: float = 1.8
# Scales raw A/D input. 0.6 puts W+D travel angle around 59° off the lateral
# axis (≈31° off forward) instead of the unscaled 45°, so sprint strafing
# trades sideways speed for forward commitment.
@export var STRAFE_SCALE: float = 0.6

var TOP_SPEED_SQ: float:
	get: return SPEED * SPEED

func logic_enter() -> void:
	player.set_parameters(SPEED, ACCELERATION, STRAFE_SCALE)


func visual_enter() -> void:
	animation_tree.set("parameters/Movement/transition_request", "Idle")
	camera_animation_player.play(&"Sprint")


func logic_physics(delta: float) -> void:
	player.update_gravity(delta)
	player.update_movement(delta)
	player.update_velocity()


func logic_transitions() -> void:
	if not player.on_floor():
		transition.emit(&"FallMovementState")
		return

	if player.velocity.is_zero_approx():
		transition.emit(&"IdleMovementState")

	# Drop out of sprint if either shift released or forward input released. Sprint
	# is forward-only — sideways/backward strafing while holding shift falls back
	# to walk/run.
	if !player.input.is_sprinting_forward():
		if player.input.is_walk_mode():
			transition.emit(&"WalkMovementState")
		else:
			transition.emit(&"RunMovementState")

	if player.input.is_jump_just_pressed() and player.on_floor():
		transition.emit(&"JumpMovementState")

	if player.input.is_crouching():
		transition.emit(&"CrouchMovementState")

	if player.input.is_prone_just_pressed():
		transition.emit(&"ProneMovementState")


func visual_physics(_delta: float) -> void:
	_set_animation_speed(player.velocity.length_squared())


func _set_animation_speed(speed_sq: float) -> void:
	var alpha = remap(speed_sq, 0.0, TOP_SPEED_SQ, 0.0, 1.0)
	camera_animation_player.speed_scale = lerp(0.0, TOP_ANIM_SPEED, alpha)
