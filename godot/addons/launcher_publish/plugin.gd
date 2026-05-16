@tool
extends EditorPlugin
#
# Editor plugin scaffold. Adds a "Launcher Publish" dock with two actions:
#   1. "Generate manifest" — opens a dialog where you pick a folder of built
#      artifacts and a destination URL prefix; emits a versions.json v2 file
#      with sha256s. Signing is done externally (see the project's
#      `infrastructure/keys/generate-signing-key.sh` and the Cloud Build
#      signing step).
#   2. "Download launcher binaries" — pulls prebuilt cross-platform launcher
#      binaries from a configured release URL and stamps them next to your
#      exports.
#
# This is the marketplace-facing surface of the launcher tooling. The
# launcher binary itself is a separate Rust crate maintained outside this
# addon.

const PluginName := "Launcher Publish"

var _dock: Control

func _enter_tree() -> void:
	_dock = preload("res://addons/launcher_publish/launcher_publish_dock.tscn").instantiate()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_BR, _dock)

func _exit_tree() -> void:
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
