extends PeekState

func visual_enter() -> void:
	animation_tree.set("parameters/Peeking/transition_request", "Not Peek")


func logic_transitions() -> void:
	if %MovementStateMachine.current_state not in [&"IdleMovementState", &"CrouchMovementState", &"WalkMovementState"]:
		return
	
	if player.game_velocity.length() > MAX_VELOCITY:
		return
	
	if player.input.is_peeking_left() or player.input.is_peeking_right():
		transition.emit(&"PeekState")
