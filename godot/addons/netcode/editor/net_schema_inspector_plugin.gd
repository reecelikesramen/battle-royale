@tool
class_name NetSchemaInspectorPlugin extends EditorInspectorPlugin

# Sprint 5: inspector polish for NetSchema resources. Adds a "Generate fields
# from state_class" button at the top of the schema inspector that introspects
# the state Resource's @export properties via get_property_list() and rewrites
# schema.state_fields to a parallel NetFieldConfig array (one entry per user
# field, Quant.AUTO by default). Mirrors the field-discovery logic that
# NetPredictor._user_field_names already runs at runtime, so the inspector's
# generated config matches the codec's view exactly.
#
# Scope: this sprint targets state_fields only. Adding similar generators for
# command_fields, NetChildRef path pickers, or correction-channel templates
# would land as follow-up commits — the registration hook below makes it easy
# to extend.

const _SKIP_PROPS := [
	&"resource_local_to_scene",
	&"resource_path",
	&"resource_name",
	&"resource_scene_unique_id",
	&"script",
]


func _can_handle(object: Object) -> bool:
	return object is NetSchema


func _parse_begin(object: Object) -> void:
	var schema: NetSchema = object as NetSchema
	if schema == null:
		return
	var gen := Button.new()
	gen.text = "Generate state_fields from state_class"
	gen.tooltip_text = "Walks state_class @export properties and rewrites state_fields with one NetFieldConfig per field (Quant.AUTO). Existing entries are replaced."
	gen.pressed.connect(_on_generate_state_fields.bind(schema))
	add_custom_control(gen)


func _on_generate_state_fields(schema: NetSchema) -> void:
	if schema == null or schema.state_class == null:
		push_warning("NetSchemaInspectorPlugin: state_class is unset; nothing to generate")
		return
	var probe: Resource = schema.state_class.new()
	if probe == null:
		push_warning("NetSchemaInspectorPlugin: failed to instantiate state_class %s" % schema.state_class)
		return
	var fields: Array[NetFieldConfig] = []
	for prop in probe.get_property_list():
		if (prop.usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		if (prop.usage & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		if (prop.usage & PROPERTY_USAGE_GROUP) != 0:
			continue
		if prop.name in _SKIP_PROPS:
			continue
		var cfg := NetFieldConfig.new()
		cfg.name = prop.name
		fields.append(cfg)
	schema.state_fields = fields
	# emit_changed triggers the inspector to re-read + the editor to mark the
	# resource dirty so it gets persisted on next save.
	schema.emit_changed()
	print("NetSchemaInspectorPlugin: regenerated %d state_fields for %s" % [fields.size(), schema.state_class])
