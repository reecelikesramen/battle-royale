class_name GrenadeSpawner extends Node3D

# On-demand spawn via NetReplication.spawn_entity. Framework instantiates auth
# (server) and proxy (clients) automatically via register_entity_scene; this
# script just decodes the throw payload + fills in game-specific spawn data
# (thrower_id, origin, velocity) once the auth predictor lands in the registry.

const GRENADE_SCHEMA_ID := 2
const GRENADE_SCENE_PATH := "res://entities/grenade/grenade.tscn"
const GHOST_GRENADE_SCENE_PATH := "res://entities/grenade/ghost_grenade.tscn"
const THROW_COOLDOWN_SEC := 1.0

# Local ghost-grenade prediction (client-side, local thrower only).
# Match heuristic in try_match_ghost: oldest ghost whose age sits inside this
# window and whose current pos is within GHOST_MATCH_DISTANCE of the proxy's
# first-frame pos. Min-age guards against ghosts that haven't simulated long
# enough to be plausibly attributable to an incoming proxy; max-age trims
# stragglers from rejected throws.
const GHOST_MATCH_DISTANCE: float = 5.0
const GHOST_MIN_MATCH_AGE_US: int = 30_000          # 30ms — covers loopback / LAN
const GHOST_MAX_MATCH_AGE_US: int = 2_000_000       # 2s — beyond this, treat as stale
const MAX_LOCAL_GHOSTS: int = 4

# Single-process singleton for player.gd + grenade.gd to reach the predict
# path without a tree walk. Listen-server (future) still has one spawner.
static var instance: GrenadeSpawner = null

var _next_entity_id: int = 1
var _last_throw_us: Dictionary = {}  # peer_id -> usec
# Staged throw payloads keyed by entity_id, applied to the auth in
# _on_entity_registered. Lets the framework drive instantiation while we still
# inject game-specific fields at the right moment.
var _pending_throws: Dictionary = {}
# FIFO of unmatched local ghosts. Cap at MAX_LOCAL_GHOSTS — overflow drops the
# oldest so a runaway "predictions outpace confirmations" state self-heals.
var _local_ghosts: Array[GhostGrenade] = []


func _ready() -> void:
	NetReplication.register_entity_scene(GRENADE_SCHEMA_ID, GRENADE_SCENE_PATH, self)
	NetReplication.entity_registered.connect(_on_entity_registered)
	NetSession.when_roles_ready(_finish_setup)
	GrenadeSpawner.instance = self


func _exit_tree() -> void:
	if GrenadeSpawner.instance == self:
		GrenadeSpawner.instance = null


func _finish_setup() -> void:
	if NetSession.has_server_role:
		NetReliableHub.subscribe_server(Enums.ReliableTopic.THROW_GRENADE, _on_throw_request)
	print("[GRENADE] spawner ready mode=%d" % NetSession.mode)


func _on_throw_request(peer_id: int, payload: PackedByteArray) -> void:
	print("[GRENADE] server received throw from peer=%d bytes=%d" % [peer_id, payload.size()])
	var thrower_pred: NetPredictor = NetReplication.get_entity(1, peer_id) as NetPredictor
	if thrower_pred != null and thrower_pred.shadow_state != null:
		if (thrower_pred.shadow_state as PlayerState).health <= 0:
			print("[GRENADE] throw rejected: peer=%d is dead" % peer_id)
			return
	var now_us: int = Time.get_ticks_usec()
	var last_us: int = _last_throw_us.get(peer_id, 0)
	if last_us > 0 and now_us - last_us < int(THROW_COOLDOWN_SEC * 1_000_000):
		print("[GRENADE] throw cooldown active for peer=%d" % peer_id)
		return
	_last_throw_us[peer_id] = now_us

	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var origin := Vector3(sp.get_float(), sp.get_float(), sp.get_float())
	var velocity := Vector3(sp.get_float(), sp.get_float(), sp.get_float())

	var entity_id := _next_entity_id
	_next_entity_id += 1
	_pending_throws[entity_id] = {"thrower_id": peer_id, "origin": origin, "velocity": velocity}

	NetReplication.spawn_entity(GRENADE_SCHEMA_ID, entity_id, GRENADE_SCENE_PATH, -1)


