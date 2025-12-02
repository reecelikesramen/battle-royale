class_name PlayerSpawner extends Node3D

const PLAYER: PackedScene = preload("res://controllers/player/player.tscn")

var players: Dictionary = {}

func _ready() -> void:
	NetworkTransport.on_peer_connect.connect(spawn_player)
	NetworkTransport.on_peer_disconnect.connect(despawn_player)
	NetworkClient.handle_disconnect_from_server.connect(despawn_all_players)
	NetworkClient.handle_local_id_assignment.connect(spawn_player)
	NetworkClient.handle_remote_id_assignment.connect(spawn_player)
	NetworkClient.handle_player_disconnected.connect(despawn_player)


func spawn_player(id: int) -> void:
	NetworkClient.player = PLAYER.instantiate()
	var player := NetworkClient.player
	player._owner_id = id
	if id == NetworkClient.id:
		NetworkClient.player = player
	player.name = "Player_%d" % id # Optional, but it beats the name "@CharacterBody2D@2/3/4..."
	players[id] = player
	call_deferred("add_child", player)


func despawn_player(id: int) -> void:
	if NetworkTransport.is_server:
		var disconnect_packet := PlayerDisconnectedPacket.new()
		disconnect_packet.player_id = id
		NetworkTransport.broadcast_packet(disconnect_packet.to_payload())
	var player = players[id]
	player.despawn()
	player.queue_free()
	players.erase(id)


func despawn_all_players() -> void:
	for player in players.values():
		player.despawn()
		player.queue_free()
	players.clear()
