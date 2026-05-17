class_name PlayerSpawner extends Node3D

const PLAYER: PackedScene = preload("res://controllers/player/player.tscn")

# Per-role rosters. Authoritative + proxy instances of the same peer's player
# coexist in listen mode under distinct parent roots. Single-mode runs
# populate just one of the two dicts.
var _server_players: Dictionary = {}    # peer_id -> PlayerController (auth)
var _client_players: Dictionary = {}    # peer_id -> PlayerController (proxy)
var _server_root: Node3D
var _client_root: Node3D


func _ready() -> void:
	_server_root = Node3D.new()
	_server_root.name = "ServerPlayers"
	add_child(_server_root)
	_client_root = Node3D.new()
	_client_root.name = "ClientPlayers"
	add_child(_client_root)

	NetSession.on_peer_connect.connect(_spawn_server_player)
	NetSession.on_peer_disconnect.connect(_despawn)
	NetClient.handle_disconnect_from_server.connect(_despawn_all)
	NetClient.handle_local_id_assignment.connect(_spawn_client_player)
	NetClient.handle_remote_id_assignment.connect(_spawn_client_player)
	NetClient.handle_player_disconnected.connect(_despawn)

	# Backfill: signals can fire on autoloads before this scene's spawner is
	# in the tree. Without backfill the local client gets the default scene
	# camera and the server's spectator view shows zero capsules.
	if NetSession.has_server_role:
		for peer_id in NetServer.peer_ids:
			_spawn_server_player(peer_id)
	if NetSession.has_client_role:
		if NetClient.id != -1:
			_spawn_client_player(NetClient.id)
		for remote_id in NetClient.remote_ids:
			if remote_id == NetClient.id:
				continue
			_spawn_client_player(remote_id)

	# Phase 9b: server-side reliable RPC fan-out. Chat is the first user — when
	# a peer sends, the server re-broadcasts the same payload to all peers so
	# every client sees it. Fresh idem_key per fan-out is fine; the hub's per-
	# topic dedup ring isolates client and server views.
	if NetSession.has_server_role:
		NetReliableHub.subscribe(Enums.ReliableTopic.CHAT, _relay_chat_to_clients)


func _relay_chat_to_clients(_peer_id: int, payload: PackedByteArray) -> void:
	NetReliableHub.broadcast(Enums.ReliableTopic.CHAT, payload)


# on_peer_connect fires server-side when any peer (including the loopback host)
# joins. The auth instance carries shadow_state + server-tick simulation and
# is invisible (no camera, no input) since PlayerController gates rendering on
# is_local_view.
func _spawn_server_player(id: int) -> void:
	if _server_players.has(id):
		return  # idempotent — backfill + on_peer_connect can race for same id
	var p := _instantiate_player(id, _server_root, "_Server", true)
	_server_players[id] = p


# Client-side id-assignment fires after the loopback / remote handshake. The
# proxy instance is the one the local client actually sees + controls (if its
# owner_id matches NetClient.id) — camera becomes current, input is gathered,
# prediction + reconcile run against it.
func _spawn_client_player(id: int) -> void:
	if _client_players.has(id):
		return
	var p := _instantiate_player(id, _client_root, "_Client", false)
	_client_players[id] = p
	if id == NetClient.id:
		NetClient.player = p


func _instantiate_player(id: int, parent: Node, suffix: String, is_auth: bool) -> PlayerController:
	var player: PlayerController = PLAYER.instantiate()
	player._owner_id = id
	# Listen mode has two instances per peer as siblings — distinct names
	# avoid Godot's auto-renaming and make scene-tree debug readable.
	player.name = "Player_%d%s" % [id, suffix]
	var pred: NetPredictor = player.get_node("NetPredictor")
	pred.is_authoritative_instance = is_auth
	parent.call_deferred("add_child", player)
	return player


# Despawn both sides if both exist. Multiple disconnect signals can race
# (on_peer_disconnect server-side + handle_player_disconnected client-side
# via the broadcast); each dict's idempotency guard absorbs duplicates.
func _despawn(id: int) -> void:
	if NetSession.has_server_role:
		var disconnect_packet := PlayerDisconnectedPacket.new()
		disconnect_packet.player_id = id
		NetSession.broadcast_packet(disconnect_packet.to_payload())
	if _server_players.has(id):
		var s_player: PlayerController = _server_players[id]
		_server_players.erase(id)
		s_player.despawn()
		s_player.queue_free()
	if _client_players.has(id):
		var c_player: PlayerController = _client_players[id]
		_client_players.erase(id)
		if NetClient.player == c_player:
			NetClient.player = null
		c_player.despawn()
		c_player.queue_free()


func _despawn_all() -> void:
	for player in _server_players.values():
		player.despawn()
		player.queue_free()
	_server_players.clear()
	for player in _client_players.values():
		player.despawn()
		player.queue_free()
	_client_players.clear()
	NetClient.player = null
