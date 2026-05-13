class_name PlayerSchema

# Code-built default schema for the player NetPredictor. Phase 5 keeps this in
# code so the structure ships without yet authoring a .tres. Phase 7 or later
# may persist it to res://entities/player/player_predicted.tres for inspector
# editing.

static func build() -> NetSchema:
	var schema := NetSchema.new()
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

	return schema
