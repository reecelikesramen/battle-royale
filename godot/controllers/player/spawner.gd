class_name PlayerSpawner extends Node3D

const PLAYER: PackedScene = preload("res://controllers/player/player.tscn")

var players: Dictionary = {}

func _ready() -> void:
	NetSession.on_peer_connect.connect(spawn_player)
	NetSession.on_peer_disconnect.connect(despawn_player)
	NetClient.handle_disconnect_from_server.connect(despawn_all_players)
	NetClient.handle_local_id_assignment.connect(spawn_player)
	NetClient.handle_remote_id_assignment.connect(spawn_player)
	NetClient.handle_player_disconnected.connect(despawn_player)

	# Backfill: NetSession.on_peer_connect / NetClient.handle_*_id_assignment can
	# fire on the autoload before this scene's spawner is in the tree, so the
	# signals emit to zero listeners. Without backfill the local client gets the
	# default scene camera (own PlayerController never spawned) and the server's
	# spectator view shows zero/stale capsules.
	if NetSession.is_server:
		for peer_id in NetServer.peer_ids:
			spawn_player(peer_id)
	else:
		if NetClient.id != -1:
			spawn_player(NetClient.id)
		for remote_id in NetClient.remote_ids:
			if remote_id == NetClient.id:
				continue
			spawn_player(remote_id)

	# Phase 9b: server-side reliable RPC fan-out. Chat is the first user — when
	# a peer sends, the server re-broadcasts the same payload to all peers so
	# every client sees it. Fresh idem_key per fan-out is fine; the hub's per-
	# topic dedup ring isolates client and server views.
	if NetSession.is_server:
		NetReliableHub.subscribe(Enums.ReliableTopic.CHAT, _relay_chat_to_clients)


func _relay_chat_to_clients(_peer_id: int, payload: PackedByteArray) -> void:
	NetReliableHub.broadcast(Enums.ReliableTopic.CHAT, payload)


func spawn_player(id: int) -> void:
	# Idempotency: three signals (on_peer_connect, handle_local_id_assignment,
	# handle_remote_id_assignment) can all deliver the same id during a
	# simultaneous-join race. Without this guard the dict entry gets clobbered
	# and the first-spawned player leaks (no parent, camera never becomes current
	# → users see the default scene camera).
	if players.has(id):
		push_warning("[spawner] spawn_player(%d) called for already-spawned id; skipping duplicate" % id)
		return
	var player: PlayerController = PLAYER.instantiate()
	player._owner_id = id
	player.name = "Player_%d" % id # Optional, but it beats the name "@CharacterBody2D@2/3/4..."
	players[id] = player
	if id == NetClient.id:
		NetClient.player = player
	call_deferred("add_child", player)


func despawn_player(id: int) -> void:
	if NetSession.is_server:
		var disconnect_packet := PlayerDisconnectedPacket.new()
		disconnect_packet.player_id = id
		NetSession.broadcast_packet(disconnect_packet.to_payload())
	# Multiple disconnect signals can race here (on_peer_disconnect locally on
	# the server, handle_player_disconnected on the client via the broadcast).
	# Without this guard a second delivery hits `players[id]` on an erased key
	# and throws "Out of bounds get index 'N' (on base: 'Dictionary')".
	if not players.has(id):
		push_warning("[spawner] despawn_player(%d) called but id not in dict (already despawned or never spawned)" % id)
		return
	var player = players[id]
	players.erase(id)
	if NetClient.player == player:
		NetClient.player = null
	player.despawn()
	player.queue_free()


func despawn_all_players() -> void:
	for player in players.values():
		player.despawn()
		player.queue_free()
	players.clear()
