extends MovementState

@export var SPEED := 7.0
@export var ACCELERATION := 0.1
@export var DECELERATION := 0.25
@export var TOP_ANIM_SPEED: float = 1.6

var _speed_squared := SPEED * SPEED

func enter():
	player.set_parameters(SPEED, ACCELERATION, DECELERATION)
	if ctx == Enums.IntegrationContext.VISUAL:
		animation_player.play("Sprinting", 0.5, 1.0)


func exit():
	if ctx == Enums.IntegrationContext.VISUAL:
		animation_player.speed_scale = 1.0


# TODO: on floor for game state as well
func physics_update(delta: float):
	player.update_gravity(delta, ctx)
	player.update_movement(ctx)
	player.update_velocity(ctx)
	
	if ctx == Enums.IntegrationContext.VISUAL:
		set_animation_speed(player.velocity.length_squared())

	var velocity := player.velocity if ctx == Enums.IntegrationContext.VISUAL else player.game_velocity
	if velocity.is_zero_approx():
		transition.emit("IdleMovementState")

	if !player.current_frame_input.sprint:
		transition.emit("WalkingMovementState")
	
	if player.current_frame_input.crouch:
		transition.emit("CrouchingMovementState")
		
	if player.current_frame_input.jump and player.on_floor(ctx):
		transition.emit("JumpingMovementState")


func set_animation_speed(speed: float):
	var alpha = remap(speed, 0.0, _speed_squared, 0.0, 1.0)
	animation_player.speed_scale = lerp(0.0, TOP_ANIM_SPEED, alpha)
