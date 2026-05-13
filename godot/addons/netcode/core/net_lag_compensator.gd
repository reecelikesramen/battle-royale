class_name NetLagCompensator extends RefCounted

# Phase 10b: server-side hit-detection helper. Given a client-quoted server
# tick, restores every registered NetPredictor's shadow_state to the value it
# had at that tick (from the predictor's history ring), runs a caller-supplied
# closure (typically a raycast / overlap check), then restores live state.
# Refuses rewinds older than max_rewind_ticks to bound anti-cheat exposure.
#
# Hit detection wrapper that physically moves CharacterBody3D positions for
# collision is still per-game: this class only rewinds the *replicated state*,
# and entity controllers must read shadow_state when computing intersections.
# Phase 10c could add an opt-in "apply state to scene-node" hook on
# NetPredictor that wires this automatically.

const DEFAULT_MAX_REWIND_TICKS: int = NetPredictor.HISTORY_TICK_CAPACITY

# Anti-cheat clamp: max distance into the past a single rewind may target,
# measured in server ticks. A malicious client quoting an ancient tick (e.g.
# 5 seconds ago) gets clamped here rather than rewinding world state to it.
var max_rewind_ticks: int = DEFAULT_MAX_REWIND_TICKS

# (schema_id, entity_id) -> NetState live snapshot taken at rewind_to time.
# restore() copies these back into each predictor's shadow_state and clears.
var _saved_live: Dictionary = {}


# Rewinds every NetPredictor that has history at `tick` to that historical
# state. Returns the number of entities successfully rewound. Out-of-window
# `tick` values are refused (returns 0, saves nothing). Caller must pair
# with restore() once the hit detection / inspection is done.
func rewind_to(tick: int) -> int:
	if not _saved_live.is_empty():
		push_warning("NetLagCompensator.rewind_to called while a rewind is still active; restore() first")
		return 0
	if not _is_tick_in_window(tick):
		return 0
	var count := 0
	for entry in NetReplication.iter_entities():
		var schema_id: int = entry[0]
		var entity_id: int = entry[1]
		var predictor: NetPredictor = entry[2]
		if not predictor.has_history_at(tick):
			continue
		_saved_live[Vector2i(schema_id, entity_id)] = predictor.shadow_state.duplicate()
		var historical: NetState = predictor.rewind_to(tick)
		_copy_state(historical, predictor.shadow_state, predictor.state_field_names)
		count += 1
	return count


# Reverts every rewound predictor's shadow_state to the value it held before
# rewind_to(). No-op if no rewind is active.
func restore() -> void:
	for key in _saved_live:
		var k: Vector2i = key
		var predictor: NetPredictor = NetReplication.get_entity(k.x, k.y)
		if predictor == null:
			continue
		var saved: NetState = _saved_live[key]
		_copy_state(saved, predictor.shadow_state, predictor.state_field_names)
	_saved_live.clear()


# Convenience wrapper: rewind, run callback, always restore (even on
# exception). Returns whatever the callback returns, or null on refusal.
func with_rewind(tick: int, callback: Callable) -> Variant:
	if rewind_to(tick) == 0:
		return null
	var result: Variant = callback.call()
	restore()
	return result


func _is_tick_in_window(tick: int) -> bool:
	var current_tick: int = _current_server_tick if _current_server_tick >= 0 else NetworkServer.server_tick
	var age: int = current_tick - tick
	return age >= 0 and age <= max_rewind_ticks


# Optional injection for tests + deterministic replays: when >= 0, used as
# "now" instead of NetworkServer.server_tick. Set via set_current_tick().
var _current_server_tick: int = -1

func set_current_tick(tick: int) -> void:
	_current_server_tick = tick


static func _copy_state(src: NetState, dst: NetState, field_names: PackedStringArray) -> void:
	if src == null or dst == null:
		return
	for f in field_names:
		dst.set(f, src.get(f))
