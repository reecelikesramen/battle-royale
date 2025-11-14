class_name StateMachine extends Node

@export var CURRENT_STATE: State
@export var DEBUG_NAME: String
@export var SHOW_IN_DEBUG: bool = true
var states: Dictionary[StringName, State] = {}
var state_to_id: Dictionary[StringName, int] = {}
var id_to_state: Dictionary[int, StringName] = {}

var _show_in_debug: bool:
	get: return SHOW_IN_DEBUG and !LowLevelNetworkHandler.is_server

func _ready() -> void:
	for child in get_children():
		if child is State:
			states[child.name] = child
			state_to_id[child.name] = child.get_index()
			id_to_state[child.get_index()] = child.name
			child.transition.connect(_on_child_transition)
		else:
			push_warning("State Machine '%s' contains an incompatible child node '%s', type '%s'" % [name, child.name, type_string(typeof(child))])
	
	await owner.ready
	await CURRENT_STATE.ready
	CURRENT_STATE.enter()


func _process(delta: float) -> void:
	CURRENT_STATE.update(delta)
	if _show_in_debug:
		ClientNetworkGlobals.debug.set_debug_property(DEBUG_NAME, CURRENT_STATE.name)


func physics_process(delta: float) -> void:
	CURRENT_STATE.physics_update(delta)


func set_state(new_state_name: StringName) -> void:
	_on_child_transition(new_state_name)


func set_state_by_id(new_state_id: int) -> void:
	_on_child_transition(id_to_state[new_state_id])


func get_state() -> StringName:
	return CURRENT_STATE.name


func get_state_id() -> int:
	return state_to_id[CURRENT_STATE.name]


func _on_child_transition(new_state_name: StringName) -> void:
	var new_state = states.get(new_state_name)
	if new_state == null:
		push_warning("State Machine '%s' transitioned to nonexistant state '%s'" % [name, new_state_name])
		return
	elif new_state == CURRENT_STATE: return
	
	CURRENT_STATE.exit()
	new_state.enter()
	CURRENT_STATE = new_state
