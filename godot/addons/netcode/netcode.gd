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


func _exit_tree() -> void:
	if _schema_inspector:
		remove_inspector_plugin(_schema_inspector)
		_schema_inspector = null
