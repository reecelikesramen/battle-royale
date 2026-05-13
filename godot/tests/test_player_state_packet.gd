extends TestBase

# Smoke test the Rust-side PlayerStatePacket godot class to catch breakage in
# the define_packet! macro / Vector3 / int conversions. The Wire-level postcard
# roundtrip is covered in Rust unit tests; here we just verify the GDScript
# surface stays sane.

func test_construct_and_read_back_fields() -> void:
	var p := PlayerStatePacket.new()
	p.player_id = 3
	p.last_input_sequence_id = 1024
	p.timestamp_us = 1_234_567
	p.position = Vector3(5.0, 10.0, -2.5)
	p.look_abs = Vector2(0.5, -0.25)
	p.velocity = Vector3(1.0, 0.0, 0.0)
	p.movement_state = 4
	p.crouch_progress = 0.5
	p.prone_progress = 0.0
	p.peek_state = 2
	p.peek_progress = 0.3

	assert_eq(p.player_id, 3)
	assert_eq(p.last_input_sequence_id, 1024)
	assert_eq(p.timestamp_us, 1_234_567)
	assert_vec3_approx(p.position, Vector3(5.0, 10.0, -2.5))
	assert_eq(p.look_abs, Vector2(0.5, -0.25))
	assert_eq(p.movement_state, 4)
	assert_approx(p.crouch_progress, 0.5)


func test_player_input_packet_last_received_tick() -> void:
	var p := PlayerInputPacket.new()
	p.last_received_tick = 12345
	assert_eq(p.last_received_tick, 12345)


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
