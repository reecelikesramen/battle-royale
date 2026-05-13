extends TestBase

# Phase 5 sanity: PlayerSchema.build() produces the channels NetPredictor
# reconcile reads, and lookup helpers return the right entries (or null).

func test_player_schema_carries_class_refs() -> void:
	var schema := PlayerSchema.build()
	assert_not_null(schema, "build() returned null")
	assert_eq(schema.id, PlayerSchema.SCHEMA_ID, "schema_id mismatch")
	assert_eq(schema.state_class, PlayerState, "state_class mismatch")
	assert_eq(schema.command_class, PlayerInput, "command_class mismatch")


func test_player_schema_tick_rates() -> void:
	var schema := PlayerSchema.build()
	assert_eq(schema.tick_hz, 120)
	assert_eq(schema.snapshot_hz, 30)


func test_find_correction_returns_named_channel() -> void:
	var schema := PlayerSchema.build()
	var horiz := schema.find_correction(&"horizontal")
	assert_not_null(horiz, "horizontal channel missing")
	assert_eq(horiz.snap_threshold, 1.5)
	assert_eq(horiz.smooth_rate, 8.0)
	assert_approx(horiz.deadband, 0.07)


func test_find_correction_returns_null_for_unknown() -> void:
	var schema := PlayerSchema.build()
	assert_null(schema.find_correction(&"nope"))


func test_find_correction_all_three_present() -> void:
	var schema := PlayerSchema.build()
	assert_not_null(schema.find_correction(&"horizontal"))
	assert_not_null(schema.find_correction(&"vertical"))
	assert_not_null(schema.find_correction(&"velocity_horizontal"))


func test_correction_field_paths() -> void:
	var schema := PlayerSchema.build()
	var horiz := schema.find_correction(&"horizontal")
	assert_eq(horiz.fields.size(), 1)
	assert_eq(horiz.fields[0], "pos.xz")

	var vert := schema.find_correction(&"vertical")
	assert_eq(vert.fields[0], "pos.y")

	var vel_h := schema.find_correction(&"velocity_horizontal")
	assert_eq(vel_h.fields[0], "velocity.xz")
