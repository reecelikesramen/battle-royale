class_name GrenadeSpawner extends Node3D

# On-demand spawn via NetReplication.spawn_entity. Framework instantiates auth
# (server) and proxy (clients) automatically via register_entity_scene; this
# script just decodes the throw payload + fills in game-specific spawn data
# (thrower_id, origin, velocity) once the auth predictor lands in the registry.

const GRENADE_SCHEMA_ID := 2
const GRENADE_SCENE_PATH := "res://entities/grenade/grenade.tscn"
const THROW_COOLDOWN_SEC := 1.0

var _next_entity_id: int = 1
var _last_throw_us: Dictionary = {}  # peer_id -> usec
# Staged throw payloads keyed by entity_id, applied to the auth in
# _on_entity_registered. Lets the framework drive instantiation while we still
# inject game-specific fields at the right moment.
var _pending_throws: Dictionary = {}


func _ready() -> void:
	NetReplication.register_entity_scene(GRENADE_SCHEMA_ID, GRENADE_SCENE_PATH, self)
	NetReplication.entity_registered.connect(_on_entity_registered)
	NetSession.when_roles_ready(_finish_setup)


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
