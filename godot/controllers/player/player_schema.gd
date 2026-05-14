class_name PlayerSchema

# Player NetPredictor schema. Source of truth is player_schema.tres (inspector-
# editable). build() reconstructs the same schema in code as a fresh-clone /
# tools fallback; both paths must compute_hash() identically so the
# registration drift warning doesn't fire.

const SCHEMA_ID := 1
const RESOURCE_PATH := "res://entities/player/player_schema.tres"


# Production entrypoint. Returns the inspector-editable .tres when present;
# otherwise rebuilds the schema in code so the game still runs on a fresh
# clone. Logs a hint pointing at the save tool when falling back.
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

	# Correction channels. Field paths are sub-axis selectors ("pos.xz",
	# "velocity.y"); the framework parses them in NetPredictor._corrections_pass
	# to compute per-channel error magnitudes and lerp render_state toward
	# shadow_state on the matching axes.
	var horizontal := NetCorrection.new()
	horizontal.name = &"horizontal"
	horizontal.fields = PackedStringArray(["pos.xz"])
	horizontal.snap_threshold = 1.5
	horizontal.smooth_rate = 8.0
	horizontal.deadband = 0.07
	schema.corrections.append(horizontal)

	# Vertical drags velocity.y along with pos.y so the smoothing keeps them
	# coherent — falling through a snap on pos.y without zeroing vel.y produces
	# a visible re-fall on the next tick.
	var vertical := NetCorrection.new()
	vertical.name = &"vertical"
	vertical.fields = PackedStringArray(["pos.y", "velocity.y"])
	vertical.snap_threshold = 2.5
	vertical.smooth_rate = 4.0
	vertical.deadband = 0.15
	schema.corrections.append(vertical)

	# always_smooth = true keeps the channel from ever snapping velocity to the
	# server value; the natural exp-smoothing alpha plateaus around 0.18/tick at
	# rate 12 so even large velocity divergence fades over ~4-6 frames without
	# the visible jerk a snap would cause.
	var velocity_horizontal := NetCorrection.new()
	velocity_horizontal.name = &"velocity_horizontal"
	velocity_horizontal.fields = PackedStringArray(["velocity.xz"])
	velocity_horizontal.snap_threshold = 1.5
	velocity_horizontal.smooth_rate = 12.0
	velocity_horizontal.deadband = 0.2
	velocity_horizontal.always_smooth = true
	schema.corrections.append(velocity_horizontal)

	# Per-field codec config. Must match player_schema.tres exactly — the hash
	# check in NetReplication.register_schema warns on drift. Add new fields in
	# both places in the same commit.
	schema.state_fields.append(_field(&"pos", NetFieldConfig.Quant.FLOAT32))
	schema.state_fields.append(_field(&"velocity", NetFieldConfig.Quant.FLOAT32))
	schema.state_fields.append(_field(&"look", NetFieldConfig.Quant.FLOAT32))
	schema.state_fields.append(_field(&"movement_state", NetFieldConfig.Quant.QUANT8, 0.0, 15.0, true))
	schema.state_fields.append(_field(&"peek_state", NetFieldConfig.Quant.QUANT8, 0.0, 15.0, true))
	schema.state_fields.append(_field(&"crouch_progress", NetFieldConfig.Quant.QUANT8, 0.0, 1.0))
	schema.state_fields.append(_field(&"prone_progress", NetFieldConfig.Quant.QUANT8, 0.0, 1.0))
	schema.state_fields.append(_field(&"peek_progress", NetFieldConfig.Quant.QUANT8, -1.0, 1.0))

	return schema


static func _field(
		field_name: StringName,
		quant: NetFieldConfig.Quant,
		lo: float = 0.0,
		hi: float = 0.0,
		no_interp: bool = false) -> NetFieldConfig:
	var cfg := NetFieldConfig.new()
	cfg.name = field_name
	cfg.quant = quant
	cfg.min_value = lo
	cfg.max_value = hi
	cfg.no_interp = no_interp
	return cfg
