extends Node

signal handle_local_id_assignment(local_id: int)
signal handle_remote_id_assignment(remote_id: int)
signal handle_player_disconnected(player_id: int)
signal handle_net_state(packet: NetStatePacket)
signal handle_net_reliable(packet: NetReliablePacket)
signal handle_server_tick(tick: ServerTickPacket)
signal handle_disconnect_from_server()
signal self_spawned()

var username: String
var id: int = -1
var player: PlayerController:
	get: return player
	set(value):
		player = value
		self_spawned.emit()
	
var debug
var remote_ids: Array[int]
var _disconnected_message: String = ""

func _ready() -> void:
	NetSession.on_client_packet.connect(on_client_packet)
	NetSession.on_disconnect_from_server.connect(on_disconnect_from_server)


func on_client_packet(data) -> void:
	if data is ServerHelloPacket:
		_on_server_hello(data)
	elif data is IdAssignmentPacket:
		manage_ids(data)
	elif data is NetStatePacket:
		handle_net_state.emit(data)
	elif data is NetReliablePacket:
		handle_net_reliable.emit(data)
	elif data is ServerTickPacket:
		handle_server_tick.emit(data)
	elif data is PlayerDisconnectedPacket:
		handle_player_disconnected.emit(data.player_id)
	else:
		push_error("Packet unknown type unhandled!")


# First server-originated packet on every new connection. Carries the
# server's BUILD_SHA + version so the client can refuse to proceed against a
# server running a different build (which would otherwise manifest as desync,
# crashes, or silent protocol drift). On mismatch we disconnect locally with
# a rich reason; on match we reply with our own sha + version so the server
# can do the symmetric check.
func _on_server_hello(packet: ServerHelloPacket) -> void:
	var local_sha := Constants.get_build_sha()
	if packet.build_sha != local_sha:
		_disconnected_message = "Version mismatch: server %s, you %s. Update via the launcher." \
			% [packet.version, Constants.get_version()]
		push_warning("[net_client] %s" % _disconnected_message)
		NetSession.disconnect_client()
		return

	var reply := ClientHelloPacket.new()
	reply.build_sha = local_sha
	reply.version = Constants.get_version()
	NetSession.send_packet(reply.to_payload())


func manage_ids(packet: IdAssignmentPacket) -> void:
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


func get_disconnect_message(end_reason: int) -> String:
	match end_reason:
		DisconnectReason.INVALID:
			return "Connection ended: Invalid reason"
		DisconnectReason.APP_INTENTIONAL:
			return "Disconnected from server"
		DisconnectReason.APP_SERVER_FULL:
			return "Connection failed: Server is full"
		DisconnectReason.APP_SERVER_FULL_UPON_CONNECTED:
			return "Connection failed: Server is full upon connected"
		DisconnectReason.APP_SERVER_CONNECTION_ENDED_BY_CLIENT:
			return "Connection failed: Server connection ended by client"
		DisconnectReason.APP_BUILD_MISMATCH:
			return "Build mismatch — your client is on a different release than the server. Update via the launcher."
		DisconnectReason.APP_HANDSHAKE_TIMEOUT:
			return "Server kicked us: version handshake timed out. Client likely too old to talk to this server."
		
		# Local errors
		DisconnectReason.LOCAL_OFFLINE_MODE:
			return "Cannot connect: Steam is in offline mode"
		DisconnectReason.LOCAL_MANY_RELAY_CONNECTIVITY:
			return "Connection failed: Network connectivity issues"
		DisconnectReason.LOCAL_HOSTED_SERVER_PRIMARY_RELAY:
			return "Connection failed: Server relay connectivity problem"
		DisconnectReason.LOCAL_NETWORK_CONFIG:
			return "Connection failed: Unable to get network configuration"
		DisconnectReason.LOCAL_RIGHTS:
			return "Connection failed: Insufficient Steam permissions"
		
		# Remote errors
		DisconnectReason.REMOTE_TIMEOUT:
			return "Connection timed out"
		DisconnectReason.REMOTE_BAD_CRYPT:
			return "Connection failed: Encryption handshake failed"
		DisconnectReason.REMOTE_BAD_CERT:
			return "Connection failed: Server certificate validation failed"
		DisconnectReason.REMOTE_BAD_PROTOCOL_VERSION:
			return "Connection failed: Protocol version mismatch (update required)"
		
		# Miscellaneous errors
		DisconnectReason.MISC_GENERIC:
			return "Connection ended unexpectedly"
		DisconnectReason.MISC_INTERNAL_ERROR:
			return "Connection failed: Internal error"
		DisconnectReason.MISC_TIMEOUT:
			return "Connection timed out"
		DisconnectReason.MISC_STEAM_CONNECTIVITY:
			return "Connection failed: Cannot connect to Steam services"
		DisconnectReason.MISC_NO_RELAY_SESSIONS_TO_CLIENT:
			return "Connection failed: No relay sessions available"
		DisconnectReason.MISC_PEER_SENT_NO_CONNECTION:
			return "Connection failed: Server has no record of this connection"
		
		_:
			# Handle application-defined codes (1000-2999) if needed
			if end_reason >= 1000 and end_reason <= 1999:
				return "Connection ended by application"
			if end_reason >= 2000 and end_reason <= 2999:
				return "Connection ended: Application error"
			return "Connection ended (reason code: %d)" % end_reason


