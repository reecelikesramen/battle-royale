extends SceneTree

# One-off generator that materializes PlayerSchema.build() to
# res://entities/player/player_schema.tres so the inspector can edit it. Run:
#   godot --headless --path godot --script res://tools/save_player_schema.gd
#
# build() already contains the full per-field codec config (quant, predict,
# no_interp, min/max) so the saved .tres matches build()'s compute_hash().
# Subsequent runs overwrite the file; safe to re-run after touching
# PlayerSchema.build() while iterating.


const OUT_PATH := "res://entities/player/player_schema.tres"


func _init() -> void:
	var schema: NetSchema = PlayerSchema.build()
	DirAccess.make_dir_recursive_absolute("res://entities/player")
	var err := ResourceSaver.save(schema, OUT_PATH)
	if err != OK:
		push_error("Failed to save schema to %s (err=%d)" % [OUT_PATH, err])
		quit(1)
		return
	print("Saved PlayerSchema to %s" % OUT_PATH)
	quit(0)
