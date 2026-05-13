extends TestBase

# Phase 2: JitterBuffer must dedup by sequence_id, drop stale (already
# consumed) or absurdly future sequence ids, and surface consumed packets in
# order with reasonable per-frame deltas.

func test_dedup_same_sequence_id() -> void:
	var jb := JitterBuffer.new()
	var p1 := _packet(1, 1000)
	var p2 := _packet(1, 1500)
	jb.enqueue(p1.sequence_id, p1.timestamp_us, p1)
	jb.enqueue(p2.sequence_id, p2.timestamp_us, p2)
	assert_eq(jb.size(), 1, "duplicate seq_id should be dropped")


func test_stale_sequence_dropped_after_consume() -> void:
	var jb := JitterBuffer.new()
	# Fill enough to allow consume past PACKET_LOSS_TOLERANCE
	for i in range(8):
		var p := _packet(i, i * 10000 + 1000)
		jb.enqueue(p.sequence_id, p.timestamp_us, p)
	var _consumed := jb.consume()
	# Re-enqueue an already-consumed id; size should not increase.
	var size_before: int = jb.size()
	jb.enqueue(0, 1000, _packet(0, 1000))
	assert_eq(jb.size(), size_before, "stale seq should not be re-buffered")


func test_far_future_sequence_dropped() -> void:
	var jb := JitterBuffer.new()
	# MAX_INPUT_AGE_TICKS = 26
	jb.enqueue(100, 1_000_000, _packet(100, 1_000_000))
	assert_eq(jb.size(), 0, "seq 100 ticks ahead should be dropped")


func test_in_window_future_accepted() -> void:
	var jb := JitterBuffer.new()
	jb.enqueue(10, 1_000_000, _packet(10, 1_000_000))
	assert_eq(jb.size(), 1)


# Helper: produce a PlayerInputPacket with the bare-minimum fields the buffer
# inspects (sequence_id, timestamp_us). All other fields stay defaults.
func _packet(seq: int, ts_us: int) -> PlayerInputPacket:
	var p := PlayerInputPacket.new()
	p.sequence_id = seq
	p.timestamp_us = ts_us
	return p
