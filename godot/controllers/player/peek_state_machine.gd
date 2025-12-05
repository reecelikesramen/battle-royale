extends StateMachine


var peek_progress: float:
	get: return 0.0 if _logic_state.name == &"NotPeekState" else _logic_state.progress
