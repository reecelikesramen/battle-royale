class_name PlayerSchema

# Player NetPredictor schema. Sprint 2: persisted to .tres for inspector
# editing — load() returns the resource, falling back to a code-built default
# when the file is missing (mostly for tests and one-time bootstrap before
# tools/save_player_schema.gd has been run on a fresh checkout).

const SCHEMA_ID := 1
const RESOURCE_PATH := "res://entities/player/player_schema.tres"


# Sprint 2: production entrypoint. Returns the inspector-editable .tres when
# present; otherwise rebuilds the schema in code so the game still runs on a
# fresh clone. Logs a hint pointing at the save tool when falling back.
static func get_schema() -> NetSchema:
	if ResourceLoader.exists(RESOURCE_PATH):
		var loaded: NetSchema = load(RESOURCE_PATH)
		if loaded != null:
			return loaded
		push_warning("PlayerSchema: %s exists but failed to load; building in code" % RESOURCE_PATH)
	else:
		push_warning("PlayerSchema: %s missing; building in code. Run tools/save_player_schema.gd to materialize." % RESOURCE_PATH)
	return build()


static func build() -> NetSchema:
	var schema := NetSchema.new()
	schema.id = SCHEMA_ID
	schema.state_class = PlayerState
	schema.command_class = PlayerInput
	schema.tick_hz = 120
	schema.snapshot_hz = 30

	var horizontal := NetCorrection.new()
	horizontal.name = &"horizontal"
	horizontal.fields = PackedStringArray(["pos.xz"])
	horizontal.snap_threshold = 1.5
	horizontal.smooth_rate = 8.0
	horizontal.deadband = 0.07
	schema.corrections.append(horizontal)

	var vertical := NetCorrection.new()
	vertical.name = &"vertical"
	vertical.fields = PackedStringArray(["pos.y"])
	vertical.snap_threshold = 2.5
	vertical.smooth_rate = 4.0
	vertical.deadband = 0.15
	schema.corrections.append(vertical)

	var velocity_horizontal := NetCorrection.new()
	velocity_horizontal.name = &"velocity_horizontal"
	velocity_horizontal.fields = PackedStringArray(["velocity.xz"])
	velocity_horizontal.snap_threshold = 1.5
	velocity_horizontal.smooth_rate = 12.0
	velocity_horizontal.deadband = 0.2
	schema.corrections.append(velocity_horizontal)

	# Sprint 2: include name-matched state_fields cfgs so a code-built schema
	# matches the .tres byte-for-byte (both produce Quant.AUTO for every
	# field). Hash compatibility between fresh-clone (build()) and
	# tools-saved (.tres) is required for the registration hash check.
	var probe := PlayerState.new()
	var cfgs: Array[NetFieldConfig] = []
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
		cfgs.append(cfg)
	schema.state_fields = cfgs

	return schema
