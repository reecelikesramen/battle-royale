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
	b.state_fields[&"pos"].quant = NetStateField.Quant.FLOAT32
	assert_true(a.compute_hash() != b.compute_hash(),
			"toggling quant on a field should change the schema hash")


func test_renaming_field_changes_hash() -> void:
	# After moving to Dictionary[StringName, NetStateField] storage, "order"
	# isn't a property of the schema (compute_hash sorts keys). What matters
	# instead is the *set* of keys + their per-field config. Renaming a key
	# changes the hash; identity content under a different name is a different
	# wire shape.
	var a := _make_schema()
	var b := _make_schema()
	var pos_cfg: NetStateField = b.state_fields[&"pos"]
	b.state_fields.erase(&"pos")
	b.state_fields[&"position"] = pos_cfg
	assert_true(a.compute_hash() != b.compute_hash(),
			"renaming a state_fields key should change the hash")


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
	schema.state_template = NetState.new()
	schema.command_template = NetCommand.new()
	schema.tick_hz = 120
	schema.snapshot_hz = 30

	var f1 := NetStateField.new()
	f1.quant = NetStateField.Quant.AUTO
	var f2 := NetStateField.new()
	f2.quant = NetStateField.Quant.AUTO
	schema.state_fields = {&"pos": f1, &"velocity": f2}

	var c := NetCorrection.new()
	c.name = &"horizontal"
	c.fields = PackedStringArray(["pos.xz"])
	c.snap_threshold = 1.5
	schema.corrections = [c]

	return schema
