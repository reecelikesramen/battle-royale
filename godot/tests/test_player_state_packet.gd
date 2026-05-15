extends TestBase

# Smoke test the Rust-side Godot packet classes to catch breakage in the
# define_packet! macro / Vector3 / int / PackedByteArray conversions. Wire-
# level postcard roundtrips are covered in Rust unit tests; this is just the
# GDScript surface.

func test_net_command_packet_round_trips() -> void:
	var p := NetCommandPacket.new()
	p.schema_id = 1
	p.entity_id = 42
	p.sequence_id = 99
	p.timestamp_us = 1234
	p.last_received_tick = 12345
	p.payload = PackedByteArray([0xAA, 0xBB])
	assert_eq(p.schema_id, 1)
	assert_eq(p.entity_id, 42)
	assert_eq(p.sequence_id, 99)
	assert_eq(p.timestamp_us, 1234)
	assert_eq(p.last_received_tick, 12345)
	assert_eq(p.payload, PackedByteArray([0xAA, 0xBB]))


func test_net_state_packet_payload_round_trips() -> void:
	var p := NetStatePacket.new()
	p.schema_id = 1
	p.entity_id = 42
	p.last_input_seq = 99
	p.baseline_tick = 0
	p.new_tick = 5000
	var payload := PackedByteArray([0x01, 0x02, 0x03, 0x04])
	p.payload = payload
	assert_eq(p.schema_id, 1)
	assert_eq(p.entity_id, 42)
	assert_eq(p.new_tick, 5000)
	assert_eq(p.payload, payload)
