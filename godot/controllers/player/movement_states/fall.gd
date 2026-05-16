extends MovementState

@export var SPEED := 3.5
@export var ACCELERATION := 5.0


func logic_enter() -> void:
	# Match jump: don't raise the wish-dir target above the previous ground speed.
	player.set_parameters(minf(SPEED, player._speed), ACCELERATION)


func visual_enter() -> void:
	animation_tree.set("parameters/Movement/transition_request", "Fall")
	camera_animation_player.stop()


func logic_physics(delta: float) -> void:
	player.update_gravity(delta, Enums.IntegrationContext.GAME)
	player.update_movement(delta, Enums.IntegrationContext.GAME)
	player.update_velocity(Enums.IntegrationContext.GAME)


func logic_transitions() -> void:
	if player.on_floor(Enums.IntegrationContext.GAME):
		transition.emit(_land_target())


func _land_target() -> StringName:
	if player.input.is_crouching():
		return &"CrouchMovementState"
	var moving := !is_zero_approx(player.game_velocity.x) or !is_zero_approx(player.game_velocity.z)
	if not moving:
		return &"IdleMovementState"
	if player.input.is_sprinting_forward():
		return &"SprintMovementState"
	if player.input.is_walk_mode():
		return &"WalkMovementState"
	return &"RunMovementState"


func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(delta, Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
