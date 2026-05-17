class_name GrenadeSpawner extends Node3D

const GRENADE_SCHEMA_ID := 2
const GRENADE_SCENE_PATH := "res://entities/grenade/grenade.tscn"
const THROW_COOLDOWN_SEC := 1.0

var _grenade_scene: PackedScene = preload("res://entities/grenade/grenade.tscn")
var _next_entity_id: int = 1
var _last_throw_us: Dictionary = {}  # peer_id -> usec

# Per-role parent nodes. Authoritative + proxy instances of the same grenade
# coexist in listen mode as siblings under these distinct roots — physics
# share one space but the proxy keeps freeze + collider-disabled (set on the
# Grenade itself by NetPredictor.is_authoritative_instance gate) so it never
# touches the auth's collisions. Single-mode runs populate just one root.
var _server_root: Node3D
var _client_root: Node3D


func _ready() -> void:
	_server_root = Node3D.new()
	_server_root.name = "ServerGrenades"
	add_child(_server_root)
	_client_root = Node3D.new()
	_client_root.name = "ClientGrenades"
	add_child(_client_root)

	NetReplication.server_entity_spawn_requested.connect(_on_server_spawn_requested)
	NetReplication.client_entity_spawn_requested.connect(_on_client_spawn_requested)
	NetSession.when_roles_ready(_finish_setup)


func _finish_setup() -> void:
	if NetSession.has_server_role:
		NetReliableHub.subscribe_server(Enums.ReliableTopic.THROW_GRENADE, _on_throw_request)
	print("[GRENADE] spawner ready mode=%d" % NetSession.mode)


func _on_throw_request(peer_id: int, payload: PackedByteArray) -> void:
	print("[GRENADE] server received throw from peer=%d bytes=%d" % [peer_id, payload.size()])
	# Dead players can't throw. shadow_state.health<=0 → drop.
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

	NetReplication.spawn_entity(GRENADE_SCHEMA_ID, entity_id, GRENADE_SCENE_PATH, -1)

	# Server-side spawn fires synchronously inside spawn_entity → look up the
	# auth instance specifically. In listen mode the client proxy hasn't
	# spawned yet (waits for loopback reliable receipt) so a server-priority
	# get_entity must explicitly say so to avoid hitting a leftover proxy
	# from a previous spawn cycle.
	var predictor: NetPredictor = NetReplication.get_entity(GRENADE_SCHEMA_ID, entity_id, true)
	if predictor == null or predictor.shadow_state == null:
		push_error("[GRENADE] spawn_entity called but predictor or shadow_state is null")
		return
	var grenade: Grenade = predictor.host as Grenade
	var s: GrenadeState = predictor.shadow_state as GrenadeState
	s.pos = origin
	s.rotation_quat = Quaternion.IDENTITY
	s.state = Grenade.STATE_FLYING
	s.fuse_remaining = 3.0
	s.explosion_progress = 0.0
	grenade.thrower_id = peer_id
	grenade.global_position = origin
	grenade.global_basis = Basis.IDENTITY
	grenade.linear_velocity = velocity
	grenade.angular_velocity = Vector3(randf_range(-8.0, 8.0), randf_range(-8.0, 8.0), randf_range(-8.0, 8.0))
	print("[GRENADE] spawned id=%d at %v vel=%v" % [entity_id, origin, velocity])


func _on_server_spawn_requested(schema_id: int, entity_id: int, scene_path: String, _owner_peer_id: int) -> void:
	if schema_id != GRENADE_SCHEMA_ID or scene_path != GRENADE_SCENE_PATH:
		return
	_instantiate_under(_server_root, entity_id, "_Server", true)


func _on_client_spawn_requested(schema_id: int, entity_id: int, scene_path: String, _owner_peer_id: int) -> void:
	if schema_id != GRENADE_SCHEMA_ID or scene_path != GRENADE_SCENE_PATH:
		return
	_instantiate_under(_client_root, entity_id, "_Client", false)


func _instantiate_under(parent: Node, entity_id: int, suffix: String, is_auth: bool) -> void:
	# Distinct names so listen-mode siblings don't collide ("Grenade_5_Server"
	# vs "Grenade_5_Client"). Single-mode operation creates only one of them.
	var grenade: Grenade = _grenade_scene.instantiate()
	grenade.name = "Grenade_%d%s" % [entity_id, suffix]
	var predictor: NetPredictor = grenade.get_node("NetPredictor")
	predictor.entity_id = entity_id
	predictor.is_authoritative_instance = is_auth
	parent.add_child(grenade)
	print("[GRENADE] instantiated id=%d auth=%s mode=%d" % [entity_id, is_auth, NetSession.mode])
