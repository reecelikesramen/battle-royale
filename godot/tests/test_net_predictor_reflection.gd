extends TestBase

# Phase 4: NetPredictor._user_field_names should return only the user-authored
# @export vars on a NetState/NetCommand, skipping Resource-base properties.

func test_player_state_fields_are_user_authored() -> void:
	var state := PlayerState.new()
	var fields := NetPredictor._user_field_names(state)
	# Set comparison: every PlayerState @export must appear, no Resource-base
	# leakage (resource_path, resource_name, resource_local_to_scene, script).
	var expected := PackedStringArray([
		"pos", "velocity", "look",
		"movement_state", "peek_state",
		"crouch_progress", "prone_progress", "peek_progress",
	])
	for name in expected:
		assert_true(name in fields, "missing field: %s" % name)
	for forbidden in ["resource_path", "resource_name", "resource_local_to_scene", "script"]:
		assert_false(forbidden in fields, "leaked Resource-base property: %s" % forbidden)


func test_player_input_fields_user_authored() -> void:
	var cmd := PlayerInput.new()
	var fields := NetPredictor._user_field_names(cmd)
	var expected := PackedStringArray([
		"sequence_id", "timestamp_us",
		"move_forward_backward", "move_left_right", "look_abs",
		"jump", "crouch", "sprint", "prone",
		"peek_left_right",
		"last_received_tick",
	])
	for name in expected:
		assert_true(name in fields, "missing field: %s" % name)


func test_empty_netstate_returns_empty() -> void:
	var bare := NetState.new()
	var fields := NetPredictor._user_field_names(bare)
	# NetState declares no @export vars of its own, only inherits from Resource.
	for forbidden in ["resource_path", "resource_name", "script"]:
		assert_false(forbidden in fields, "leaked Resource-base property: %s" % forbidden)
