extends Node

signal handle_net_command(peer_id: int, packet: NetCommandPacket)
signal handle_net_reliable(peer_id: int, packet: NetReliablePacket)

var peer_ids: Array[int]

## Monotonic u32 tick counter, incremented each physics frame on the server.
## Wraps around at 2^32; clients tolerate via sequence-style comparison.
var server_tick: int = 0

func _ready() -> void:
	NetSession.on_peer_connect.connect(on_peer_connected)
	NetSession.on_peer_disconnect.connect(on_peer_disconnected)
	NetSession.on_server_packet.connect(on_server_packet)


func _physics_process(_delta: float) -> void:
	if not NetSession.is_server:
		return
	if peer_ids.is_empty():
		return

	server_tick = (server_tick + 1) & 0xFFFFFFFF

	var packet := ServerTickPacket.new()
	packet.server_tick = server_tick
	packet.server_tick_us = Time.get_ticks_usec() & 0xFFFFFFFF
	NetSession.broadcast_packet(packet.to_payload())

func on_peer_connected(peer_id: int) -> void:
	# Rust drains all GNS Connecting→Connected events in one poll before emitting
	# on_peer_connect signals, so connected_clients can already contain a peer
	# that hasn't received its IdAssignment yet. Broadcasting the first assignment
	# would race: the unassigned peer (id==-1) takes whichever packet arrives
	# first as its local id. Target sends instead.
	for existing_id in peer_ids:
		var remote_notify := IdAssignmentPacket.new()
		remote_notify.id = peer_id
		remote_notify.remote_ids = peer_ids.duplicate()
		remote_notify.remote_ids.append(peer_id)
		NetSession.send_packet_to_peer(existing_id, remote_notify.to_payload())

	peer_ids.append(peer_id)

	var id_assignment := IdAssignmentPacket.new()
	id_assignment.id = peer_id
	id_assignment.remote_ids = peer_ids.duplicate()
	NetSession.send_packet_to_peer(peer_id, id_assignment.to_payload())


func on_peer_disconnected(peer_id: int) -> void:
	peer_ids.erase(peer_id)

	# Create IDUnassignment to broadcast to all still connected peers


func on_server_packet(peer_id: int, packet) -> void:
	if packet is NetCommandPacket:
		handle_net_command.emit(peer_id, packet)
	elif packet is NetReliablePacket:
		handle_net_reliable.emit(peer_id, packet)
	else:
		push_error("Unknown packet type unhandled!")
