extends MovementState

@export var SPEED := 3.5
@export var ACCELERATION := 5.0
@export var JUMP_VELOCITY := 4.5

var _enter_time := -1

func logic_enter() -> void:
	# Cap target at the previous ground speed so walk-jump (2.0) doesn't get
	# bumped up to 3.5. Sprint/run still clamp to 3.5 — momentum above the cap is
	# preserved by low AIR_FRICTION rather than by raising the wish-dir target.
	player.set_parameters(minf(SPEED, player._speed), ACCELERATION)
	player.velocity.y += JUMP_VELOCITY
	_enter_time = Time.get_ticks_usec()


func visual_enter() -> void:
	animation_tree.set("parameters/Movement/transition_request", "Jump")
	camera_animation_player.stop()


func logic_physics(delta: float) -> void:
	player.update_gravity(delta)
	player.update_movement(delta)
	player.update_velocity()


func logic_transitions() -> void:
	var enough_time := Time.get_ticks_usec() - _enter_time > 100_000
	if enough_time and player.on_floor():
		transition.emit(_land_target())

	if player.input.is_prone_just_pressed():
		transition.emit(&"ProneMovementState")

	if player.global_position.y < player.last_grounded_height:
		transition.emit(&"FallMovementState")


func _land_target() -> StringName:
	if player.input.is_crouching():
		return &"CrouchMovementState"
	var moving := !is_zero_approx(player.velocity.x) or !is_zero_approx(player.velocity.z)
	if not moving:
		return &"IdleMovementState"
	if player.input.is_sprinting_forward():
		return &"SprintMovementState"
	if player.input.is_walk_mode():
		return &"WalkMovementState"
	return &"RunMovementState"


func visual_physics(_delta: float) -> void:
	pass
