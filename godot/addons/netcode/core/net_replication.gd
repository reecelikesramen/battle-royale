extends Node

# Registry that ties (schema_id, entity_id) -> NetPredictor for inbound packet
# routing and outbound iteration. Phase 6 uses a hard-coded schema_id=1 for the
# player; later phases will assign ids as schemas register.

signal entity_registered(schema_id: int, entity_id: int, is_authoritative: bool)
signal entity_unregistered(schema_id: int, entity_id: int, is_authoritative: bool)

# Spawn dispatch is split per role so listen-server can create distinct
# server-authoritative + client-proxy instances of the same logical entity.
#
# `server_entity_spawn_requested` fires on the server-side path (spawn_entity
# local emit). Subscribers parent the entity under their ServerEntitiesRoot
# and set NetPredictor.is_authoritative_instance = true.
#
# `client_entity_spawn_requested` fires when the reliable SPAWN_TOPIC payload
# is received (remote clients in multiplayer; loopback receipt in listen
# mode). Subscribers parent under ClientEntitiesRoot with auth = false.
#
# Snapshot packets that arrived ahead of the proxy spawn are buffered by
# _on_net_state -> _pending_packets and drain when the predictor's _ready
# calls register_entity. (`min_spawn_seq` from the design doc is implicit.)
signal server_entity_spawn_requested(schema_id: int, entity_id: int, scene_path: String, owner_peer_id: int)
signal client_entity_spawn_requested(schema_id: int, entity_id: int, scene_path: String, owner_peer_id: int)

# Reliable-hub topic id reserved for spawn dispatch. Picked from the high end
# of the int range to avoid colliding with user-defined topics; userspace
# should start its own topic numbering from 1.
const SPAWN_TOPIC: int = 65001

var _schemas: Dictionary = {}             # int -> NetSchema

# Phase D split: in listen-server mode the same (schema_id, entity_id) maps to
# two NetPredictor instances — one server-authoritative (drives outbound state
# broadcast) and one client-rendered proxy (receives inbound state packets).
# Single-mode operation populates only one of the two registries. Predictors
# self-route into the correct registry via NetPredictor.is_authoritative_instance.
var _server_entities: Dictionary = {}     # Vector2i -> NetPredictor (auth)
var _client_entities: Dictionary = {}     # Vector2i -> NetPredictor (proxy)

# Sprint 7: drift detection. First registrant for a schema_id pins the
# expected content hash; subsequent registrants with the same id but a
# different hash emit a hard warning so build mismatch shows up at boot
# instead of as silent state corruption on the wire. Wire-level handshake
# enforcement (refuse-to-connect) lands in a follow-up that touches the
# Rust packet types.
var _schema_hashes: Dictionary = {}       # int (schema_id) -> int (NetSchema.compute_hash())

# Phase 9c: snapshots for entities not yet registered are queued instead of
# dropped. When the entity finally registers (typically after a deferred
# add_child chain triggered by id-assignment), the queue flushes in
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
	# Spawn dispatch payloads only travel server → clients (host emits its own
	# auth instance locally inside spawn_entity). Subscribe on the client lane
	# only so the loopback echo in listen mode doesn't re-emit the proxy spawn
	# inside server reception.
	NetReliableHub.subscribe_client(SPAWN_TOPIC, _on_spawn_payload)


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


# Predictor's is_authoritative_instance routes the registration into the
# correct dual-mode registry. Non-NetPredictor fixtures (test fakes) without
# the field default to server-side, since that's the dominant pre-listen-mode
# convention for tests that bypass scene-level spawn flow.
func _is_authoritative(predictor) -> bool:
	if "is_authoritative_instance" in predictor:
		return predictor.is_authoritative_instance
	return true


func register_entity(schema_id: int, entity_id: int, predictor) -> void:
	var key := Vector2i(schema_id, entity_id)
	var is_auth: bool = _is_authoritative(predictor)
	if is_auth:
		_server_entities[key] = predictor
		_pending_auth_spawns.erase(key)
	else:
		_client_entities[key] = predictor
		_pending_proxy_spawns.erase(key)
	entity_registered.emit(schema_id, entity_id, is_auth)
	# Phase 9c: drain any snapshots that arrived before this entity registered.
	# Only proxies receive snapshots (state flows server → client), so only
	# client-side registration triggers the flush. Authoritative-only single-
	# mode operation (DEDICATED_SERVER) never has pending packets to drain.
	if not is_auth and _pending_packets.has(key):
		var queued: Array = _pending_packets[key]
		_pending_packets.erase(key)
		for packet in queued:
			predictor.handle_net_state_packet(packet)


