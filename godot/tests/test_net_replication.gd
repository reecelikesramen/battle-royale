extends TestBase

# Phase 6b: NetReplication is the (schema_id, entity_id) -> predictor registry
# that routes inbound NetStatePacket. Tests use a fresh local instance rather
# than the autoload so they don't fight other tests / autoload boot order.

func test_register_and_lookup() -> void:
	var reg := _new_registry()
	var schema := PlayerSchema.build()
	var p := NetPredictor.new()
	p.schema = schema
	p.entity_id = 42
	reg.register_schema(schema.id, schema)
	reg.register_entity(schema.id, 42, p)
	assert_eq(reg.get_entity(schema.id, 42), p)
	assert_eq(reg.get_schema(schema.id), schema)


func test_unknown_lookup_returns_null() -> void:
	var reg := _new_registry()
	assert_null(reg.get_entity(99, 99))
	assert_null(reg.get_schema(99))


func test_unregister_removes() -> void:
	var reg := _new_registry()
	var schema := PlayerSchema.build()
	var p := NetPredictor.new()
	p.schema = schema
	p.entity_id = 7
	reg.register_entity(schema.id, 7, p)
	reg.unregister_entity(schema.id, 7)
	assert_null(reg.get_entity(schema.id, 7))


func test_iter_entities_returns_all() -> void:
	var reg := _new_registry()
	var schema := PlayerSchema.build()
	var p1 := NetPredictor.new()
	var p2 := NetPredictor.new()
	p1.schema = schema
	p2.schema = schema
	reg.register_entity(schema.id, 1, p1)
	reg.register_entity(schema.id, 2, p2)
	var entries: Array = reg.iter_entities()
	assert_eq(entries.size(), 2)


func _new_registry() -> Node:
	# Load the NetReplication script and instantiate it. We don't attach to a
	# scene tree, so its _ready won't run — _ready only wires the
	# NetworkClient.handle_net_state signal, which tests don't need.
	var script: Script = load("res://addons/netcode/core/net_replication.gd")
	return script.new()
