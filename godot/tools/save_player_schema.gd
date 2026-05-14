extends SceneTree

# Sprint 2: one-off generator that materializes PlayerSchema.build() to
# res://entities/player/player_schema.tres so the inspector can edit it. Run
# with:
#   godot --headless --path godot --script res://tools/save_player_schema.gd
#
# Subsequent runs overwrite the file; safe to re-run after touching
# PlayerSchema.build() while iterating.


const OUT_PATH := "res://entities/player/player_schema.tres"


func _init() -> void:
	var schema: NetSchema = PlayerSchema.build()

	# Sprint 2: prime state_fields with name-matched NetFieldConfig entries so
	# the inspector has rows to edit on first open. Quant.AUTO keeps the wire
	# format byte-for-byte identical to a no-cfg schema; per-field overrides
	# happen in the inspector after this.
	var probe := PlayerState.new()
	var configs: Array[NetFieldConfig] = []
	for prop in probe.get_property_list():
		if (prop.usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		if (prop.usage & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		if (prop.usage & PROPERTY_USAGE_GROUP) != 0:
			continue
		if prop.name in [&"resource_local_to_scene", &"resource_path", &"resource_name", &"resource_scene_unique_id", &"script"]:
			continue
		var cfg := NetFieldConfig.new()
		cfg.name = prop.name
		configs.append(cfg)
	schema.state_fields = configs

	DirAccess.make_dir_recursive_absolute("res://entities/player")
	var err := ResourceSaver.save(schema, OUT_PATH)
	if err != OK:
		push_error("Failed to save schema to %s (err=%d)" % [OUT_PATH, err])
		quit(1)
		return
	print("Saved PlayerSchema to %s" % OUT_PATH)
	quit(0)
