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
	if not NetSession.has_server_role:
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
	# that hasn't received its id-assignment yet. Broadcasting the first assignment
	# would race: the unassigned peer (id==-1) takes whichever packet arrives
	# first as its local id. Target sends instead.
	for existing_id in peer_ids:
		var remote_payload := peer_ids.duplicate()
		remote_payload.append(peer_id)
		NetReliableHub.send_to_peer(existing_id, NetReliableHub.TOPIC_ID_ASSIGNMENT, _encode_id_assignment(peer_id, remote_payload))

	peer_ids.append(peer_id)

	NetReliableHub.send_to_peer(peer_id, NetReliableHub.TOPIC_ID_ASSIGNMENT, _encode_id_assignment(peer_id, peer_ids.duplicate()))


func on_peer_disconnected(peer_id: int) -> void:
	peer_ids.erase(peer_id)
	var sp := StreamPeerBuffer.new()
	sp.put_u8(peer_id)
	NetReliableHub.broadcast(NetReliableHub.TOPIC_PLAYER_DISCONNECTED, sp.data_array)


# Wire format: u8 id, u8 count, then `count` u8 remote ids.
func _encode_id_assignment(id: int, remote_ids: Array) -> PackedByteArray:
	var sp := StreamPeerBuffer.new()
	sp.put_u8(id)
	sp.put_u8(remote_ids.size())
	for rid in remote_ids:
		sp.put_u8(rid)
	return sp.data_array


func on_server_packet(peer_id: int, packet) -> void:
	if packet is NetCommandPacket:
		handle_net_command.emit(peer_id, packet)
	elif packet is NetReliablePacket:
		handle_net_reliable.emit(peer_id, packet)
	else:
		push_error("Unknown packet type unhandled!")
