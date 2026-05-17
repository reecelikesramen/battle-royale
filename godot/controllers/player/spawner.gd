class_name PlayerSpawner extends Node3D

# Per-peer auto-spawn is fully framework-owned. We just register the schema +
# scene + parent, then handle the one game-specific bit (chat relay) once roles
# settle. Framework spawns the auth on peer-connect, proxy on id-assignment,
# despawns on disconnects, and emits entity_registered when each side is wired.

const PLAYER_SCHEMA_ID: int = 1
const PLAYER_SCENE_PATH: String = "res://controllers/player/player.tscn"


func _ready() -> void:
	NetReplication.bind_peer_entity(PLAYER_SCHEMA_ID, PLAYER_SCENE_PATH, self)
	NetReplication.entity_registered.connect(_on_entity_registered)
	NetClient.handle_disconnect_from_server.connect(_clear_local_player_ref)
	NetSession.when_roles_ready(_subscribe_chat_relay)


func _on_entity_registered(schema_id: int, entity_id: int, is_authoritative: bool) -> void:
	if schema_id != PLAYER_SCHEMA_ID:
		return
	# Local view goes on the proxy that owns the local peer's input. Auth-side
	# spawn happens too but is hidden + non-input; framework wires both sides
	# automatically.
	if is_authoritative:
		return
	if entity_id != NetClient.id:
		return
	var pred: NetPredictor = NetReplication.get_entity(schema_id, entity_id, false)
	if pred != null:
		NetClient.player = pred.host as PlayerController


func _clear_local_player_ref() -> void:
	NetClient.player = null


func _subscribe_chat_relay() -> void:
	if NetSession.has_server_role:
		NetReliableHub.subscribe_server(Enums.ReliableTopic.CHAT, _relay_chat_to_clients)


func _relay_chat_to_clients(_peer_id: int, payload: PackedByteArray) -> void:
	NetReliableHub.broadcast(Enums.ReliableTopic.CHAT, payload)
