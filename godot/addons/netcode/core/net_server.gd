extends Node

signal handle_player_input(peer_id: int, input: PlayerInputPacket)
signal handle_chat(peer_id: int, chat: ChatPacket)
signal handle_net_reliable(peer_id: int, packet: NetReliablePacket)

var peer_ids: Array[int]

## Monotonic u32 tick counter, incremented each physics frame on the server.
## Wraps around at 2^32; clients tolerate via sequence-style comparison.
var server_tick: int = 0

func _ready() -> void:
	NetworkTransport.on_peer_connect.connect(on_peer_connected)
	NetworkTransport.on_peer_disconnect.connect(on_peer_disconnected)
	NetworkTransport.on_server_packet.connect(on_server_packet)
	handle_chat.connect(on_chat)


func _physics_process(_delta: float) -> void:
	if not NetworkTransport.is_server:
		return
	if peer_ids.is_empty():
		return

	server_tick = (server_tick + 1) & 0xFFFFFFFF

	var packet := ServerTickPacket.new()
	packet.server_tick = server_tick
	packet.server_tick_us = Time.get_ticks_usec() & 0xFFFFFFFF
	NetworkTransport.broadcast_packet(packet.to_payload())

func on_peer_connected(peer_id: int) -> void:
	peer_ids.append(peer_id)

	var id_assignment := IdAssignmentPacket.new()
	id_assignment.id = peer_id
	id_assignment.remote_ids = peer_ids.duplicate()
	NetworkTransport.broadcast_packet(id_assignment.to_payload())


func on_peer_disconnected(peer_id: int) -> void:
	peer_ids.erase(peer_id)

	# Create IDUnassignment to broadcast to all still connected peers


func on_server_packet(peer_id: int, packet) -> void:
	if packet is PlayerInputPacket:
		handle_player_input.emit(peer_id, packet)
	elif packet is ChatPacket:
		handle_chat.emit(peer_id, packet)
	elif packet is NetReliablePacket:
		handle_net_reliable.emit(peer_id, packet)
	else:
		push_error("Unknown packet type unhandled!")


func on_chat(peer_id: int, packet: ChatPacket):
	NetworkTransport.broadcast_packet(packet.to_payload())
