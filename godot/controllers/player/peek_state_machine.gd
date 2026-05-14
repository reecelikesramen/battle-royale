extends StateMachine


# peek_progress proxies the active peek state's progress (signed: negative=left,
# positive=right). Setter writes directly to PeekState's progress so reconcile
# can restore snapshot progress regardless of whether PeekState or NotPeekState
# is currently active.
var peek_progress: float:
	get: return 0.0 if _logic_state.name == &"NotPeekState" else _logic_state.progress
	set(value):
		var peek_state: State = states.get(&"PeekState")
		if peek_state != null:
			peek_state.progress = value
