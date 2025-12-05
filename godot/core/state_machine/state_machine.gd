class_name StateMachine extends Node

@export var INITIAL_STATE: State
@export var DEBUG_NAME: String
@export var SHOW_IN_DEBUG: bool = true

var current_state: StringName:
	get: return _logic_state.name

var states: Dictionary[StringName, State] = {}
var state_to_id: Dictionary[StringName, int] = {}
var id_to_state: Dictionary[int, StringName] = {}

var _logic_state: State
var _visual_state: State
var _pending_transition: StringName = &""

var _show_in_debug: bool:
	get:
		if !SHOW_IN_DEBUG: return false
		if NetworkTransport.is_server: return false
		if not NetworkClient.debug: return false
		var player: PlayerController = owner
		return player.is_authority


func _ready() -> void:
	for child in get_children():
		if child is State:
			states[child.name] = child
			state_to_id[child.name] = child.get_index()
			id_to_state[child.get_index()] = child.name
			child.transition.connect(_on_logic_transition)
		else:
			push_warning("State Machine '%s' contains an incompatible child node '%s', type '%s'" % [name, child.name, type_string(typeof(child))])
	
	_logic_state = INITIAL_STATE
	_visual_state = INITIAL_STATE
	await owner.ready
	_logic_state.previous_state = null
	_visual_state.previous_state = null
	_logic_state.logic_enter()
	_visual_state.visual_enter()


# TODO: known bug where visual/game desync for single frame transitions
func run_logic(delta: float) -> void:
	_logic_state.logic_physics(delta)
	var visited_states: Dictionary = {}
	var transition_path: PackedStringArray = []
	visited_states[_logic_state.name] = true
	transition_path.append(String(_logic_state.name))
	while true:
		_logic_state.logic_transitions()
		if _pending_transition == &"":
			break
		var next_state_name := _pending_transition
		_pending_transition = &""
		if visited_states.has(next_state_name):
			transition_path.append(String(next_state_name))
			push_warning("State Machine '%s' detected same-frame cycle: %s" % [name, " -> ".join(transition_path)])
			break
		visited_states[next_state_name] = true
		transition_path.append(String(next_state_name))
		_switch_logic(next_state_name)


# TODO: known bug where visual/game desync for single frame transitions
func sync_visual() -> void:
	if _visual_state == _logic_state:
		return
	_visual_state.visual_exit()
	_visual_state = _logic_state
	_visual_state.visual_enter()


func run_visual(delta: float) -> void:
	_visual_state.visual_physics(delta)


func get_logic_state_id() -> int:
	return state_to_id[_logic_state.name]


func set_logic_state_by_id(new_state_id: int) -> void:
	var target := states[id_to_state[new_state_id]]
	if target == null or target == _logic_state:
		return
	_logic_state.logic_exit()
	target.previous_state = _logic_state
	_logic_state = target
	_logic_state.logic_enter()


func set_visual_state_by_id(new_state_id: int) -> void:
	var target := states[id_to_state[new_state_id]]
	if target == null or target == _visual_state:
		return
	_visual_state.visual_exit()
	target.previous_state = _visual_state
	_visual_state = target
	_visual_state.visual_enter()


func _on_logic_transition(new_state_name: StringName) -> void:
	_pending_transition = new_state_name


func _switch_logic(new_state_name: StringName) -> void:
	var target := states[new_state_name]
	if target == null or target == _logic_state:
		return
	_logic_state.logic_exit()
	target.previous_state = _logic_state
	_logic_state = target
	_logic_state.logic_enter()


func _process(_delta: float) -> void:
	if _show_in_debug:
		NetworkClient.debug.set_debug_property(DEBUG_NAME, _logic_state.name)
