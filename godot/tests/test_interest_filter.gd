extends TestBase

# Phase 11: interest management hook on NetPredictor. The framework provides
# a per-entity Callable(peer_id, predictor) -> bool that the server's snapshot
# broadcast loop consults to decide which peers receive each packet. Games
# install AOI / role / team rules in the filter; the addon stays game-agnostic.

func test_should_replicate_default_true() -> void:
	# No filter installed -> broadcast-to-all preserved.
	var p: NetPredictor = _make_predictor()
	assert_true(p.should_replicate_to(1))
	assert_true(p.should_replicate_to(99))


func test_should_replicate_consults_filter() -> void:
	var p: NetPredictor = _make_predictor()
	# Only peer 5 is interested.
	p.interest_filter = func(peer_id: int, _pred: NetPredictor) -> bool:
		return peer_id == 5
	assert_true(p.should_replicate_to(5))
	assert_false(p.should_replicate_to(1))
	assert_false(p.should_replicate_to(99))


func test_filter_receives_predictor_reference() -> void:
	var p: NetPredictor = _make_predictor()
	(p.shadow_state as PlayerState).pos = Vector3(10.0, 0.0, 0.0)
	# Filter inspects predictor.shadow_state to make a decision — proves the
	# second arg is the predictor itself, not a copy.
	p.interest_filter = func(_peer_id: int, pred: NetPredictor) -> bool:
		return (pred.shadow_state as PlayerState).pos.x > 0.0
	assert_true(p.should_replicate_to(1))
	(p.shadow_state as PlayerState).pos = Vector3(-5.0, 0.0, 0.0)
	assert_false(p.should_replicate_to(1))


func _make_predictor() -> NetPredictor:
	var p := NetPredictor.new()
	p.schema = PlayerSchema.build()
	p.shadow_state = p.state_template.duplicate(true) as NetState
	p.render_state = p.state_template.duplicate(true) as NetState
	p.state_field_names = NetPredictor._user_field_names(p.shadow_state)
	return p
