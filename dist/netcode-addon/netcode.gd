@tool
extends EditorPlugin

# Sprint 5: addon scaffolding + inspector plugin registration. The autoloads
# stay declared in project.godot for now (registering them here would require
# the user to enable the plugin before networking works — early friction with
# no upside). The inspector plugin adds editor-time helpers to NetSchema
# resources; harmless when the user never opens one.

const NetSchemaInspectorPluginScript := preload("res://addons/netcode/editor/net_schema_inspector_plugin.gd")

var _schema_inspector: EditorInspectorPlugin


func _enter_tree() -> void:
	_schema_inspector = NetSchemaInspectorPluginScript.new()
	add_inspector_plugin(_schema_inspector)
	# Keep NetSchema's project-wide id collision cache fresh. Connecting on
	# enter_tree + an immediate refresh covers (a) the case where the user
	# already had schemas in the project before enabling the plugin and (b)
	# every subsequent FS change (add/rename/delete of a NetSchema .tres).
	var fs := EditorInterface.get_resource_filesystem()
	if fs and not fs.filesystem_changed.is_connected(NetSchema.refresh_id_cache):
		fs.filesystem_changed.connect(NetSchema.refresh_id_cache)
	NetSchema.refresh_id_cache()
	# Belt-and-suspenders for editor-time reactivity. The primary mechanism is
	# per-property setters on NetSchema + NetCorrection that emit_changed (see
	# those files) — Godot's engine writes @export vars directly to the script
	# var, so a generic _set override doesn't see them, but explicit setters
	# fire reliably regardless of which inspector triggered the write
	# (including nested sub-resource inspectors that don't bubble
	# property_edited up to the main inspector). This property_edited hook
	# adds a second path for any future @export property added without a
	# matching setter, walking the inspected object's graph for NetSchemas to
	# emit_changed on.
	var inspector := EditorInterface.get_inspector()
	if inspector and not inspector.property_edited.is_connected(_on_inspector_property_edited):
		inspector.property_edited.connect(_on_inspector_property_edited)


func _exit_tree() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	if fs and fs.filesystem_changed.is_connected(NetSchema.refresh_id_cache):
		fs.filesystem_changed.disconnect(NetSchema.refresh_id_cache)
	var inspector := EditorInterface.get_inspector()
	if inspector and inspector.property_edited.is_connected(_on_inspector_property_edited):
		inspector.property_edited.disconnect(_on_inspector_property_edited)
	if _schema_inspector:
		remove_inspector_plugin(_schema_inspector)
		_schema_inspector = null


func _on_inspector_property_edited(_property: String) -> void:
	var inspector := EditorInterface.get_inspector()
	if inspector == null:
		return
	var obj := inspector.get_edited_object()
	if obj == null:
		return
	# The inspector's "edited object" is the top-level node/resource — NOT
	# necessarily the NetSchema. Two common cases miss a naive `obj is NetSchema`:
	#   (a) NetPredictor is selected with `schema` expanded inline. Editing
	#       state_template / id / corrections[i].fields still has the NetPredictor
	#       as the edited object.
	#   (b) Any future container resource that holds a NetSchema sub-resource.
	# Walk the resource graph and emit_changed on every NetSchema reached, so
	# the validation revalidate + button-refresh listeners fire regardless of
	# how deep the user is editing.
	var visited: Dictionary = {}
	_emit_changed_on_nested_schemas(obj, visited)


func _emit_changed_on_nested_schemas(obj: Object, visited: Dictionary) -> void:
	if obj == null:
		return
	var id := obj.get_instance_id()
	if visited.has(id):
		return
	visited[id] = true
	if obj is NetSchema:
		(obj as NetSchema).emit_changed()
		# Fall through — a NetSchema can itself hold further sub-resources we
		# might want to descend into in the future. Cheap.
	for prop in obj.get_property_list():
		if (prop.usage & PROPERTY_USAGE_STORAGE) == 0:
			continue
		var v: Variant = obj.get(prop.name)
		if v is Resource:
			_emit_changed_on_nested_schemas(v, visited)
		elif v is Array:
			for item in v:
				if item is Resource:
					_emit_changed_on_nested_schemas(item, visited)
		elif v is Dictionary:
			for item in (v as Dictionary).values():
				if item is Resource:
					_emit_changed_on_nested_schemas(item, visited)
