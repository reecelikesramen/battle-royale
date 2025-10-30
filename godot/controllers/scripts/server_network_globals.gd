extends Node

signal handle_game_state(peer_id: int, game_state: GameStatePacket)
signal handle_chat(peer_id: int, chat: ChatPacket)

var peer_ids: Array[int]

func _ready() -> void:
	LowLevelNetworkHandler.on_peer_connect.connect(on_peer_connected)
	LowLevelNetworkHandler.on_peer_disconnect.connect(on_peer_disconnected)
	LowLevelNetworkHandler.on_server_packet.connect(on_server_packet)
	handle_chat.connect(on_chat)

func on_peer_connected(peer_id: int) -> void:
	peer_ids.append(peer_id)

	LowLevelNetworkHandler.broadcast_packet(IdAssignmentPacket.create(peer_id, peer_ids))


func on_peer_disconnected(peer_id: int) -> void:
	peer_ids.erase(peer_id)

	# Create IDUnassignment to broadcast to all still connected peers


func on_server_packet(peer_id: int, packet) -> void:
	if packet is GameStatePacket:
		handle_game_state.emit(peer_id, packet)
	elif packet is ChatPacket:
		handle_chat.emit(peer_id, packet)
	else:
		push_error("Unknown packet type unhandled!")


func on_chat(peer_id: int, packet: ChatPacket):
	LowLevelNetworkHandler.broadcast_packet(packet.to_payload())
