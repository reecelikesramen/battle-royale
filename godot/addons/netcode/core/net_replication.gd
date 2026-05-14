extends Node

# Registry that ties (schema_id, entity_id) -> NetPredictor for inbound packet
# routing and outbound iteration. Phase 6 uses a hard-coded schema_id=1 for the
# player; later phases will assign ids as schemas register.

signal entity_registered(schema_id: int, entity_id: int)
signal entity_unregistered(schema_id: int, entity_id: int)

# Sprint 7: spawn replication. The server calls spawn_entity() to request that
# every peer instantiate a networked entity; the receiver emits this signal
# and the world controller (e.g. a level script) listens, loads the scene at
# `scene_path`, sets the predictor's owner/entity ids, and adds it to the
# tree. Snapshot packets that arrived ahead of the spawn are already buffered
# by _on_net_state -> _pending_packets and drain automatically when the new
# predictor's _ready calls register_entity. (`min_spawn_seq` from the design
# doc is implicit: state packets queue until their target exists.)
signal entity_spawn_requested(schema_id: int, entity_id: int, scene_path: String, owner_peer_id: int)

# Reliable-hub topic id reserved for spawn dispatch. Picked from the high end
# of the int range to avoid colliding with user-defined topics; userspace
# should start its own topic numbering from 1.
const SPAWN_TOPIC: int = 65001

var _schemas: Dictionary = {}             # int -> NetSchema
var _entities: Dictionary = {}            # Vector2i(schema_id, entity_id) -> NetPredictor

# Sprint 7: drift detection. First registrant for a schema_id pins the
# expected content hash; subsequent registrants with the same id but a
# different hash emit a hard warning so build mismatch shows up at boot
# instead of as silent state corruption on the wire. Wire-level handshake
# enforcement (refuse-to-connect) lands in a follow-up that touches the
# Rust packet types.
var _schema_hashes: Dictionary = {}       # int (schema_id) -> int (NetSchema.compute_hash())

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
	if NetClient.has_signal("handle_net_state"):
		NetClient.handle_net_state.connect(_on_net_state)
	# Sprint 7: only the client subscribes to spawn packets. The server fires
	# entity_spawn_requested locally inside spawn_entity() so its own world
	# controller spawns without bouncing through the wire.
	NetReliableHub.subscribe(SPAWN_TOPIC, _on_spawn_payload)


func register_schema(schema_id: int, schema: NetSchema) -> void:
	# Sprint 7: pin the schema's content hash on first registration; warn if a
	# later registrant for the same id presents a different hash, which means
	# either two schemas are colliding on an id or the build is mid-rollout
	# (server upgraded fields but client still on previous version).
	var h: int = schema.compute_hash()
	if _schema_hashes.has(schema_id):
		var pinned: int = _schema_hashes[schema_id]
		if pinned != h:
			push_warning("NetReplication: schema_id %d hash mismatch (pinned=%d new=%d). Likely build skew between peers — wire decode will corrupt state." \
					% [schema_id, pinned, h])
	else:
		_schema_hashes[schema_id] = h
	_schemas[schema_id] = schema
	# Surface schema.validate() issues at startup so drift between the script
	# (state_template @export vars) and codec config (state_fields entries)
	# doesn't pass silently. Editor-time NetPredictor._get_configuration_warnings
	# shows the same list while authoring; this catches the case where the
	# schema is loaded into a build without editor inspection.
	# ERRORs hit push_error so they surface in the GUT/test output too;
	# WARNINGs go to push_warning. INFOs are suppressed at register time.
	for issue in schema.validate():
		var line: String = "NetReplication: schema_id %d %s" % [schema_id, issue.to_string_line()]
		match issue.severity:
			ValidationIssue.Severity.ERROR:
				push_error(line)
			ValidationIssue.Severity.WARNING:
				push_warning(line)
			_:
				pass


# Sprint 7: exposes the hash pinned by the first registrant for a schema_id.
# Used by the handshake / drift-detection layer to ship expected hashes to
# peers; returns 0 if no schema has registered under this id yet.
func get_schema_hash(schema_id: int) -> int:
	return _schema_hashes.get(schema_id, 0)


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


# Sprint 7: server-side spawn dispatch. Broadcasts a reliable SPAWN_TOPIC
# message to every peer carrying (schema_id, entity_id, scene_path, owner_peer_id),
# then fires entity_spawn_requested locally so the server's own world script
# spawns alongside. World controllers subscribe to entity_spawn_requested and
# decide how to actually instantiate (PackedScene load + add_child). The
# `owner_peer_id` is the peer that owns the entity's input stream (-1 for
# unowned entities like AI / props).
func spawn_entity(schema_id: int, entity_id: int, scene_path: String, owner_peer_id: int = -1) -> void:
	if not NetSession.is_server:
		push_warning("NetReplication.spawn_entity called on a non-server peer; ignored")
		return
	var payload: PackedByteArray = _encode_spawn(schema_id, entity_id, scene_path, owner_peer_id)
	NetReliableHub.broadcast(SPAWN_TOPIC, payload)
	entity_spawn_requested.emit(schema_id, entity_id, scene_path, owner_peer_id)


# Client-side reliable-hub callback. Decodes the wire payload and emits the
# signal that world scripts listen on. Tests can call this directly with a
# crafted payload to drive the spawn path without a NetSession.
func _on_spawn_payload(payload: PackedByteArray) -> void:
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var schema_id: int = sp.get_u32()
	var entity_id: int = sp.get_u32()
	var owner_peer_id: int = sp.get_32()
	var scene_path: String = sp.get_string()
	entity_spawn_requested.emit(schema_id, entity_id, scene_path, owner_peer_id)


func _encode_spawn(schema_id: int, entity_id: int, scene_path: String, owner_peer_id: int) -> PackedByteArray:
	var sp := StreamPeerBuffer.new()
	sp.put_u32(schema_id)
	sp.put_u32(entity_id)
	sp.put_32(owner_peer_id)
	sp.put_string(scene_path)
	return sp.data_array
