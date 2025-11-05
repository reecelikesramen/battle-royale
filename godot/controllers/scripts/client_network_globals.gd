extends Node

signal handle_local_id_assignment(local_id: int)
signal handle_remote_id_assignment(remote_id: int)
signal handle_player_disconnected(player_id: int)
signal handle_player_state(player_state: PlayerStatePacket)
signal handle_chat(message: ChatPacket)
signal handle_disconnect_from_server()

enum DisconnectReason {
	INVALID = 0,
	
	# Application ranges (for reference):
	# App range: 1000-1999 (normal disconnections)
	APP_INTENTIONAL = 1000,
	APP_SERVER_FULL = 1001,
	APP_SERVER_CONNECTION_ENDED_BY_CLIENT = 1002,

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

var username: String
var id: int = -1
var player: FPSController
var debug
var remote_ids: Array[int]
var _disconnected_message: String = ""

func _ready() -> void:
	LowLevelNetworkHandler.on_client_packet.connect(on_client_packet)
	LowLevelNetworkHandler.on_disconnect_from_server.connect(on_disconnect_from_server)


func on_client_packet(data) -> void:
	if data is IdAssignmentPacket:
		manage_ids(data)
	elif data is PlayerStatePacket:
		handle_player_state.emit(data)
	elif data is ChatPacket:
		handle_chat.emit(data)
	elif data is PlayerDisconnectedPacket:
		handle_player_disconnected.emit(data.player_id)
	else:
		push_error("Packet unknown type unhandled!")


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
	_disconnected_message = get_disconnect_message(end_reason)
	print("Disconnected from server: ", _disconnected_message)
	handle_disconnect_from_server.emit()
	id = -1
	remote_ids.clear()
