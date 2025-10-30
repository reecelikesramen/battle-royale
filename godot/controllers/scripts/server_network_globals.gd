extends Node

signal handle_game_state(peer_id: int, game_state: GdGameStatePacket)
signal handle_chat(peer_id: int, chat: GdChatPacket)

var peer_ids: Array[int]

func _ready() -> void:
	LowLevelNetworkHandler.on_peer_connect.connect(on_peer_connected)
	LowLevelNetworkHandler.on_peer_disconnect.connect(on_peer_disconnected)
	LowLevelNetworkHandler.on_server_packet.connect(on_server_packet)
	handle_chat.connect(on_chat)

func on_peer_connected(peer_id: int) -> void:
	peer_ids.append(peer_id)

	LowLevelNetworkHandler.broadcast_packet(GdIdAssignmentPacket.create(peer_id, peer_ids))


func on_peer_disconnected(peer_id: int) -> void:
	peer_ids.erase(peer_id)

	# Create IDUnassignment to broadcast to all still connected peers


func on_server_packet(peer_id: int, packet) -> void:
	if packet is GdGameStatePacket:
		handle_game_state.emit(peer_id, packet)
	elif packet is GdChatPacket:
		handle_chat.emit(peer_id, packet)
	else:
		push_error("Unknown packet type unhandled!")


func on_chat(peer_id: int, packet: GdChatPacket):
	LowLevelNetworkHandler.broadcast_packet(GdChatPacket.create(packet.username, packet.message))
