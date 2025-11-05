class_name StateMachine

extends Node

@export var CURRENT_STATE: State
@export var DEBUG_NAME: String
@export var SHOW_IN_DEBUG: bool = true
var states: Dictionary[StringName, State] = {}

var _show_in_debug: bool:
	get: return SHOW_IN_DEBUG and !LowLevelNetworkHandler.is_server

func _ready() -> void:
	for child in get_children():
		if child is State:
			states[child.name] = child
			child.transition.connect(on_child_transition)
		else:
			push_warning("State Machine '%s' contains an incompatible child node '%s', type '%s'" % [name, child.name, type_string(typeof(child))])
	
	CURRENT_STATE.enter()

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	CURRENT_STATE.update(delta)
	if _show_in_debug:
		ClientNetworkGlobals.debug.set_debug_property(DEBUG_NAME, CURRENT_STATE.name)
	
func _physics_process(delta: float) -> void:
	CURRENT_STATE.physics_update(delta)

func on_child_transition(new_state_name: StringName) -> void:
	var new_state = states.get(new_state_name)
	if new_state == null:
		push_warning("State Machine '%s' transitioned to nonexistant state '%s'" % [name, new_state_name])
		return
	elif new_state == CURRENT_STATE: return
	
	CURRENT_STATE.exit()
	new_state.enter()
	CURRENT_STATE = new_state
