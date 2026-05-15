extends StateMachine

# crouch_progress / prone_progress proxy the active state's animation progress
# field so PlayerState (the network schema) can read/write it without coupling
# to which state is currently active. Setters write directly to the named state
# node so reconcile-side _load_simulation_state can restore the snapshot's
# progress regardless of the live _logic_state pointer — replay then resumes
# from the server-confirmed progress instead of the client's stale prediction.
var crouch_progress: float:
	get: return _logic_state.progress if _logic_state.name == &"CrouchMovementState" else 0.0
	set(value):
		var crouch_state: State = states.get(&"CrouchMovementState")
		if crouch_state != null:
			crouch_state.progress = value

var prone_progress: float:
	get: return _logic_state.progress if _logic_state.name == &"ProneMovementState" else 0.0
	set(value):
		var prone_state: State = states.get(&"ProneMovementState")
		if prone_state != null:
			prone_state.progress = value
