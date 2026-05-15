extends TestBase

# Phase 9a: the reliable hub dedupes (topic, idempotency_key) pairs and fans
# packets out to per-topic subscribers. Tests use the autoload directly since
# its state (idempotency rings, handlers) is process-global; each test cleans
# up after itself via unsubscribe + clearing the relevant topic.

func test_record_and_check_first_key_passes() -> void:
	var hub: Node = NetReliableHub
	# Use unique topic per test to avoid cross-test pollution.
	var topic := 9001
	assert_true(hub._record_and_check(topic, 1))
	# Repeat of same key should be rejected.
	assert_false(hub._record_and_check(topic, 1))
	# Different key on same topic should pass.
	assert_true(hub._record_and_check(topic, 2))
	hub._seen_keys_per_topic.erase(topic)


func test_dedup_ring_evicts_oldest_when_full() -> void:
	var hub: Node = NetReliableHub
	var topic := 9002
	var cap: int = hub.MAX_DEDUP_PER_TOPIC
	for i in cap:
		assert_true(hub._record_and_check(topic, i), "key %d should be new" % i)
	# Ring full. One more eviction-triggering insert.
	assert_true(hub._record_and_check(topic, cap), "key %d should be new (just inserted)" % cap)
	# The oldest (key 0) should have been evicted; reinserting it returns true.
	assert_true(hub._record_and_check(topic, 0), "key 0 should be evicted and re-acceptable")
	hub._seen_keys_per_topic.erase(topic)


func test_subscribe_and_dispatch_via_received_signal() -> void:
	var hub: Node = NetReliableHub
	var topic := 9003
	var seen_payloads: Array[PackedByteArray] = []
	var listener := func(payload: PackedByteArray): seen_payloads.append(payload)
	hub.subscribe(topic, listener)

	# Simulate an inbound packet by calling the client receive path directly.
	var packet := NetReliablePacket.new()
	packet.topic = topic
	packet.idempotency_key = 100
	packet.payload = PackedByteArray([0xCA, 0xFE])
	hub._on_client_reliable_packet(packet)

	assert_eq(seen_payloads.size(), 1)
	assert_eq(seen_payloads[0], PackedByteArray([0xCA, 0xFE]))

	hub.unsubscribe(topic, listener)
	hub._seen_keys_per_topic.erase(topic)


func test_duplicate_idempotency_key_drops_packet() -> void:
	var hub: Node = NetReliableHub
	var topic := 9004
	var call_count := [0]
	var listener := func(_payload: PackedByteArray): call_count[0] += 1
	hub.subscribe(topic, listener)

	var packet := NetReliablePacket.new()
	packet.topic = topic
	packet.idempotency_key = 555
	packet.payload = PackedByteArray()
	hub._on_client_reliable_packet(packet)
	hub._on_client_reliable_packet(packet)  # duplicate key
	hub._on_client_reliable_packet(packet)  # duplicate key

	assert_eq(call_count[0], 1, "duplicate idem keys should not re-fire")

	hub.unsubscribe(topic, listener)
	hub._seen_keys_per_topic.erase(topic)


func test_resolve_idem_key_increments_counter_when_unset() -> void:
	var hub: Node = NetReliableHub
	var before: int = hub._idem_counter
	var a: int = hub._resolve_idem_key(-1)
	var b: int = hub._resolve_idem_key(-1)
	assert_eq(a, before + 1)
	assert_eq(b, before + 2)
	# Explicit key passes through unchanged.
	assert_eq(hub._resolve_idem_key(42), 42)
