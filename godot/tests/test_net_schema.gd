extends TestBase

# Phase 5 sanity: player_schema.tres carries the channels NetPredictor
# reconcile reads, and lookup helpers return the right entries (or null).

func test_player_schema_carries_class_refs() -> void:
	var schema := load("res://entities/player/player_schema.tres") as NetSchema
	assert_not_null(schema, "schema load returned null")
	assert_eq(schema.id, 1, "schema_id mismatch")
	assert_not_null(schema.state_template, "state_template missing")
	assert_not_null(schema.command_template, "command_template missing")
	assert_eq(schema.state_template.get_script(), PlayerState, "state_template wrong class")
	assert_eq(schema.command_template.get_script(), PlayerInput, "command_template wrong class")


func test_player_schema_tick_rates() -> void:
	var schema := load("res://entities/player/player_schema.tres") as NetSchema
	assert_eq(schema.tick_hz, 120)
	assert_eq(schema.snapshot_hz, 30)


func test_find_correction_returns_named_channel() -> void:
	var schema := load("res://entities/player/player_schema.tres") as NetSchema
	var horiz := schema.find_correction(&"horizontal")
	assert_not_null(horiz, "horizontal channel missing")
	assert_eq(horiz.snap_threshold, 1.5)
	assert_eq(horiz.smooth_rate, 8.0)
	assert_approx(horiz.deadband, 0.07)


func test_find_correction_returns_null_for_unknown() -> void:
	var schema := load("res://entities/player/player_schema.tres") as NetSchema
	assert_null(schema.find_correction(&"nope"))


func test_find_correction_all_three_present() -> void:
	var schema := load("res://entities/player/player_schema.tres") as NetSchema
	assert_not_null(schema.find_correction(&"horizontal"))
	assert_not_null(schema.find_correction(&"vertical"))
	assert_not_null(schema.find_correction(&"velocity"))


func test_correction_field_paths() -> void:
	var schema := load("res://entities/player/player_schema.tres") as NetSchema
	var horiz := schema.find_correction(&"horizontal")
	assert_eq(horiz.fields.size(), 1)
	assert_eq(horiz.fields[0], "pos.xz")
	assert_eq(horiz.mode, NetCorrection.Mode.SMOOTHED_OFFSET)

	var vert := schema.find_correction(&"vertical")
	assert_eq(vert.fields[0], "pos.y")
	assert_eq(vert.mode, NetCorrection.Mode.SMOOTHED_OFFSET)

	var vel := schema.find_correction(&"velocity")
	assert_eq(vel.fields[0], "velocity")
	assert_true(vel.always_snap)


# ---- validate() ----

class _ProbeState extends NetState:
	@export var pos: Vector3 = Vector3.ZERO
	@export var hp: float = 0.0
	@export var spin: Quaternion = Quaternion.IDENTITY


func _probe_schema() -> NetSchema:
	var s := NetSchema.new()
	s.id = 4242
	# Phase 6.1: REPLICATED keeps the probe consistent without needing a
	# command_template. Tests that care about archetype validation set it
	# explicitly per test.
	s.archetype = NetSchema.Archetype.REPLICATED
	s.state_template = _ProbeState.new()
	var fpos := NetStateField.new()
	var fhp := NetStateField.new()
	var fspin := NetStateField.new()
	s.state_fields = {&"pos": fpos, &"hp": fhp, &"spin": fspin}
	return s


func _find_issue(issues: Array, category: StringName) -> ValidationIssue:
	for i in issues:
		if (i as ValidationIssue).category == category:
			return i
	return null


func test_validate_clean_schema_has_no_errors() -> void:
	var s := _probe_schema()
	var issues := s.validate()
	# Probe schema is clean — id set, template present, fields aligned, no
	# corrections. Should yield zero ERROR-severity issues.
	for issue in issues:
		var v: ValidationIssue = issue
		assert_true(v.severity != ValidationIssue.Severity.ERROR,
				"unexpected error: %s" % v.to_string_line())


func test_validate_flags_unset_id() -> void:
	var s := _probe_schema()
	s.id = 0
	var hit: ValidationIssue = _find_issue(s.validate(), &"id_unset")
	assert_not_null(hit, "id_unset should fire when id == 0")
	assert_eq(hit.severity, ValidationIssue.Severity.ERROR)


func test_validate_flags_unset_template() -> void:
	var s := _probe_schema()
	s.state_template = null
	var hit: ValidationIssue = _find_issue(s.validate(), &"template_unset")
	assert_not_null(hit)
	assert_eq(hit.severity, ValidationIssue.Severity.ERROR)


func test_validate_flags_quat32_on_non_quaternion() -> void:
	var s := _probe_schema()
	(s.state_fields[&"pos"] as NetStateField).quant = NetStateField.Quant.QUAT32
	var hit: ValidationIssue = _find_issue(s.validate(), &"quant_type_mismatch")
	assert_not_null(hit, "QUAT32 on Vector3 must flag")
	assert_eq(hit.severity, ValidationIssue.Severity.ERROR)


func test_validate_flags_quant8_inverted_range() -> void:
	var s := _probe_schema()
	var cfg: NetStateField = s.state_fields[&"hp"]
	cfg.quant = NetStateField.Quant.QUANT8
	cfg.min_value = 100.0
	cfg.max_value = 0.0
	var hit: ValidationIssue = _find_issue(s.validate(), &"quant_range_inverted")
	assert_not_null(hit)
	assert_eq(hit.severity, ValidationIssue.Severity.ERROR)


