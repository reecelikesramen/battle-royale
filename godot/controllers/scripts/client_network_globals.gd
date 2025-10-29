extends Node

signal handle_local_id_assignment(local_id: int)
signal handle_remote_id_assignment(remote_id: int)
signal handle_game_state(game_state: GdGameStatePacket)

var id: int = -1
var remote_ids: Array[int]

func _ready() -> void:
	LowLevelNetworkHandler.on_client_packet.connect(on_client_packet)


func on_client_packet(data) -> void:
	if data is GdIdAssignmentPacket:
		manage_ids(data)
	elif data is GdGameStatePacket:
		handle_game_state.emit(data)
	else:
		push_error("Packet unknown type unhandled!")


func manage_ids(packet: GdIdAssignmentPacket) -> void:
	if id == -1: # When id == -1, the id sent by the server is for us
		id = packet.id
		handle_local_id_assignment.emit(packet.id)

		remote_ids = packet.remote_ids
		for remote_id in remote_ids:
			if remote_id == id: continue
			handle_remote_id_assignment.emit(remote_id)
	else: # When id != -1, we already own an id, and just append the remote ids by the sent id
		remote_ids.append(packet.id)
		handle_remote_id_assignment.emit(packet.id)
