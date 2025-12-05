extends StateMachine

var crouch_progress: float:
	get: return _logic_state.progress if _logic_state.name == &"CrouchMovementState" else 0.0

var prone_progress: float:
	get: return _logic_state.progress if _logic_state.name == &"ProneMovementState" else 0.0
