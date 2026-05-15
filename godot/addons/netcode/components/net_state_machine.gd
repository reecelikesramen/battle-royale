class_name NetStateMachine extends Node

# Phase 8b: opt-in adapter that surfaces a StateMachine's identity + progress
# as plain read/write properties so a NetPredictor's NetChildRef can sync them
# via the dirty-mask wire format.
#
# Setup:
#   - Add NetStateMachine as a sibling of the StateMachine you want to sync.
#   - Point `state_machine_path` at the target (defaults to "../StateMachine").
#   - Register a NetChildRef on the entity's schema pointing at this node with
#     fields = ["state_id", "progress"] (or whichever subset you need).
#
# Why a wrapper and not direct StateMachine sync: state_id reads/writes via
# methods, not a property. NetChildRef uses Node.get/set which can't reach a
# method-only API. This wrapper bridges that gap. progress is opt-in and only
# applied when the active state exposes a writeable `progress` field.

@export var state_machine_path: NodePath = ^"../StateMachine"

# Manual progress override. When non-NaN, decode writes here and apply_progress
# pushes it onto the active state. encode reads from the active state if it
# exposes a progress property, otherwise falls back to this cache.
var _progress_cache: float = 0.0

# Duck-typed: any node exposing get_logic_state_id / set_logic_state_by_id /
# set_visual_state_by_id (and optionally _visual_state.progress) is accepted.
# Avoids a hard dep on the project's StateMachine class so test fakes and
# future state-machine variants drop in cleanly.
#
# state_machine_override lets callers inject a target without needing a tree
# (tests primarily). When set, the path is ignored.
var state_machine_override: Node = null

var state_machine: Node:
	get:
		if state_machine_override:
			return state_machine_override
		return get_node_or_null(state_machine_path)


# Wire-replicable: the active logic state's child index. Maps to / from the
# child-index ids the StateMachine maintains in state_to_id / id_to_state.
var state_id: int:
	get:
		var sm := state_machine
		if sm == null or not sm.has_method(&"get_logic_state_id"):
			return -1
		return sm.get_logic_state_id()
	set(value):
		var sm := state_machine
		if sm == null or value < 0:
			return
		# Both logic + visual: a snapshot represents the authoritative server
		# view, so the local sim should adopt it for both integration channels.
		if sm.has_method(&"set_logic_state_by_id"):
			sm.set_logic_state_by_id(value)
		if sm.has_method(&"set_visual_state_by_id"):
			sm.set_visual_state_by_id(value)


# Wire-replicable progress on the active state. Reads from the visual state's
# `progress` if it has one (most game states), else returns the cached value.
# Writes update both the cache and the visual state. Suitable for crouch /
# prone / peek lerp values that today live as floats on PlayerState.
var progress: float:
	get:
		var sm := state_machine
		if sm and sm.get(&"_visual_state") and "progress" in sm.get(&"_visual_state"):
			return sm.get(&"_visual_state").progress
		return _progress_cache
	set(value):
		_progress_cache = value
		var sm := state_machine
		if sm and sm.get(&"_visual_state") and "progress" in sm.get(&"_visual_state"):
			sm.get(&"_visual_state").progress = value
