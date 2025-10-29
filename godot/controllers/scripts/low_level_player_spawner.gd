extends Node

const LOW_LEVEL_NETWORK_PLAYER = preload("res://controllers/fps_controller.tscn")

func _ready() -> void:
	LowLevelNetworkHandler.on_peer_connect.connect(spawn_player)
	ClientNetworkGlobals.handle_local_id_assignment.connect(spawn_player)
	ClientNetworkGlobals.handle_remote_id_assignment.connect(spawn_player)


func spawn_player(id: int) -> void:
	var player = LOW_LEVEL_NETWORK_PLAYER.instantiate()
	player.owner_id = id
	player.name = "Player_%d" % id # Optional, but it beats the name "@CharacterBody2D@2/3/4..."

	call_deferred("add_child", player)