func unregister_entity(schema_id: int, entity_id: int) -> void:
	var key := Vector2i(schema_id, entity_id)
	var was_auth: bool = _server_entities.has(key)
	var was_proxy: bool = _client_entities.has(key)
	# Re-entry from the cascade-free path: auth unregister queue_frees the proxy
	# host, whose _exit_tree calls back into unregister_entity with both keys
	# already gone. Without this guard, listeners fire twice per entity death.
	if not was_auth and not was_proxy:
		return
	# Cascade-free a co-resident proxy when its auth unregisters (listen mode
	# only). Without this, NetProxyBlender's buffer drains to null after the
	# auth queue_frees and DISCRETE fields fall back to the last known value —
	# proxies get stuck rendering their final frame forever (grenades hung in
	# EXPLODING on the explosion site). Auth unregister is the canonical
	# "no more snapshots are coming" signal, so the proxy can free immediately.
	# Capture the proxy ref before erasing so the cascade queue_free still has
	# something to act on.
	var proxy_to_free: NetPredictor = null
	if was_auth and was_proxy:
		proxy_to_free = _client_entities[key]
	_server_entities.erase(key)
	_client_entities.erase(key)
	_pending_packets.erase(key)
	if proxy_to_free != null and is_instance_valid(proxy_to_free) and is_instance_valid(proxy_to_free.host):
		proxy_to_free.host.queue_free()
	# Use was_auth as the is_authoritative flag; if both sides existed the
	# auth-side unregister fires first. Listeners that care can re-check via
	# is_predictor_authoritative — but generally unregister handlers don't
	# branch on role.
	entity_unregistered.emit(schema_id, entity_id, was_auth)


# Lookup defaults to "server registry first, fall back to client". In single-
# mode operation only one registry is populated so the lookup hits whichever
# exists; in listen-server the default returns the authoritative instance
# (which is what every server-side game-logic caller wants — lag-comp, blast
# damage iteration, hit resolution). Pass `prefer_server` explicitly to force
# one side (e.g. a client-only debug overlay enumerating proxies).
func get_entity(schema_id: int, entity_id: int, prefer_server: Variant = null):
	var key := Vector2i(schema_id, entity_id)
	if prefer_server != null:
		return (_server_entities if bool(prefer_server) else _client_entities).get(key, null)
	var p = _server_entities.get(key, null)
	if p != null:
		return p
	return _client_entities.get(key, null)


# Iterates predictors. Default merges both registries (server first); explicit
# `prefer_server` restricts to one side. Server-only entries are emitted
# first so order-sensitive callers (lag-comp rewind) see authoritative state.
func iter_entities(prefer_server: Variant = null) -> Array:
	var out: Array = []
	if prefer_server != null:
		var registry: Dictionary = _server_entities if bool(prefer_server) else _client_entities
		for key in registry:
			var k: Vector2i = key
			out.append([k.x, k.y, registry[key]])
		return out
	for key in _server_entities:
		var k: Vector2i = key
		out.append([k.x, k.y, _server_entities[key]])
	for key in _client_entities:
		if _server_entities.has(key):
			continue
		var k: Vector2i = key
		out.append([k.x, k.y, _client_entities[key]])
	return out


func _on_net_state(packet) -> void:
	# State packets target client-side proxies — server doesn't replay its own
	# snapshots back into its auth instances. Always look up in client registry.
	var key := Vector2i(packet.schema_id, packet.entity_id)
	var predictor = _client_entities.get(key, null)
	if predictor == null:
		# Phase 9c: queue for when the proxy registers. FIFO trim drops oldest
		# to bound memory; recent entries are most useful because a subsequent
		# keyframe will land within KEYFRAME_INTERVAL ticks.
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


# Server-side spawn dispatch. Broadcasts a reliable SPAWN_TOPIC message to
# every peer carrying (schema_id, entity_id, scene_path, owner_peer_id), then
# fires server_entity_spawn_requested locally so the server's own world script
# spawns the authoritative instance alongside. Remote clients (and the loop-
# back client in listen mode) receive the broadcast and emit the client
# variant of the signal — see _on_spawn_payload.
func spawn_entity(schema_id: int, entity_id: int, scene_path: String, owner_peer_id: int = -1) -> void:
	if not NetSession.has_server_role:
		push_warning("NetReplication.spawn_entity called on a non-server peer; ignored")
		return
	var payload: PackedByteArray = _encode_spawn(schema_id, entity_id, scene_path, owner_peer_id)
	NetReliableHub.broadcast(SPAWN_TOPIC, payload)
	server_entity_spawn_requested.emit(schema_id, entity_id, scene_path, owner_peer_id)


# Reliable-hub callback that fires on any peer receiving a SPAWN_TOPIC payload
# (remote clients in multiplayer, loopback client in listen mode). Decodes the
# wire payload and emits the client-side spawn signal so the local world
# script can instantiate the proxy. Tests can call this directly to drive the
# decode path without a NetSession.
func _on_spawn_payload(payload: PackedByteArray) -> void:
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var schema_id: int = sp.get_u32()
	var entity_id: int = sp.get_u32()
	var owner_peer_id: int = sp.get_32()
	var scene_path: String = sp.get_string()
	client_entity_spawn_requested.emit(schema_id, entity_id, scene_path, owner_peer_id)


