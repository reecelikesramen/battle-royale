extends TestBase

# NetPredictor auto-subscribes to NetServer.handle_net_command when it has a
# command_template set, on the server only. Each predictor filters incoming
# packets by (schema_id, entity_id, peer_id == owner_id), decodes the schema-
# driven payload into a typed NetCommand, and enqueues for the next server_tick.


class _PktSim:
	# Stand-in for NetCommandPacket. Carries the fields _on_server_net_command
	# reads. Real wire packet is the Rust NetCommandPacket; this duck-types it
	# so the test doesn't need to build a live network stack.
	var schema_id: int = 9100
	var entity_id: int = 0
	var sequence_id: int = 0
	var timestamp_us: int = 0
	var last_received_tick: int = 0
	var payload: PackedByteArray = PackedByteArray()


func _make_predictor(owner_id: int, entity_id: int = 0) -> NetPredictor:
	var schema := NetSchema.new()
	schema.id = 9100
	schema.state_template = NetState.new()
	schema.command_template = NetCommand.new()
	var p := NetPredictor.new()
	p.schema = schema
	p.owner_id = owner_id
	p.entity_id = entity_id
	p.shadow_state = schema.state_template.duplicate(true) as NetState
	p.render_state = schema.state_template.duplicate(true) as NetState
	p.state_field_names = PackedStringArray()
	p.command_field_names = PackedStringArray()
	return p


func test_input_for_owner_enqueues() -> void:
	var p := _make_predictor(42, 42)
	var pkt := _PktSim.new()
	pkt.entity_id = 42
	pkt.sequence_id = 7
	pkt.timestamp_us = 12345
	p._on_server_net_command(42, pkt)
	assert_eq(p.server_input_queue.size(), 1, "owner's packet should land in the queue")


func test_input_for_other_peer_is_dropped() -> void:
	# Predictor owned by peer 42 receives a packet from peer 99 — must drop.
	var p := _make_predictor(42, 42)
	var pkt := _PktSim.new()
	pkt.entity_id = 42
	pkt.sequence_id = 3
	p._on_server_net_command(99, pkt)
	assert_eq(p.server_input_queue.size(), 0, "non-owner packet must be dropped")


func test_owner_id_minus_one_drops_unowned_packets() -> void:
	var p := _make_predictor(-1, -1)
	var pkt := _PktSim.new()
	p._on_server_net_command(0, pkt)
	p._on_server_net_command(7, pkt)
	assert_eq(p.server_input_queue.size(), 0)


func test_wrong_schema_id_is_dropped() -> void:
	# Phase 6: predictor must reject packets routed to a different schema even
	# from the right peer — multi-entity scenarios can't accept cross-schema
	# input bytes.
	var p := _make_predictor(42, 42)
	var pkt := _PktSim.new()
	pkt.schema_id = 9999
	pkt.entity_id = 42
	p._on_server_net_command(42, pkt)
	assert_eq(p.server_input_queue.size(), 0, "wrong schema_id must be dropped")


func test_wrong_entity_id_is_dropped() -> void:
	var p := _make_predictor(42, 42)
	var pkt := _PktSim.new()
	pkt.entity_id = 13
	p._on_server_net_command(42, pkt)
	assert_eq(p.server_input_queue.size(), 0, "wrong entity_id must be dropped")
