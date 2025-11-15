extends Node

const LOW_LEVEL_NETWORK_PLAYER := preload("res://controllers/fps_controller.tscn")

var players: Dictionary = {}

func _ready() -> void:
	LowLevelNetworkHandler.on_peer_connect.connect(spawn_player)
	LowLevelNetworkHandler.on_peer_disconnect.connect(despawn_player)
	ClientNetworkGlobals.handle_disconnect_from_server.connect(despawn_all_players)
	ClientNetworkGlobals.handle_local_id_assignment.connect(spawn_player)
	ClientNetworkGlobals.handle_remote_id_assignment.connect(spawn_player)
	ClientNetworkGlobals.handle_player_disconnected.connect(despawn_player)


func spawn_player(id: int) -> void:
	var player = LOW_LEVEL_NETWORK_PLAYER.instantiate()
	player._owner_id = id
	if id == ClientNetworkGlobals.id:
		ClientNetworkGlobals.player = player
	player.name = "Player_%d" % id # Optional, but it beats the name "@CharacterBody2D@2/3/4..."
	player.global_position = Vector3(0, 21.079, -76.501)
	player.game_position = player.global_position
	players[id] = player
	call_deferred("add_child", player)


func despawn_player(id: int) -> void:
	if LowLevelNetworkHandler.is_server:
		var disconnect_packet := PlayerDisconnectedPacket.new()
		disconnect_packet.player_id = id
		LowLevelNetworkHandler.broadcast_packet(disconnect_packet.to_payload())
	var player = players[id]
	player.despawn()
	player.queue_free()
	players.erase(id)


func despawn_all_players() -> void:
	for player in players.values():
		player.despawn()
		player.queue_free()
	players.clear()
