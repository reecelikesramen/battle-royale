extends Node

signal handle_local_id_assignment(local_id: int)
signal handle_remote_id_assignment(remote_id: int)
signal handle_player_disconnected(player_id: int)
signal handle_net_state(packet: NetStatePacket)
signal handle_net_reliable(packet: NetReliablePacket)
signal handle_server_tick(tick: ServerTickPacket)
signal handle_disconnect_from_server()

var username: String
var id: int = -1
var player: PlayerController
var debug
var remote_ids: Array[int]
var _disconnected_message: String = ""

# Network Quality AUTO mode: samples NetSession.client_ping into an EMA, then
# every AUTO_SAMPLE_PERIOD_S seconds picks LOW/BALANCED/HIGH based on the
# bucketed value. Hysteresis prevents flap around bucket boundaries.
# Only runs when SettingsStore.current_preset == AUTO; manual user picks
# (escape-menu / main-menu UI) bypass this loop entirely.
const AUTO_SAMPLE_PERIOD_S: float = 5.0
const AUTO_SETTLE_INITIAL_S: float = 2.0
const AUTO_PING_EMA_ALPHA: float = 0.1
const AUTO_LOW_THRESHOLD_MS: int = 40
const AUTO_HIGH_THRESHOLD_MS: int = 100
const AUTO_HYSTERESIS_MS: int = 10

var ping_ema_ms: float = 80.0
var _auto_sample_accum_s: float = 0.0
var _auto_active: bool = false
var _auto_last_bucket: int = -1  # -1 = no decision yet this connection


func _ready() -> void:
	NetSession.on_client_packet.connect(on_client_packet)
	NetSession.on_disconnect_from_server.connect(on_disconnect_from_server)
	NetReliableHub.subscribe_client(NetReliableHub.TOPIC_ID_ASSIGNMENT, _on_id_assignment_payload)
	NetReliableHub.subscribe_client(NetReliableHub.TOPIC_PLAYER_DISCONNECTED, _on_player_disconnected_payload)


func on_client_packet(data) -> void:
	if data is ServerHelloPacket:
		_on_server_hello(data)
	elif data is NetStatePacket:
		handle_net_state.emit(data)
	elif data is NetReliablePacket:
		handle_net_reliable.emit(data)
	elif data is ServerTickPacket:
		handle_server_tick.emit(data)
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
		NetSession.shutdown_all()
		return

	var reply := ClientHelloPacket.new()
	reply.build_sha = local_sha
	reply.version = Constants.get_version()
	NetSession.send_packet(reply.to_payload())


# Wire format: u8 id, u8 count, then `count` u8 remote ids. Mirrors NetServer
# ._encode_id_assignment. Reliable-hub topic delivery is per-peer so packet
# semantics match the old targeted typed-packet send.
func _on_id_assignment_payload(payload: PackedByteArray) -> void:
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var assigned_id: int = sp.get_u8()
	var count: int = sp.get_u8()
	var ids: Array[int] = []
	for _i in count:
		ids.append(sp.get_u8())
	_manage_ids(assigned_id, ids)


func _manage_ids(assigned_id: int, ids: Array[int]) -> void:
	if id == -1: # First receipt: server is telling us our own id + current roster.
		id = assigned_id
		handle_local_id_assignment.emit(assigned_id)
		remote_ids = ids
		for remote_id in remote_ids:
			if remote_id == id: continue
			handle_remote_id_assignment.emit(remote_id)
	else: # Subsequent receipts: a new peer joined; ids[0..n) is current roster including them.
		remote_ids.append(assigned_id)
		handle_remote_id_assignment.emit(assigned_id)


func _on_player_disconnected_payload(payload: PackedByteArray) -> void:
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var peer_id: int = sp.get_u8()
	handle_player_disconnected.emit(peer_id)


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
	# NetSession.shutdown_all). Without this guard we'd clobber it
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


# Drives AUTO Network Quality mode. EMA-smoothes the GNS-measured ping, then
# every AUTO_SAMPLE_PERIOD_S seconds picks a bucket and tells SettingsStore.
# Hysteresis keeps borderline pings from flapping the preset back and forth.
# No-op unless SettingsStore.current_preset == AUTO.
func _process(delta: float) -> void:
	if id < 0:
		# Not connected — reset accumulator so first AUTO_SETTLE_INITIAL_S
		# after reconnect lets the EMA stabilize before we pick.
		ping_ema_ms = 80.0
		_auto_sample_accum_s = 0.0
		_auto_last_bucket = -1
		_auto_active = false
		return
	if SettingsStore == null:
		return
	if SettingsStore.current_preset != SettingsStore.QualityPreset.AUTO:
		_auto_last_bucket = -1
		return
	var raw_ping: int = NetSession.client_ping
	if raw_ping > 0:
		ping_ema_ms = lerp(ping_ema_ms, float(raw_ping), AUTO_PING_EMA_ALPHA)
	_auto_sample_accum_s += delta
	var settle_threshold: float = AUTO_SAMPLE_PERIOD_S if _auto_active else AUTO_SETTLE_INITIAL_S
	if _auto_sample_accum_s < settle_threshold:
		return
	_auto_sample_accum_s = 0.0
	_auto_active = true
	var picked: int = _pick_quality_bucket(ping_ema_ms, _auto_last_bucket)
	if picked != _auto_last_bucket:
		_auto_last_bucket = picked
		SettingsStore.apply_auto_preset(picked)


# Hysteresis: from BALANCED, switch to LOW only when ema < 30ms; switch to
# HIGH only when ema > 110ms. From LOW/HIGH, switch back when ema returns
# above/below the +hys / -hys edge of the inflated bucket. First-call picks
# directly from raw thresholds (no current bucket to widen).
func _pick_quality_bucket(ema_ms: float, current: int) -> int:
	var QP := SettingsStore.QualityPreset
	var lo: float = AUTO_LOW_THRESHOLD_MS
	var hi: float = AUTO_HIGH_THRESHOLD_MS
	var hys: float = AUTO_HYSTERESIS_MS
	match current:
		QP.LOW:
			if ema_ms > lo + hys:
				return QP.BALANCED if ema_ms <= hi else QP.HIGH
			return QP.LOW
		QP.BALANCED:
			if ema_ms < lo - hys:
				return QP.LOW
			if ema_ms > hi + hys:
				return QP.HIGH
			return QP.BALANCED
		QP.HIGH:
			if ema_ms < hi - hys:
				return QP.LOW if ema_ms < lo else QP.BALANCED
			return QP.HIGH
	if ema_ms < lo:
		return QP.LOW
	if ema_ms > hi:
		return QP.HIGH
	return QP.BALANCED