func _encode_spawn(schema_id: int, entity_id: int, scene_path: String, owner_peer_id: int) -> PackedByteArray:
	var sp := StreamPeerBuffer.new()
	sp.put_u32(schema_id)
	sp.put_u32(entity_id)
	sp.put_32(owner_peer_id)
	sp.put_string(scene_path)
	return sp.data_array


# F1: framework-owned spawn placement. Game registers a scene + parent once
# per schema; framework instantiates + parents + stamps is_authoritative_instance
# whenever a spawn signal fires (whether from spawn_entity, bind_peer_entity, or
# a SPAWN_TOPIC loopback receive). Game stops needing per-role spawner forks.
var _entity_scene_config: Dictionary = {}  # schema_id -> {scene_path, parent}
# Synchronous "we're about to spawn this" markers. NetPredictor.register_entity
# happens inside NetPredictor._ready which is deferred via call_deferred(
# "add_child"), so _server_entities / _client_entities aren't populated until
# the next frame. Without a synchronous marker, a peer-event spawn followed by
# a same-frame backfill spawn would both pass the registry-idempotency check
# and double-instantiate. These dicts clear lazily in _instantiate_for_role.
var _pending_auth_spawns: Dictionary = {}    # Vector2i -> true
var _pending_proxy_spawns: Dictionary = {}   # Vector2i -> true


func register_entity_scene(schema_id: int, scene_path: String, parent: Node) -> void:
	_entity_scene_config[schema_id] = {"scene_path": scene_path, "parent": parent}
	if not server_entity_spawn_requested.is_connected(_auto_instantiate_auth):
		server_entity_spawn_requested.connect(_auto_instantiate_auth)
	if not client_entity_spawn_requested.is_connected(_auto_instantiate_proxy):
		client_entity_spawn_requested.connect(_auto_instantiate_proxy)


# Per-peer auto-spawn driver. Wraps register_entity_scene + binds every peer
# event (server-side connect/disconnect, client-side id-assignment / player-
# disconnected / disconnect-from-server) to spawn or despawn the entity for
# that peer. After this call the game spawner is just a one-liner — no roster
# bookkeeping, no role bifurcation, no backfill loops.
func bind_peer_entity(schema_id: int, scene_path: String, parent: Node) -> void:
	register_entity_scene(schema_id, scene_path, parent)
	NetSession.on_peer_connect.connect(
			func(peer_id): _spawn_peer_auth(schema_id, peer_id, scene_path))
	NetSession.on_peer_disconnect.connect(
			func(peer_id): _despawn_peer_entity(schema_id, peer_id))
	NetClient.handle_local_id_assignment.connect(
			func(peer_id): _spawn_peer_proxy(schema_id, peer_id, scene_path))
	NetClient.handle_remote_id_assignment.connect(
			func(peer_id): _spawn_peer_proxy(schema_id, peer_id, scene_path))
	NetClient.handle_player_disconnected.connect(
			func(peer_id): _despawn_peer_entity(schema_id, peer_id))
	NetClient.handle_disconnect_from_server.connect(
			func(): _despawn_all_for_schema(schema_id))
	# Backfill once role identity settles. Peer events that fired before this
	# subscription (typical in listen mode: on_peer_connect fires inside
	# start_listen_mode before downstream subscribers exist) are caught here.
	NetSession.when_roles_ready(
			func(): _backfill_peer_entities(schema_id, scene_path))


func _backfill_peer_entities(schema_id: int, scene_path: String) -> void:
	if NetSession.has_server_role:
		for pid in NetServer.peer_ids:
			_spawn_peer_auth(schema_id, pid, scene_path)
	if NetSession.has_client_role:
		if NetClient.id != -1:
			_spawn_peer_proxy(schema_id, NetClient.id, scene_path)
		for rid in NetClient.remote_ids:
			if rid != NetClient.id:
				_spawn_peer_proxy(schema_id, rid, scene_path)


# Idempotent local-only spawn — no SPAWN_TOPIC broadcast. Peer entities are
# discovered via id-assignment / peer-connect, not arbitrary spawn calls, so
# they don't go on the reliable wire.
func _spawn_peer_auth(schema_id: int, peer_id: int, scene_path: String) -> void:
	var key := Vector2i(schema_id, peer_id)
	if _server_entities.has(key) or _pending_auth_spawns.has(key):
		return
	server_entity_spawn_requested.emit(schema_id, peer_id, scene_path, peer_id)


