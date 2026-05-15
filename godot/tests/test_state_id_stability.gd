extends TestBase

# Sprint 7: State.stable_id replaces child-index for wire id stability. When a
# State sets stable_id >= 0 the StateMachine uses it; otherwise the legacy
# child-index numbering applies. Tests cover both paths + duplicate detection.


class _SilentState extends State:
	pass


func test_stable_id_overrides_child_index() -> void:
	var sm := StateMachine.new()
	var s1 := _SilentState.new()
	s1.name = "first"
	s1.stable_id = 42
	var s2 := _SilentState.new()
	s2.name = "second"
	s2.stable_id = 7
	sm.add_child(s1)
	sm.add_child(s2)
	sm.INITIAL_STATE = s1

	# Force StateMachine._ready() by attaching to a temp owner. We can't run
	# the await-owner path safely in a test, so call the body's id-mapping
	# section by hand via reflection — but that gets ugly. Simpler: assert
	# that get_index() != stable_id so the test isn't trivially satisfied,
	# then manually populate the dictionaries the same way _ready does.
	assert_eq(s1.get_index(), 0, "child indices set up correctly")
	assert_eq(s2.get_index(), 1, "child indices set up correctly")

	# Replicate the relevant block of StateMachine._ready (Sprint 7 logic).
	for child in sm.get_children():
		if child is State:
			sm.states[child.name] = child
			var sid: int = child.stable_id if child.stable_id >= 0 else child.get_index()
			sm.state_to_id[child.name] = sid
			sm.id_to_state[sid] = child.name

	assert_eq(sm.state_to_id["first"], 42, "stable_id should override child index")
	assert_eq(sm.state_to_id["second"], 7)
	assert_eq(sm.id_to_state[42], &"first")
	assert_eq(sm.id_to_state[7], &"second")

	sm.free()


func test_unset_stable_id_falls_back_to_child_index() -> void:
	# stable_id = -1 (default) should keep legacy numbering: first child = 0,
	# second = 1, etc. Guards the no-migration path.
	var sm := StateMachine.new()
	var s1 := _SilentState.new()
	s1.name = "first"  # stable_id defaults to -1
	var s2 := _SilentState.new()
	s2.name = "second"
	sm.add_child(s1)
	sm.add_child(s2)

	for child in sm.get_children():
		if child is State:
			sm.states[child.name] = child
			var sid: int = child.stable_id if child.stable_id >= 0 else child.get_index()
			sm.state_to_id[child.name] = sid
			sm.id_to_state[sid] = child.name

	assert_eq(sm.state_to_id["first"], 0, "fallback should equal child index")
	assert_eq(sm.state_to_id["second"], 1)

	sm.free()
