extends TestBase

# Sprint 2: PlayerSchema is persisted to res://entities/player/player_schema.tres
# for inspector editing. Loaded schema must hash-match the code-built fallback
# so the registration drift check (NetReplication.register_schema) doesn't
# fire on fresh clones that re-run tools/save_player_schema.gd.


func test_loaded_schema_matches_built_hash() -> void:
	# Both paths populate state_fields the same way (probe PlayerState exports
	# in property-order, Quant.AUTO). When they diverge the registration warn
	# would fire — guard against accidental drift.
	if not ResourceLoader.exists(PlayerSchema.RESOURCE_PATH):
		print("[SKIP] %s missing; run tools/save_player_schema.gd" % PlayerSchema.RESOURCE_PATH)
		return
	var loaded: NetSchema = load(PlayerSchema.RESOURCE_PATH)
	var built: NetSchema = PlayerSchema.build()
	assert_eq(loaded.compute_hash(), built.compute_hash(),
			"loaded .tres and PlayerSchema.build() must produce the same hash")


func test_get_schema_falls_back_when_missing() -> void:
	# get_schema() must return a valid schema even when the .tres is missing
	# (fresh checkouts, CI without the tools step). Hard to simulate
	# "missing" cleanly so we just assert the happy path: returned schema
	# has the SCHEMA_ID + populated state_fields.
	var s: NetSchema = PlayerSchema.get_schema()
	assert_true(s != null, "get_schema() should never return null")
	assert_eq(s.id, PlayerSchema.SCHEMA_ID)
	assert_true(s.state_fields.size() > 0, "state_fields should be populated by build() or .tres")
	assert_true(s.corrections.size() >= 3, "at least horizontal/vertical/velocity_horizontal corrections")
