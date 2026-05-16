extends Node

signal handle_net_command(peer_id: int, packet: NetCommandPacket)
signal handle_net_reliable(peer_id: int, packet: NetReliablePacket)
# Fires only AFTER the version handshake passes. Subscribers (e.g. the
# PlayerSpawner) should listen on this instead of NetSession.on_peer_connect
# so a mismatched-build peer doesn't get a player spawned before it's kicked.
signal peer_admitted(peer_id: int)

const HANDSHAKE_TIMEOUT_MS := 5000
# App-defined disconnect codes — surfaced on the client via the on_disconnect
# signal's end_reason. Keep aligned with NetClient.DisconnectReason additions.
const APP_BUILD_MISMATCH := 1003
const APP_HANDSHAKE_TIMEOUT := 1004

var peer_ids: Array[int]

## Monotonic u32 tick counter, incremented each physics frame on the server.
## Wraps around at 2^32; clients tolerate via sequence-style comparison.
var server_tick: int = 0

# peer_id (int) -> deadline_ms (int). Peers waiting on their ClientHello
# reply. Cleared on hello receipt or kick; on_peer_disconnected also
# scrubs in case GNS tears the conn down before either fires.
var _pending_handshakes: Dictionary = {}

func _ready() -> void:
	NetSession.on_peer_connect.connect(on_peer_connected)
	NetSession.on_peer_disconnect.connect(on_peer_disconnected)
	NetSession.on_server_packet.connect(on_server_packet)


func _process(_delta: float) -> void:
	if not NetSession.is_server:
		return
	if _pending_handshakes.is_empty():
		return
	var now := Time.get_ticks_msec()
	var timed_out: Array[int] = []
	for pid in _pending_handshakes:
		if now >= _pending_handshakes[pid]:
			timed_out.append(pid)
	for pid in timed_out:
		push_warning("[net_server] peer %d hello timeout — kicking" % pid)
		_pending_handshakes.erase(pid)
		NetSession.kick_peer(pid, APP_HANDSHAKE_TIMEOUT,
			"Hello timeout: client too old or stuck")


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
	# Begin version handshake: send our build sha + version, defer everything
	# else (id assignment, peer broadcast, spawner notification) until the
	# matching ClientHelloPacket arrives. Mismatched or stuck clients get
	# kicked with a clear reason instead of stumbling through protocol
	# drift further into the session.
	var hello := ServerHelloPacket.new()
	hello.build_sha = Constants.get_build_sha()
	hello.version = Constants.get_version()
	NetSession.send_packet_to_peer(peer_id, hello.to_payload())
	_pending_handshakes[peer_id] = Time.get_ticks_msec() + HANDSHAKE_TIMEOUT_MS


func on_peer_disconnected(peer_id: int) -> void:
	_pending_handshakes.erase(peer_id)
	peer_ids.erase(peer_id)


func on_server_packet(peer_id: int, packet) -> void:
	if packet is ClientHelloPacket:
		_on_client_hello(peer_id, packet)
		return
	if packet is NetCommandPacket:
		handle_net_command.emit(peer_id, packet)
	elif packet is NetReliablePacket:
		handle_net_reliable.emit(peer_id, packet)
	else:
		push_error("Unknown packet type unhandled!")


func _on_client_hello(peer_id: int, packet: ClientHelloPacket) -> void:
	if not _pending_handshakes.has(peer_id):
		# Either a duplicate (re-sent by a chatty client) or a late hello
		# after we already kicked. Either way: ignore.
		push_warning("[net_server] stale ClientHello from peer %d — ignoring" % peer_id)
		return
	_pending_handshakes.erase(peer_id)

	var server_sha := Constants.get_build_sha()
	if packet.build_sha != server_sha:
		var msg := "Build mismatch: server=%s (%s) client=%s (%s)" \
			% [Constants.get_version(), server_sha, packet.version, packet.build_sha]
		push_warning("[net_server] kicking peer %d — %s" % [peer_id, msg])
		NetSession.kick_peer(peer_id, APP_BUILD_MISMATCH, msg)
		return

	_admit_peer(peer_id)


func _admit_peer(peer_id: int) -> void:
	# Notify existing peers of the newcomer, then send the newcomer their
	# id + roster. Targeted (not broadcast) — see the comment on the old
	# on_peer_connected: a connected-but-unassigned peer would steal the
	# first IdAssignment that hit the wire.
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

	peer_admitted.emit(peer_id)
