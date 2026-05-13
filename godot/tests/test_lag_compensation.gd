extends TestBase

# Phase 10: NetPredictor maintains a bounded history ring of post-broadcast
# states keyed by server tick. LagCompensator (later) will read from it via
# rewind_to(client_tick) to verify shot intersections in the past.

func test_rewind_returns_stored_state() -> void:
	var p: NetPredictor = _make_predictor()
	var s: PlayerState = PlayerState.new()
	s.pos = Vector3(10.0, 0.0, 0.0)
	p._record_history(5, s)
	assert_true(p.has_history_at(5))
	var got: PlayerState = p.rewind_to(5)
	assert_not_null(got)
	assert_vec3_approx(got.pos, Vector3(10.0, 0.0, 0.0))


func test_rewind_unknown_tick_returns_null() -> void:
	var p: NetPredictor = _make_predictor()
	assert_null(p.rewind_to(99))
	assert_false(p.has_history_at(99))


func test_history_evicts_oldest_when_capacity_exceeded() -> void:
	var p: NetPredictor = _make_predictor()
	var cap: int = NetPredictor.HISTORY_TICK_CAPACITY
	for t in range(cap + 5):
		var s := PlayerState.new()
		s.pos = Vector3(t, 0.0, 0.0)
		p._record_history(t, s)
	# First 5 ticks should be evicted.
	for evicted in range(5):
		assert_false(p.has_history_at(evicted), "tick %d should be evicted" % evicted)
	# Oldest remaining should be tick 5.
	assert_eq(p.oldest_history_tick(), 5)
	# Newest should still be present.
	assert_true(p.has_history_at(cap + 4))


func test_oldest_history_tick_empty() -> void:
	var p: NetPredictor = _make_predictor()
	assert_eq(p.oldest_history_tick(), -1)


func _make_predictor() -> NetPredictor:
	# Construct without entering tree to skip NetReplication autoload coupling.
	var n := NetPredictor.new()
	n.schema = PlayerSchema.build()
	n.shadow_state = n.state_class.new()
	n.render_state = n.state_class.new()
	n.state_field_names = NetPredictor._user_field_names(n.shadow_state)
	return n
