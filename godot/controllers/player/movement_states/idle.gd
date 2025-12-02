extends MovementState

func visual_enter() -> void:
	animation_player.play(&"RESET")
	#animation_player.play("Idle")
	animation_player.pause()


func logic_physics(delta: float) -> void:
	player.update_gravity(delta, Enums.IntegrationContext.GAME)
	player.update_movement(Enums.IntegrationContext.GAME)
	player.update_velocity(Enums.IntegrationContext.GAME)


func logic_transitions() -> void:
	#print("i x: %f, z: %f" % [player.game_velocity.x, player.game_velocity.z])
	if !is_zero_approx(player.game_velocity.x) or !is_zero_approx(player.game_velocity.z):
		transition.emit("WalkMovementState")
	
	if player.input.is_crouching():
		transition.emit("CrouchMovementState")

	if player.input.is_jump_just_pressed() and player.on_floor(Enums.IntegrationContext.GAME):
		transition.emit("JumpMovementState")

	if player.input.is_prone():
		transition.emit("ProneMovementState")


func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
