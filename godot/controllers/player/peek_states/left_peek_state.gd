extends PeekState


var progress: float = 0.0

## game logic callback on enter
func logic_enter() -> void: pass
## game logic callback on exit
func logic_exit() -> void: pass
## game logic callback per physics update
func logic_physics(_delta: float) -> void: pass
## game logic callback per frame
func logic_process(_delta: float) -> void: pass


func logic_transitions() -> void:
	if %MovementStateMachine.current_state not in [&"IdleMovementState", &"CrouchMovementState", &"WalkMovementState"]:
		transition.emit(&"NotPeekState")
		return
	
	if player.game_velocity.length() > MAX_VELOCITY:
		transition.emit(&"NotPeekState")
		return
	
	if not player.input.is_peeking_left():
		transition.emit(&"NotPeekState")
		return

## visual callback on enter
func visual_enter() -> void:
	animation_player.play(&"PeekLeft", -1, PEEK_SPEED)
## visual callback on exit
func visual_exit() -> void:
	animation_player.play(&"PeekLeft", -1, UNPEEK_SPEED, true)
## visual callback per physics update
func visual_physics(_delta: float) -> void: pass
## visual callback per frame
func visual_process(_delta: float) -> void: pass
