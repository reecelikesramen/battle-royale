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

# Framework-reserved topic IDs. Game code must keep its own Enums.ReliableTopic
# below 0xFF00 to avoid collisions. u16 wire on the Rust side, so range is
# 0..=65535; we reserve the high byte 0xFFxx for framework internals.
const TOPIC_ID_ASSIGNMENT: int = 0xFF00
const TOPIC_PLAYER_DISCONNECTED: int = 0xFF01

signal received(topic: int, payload: PackedByteArray, peer_id: int)

# topic -> Array[int] FIFO of idem keys we've already delivered.
# Split per side: in listen mode the same broadcast lands on the server (sender
# echo) AND the client (loopback receive). Shared ring would drop the second
# half. Pure-mode operation populates only one of the two.
var _seen_keys_per_topic_server: Dictionary = {}
var _seen_keys_per_topic_client: Dictionary = {}

# topic -> Array[Callable] handlers; called with (payload) on client, with
# (peer_id, payload) on server (peer_id = -1 on client-side).
# Legacy polymorphic bucket — fires on both sides. Kept for backward compat
# during migration; new code should use subscribe_server / subscribe_client.
var _handlers: Dictionary = {}

# Phase F5: role-scoped handler buckets. In listen mode (both roles active)
# the polymorphic _handlers bucket fires twice per packet (once with peer_id+
# payload, once with just payload) which forces game code to dispatch on
# Callable arity. Split buckets eliminate that ambiguity — subscribers
# explicitly opt into the role they want.
var _server_handlers: Dictionary = {}
var _client_handlers: Dictionary = {}

# Local idempotency-key counter. send / broadcast auto-fill when omitted.
var _idem_counter: int = 0


func _ready() -> void:
	if NetClient.has_signal("handle_net_reliable"):
		NetClient.handle_net_reliable.connect(_on_client_reliable_packet)
	if NetServer.has_signal("handle_net_reliable"):
		NetServer.handle_net_reliable.connect(_on_server_reliable_packet)


# DEPRECATED polymorphic subscribe — fires on BOTH server and client delivery.
# In listen mode this means one packet calls the handler twice with different
# arities, forcing the handler to branch. Migrate to subscribe_server or
# subscribe_client. Kept for backward compat.
func subscribe(topic: int, callback: Callable) -> void:
	if not _handlers.has(topic):
		_handlers[topic] = []
	_handlers[topic].append(callback)


# Fires only when the server-side reliable lane delivers this topic. Callback
# signature: cb(peer_id: int, payload: PackedByteArray).
func subscribe_server(topic: int, callback: Callable) -> void:
	if not _server_handlers.has(topic):
		_server_handlers[topic] = []
	_server_handlers[topic].append(callback)


# Fires only when the client-side reliable lane delivers this topic. Callback
# signature: cb(payload: PackedByteArray).
func subscribe_client(topic: int, callback: Callable) -> void:
	if not _client_handlers.has(topic):
		_client_handlers[topic] = []
	_client_handlers[topic].append(callback)


# Removes a previously-registered callback. Walks all three buckets so callers
# don't need to know which subscribe variant they used.
func unsubscribe(topic: int, callback: Callable) -> void:
	if _handlers.has(topic):
		_handlers[topic].erase(callback)
	if _server_handlers.has(topic):
		_server_handlers[topic].erase(callback)
	if _client_handlers.has(topic):
		_client_handlers[topic].erase(callback)


# Client -> server reliable send. Builds the packet and posts via the
# unreliable lane's send_packet (GNS routes by IS_RELIABLE).
func send(topic: int, payload: PackedByteArray, idempotency_key: int = -1) -> int:
	var key: int = _resolve_idem_key(idempotency_key)
	var packet := NetReliablePacket.new()
	packet.topic = topic
	packet.idempotency_key = key
	packet.payload = payload
	NetSession.send_packet(packet.to_payload())
	return key


# Server -> all-clients reliable broadcast.
func broadcast(topic: int, payload: PackedByteArray, idempotency_key: int = -1) -> int:
	var key: int = _resolve_idem_key(idempotency_key)
	var packet := NetReliablePacket.new()
	packet.topic = topic
	packet.idempotency_key = key
	packet.payload = payload
	NetSession.broadcast_packet(packet.to_payload())
	return key


# Server -> one-specific-peer reliable send. Used when a payload is meaningful
# only to a single recipient (e.g. that peer's own id-assignment on connect).
func send_to_peer(peer_id: int, topic: int, payload: PackedByteArray, idempotency_key: int = -1) -> int:
	var key: int = _resolve_idem_key(idempotency_key)
	var packet := NetReliablePacket.new()
	packet.topic = topic
	packet.idempotency_key = key
	packet.payload = payload
	NetSession.send_packet_to_peer(peer_id, packet.to_payload())
	return key


func _resolve_idem_key(supplied: int) -> int:
	if supplied >= 0:
		return supplied
	_idem_counter = (_idem_counter + 1) & 0xFFFFFFFF
	return _idem_counter


func _on_client_reliable_packet(packet) -> void:
	if not _record_and_check_client(packet.topic, packet.idempotency_key):
		return
	received.emit(packet.topic, packet.payload, -1)
	_dispatch(_client_handlers, packet.topic, [packet.payload])
	_dispatch(_handlers, packet.topic, [packet.payload])


func _on_server_reliable_packet(peer_id: int, packet) -> void:
	if not _record_and_check_server(packet.topic, packet.idempotency_key):
		return
	received.emit(packet.topic, packet.payload, peer_id)
	_dispatch(_server_handlers, packet.topic, [peer_id, packet.payload])
	_dispatch(_handlers, packet.topic, [peer_id, packet.payload])


# Iterates handlers for a topic, pruning any whose target was freed (autoload
# hub outlives scene-bound subscribers like ShootHandler — without this, a
# scene reload leaves a stale Callable that crashes on next dispatch).
func _dispatch(bucket: Dictionary, topic: int, args: Array) -> void:
	var handlers: Array = bucket.get(topic, [])
	if handlers.is_empty():
		return
	var alive: Array = []
	for cb in handlers:
		if not (cb is Callable) or not cb.is_valid():
			continue
		alive.append(cb)
		cb.callv(args)
	if alive.size() != handlers.size():
		bucket[topic] = alive


# Returns true if (topic, idem_key) is new for the given side ring. False if
# already-seen (drops the packet). Records the key on success.
func _record_and_check_server(topic: int, idem_key: int) -> bool:
	return _record_and_check_in(_seen_keys_per_topic_server, topic, idem_key)


func _record_and_check_client(topic: int, idem_key: int) -> bool:
	return _record_and_check_in(_seen_keys_per_topic_client, topic, idem_key)


func _record_and_check_in(ring: Dictionary, topic: int, idem_key: int) -> bool:
	var seen: Array = ring.get(topic, [])
	if idem_key in seen:
		return false
	seen.append(idem_key)
	if seen.size() > MAX_DEDUP_PER_TOPIC:
		seen.pop_front()
	ring[topic] = seen
	return true
