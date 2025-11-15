extends MovementState

func enter():
	if ctx == Enums.IntegrationContext.VISUAL:
		animation_player.pause()


func physics_update(_delta: float):
	player.update_movement(ctx)
	player.update_velocity(ctx)

	var velocity := player.velocity if ctx == Enums.IntegrationContext.VISUAL else player.game_velocity
	if !velocity.is_zero_approx() and player.on_floor(ctx):
		transition.emit("WalkingMovementState")
	
	if player.current_frame_input.crouch:
		transition.emit("CrouchingMovementState")
	
	if player.current_frame_input.jump and player.on_floor(ctx):
		transition.emit("JumpingMovementState")
