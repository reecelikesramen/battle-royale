extends TestBase

# Phase 8b: NetStateMachine surfaces the underlying StateMachine's id +
# progress as plain properties so NetChildRef + the predictor's dirty-mask
# encoder can sync them like any other field. TestBase extends RefCounted so
# we can't add nodes to a tree; tests use state_machine_override to inject
# the duck-typed target directly.

class FakeState:
	extends RefCounted
	var progress: float = 0.0


class FakeStateMachine:
	extends Node
	var current_id: int = 0
	var _visual_state := FakeState.new()
	func get_logic_state_id() -> int:
		return current_id
	func set_logic_state_by_id(v: int) -> void:
		current_id = v
	func set_visual_state_by_id(_v: int) -> void:
		pass


func test_state_id_round_trip_via_get_set() -> void:
	var sm := FakeStateMachine.new()
	sm.current_id = 4

	var wrapper := NetStateMachine.new()
	wrapper.state_machine_override = sm

	assert_eq(wrapper.get(&"state_id"), 4)

	wrapper.set(&"state_id", 7)
	assert_eq(sm.current_id, 7)

	sm.free()
	wrapper.free()


func test_progress_read_write_uses_visual_state() -> void:
	var sm := FakeStateMachine.new()
	sm._visual_state.progress = 0.42

	var wrapper := NetStateMachine.new()
	wrapper.state_machine_override = sm

	assert_approx(wrapper.get(&"progress"), 0.42, 0.0001)

	wrapper.set(&"progress", 0.88)
	assert_approx(sm._visual_state.progress, 0.88, 0.0001)
	# Cache also updated so a get after the visual state goes away still
	# returns the last value.
	assert_approx(wrapper._progress_cache, 0.88, 0.0001)

	sm.free()
	wrapper.free()


func test_progress_falls_back_to_cache_when_no_state_machine() -> void:
	# No override + invalid path -> falls back to cache instead of crashing.
	var wrapper := NetStateMachine.new()
	wrapper._progress_cache = 0.33
	assert_approx(wrapper.get(&"progress"), 0.33, 0.0001)
	wrapper.free()


func test_state_id_returns_minus_one_when_no_state_machine() -> void:
	var wrapper := NetStateMachine.new()
	assert_eq(wrapper.get(&"state_id"), -1)
	wrapper.free()
