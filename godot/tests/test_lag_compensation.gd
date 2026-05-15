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


func test_lag_compensator_rewinds_and_restores() -> void:
	# Build a predictor with one historical state, one live state. Register
	# with NetReplication so the compensator's iter_entities loop finds it.
	var p: NetPredictor = _make_predictor()
	var history := PlayerState.new()
	history.pos = Vector3(5.0, 0.0, 0.0)
	p._record_history(10, history)
	(p.shadow_state as PlayerState).pos = Vector3(1.0, 2.0, 3.0)
	NetReplication.register_entity(p.schema.id, 4242, p)

	var comp := NetLagCompensator.new()
	comp.max_rewind_ticks = 1000
	comp.set_current_tick(15)

	assert_eq(comp.rewind_to(10), 1, "expected 1 entity rewound")
	assert_vec3_approx((p.shadow_state as PlayerState).pos, Vector3(5.0, 0.0, 0.0),
			0.0001, "shadow not rewound to history")

	comp.restore()
	assert_vec3_approx((p.shadow_state as PlayerState).pos, Vector3(1.0, 2.0, 3.0),
			0.0001, "shadow not restored to live")

	NetReplication.unregister_entity(p.schema.id, 4242)


func test_lag_compensator_refuses_out_of_window() -> void:
	var p: NetPredictor = _make_predictor()
	var history := PlayerState.new()
	p._record_history(2, history)
	NetReplication.register_entity(p.schema.id, 4243, p)

	var comp := NetLagCompensator.new()
	comp.max_rewind_ticks = 5
	comp.set_current_tick(100)

	# tick 2 vs current 100 => age 98, max 5 => refused.
	assert_eq(comp.rewind_to(2), 0, "out-of-window rewind should refuse")

	NetReplication.unregister_entity(p.schema.id, 4243)


func test_with_rewind_returns_callback_result() -> void:
	var p: NetPredictor = _make_predictor()
	var history := PlayerState.new()
	history.pos = Vector3(9.0, 0.0, 0.0)
	p._record_history(7, history)
	(p.shadow_state as PlayerState).pos = Vector3(0.0, 0.0, 0.0)
	NetReplication.register_entity(p.schema.id, 4244, p)

	var comp := NetLagCompensator.new()
	comp.max_rewind_ticks = 1000
	comp.set_current_tick(20)

	# Closure reads shadow_state.pos.x mid-rewind; should see 9.0 from history.
	var probed: float = comp.with_rewind(7, func(): return (p.shadow_state as PlayerState).pos.x)
	assert_approx(probed, 9.0, 0.001)
	# After with_rewind returns, restore() ran so live state is back.
	assert_vec3_approx((p.shadow_state as PlayerState).pos, Vector3(0.0, 0.0, 0.0))

	NetReplication.unregister_entity(p.schema.id, 4244)


func test_apply_state_hook_fires_on_rewind_and_restore() -> void:
	# Phase 10c: shadow_state_applied signal fires once after rewind and once
	# after restore. Subscriber mirrors shadow_state.pos onto a Node3D so
	# downstream collision queries (physics, raycast) see the rewound pose.
	var p: NetPredictor = _make_predictor()
	var history := PlayerState.new()
	history.pos = Vector3(50.0, 0.0, 0.0)
	p._record_history(11, history)
	(p.shadow_state as PlayerState).pos = Vector3(1.0, 2.0, 3.0)

	var scene_node := Node3D.new()
	scene_node.position = (p.shadow_state as PlayerState).pos
	var sync_to_scene := func():
		scene_node.position = (p.shadow_state as PlayerState).pos
	p.shadow_state_applied.connect(sync_to_scene)

	NetReplication.register_entity(p.schema.id, 4245, p)
	var comp := NetLagCompensator.new()
	comp.max_rewind_ticks = 1000
	comp.set_current_tick(15)

	assert_eq(comp.rewind_to(11), 1)
	assert_vec3_approx(scene_node.position, Vector3(50.0, 0.0, 0.0), 0.0001,
			"scene node not pushed to rewound pose")

	comp.restore()
	assert_vec3_approx(scene_node.position, Vector3(1.0, 2.0, 3.0), 0.0001,
			"scene node not restored to live pose")

	p.shadow_state_applied.disconnect(sync_to_scene)
	NetReplication.unregister_entity(p.schema.id, 4245)
	scene_node.free()


func _make_predictor() -> NetPredictor:
	# Construct without entering tree to skip NetReplication autoload coupling.
	var n := NetPredictor.new()
	n.schema = load("res://entities/player/player_schema.tres") as NetSchema
	n.shadow_state = n.state_template.duplicate(true) as NetState
	n.render_state = n.state_template.duplicate(true) as NetState
	n.state_field_names = NetPredictor._user_field_names(n.shadow_state)
	return n
