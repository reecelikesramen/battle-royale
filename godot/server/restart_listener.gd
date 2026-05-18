extends Node
#
# Client-only autoload. Subscribes to the admin "server restarting" topic
# on NetReliableHub. On message: writes a sentinel file so the launcher
# re-runs the update flow on next launch, shows a banner, and returns the
# player to the main menu.
#
# Lives in godot/server/ alongside other game-specific server tooling.
# Does NOT modify the netcode addon.

const ADMIN_TOPIC_BASE := 100_000
const ADMIN_TOPIC_RESTART := ADMIN_TOPIC_BASE + 0

func _ready() -> void:
	if NetSession.is_dedicated_server:
		queue_free()
		return
	NetReliableHub.subscribe_client(ADMIN_TOPIC_RESTART, _on_restart_notice)

func _on_restart_notice(payload: PackedByteArray) -> void:
	var text := payload.get_string_from_utf8()
	print("server restart notice: ", text)
	_write_restart_sentinel()
	NetClient._disconnected_message = "Server restarting to update — relaunching the launcher will pull the new version."
	NetSession.disconnect_client()
	get_tree().change_scene_to_file(Constants.MAIN_MENU_SCENE_PATH)

func _write_restart_sentinel() -> void:
	# Drop the sentinel next to the game executable so the launcher (which
	# lives in the same install dir) can find it without OS-specific path
	# math. The launcher checks `<install>/.restart_requested` after the
	# game exits.
	var exe_dir := OS.get_executable_path().get_base_dir()
	if exe_dir.is_empty():
		return
	var path := exe_dir.path_join(".restart_requested")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(Time.get_datetime_string_from_system(true))
		f.close()