func test_validate_flags_quant8_zero_range_as_warning() -> void:
	var s := _probe_schema()
	var cfg: NetStateField = s.state_fields[&"hp"]
	cfg.quant = NetStateField.Quant.QUANT8
	cfg.min_value = 5.0
	cfg.max_value = 5.0
	var hit: ValidationIssue = _find_issue(s.validate(), &"quant_range_zero")
	assert_not_null(hit)
	assert_eq(hit.severity, ValidationIssue.Severity.WARNING)


func test_validate_flags_correction_missing_field() -> void:
	var s := _probe_schema()
	var c := NetCorrection.new()
	c.name = &"bogus"
	c.fields = PackedStringArray(["nonexistent.x"])
	s.corrections = [c]
	var hit: ValidationIssue = _find_issue(s.validate(), &"correction_missing_field")
	assert_not_null(hit)
	assert_eq(hit.severity, ValidationIssue.Severity.ERROR)


func test_validate_flags_correction_invalid_axis() -> void:
	var s := _probe_schema()
	var c := NetCorrection.new()
	c.name = &"bad_axis"
	# pos is Vector3 — w is invalid.
	c.fields = PackedStringArray(["pos.w"])
	s.corrections = [c]
	var hit: ValidationIssue = _find_issue(s.validate(), &"correction_invalid_axis")
	assert_not_null(hit)
	assert_eq(hit.severity, ValidationIssue.Severity.ERROR)


func test_validate_flags_axis_on_scalar() -> void:
	var s := _probe_schema()
	var c := NetCorrection.new()
	c.name = &"scalar_axis"
	# hp is float — can't have .x.
	c.fields = PackedStringArray(["hp.x"])
	s.corrections = [c]
	var hit: ValidationIssue = _find_issue(s.validate(), &"correction_axis_on_scalar")
	assert_not_null(hit)
	assert_eq(hit.severity, ValidationIssue.Severity.ERROR)


func test_validate_flags_contradictory_correction() -> void:
	var s := _probe_schema()
	var c := NetCorrection.new()
	c.name = &"both"
	c.fields = PackedStringArray(["pos.xz"])
	c.always_snap = true
	c.always_smooth = true
	s.corrections = [c]
	var hit: ValidationIssue = _find_issue(s.validate(), &"correction_contradiction")
	assert_not_null(hit)
	assert_eq(hit.severity, ValidationIssue.Severity.ERROR)


func test_validate_archetype_predicted_requires_command_template() -> void:
	var s := _probe_schema()
	s.archetype = NetSchema.Archetype.PREDICTED
	# command_template is null (probe schema never sets one) — must ERROR.
	var hit: ValidationIssue = _find_issue(s.validate(), &"archetype_missing_command_template")
	assert_not_null(hit, "PREDICTED + null command_template should error")
	assert_eq(hit.severity, ValidationIssue.Severity.ERROR)


func test_validate_archetype_replicated_with_command_template_warns() -> void:
	var s := _probe_schema()
	# Probe is REPLICATED by default; attach a stale command_template.
	var cmd := NetCommand.new()
	s.command_template = cmd
	var hit: ValidationIssue = _find_issue(s.validate(), &"archetype_dead_command_template")
	assert_not_null(hit, "REPLICATED + non-null command_template should warn")
	assert_eq(hit.severity, ValidationIssue.Severity.WARNING)


func test_validate_smoothed_offset_only_on_predicted() -> void:
	var s := _probe_schema()
	# Probe is REPLICATED — SMOOTHED_OFFSET on pos is illegal.
	var c := NetCorrection.new()
	c.name = &"smooth_pos"
	c.fields = PackedStringArray(["pos"])
	c.mode = NetCorrection.Mode.SMOOTHED_OFFSET
	s.corrections = [c]
	var hit: ValidationIssue = _find_issue(s.validate(), &"correction_mode_requires_predicted")
	assert_not_null(hit, "SMOOTHED_OFFSET on REPLICATED should error")
	assert_eq(hit.severity, ValidationIssue.Severity.ERROR)


func test_player_schema_archetype_is_predicted() -> void:
	var schema := load("res://entities/player/player_schema.tres") as NetSchema
	assert_eq(schema.archetype, NetSchema.Archetype.PREDICTED, "player must be PREDICTED")


func test_grenade_schema_archetype_is_replicated() -> void:
	var schema := load("res://entities/grenade/grenade_schema.tres") as NetSchema
	assert_eq(schema.archetype, NetSchema.Archetype.REPLICATED, "grenade must be REPLICATED")


func test_validate_strings_filters_by_severity() -> void:
	var s := _probe_schema()
	# Trigger an ERROR + a WARNING.
	s.id = 0  # ERROR id_unset
	var cfg: NetStateField = s.state_fields[&"hp"]
	cfg.quant = NetStateField.Quant.QUANT8
	cfg.min_value = 1.0
	cfg.max_value = 1.0  # WARNING quant_range_zero

	var errs_only := s.validate_strings(ValidationIssue.Severity.ERROR)
	for line in errs_only:
		assert_true(line.begins_with("[ERROR]"), "non-error leaked: %s" % line)

	var with_warns := s.validate_strings(ValidationIssue.Severity.WARNING)
	var saw_warning := false
	for line in with_warns:
		if line.begins_with("[WARNING]"):
			saw_warning = true
	assert_true(saw_warning, "WARNING filter should include WARNING lines")
