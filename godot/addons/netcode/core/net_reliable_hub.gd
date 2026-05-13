extends Node

# Phase 9 autoload that brokers reliable RPCs across the GNS reliable lane.
# Subsystems register a callback for an integer topic id; on packet arrival
# the hub dedupes by (topic, idempotency_key) and fans the payload out to
# every registered callback for that topic.
#
# Dedup state per topic is a bounded FIFO ring (MAX_DEDUP_PER_TOPIC) so a
# misbehaving sender flooding new keys can't OOM the receiver. Keys older
# than the ring eventually re-fire — pick a window big enough that the
# wraparound interval exceeds your idempotency requirement.
#
# Topic numbering is per-game: define an enum like
#   class_name ReliableTopics: const INVENTORY := 1; const SCORE := 2; ...
# and pass those into subscribe / send / broadcast. Phase 9b will wire the
# Inventory entity as the first user.

const MAX_DEDUP_PER_TOPIC: int = 256

signal received(topic: int, payload: PackedByteArray, peer_id: int)

# topic -> Array[int] FIFO of idem keys we've already delivered.
var _seen_keys_per_topic: Dictionary = {}

# topic -> Array[Callable] handlers; called with (payload) on client, with
# (peer_id, payload) on server (peer_id = -1 on client-side).
var _handlers: Dictionary = {}

# Local idempotency-key counter. send / broadcast auto-fill when omitted.
var _idem_counter: int = 0


func _ready() -> void:
	if NetworkClient.has_signal("handle_net_reliable"):
		NetworkClient.handle_net_reliable.connect(_on_client_reliable_packet)
	if NetworkServer.has_signal("handle_net_reliable"):
		NetworkServer.handle_net_reliable.connect(_on_server_reliable_packet)


# Adds a callback for a topic. Server-side callbacks receive
# (peer_id: int, payload: PackedByteArray); client-side receive
# (peer_id == -1, payload). Multiple callbacks per topic supported.
func subscribe(topic: int, callback: Callable) -> void:
	if not _handlers.has(topic):
		_handlers[topic] = []
	_handlers[topic].append(callback)


# Removes a previously-registered callback. Silent if not found.
func unsubscribe(topic: int, callback: Callable) -> void:
	if _handlers.has(topic):
		_handlers[topic].erase(callback)


# Client -> server reliable send. Builds the packet and posts via the
# unreliable lane's send_packet (GNS routes by IS_RELIABLE).
func send(topic: int, payload: PackedByteArray, idempotency_key: int = -1) -> int:
	var key: int = _resolve_idem_key(idempotency_key)
	var packet := NetReliablePacket.new()
	packet.topic = topic
	packet.idempotency_key = key
	packet.payload = payload
	NetworkTransport.send_packet(packet.to_payload())
	return key


# Server -> all-clients reliable broadcast.
func broadcast(topic: int, payload: PackedByteArray, idempotency_key: int = -1) -> int:
	var key: int = _resolve_idem_key(idempotency_key)
	var packet := NetReliablePacket.new()
	packet.topic = topic
	packet.idempotency_key = key
	packet.payload = payload
	NetworkTransport.broadcast_packet(packet.to_payload())
	return key


func _resolve_idem_key(supplied: int) -> int:
	if supplied >= 0:
		return supplied
	_idem_counter = (_idem_counter + 1) & 0xFFFFFFFF
	return _idem_counter


func _on_client_reliable_packet(packet) -> void:
	if not _record_and_check(packet.topic, packet.idempotency_key):
		return
	received.emit(packet.topic, packet.payload, -1)
	for cb in _handlers.get(packet.topic, []):
		cb.call(packet.payload)


func _on_server_reliable_packet(peer_id: int, packet) -> void:
	if not _record_and_check(packet.topic, packet.idempotency_key):
		return
	received.emit(packet.topic, packet.payload, peer_id)
	for cb in _handlers.get(packet.topic, []):
		cb.call(peer_id, packet.payload)


# Returns true if (topic, idem_key) is new and should be delivered. False if
# already-seen (drops the packet). Records the key on success.
func _record_and_check(topic: int, idem_key: int) -> bool:
	var seen: Array = _seen_keys_per_topic.get(topic, [])
	if idem_key in seen:
		return false
	seen.append(idem_key)
	if seen.size() > MAX_DEDUP_PER_TOPIC:
		seen.pop_front()
	_seen_keys_per_topic[topic] = seen
	return true
