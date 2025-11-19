extends MovementState

func visual_enter() -> void:
	#animation_player.play("Idle")
	animation_player.pause()


func logic_physics(delta: float) -> void:
	player.update_gravity(delta, Enums.IntegrationContext.GAME)
	player.update_movement(Enums.IntegrationContext.GAME)
	player.update_velocity(Enums.IntegrationContext.GAME)


func logic_transitions() -> void:
	#print("i x: %f, z: %f" % [player.game_velocity.x, player.game_velocity.z])
	if !is_zero_approx(player.game_velocity.x) or !is_zero_approx(player.game_velocity.z):
		transition.emit("WalkingMovementState")
	
	if player.current_frame_input.crouch:
		transition.emit("CrouchingMovementState")

	if player.current_frame_input.jump and player.on_floor(Enums.IntegrationContext.GAME):
		transition.emit("JumpingMovementState")


func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
