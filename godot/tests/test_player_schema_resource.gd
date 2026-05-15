extends TestBase

# Player schema is sourced exclusively from
# res://entities/player/player_schema.tres. Production code binds the .tres
# via ExtResource on player.tscn's NetPredictor; tests load it directly.


func test_load_schema_returns_populated_schema() -> void:
	var s: NetSchema = load("res://entities/player/player_schema.tres") as NetSchema
	assert_true(s != null, "load_schema() returned null — .tres missing or failed to load")
	assert_true(s.id > 0, "schema id should be set in the .tres")
	assert_true(s.state_fields.size() > 0, "state_fields should be populated by the .tres")
	assert_true(s.corrections.size() >= 3,
			"at least horizontal/vertical/velocity_horizontal corrections expected")
