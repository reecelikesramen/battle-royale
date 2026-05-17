extends TestBase

# Sprint 7: NetReplication.spawn_entity broadcasts a reliable SPAWN_TOPIC
# message and fires entity_spawn_requested locally. The client-side hub
# subscriber decodes the payload and re-fires the same signal. Tests drive
# the decode path directly (no NetSession bind in test mode).


var _last_args: Array = []


func test_decode_spawn_payload_emits_signal() -> void:
	# Crafts a SPAWN_TOPIC wire payload and feeds it through the client-side
	# handler. The signal must surface every field intact.
	_last_args.clear()
	NetReplication.entity_spawn_requested.connect(_capture)

	var payload := NetReplication._encode_spawn(7, 42, "res://entities/dummy.tscn", 99)
	NetReplication._on_spawn_payload(payload)

	NetReplication.entity_spawn_requested.disconnect(_capture)
	assert_eq(_last_args.size(), 4, "signal not emitted")
	assert_eq(_last_args[0], 7, "schema_id mismatch")
	assert_eq(_last_args[1], 42, "entity_id mismatch")
	assert_eq(_last_args[2], "res://entities/dummy.tscn", "scene_path mismatch")
	assert_eq(_last_args[3], 99, "owner_peer_id mismatch")


func test_negative_owner_peer_id_round_trips() -> void:
	# owner_peer_id = -1 means "unowned" (AI / props). Verify the i32 codec
	# preserves the sign across encode + decode rather than truncating to a
	# u32 (which would surface as 4294967295).
	_last_args.clear()
	NetReplication.entity_spawn_requested.connect(_capture)

	var payload := NetReplication._encode_spawn(1, 1, "res://nope.tscn", -1)
	NetReplication._on_spawn_payload(payload)

	NetReplication.entity_spawn_requested.disconnect(_capture)
	assert_eq(_last_args[3], -1, "owner_peer_id should round-trip as -1")


func test_buffered_state_packet_flushes_on_register() -> void:
	# End-to-end Sprint 7 contract: a NetStatePacket arriving before the
	# spawning entity has registered must queue, then deliver as soon as the
	# spawn callback eventually adds the predictor. Existing _pending_packets
	# mechanism (Phase 9c) provides this; this test pins the contract under
	# the Sprint 7 spawn naming.
	const SCHEMA_ID := 88002
	const ENTITY_ID := 7
	var schema := NetSchema.new()
	schema.id = SCHEMA_ID
	NetReplication.register_schema(SCHEMA_ID, schema)

	# Drop a NetStatePacket on the floor before the entity registers — should
	# be buffered.
	var packet := NetStatePacket.new()
	packet.schema_id = SCHEMA_ID
	packet.entity_id = ENTITY_ID
	packet.last_input_seq = 1
	packet.baseline_tick = 0
	packet.new_tick = 33
	packet.payload = PackedByteArray([1])  # keyframe header, empty body (NetState has no @export fields).
	NetReplication._on_net_state(packet)
	assert_eq(NetReplication.pending_count(SCHEMA_ID, ENTITY_ID), 1,
			"packet should buffer while entity is unregistered")

	# Now register a fake predictor. The buffered packet should drain into it.
	var fake_predictor := _FakePredictor.new()
	NetReplication.register_entity(SCHEMA_ID, ENTITY_ID, fake_predictor)
	assert_eq(fake_predictor.received_count, 1, "buffered packet should drain on register")
	assert_eq(NetReplication.pending_count(SCHEMA_ID, ENTITY_ID), 0, "queue should be empty after drain")

	# Cleanup.
	NetReplication.unregister_entity(SCHEMA_ID, ENTITY_ID)
	NetReplication._schemas.erase(SCHEMA_ID)
	NetReplication._schema_hashes.erase(SCHEMA_ID)
	fake_predictor.free()


func _capture(schema_id: int, entity_id: int, scene_path: String, owner_peer_id: int) -> void:
	_last_args = [schema_id, entity_id, scene_path, owner_peer_id]


class _FakePredictor extends Node:
	var received_count: int = 0
	# Buffered state packets target client-side proxies; register as proxy so
	# the pending-packet drain on register_entity flushes into this fake.
	var is_authoritative_instance: bool = false
	func handle_net_state_packet(_packet) -> void:
		received_count += 1
