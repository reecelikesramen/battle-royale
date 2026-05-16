extends MovementState

func visual_enter() -> void:
	animation_tree.set("parameters/Movement/transition_request", "Idle")
	camera_animation_player.stop()


func logic_physics(delta: float) -> void:
	player.update_gravity(delta)
	player.update_movement(delta)
	player.update_velocity()


func logic_transitions() -> void:
	if not player.on_floor():
		transition.emit(&"FallMovementState")
		return

	if !is_zero_approx(player.velocity.x) or !is_zero_approx(player.velocity.z):
		# Run is the default ground locomotion. Walk on toggle, Sprint on hold.
		if player.input.is_sprinting_forward():
			transition.emit(&"SprintMovementState")
		elif player.input.is_walk_mode():
			transition.emit(&"WalkMovementState")
		else:
			transition.emit(&"RunMovementState")

	if player.input.is_jump_just_pressed():
		transition.emit(&"JumpMovementState")

	if player.input.is_crouching():
		transition.emit(&"CrouchMovementState")

	if player.input.is_prone_just_pressed():
		transition.emit(&"ProneMovementState")


func visual_physics(_delta: float) -> void:
	pass
