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
		# Listen-server runs both halves; show the HUD only when this process
		# has a client role to render it (dedicated server has no HUD).
		if not NetSession.has_client_role: return false
		if not NetClient.debug: return false
		var player: PlayerController = owner
		return player.is_local_view


func _ready() -> void:
	# Sprint 7: prefer the State's exported stable_id over its scene-tree
	# child index so reordering nodes in the editor doesn't reshuffle the
	# wire ids that NetStatePacket.payload carries. Fall back to child index
	# when stable_id is unset (-1) so untouched state machines keep their
	# legacy numbering byte-for-byte.
	for child in get_children():
		if child is State:
			states[child.name] = child
			var sid: int = child.stable_id if child.stable_id >= 0 else child.get_index()
			if id_to_state.has(sid):
				push_warning("State Machine '%s': duplicate stable_id %d on '%s' (conflicts with '%s'); second registrant wins" \
						% [name, sid, child.name, id_to_state[sid]])
			state_to_id[child.name] = sid
			id_to_state[sid] = child.name
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
	if DEBUG_NAME == "Move":
		print("[SM-SYNC f=%d sm=%s] visual: %s -> %s" % [
				Engine.get_physics_frames(), DEBUG_NAME, _visual_state.name, _logic_state.name])
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
	if DEBUG_NAME == "Move":
		print("[SM-LOG-SET f=%d sm=%s] logic: %s -> %s (id=%d)" % [
				Engine.get_physics_frames(), DEBUG_NAME, _logic_state.name, target.name, new_state_id])
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
	if DEBUG_NAME == "Move":
		print("[SM-LOG-TRANS f=%d sm=%s] logic: %s -> %s" % [
				Engine.get_physics_frames(), DEBUG_NAME, _logic_state.name, target.name])
	_logic_state.logic_exit()
	target.previous_state = _logic_state
	_logic_state = target
	_logic_state.logic_enter()


func _process(_delta: float) -> void:
	if _show_in_debug:
		NetClient.debug.set_debug_property(DEBUG_NAME, _logic_state.name)