func on_disconnect_from_server(end_reason: int) -> void:
	# Preserve any application-level message already set by code that
	# initiated the disconnect (e.g. _on_server_hello on build mismatch
	# writes a rich "Server: vX.Y vs you: vA.B" string before calling
	# NetSession.disconnect_client). Without this guard we'd clobber it
	# with the generic "Disconnected from server" mapped from end_reason
	# 1000 (APP_INTENTIONAL).
	if _disconnected_message.is_empty():
		_disconnected_message = get_disconnect_message(end_reason)
	print("Disconnected from server: ", _disconnected_message)
	handle_disconnect_from_server.emit()
	id = -1
	remote_ids.clear()


enum DisconnectReason {
	INVALID = 0,
	
	# Application ranges (for reference):
	# App range: 1000-1999 (normal disconnections)
	APP_INTENTIONAL = 1000,
	APP_SERVER_FULL = 1001,
	APP_SERVER_CONNECTION_ENDED_BY_CLIENT = 1002,
	# Kept in sync with NetServer.APP_BUILD_MISMATCH / APP_HANDSHAKE_TIMEOUT.
	APP_BUILD_MISMATCH = 1003,
	APP_HANDSHAKE_TIMEOUT = 1004,

	# AppException range: 2000-2999 (unusual/exceptional disconnections)
	APP_SERVER_FULL_UPON_CONNECTED = 2000, # unusual case where the server has room when connecting but not once connection is established

	# Local errors (3xxx): Problems with local host or connection to Internet
	LOCAL_OFFLINE_MODE = 3001,
	LOCAL_MANY_RELAY_CONNECTIVITY = 3002,
	LOCAL_HOSTED_SERVER_PRIMARY_RELAY = 3003,
	LOCAL_NETWORK_CONFIG = 3004,
	LOCAL_RIGHTS = 3005,
	
	# Remote errors (4xxx): Problems with remote host or in between
	REMOTE_TIMEOUT = 4001,
	REMOTE_BAD_CRYPT = 4002,
	REMOTE_BAD_CERT = 4003,
	REMOTE_BAD_PROTOCOL_VERSION = 4006,
	
	# Miscellaneous errors (5xxx): Other connection failures
	MISC_GENERIC = 5001,
	MISC_INTERNAL_ERROR = 5002,
	MISC_TIMEOUT = 5003,
	MISC_STEAM_CONNECTIVITY = 5005,
	MISC_NO_RELAY_SESSIONS_TO_CLIENT = 5006,
	MISC_PEER_SENT_NO_CONNECTION = 5010,	
}
