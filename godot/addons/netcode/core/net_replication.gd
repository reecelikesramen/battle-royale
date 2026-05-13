extends Node

# Registry that ties (schema_id, entity_id) -> NetPredictor for inbound packet
# routing and outbound iteration. Phase 6 uses a hard-coded schema_id=1 for the
# player; later phases will assign ids as schemas register.

signal entity_registered(schema_id: int, entity_id: int)
signal entity_unregistered(schema_id: int, entity_id: int)

var _schemas: Dictionary = {}             # int -> NetSchema
var _entities: Dictionary = {}            # Vector2i(schema_id, entity_id) -> NetPredictor

# Phase 9c: snapshots for entities not yet registered are queued instead of
# dropped. When the entity finally registers (typically after a deferred
# add_child chain triggered by IdAssignmentPacket), the queue flushes in
# arrival order so the predictor sees a coherent history.
# Bounded so a malicious or out-of-sync server can't OOM the receiver — keeping
# only the newest MAX_PENDING_PER_ENTITY entries; since deltas reference the
# prior baseline, an unbounded backlog wouldn't decode cleanly anyway.
const MAX_PENDING_PER_ENTITY: int = 8
var _pending_packets: Dictionary = {}     # Vector2i -> Array[NetStatePacket]


func _ready() -> void:
	if NetworkClient.has_signal("handle_net_state"):
		NetworkClient.handle_net_state.connect(_on_net_state)


func register_schema(schema_id: int, schema: NetSchema) -> void:
	_schemas[schema_id] = schema


func get_schema(schema_id: int) -> NetSchema:
	return _schemas.get(schema_id, null)


func register_entity(schema_id: int, entity_id: int, predictor) -> void:
	var key := Vector2i(schema_id, entity_id)
	_entities[key] = predictor
	entity_registered.emit(schema_id, entity_id)
	# Phase 9c: drain any snapshots that arrived before this entity registered.
	# Flushed in arrival order so a deltas-on-keyframe chain decodes correctly.
	if _pending_packets.has(key):
		var queued: Array = _pending_packets[key]
		_pending_packets.erase(key)
		for packet in queued:
			predictor.handle_net_state_packet(packet)


func unregister_entity(schema_id: int, entity_id: int) -> void:
	var key := Vector2i(schema_id, entity_id)
	_entities.erase(key)
	# Clear pending too — once the entity is gone, queued snapshots no longer
	# have a valid target. A future re-register starts from a fresh keyframe.
	_pending_packets.erase(key)
	entity_unregistered.emit(schema_id, entity_id)


func get_entity(schema_id: int, entity_id: int):
	return _entities.get(Vector2i(schema_id, entity_id), null)


# Iterates all predictors, yielding (schema_id, entity_id, predictor).
# Used by the server snapshot broadcast loop.
func iter_entities() -> Array:
	var out: Array = []
	for key in _entities:
		var k: Vector2i = key
		out.append([k.x, k.y, _entities[key]])
	return out


func _on_net_state(packet) -> void:
	var predictor = get_entity(packet.schema_id, packet.entity_id)
	if predictor == null:
		# Phase 9c: queue for when the entity registers. FIFO trim drops oldest
		# to bound memory; the most recent entries are most useful because a
		# subsequent keyframe will land within KEYFRAME_INTERVAL ticks.
		var key := Vector2i(packet.schema_id, packet.entity_id)
		var pending: Array = _pending_packets.get(key, [])
		pending.append(packet)
		while pending.size() > MAX_PENDING_PER_ENTITY:
			pending.pop_front()
		_pending_packets[key] = pending
		return
	predictor.handle_net_state_packet(packet)


# Test/debug helper: number of snapshots queued for entities that haven't
# registered yet.
func pending_count(schema_id: int, entity_id: int) -> int:
	var key := Vector2i(schema_id, entity_id)
	return _pending_packets.get(key, []).size()
