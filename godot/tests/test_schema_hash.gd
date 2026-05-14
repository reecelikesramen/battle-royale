extends TestBase

# Sprint 7: NetSchema.compute_hash() produces a deterministic, content-derived
# int that two peers can compare to detect schema drift (e.g. one side toggled
# a field's quantization). Equal hashes => identical wire layout for that
# schema; differing hashes => silent corruption guaranteed if both peers
# transmit packets.


func test_identical_schemas_hash_equal() -> void:
	var a := _make_schema()
	var b := _make_schema()
	assert_eq(a.compute_hash(), b.compute_hash(), "identical schemas should hash equal")


func test_changing_quant_changes_hash() -> void:
	var a := _make_schema()
	var b := _make_schema()
	(b.state_fields[0] as NetFieldConfig).quant = NetFieldConfig.Quant.FLOAT32
	assert_true(a.compute_hash() != b.compute_hash(),
			"toggling quant on a field should change the schema hash")


func test_reordering_fields_changes_hash() -> void:
	var a := _make_schema()
	var b := _make_schema()
	# Swap the two fields' positions: same fields, different order, different
	# wire layout, must hash differently.
	b.state_fields = [b.state_fields[1], b.state_fields[0]]
	assert_true(a.compute_hash() != b.compute_hash(),
			"reordering state_fields should change the hash")


func test_correction_change_changes_hash() -> void:
	var a := _make_schema()
	var b := _make_schema()
	(b.corrections[0] as NetCorrection).snap_threshold = 99.0
	assert_true(a.compute_hash() != b.compute_hash(),
			"changing a correction param should change the hash")


func test_net_replication_pins_first_hash() -> void:
	# First register seeds the pinned hash; second call returns it via the
	# public accessor. We're not asserting the warning fires (push_warning
	# isn't easily intercepted from gdscript), just that pinning works.
	var schema := _make_schema()
	NetReplication.register_schema(99001, schema)
	var pinned: int = NetReplication.get_schema_hash(99001)
	assert_eq(pinned, schema.compute_hash(),
			"NetReplication should pin compute_hash() on first register_schema")

	# Cleanup so subsequent test runs aren't polluted.
	NetReplication._schemas.erase(99001)
	NetReplication._schema_hashes.erase(99001)


func _make_schema() -> NetSchema:
	# Hand-roll a small, deterministic schema. Avoid PlayerSchema.build() so
	# changes to it don't break these tests.
	var schema := NetSchema.new()
	schema.id = 4242
	schema.state_class = NetState
	schema.command_class = NetCommand
	schema.tick_hz = 120
	schema.snapshot_hz = 30

	var f1 := NetFieldConfig.new()
	f1.name = &"pos"
	f1.quant = NetFieldConfig.Quant.AUTO
	var f2 := NetFieldConfig.new()
	f2.name = &"velocity"
	f2.quant = NetFieldConfig.Quant.AUTO
	schema.state_fields = [f1, f2]

	var c := NetCorrection.new()
	c.name = &"horizontal"
	c.fields = PackedStringArray(["pos.xz"])
	c.snap_threshold = 1.5
	schema.corrections = [c]

	return schema
