extends Node

# init.tscn is the project's main scene. Its only remaining job is to detect
# the dedicated-server boot path (which skips main_menu) and otherwise hand
# off to the main menu. The Rust launcher (see /launcher) owns all update
# logic — the legacy in-game phase-machine that downloaded pck patches via
# load_resource_pack() was removed when pck deltas moved to zstd zpatches
# applied by the launcher before the game process even starts.

func _ready() -> void:
	get_tree().call_deferred(&"change_scene_to_file", Constants.MAIN_MENU_SCENE_PATH)
