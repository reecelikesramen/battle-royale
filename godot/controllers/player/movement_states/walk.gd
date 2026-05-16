extends MovementState

@export var SPEED := 5.0
@export var ACCELERATION := 45.0
@export var TOP_ANIM_SPEED := 2.2

var TOP_SPEED_SQ: float:
	get: return SPEED * SPEED

func logic_enter() -> void:
	player.set_parameters(SPEED, ACCELERATION)


func visual_enter() -> void:
	animation_tree.set("parameters/Movement/transition_request", "Idle")
	camera_animation_player.play(&"Walk")


func logic_physics(delta: float) -> void:
	player.update_gravity(delta)
	player.update_movement(delta)
	player.update_velocity()


func logic_transitions() -> void:
	if not player.on_floor():
		transition.emit(&"FallMovementState")
		return

	if is_zero_approx(player.velocity.x) and is_zero_approx(player.velocity.z):
		transition.emit(&"IdleMovementState")

	if player.input.is_sprinting_forward():
		transition.emit(&"SprintMovementState")

	# walk_mode off = return to default Run.
	if not player.input.is_walk_mode():
		transition.emit(&"RunMovementState")

	if player.input.is_crouching():
		transition.emit(&"CrouchMovementState")

	if player.input.is_jump_just_pressed() and player.on_floor():
		transition.emit(&"JumpMovementState")

	if player.input.is_prone_just_pressed():
		transition.emit(&"ProneMovementState")


func visual_physics(_delta: float) -> void:
	_set_animation_speed(player.velocity.length_squared())


func _set_animation_speed(speed_sq: float) -> void:
	var alpha = remap(speed_sq, 0.0, TOP_SPEED_SQ, 0.0, 1.0)
	camera_animation_player.speed_scale = lerp(0.0, TOP_ANIM_SPEED, alpha)
