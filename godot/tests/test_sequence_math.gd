extends TestBase

# Mirror of the Rust seq math tests but exercised through the Godot-exposed
# PacketSequence class so we catch regressions in the binding layer too.

func test_diff_forward() -> void:
	assert_eq(PacketSequence.diff(10, 5), 5)
	assert_eq(PacketSequence.diff(0, 0), 0)


func test_diff_backward() -> void:
	assert_eq(PacketSequence.diff(5, 10), -5)


func test_is_newer_simple() -> void:
	assert_true(PacketSequence.is_newer(10, 5))
	assert_false(PacketSequence.is_newer(5, 10))


func test_is_newer_around_wrap() -> void:
	assert_true(PacketSequence.is_newer(5, 65530), "5 should be newer than 65530 across wrap")
	assert_false(PacketSequence.is_newer(65530, 5))


func test_is_newer_or_equal() -> void:
	assert_true(PacketSequence.is_newer_or_equal(42, 42))
	assert_true(PacketSequence.is_newer_or_equal(10, 5))
	assert_false(PacketSequence.is_newer_or_equal(5, 10))


func test_next_increments_and_wraps() -> void:
	var seq := PacketSequence.new()
	# next() goes -1 -> 0 -> 1 -> ... -> 65535 -> 0 (mod 65536)
	assert_eq(seq.next(), 0)
	assert_eq(seq.next(), 1)
	# Burn calls 3..65536 — leaves internal value at 65535.
	for i in range(65534):
		seq.next()
	# 65537th call should wrap to 0.
	assert_eq(seq.next(), 0, "expected wrap to 0 after 65535")
