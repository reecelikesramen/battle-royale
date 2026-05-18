class_name NetLagCompensator extends RefCounted

# Phase 10b: server-side hit-detection helper. Given a client-quoted server
# tick, restores every registered NetPredictor's shadow_state to the value it
# had at that tick (from the predictor's history ring), runs a caller-supplied
# closure (typically a raycast / overlap check), then restores live state.
# Refuses rewinds older than max_rewind_ticks to bound anti-cheat exposure.
#
# Phase 10c: NetPredictor.apply_shadow_state_to_scene() fires after each
# rewind and again on restore so subscribers can push shadow_state onto the
# scene graph (e.g. CharacterBody3D.position) for collision queries. Entities
# not participating in lag-comp can ignore the signal.

# Decoupled from NetPredictor.HISTORY_TICK_CAPACITY on purpose: history is sized
# for the worst-case legitimate `current_tick - last_received_tick` age under
# mobile RTT + jitter + reorder (~500ms p99 for mobile-average preset). The
# anti-cheat clamp is sized for that same legitimate worst case PLUS a small
# headroom, NOT the full history depth. If history grows for memory reasons,
# the clamp does not — otherwise a cheat can quote an ancient tick and rewind
# world state to where targets used to be visible. 60 ticks @ 120Hz = 500ms;
# CS:GO uses 200ms (`sv_maxunlag`) on lower-latency networks, we widen for
# mobile but bound the cheat surface.
const DEFAULT_MAX_REWIND_TICKS: int = 60

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
		predictor.apply_shadow_state_to_scene()
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
		predictor.apply_shadow_state_to_scene()
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
	var current_tick: int = _current_server_tick if _current_server_tick >= 0 else NetServer.server_tick
	var age: int = current_tick - tick
	return age >= 0 and age <= max_rewind_ticks


# Optional injection for tests + deterministic replays: when >= 0, used as
# "now" instead of NetServer.server_tick. Set via set_current_tick().
var _current_server_tick: int = -1

func set_current_tick(tick: int) -> void:
	_current_server_tick = tick


static func _copy_state(src: NetState, dst: NetState, field_names: PackedStringArray) -> void:
	if src == null or dst == null:
		return
	for f in field_names:
		dst.set(f, src.get(f))
