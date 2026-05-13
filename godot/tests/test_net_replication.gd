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


func test_pending_packet_buffered_then_flushed_on_register() -> void:
	# Phase 9c: a state packet for an entity that hasn't registered yet should
	# be queued and replayed once register_entity fires.
	var reg := _new_registry()
	var schema := PlayerSchema.build()

	# Build a payload from a source predictor so the receiver decodes real
	# bytes, not garbage.
	var src := NetPredictor.new()
	src.schema = schema
	src.shadow_state = src.state_class.new()
	src.render_state = src.state_class.new()
	src.state_field_names = NetPredictor._user_field_names(src.shadow_state)
	(src.shadow_state as PlayerState).pos = Vector3(11.0, 22.0, 33.0)

	var packet := NetStatePacket.new()
	packet.schema_id = schema.id
	packet.entity_id = 555
	packet.last_input_seq = 1
	packet.baseline_tick = 0
	packet.new_tick = 100
	packet.payload = src.snapshot_payload()

	# Arrives before register -> queued, not applied.
	reg._on_net_state(packet)
	assert_eq(reg.pending_count(schema.id, 555), 1)

	# Register the entity. Queue should drain into the predictor.
	var dst := NetPredictor.new()
	dst.schema = schema
	dst.shadow_state = dst.state_class.new()
	dst.render_state = dst.state_class.new()
	dst.state_field_names = NetPredictor._user_field_names(dst.shadow_state)
	reg.register_entity(schema.id, 555, dst)

	assert_eq(reg.pending_count(schema.id, 555), 0)
	assert_vec3_approx((dst.shadow_state as PlayerState).pos, Vector3(11.0, 22.0, 33.0))


func test_pending_buffer_trims_at_capacity() -> void:
	var reg := _new_registry()
	var schema := PlayerSchema.build()
	for i in range(reg.MAX_PENDING_PER_ENTITY + 5):
		var packet := NetStatePacket.new()
		packet.schema_id = schema.id
		packet.entity_id = 777
		packet.new_tick = i
		reg._on_net_state(packet)
	# Only the most recent MAX entries should be retained.
	assert_eq(reg.pending_count(schema.id, 777), reg.MAX_PENDING_PER_ENTITY)


func test_unregister_clears_pending() -> void:
	var reg := _new_registry()
	var schema := PlayerSchema.build()
	var p := NetPredictor.new()
	p.schema = schema

	reg.register_entity(schema.id, 888, p)
	reg.unregister_entity(schema.id, 888)
	# After unregister, packets queue fresh (no leftover state). Verify by
	# enqueuing one and checking count is 1, not 2.
	var packet := NetStatePacket.new()
	packet.schema_id = schema.id
	packet.entity_id = 888
	reg._on_net_state(packet)
	assert_eq(reg.pending_count(schema.id, 888), 1)


func _new_registry() -> Node:
	# Load the NetReplication script and instantiate it. We don't attach to a
	# scene tree, so its _ready won't run — _ready only wires the
	# NetworkClient.handle_net_state signal, which tests don't need.
	var script: Script = load("res://addons/netcode/core/net_replication.gd")
	return script.new()
