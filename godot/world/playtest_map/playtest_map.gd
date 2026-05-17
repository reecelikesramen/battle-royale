extends Node3D

# Race-safe listen-mode trigger. _ready runs AFTER all child spawners' _ready
# (Godot calls _ready bottom-up), so PlayerSpawner / GrenadeSpawner have
# already subscribed to NetReplication's server_/client_entity_spawn_requested
# signals before the loopback handshake fires. Pure-client and dedicated boots
# leave pending_listen_mode false and this is a no-op.
func _ready() -> void:
	if NetSession.pending_listen_mode:
		NetSession.pending_listen_mode = false
		NetSession.start_listen_mode()