func _on_entity_registered(schema_id: int, entity_id: int, is_authoritative: bool) -> void:
	if schema_id != GRENADE_SCHEMA_ID or not is_authoritative:
		return
	if not _pending_throws.has(entity_id):
		return
	var data: Dictionary = _pending_throws[entity_id]
	_pending_throws.erase(entity_id)
	var pred: NetPredictor = NetReplication.get_entity(GRENADE_SCHEMA_ID, entity_id, true)
	if pred == null or pred.shadow_state == null or not is_instance_valid(pred.host):
		push_error("[GRENADE] auth predictor missing after spawn_entity")
		return
	var grenade: Grenade = pred.host as Grenade
	var s: GrenadeState = pred.shadow_state as GrenadeState
	s.pos = data.origin
	s.rotation_quat = Quaternion.IDENTITY
	s.state = Grenade.STATE_FLYING
	s.fuse_remaining = 3.0
	s.explosion_progress = 0.0
	grenade.thrower_id = data.thrower_id
	grenade.global_position = data.origin
	grenade.global_basis = Basis.IDENTITY
	grenade.linear_velocity = data.velocity
	grenade.angular_velocity = Vector3(randf_range(-8.0, 8.0), randf_range(-8.0, 8.0), randf_range(-8.0, 8.0))
	print("[GRENADE] spawned id=%d at %v vel=%v" % [entity_id, data.origin, data.velocity])


# Client-side: instantiate a non-networked ghost grenade with the same initial
# conditions the local player is about to send to the server. Called from
# player.gd._send_grenade_throw before the THROW_GRENADE reliable goes out so
# the user sees the parabola immediately instead of waiting an RTT for the
# server's NetState to arrive.
func spawn_local_ghost(origin: Vector3, velocity: Vector3) -> GhostGrenade:
	var packed: PackedScene = load(GHOST_GRENADE_SCENE_PATH)
	if packed == null:
		push_error("[GRENADE] ghost scene load failed: %s" % GHOST_GRENADE_SCENE_PATH)
		return null
	var ghost: GhostGrenade = packed.instantiate() as GhostGrenade
	add_child(ghost)
	ghost.setup(origin, velocity)
	_local_ghosts.append(ghost)
	# Cap queue; oldest unmatched ghost (likely from a rejected throw) gets freed.
	while _local_ghosts.size() > MAX_LOCAL_GHOSTS:
		var dropped: GhostGrenade = _local_ghosts.pop_front()
		if is_instance_valid(dropped):
			dropped.queue_free()
	return ghost


# Called from Grenade._proxy_apply on the proxy's very first frame. Walks the
# pending-ghost queue and pops the first ghost whose age and current position
# plausibly correspond to this proxy. Returns the matched ghost (or null on
# no match) — caller uses the ghost's spawn_time_us for telemetry. Distance-
# based match is tolerant (5m) because RigidBody3D integration isn't
# deterministic across processes — over ~RTT of physics ticks the ghost and
# the proxy can drift a bit even from identical origin/velocity. Tighter
# threshold would risk false negatives, looser would risk matching a remote
# player's grenade.
func try_match_ghost(proxy_pos: Vector3) -> GhostGrenade:
	var now_us: int = Time.get_ticks_usec()
	var i: int = 0
	while i < _local_ghosts.size():
		var g: GhostGrenade = _local_ghosts[i]
		if not is_instance_valid(g):
			_local_ghosts.remove_at(i)
			continue
		var age_us: int = now_us - g.spawn_time_us
		if age_us < GHOST_MIN_MATCH_AGE_US:
			i += 1
			continue
		if age_us > GHOST_MAX_MATCH_AGE_US:
			# Stale: server clearly didn't spawn this one (rejected, lost packet).
			# Drop from queue but let the ghost finish its own fuse cycle.
			_local_ghosts.remove_at(i)
			continue
		if g.global_position.distance_to(proxy_pos) <= GHOST_MATCH_DISTANCE:
			_local_ghosts.remove_at(i)
			g.hide_for_real()
			return g
		i += 1
	return null