func _spawn_peer_proxy(schema_id: int, peer_id: int, scene_path: String) -> void:
	var key := Vector2i(schema_id, peer_id)
	if _client_entities.has(key) or _pending_proxy_spawns.has(key):
		return
	client_entity_spawn_requested.emit(schema_id, peer_id, scene_path, peer_id)


func _auto_instantiate_auth(schema_id: int, entity_id: int, scene_path: String, owner_peer_id: int) -> void:
	if not _entity_scene_config.has(schema_id):
		return
	_instantiate_for_role(_entity_scene_config[schema_id].parent,
			schema_id, entity_id, scene_path, owner_peer_id, true)


func _auto_instantiate_proxy(schema_id: int, entity_id: int, scene_path: String, owner_peer_id: int) -> void:
	if not _entity_scene_config.has(schema_id):
		return
	_instantiate_for_role(_entity_scene_config[schema_id].parent,
			schema_id, entity_id, scene_path, owner_peer_id, false)


func _instantiate_for_role(parent: Node, schema_id: int, entity_id: int, scene_path: String, owner_peer_id: int, is_auth: bool) -> void:
	var key := Vector2i(schema_id, entity_id)
	# Pending markers also guard the same-frame spawn_entity-then-loopback race
	# (server emits server_entity_spawn_requested locally and the SPAWN_TOPIC
	# loopback hits client_entity_spawn_requested; those go to separate auto-
	# instantiate handlers so the per-side dict guards each independently).
	var pending: Dictionary = _pending_auth_spawns if is_auth else _pending_proxy_spawns
	var registry: Dictionary = _server_entities if is_auth else _client_entities
	if registry.has(key) or pending.has(key):
		return
	pending[key] = true
	var scene: PackedScene = load(scene_path) as PackedScene
	if scene == null:
		pending.erase(key)
		push_error("[NetReplication] failed to load scene %s" % scene_path)
		return
	var instance: Node = scene.instantiate()
	# Disambiguate auth vs proxy siblings in listen mode. Single-mode runs only
	# spawn one side so name collisions wouldn't happen anyway.
	instance.name = "E_%d_%d_%s" % [schema_id, entity_id, "auth" if is_auth else "proxy"]
	var pred: NetPredictor = instance.get_node_or_null("NetPredictor") as NetPredictor
	if pred == null:
		pending.erase(key)
		push_error("[NetReplication] scene %s has no NetPredictor child — cannot wire" % scene_path)
		instance.queue_free()
		return
	pred.entity_id = entity_id
	pred.owner_id = owner_peer_id if owner_peer_id >= 0 else entity_id
	pred.is_authoritative_instance = is_auth
	# Convention: hosts with a `_owner_id` script var read it before NetPredictor
	# registers (PlayerController does in _enter_tree). Fill it in alongside the
	# predictor fields so scripts don't have to subscribe to entity_registered
	# just to get their owner id.
	if "_owner_id" in instance:
		instance._owner_id = pred.owner_id
	parent.call_deferred("add_child", instance)


func _despawn_peer_entity(schema_id: int, peer_id: int) -> void:
	_despawn_pair(schema_id, peer_id)


func _despawn_pair(schema_id: int, entity_id: int) -> void:
	var key := Vector2i(schema_id, entity_id)
	if _server_entities.has(key):
		var s = _server_entities[key]
		if is_instance_valid(s) and is_instance_valid(s.host):
			if s.host.has_method(&"despawn"):
				s.host.despawn()
			s.host.queue_free()
	if _client_entities.has(key):
		var c = _client_entities[key]
		if is_instance_valid(c) and is_instance_valid(c.host):
			if c.host.has_method(&"despawn"):
				c.host.despawn()
			c.host.queue_free()


func _despawn_all_for_schema(schema_id: int) -> void:
	for key in _server_entities.keys():
		if key.x == schema_id:
			_despawn_pair(schema_id, key.y)
	for key in _client_entities.keys():
		if key.x == schema_id:
			_despawn_pair(schema_id, key.y)


# Query helper: useful for entity_registered handlers that need to know which
# side just registered without re-checking dicts by hand.
func is_predictor_authoritative(schema_id: int, entity_id: int) -> bool:
	return _server_entities.has(Vector2i(schema_id, entity_id))


# Called by NetSession.shutdown_all. Predictor _exit_tree handles registry
# cleanup for entities still in the scene tree; this clears the
# pre-_ready pending markers (instances mid-call_deferred("add_child") when
# shutdown hit) and any buffered snapshots whose target proxy will never
# register. Without this, a second start_listen_mode in the same process can
# see stale pending markers that block re-spawn of the same (schema, entity)
# pair, leaving a ghost predictor in the registry and no live host node.
func reset_session_state() -> void:
	_pending_auth_spawns.clear()
	_pending_proxy_spawns.clear()
	_pending_packets.clear()
