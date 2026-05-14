@tool
class_name NetSchemaInspectorPlugin extends EditorInspectorPlugin

# Inspector polish for NetSchema resources. Two pieces:
#
# 1) _parse_property intercepts the `state_fields` property and replaces
#    Godot's stock typed-Dictionary editor with StateFieldsEditorProperty —
#    a custom row-per-field view driven from state_template's @export vars.
#    Field set + binding come from the script; the inspector only edits
#    codec config per row. Renames flow automatically from script edits.
#
# 2) _parse_begin adds a row of "Open <slot> script" buttons that resolve
#    the assigned NetState/NetCommand subclass's script at press time and
#    open it in the script editor. The stock resource picker only opens
#    new/load/save/clear — no way to navigate to where the class is defined.
#    A wholesale "reset state_fields to defaults" gesture lives on Godot's
#    stock revert arrow on the State Fields property header (see NetSchema's
#    _property_get_revert) — no separate button needed.

const StateFieldsEditor := preload("res://addons/netcode/editor/state_fields_editor_property.gd")


func _can_handle(object: Object) -> bool:
	return object is NetSchema


func _parse_property(_object: Object, _type: int, name: String, _hint_type: int,
		_hint_string: String, _usage_flags: int, _wide: bool) -> bool:
	if name != "state_fields":
		return false
	var editor := StateFieldsEditor.new()
	add_property_editor(name, editor)
	return true  # tell the inspector we handled it; suppress the default editor


func _parse_begin(object: Object) -> void:
	var schema: NetSchema = object as NetSchema
	if schema == null:
		return

	# Open-script row. The stock resource picker (state_template / command_template)
	# has no "navigate to the script that defines this class" affordance; clicking
	# the slot only opens new/load/save/clear. These buttons resolve the bound
	# Resource's script live (on press) and refresh their enabled state on
	# schema.changed — so clearing a template disables the button immediately
	# instead of staying stale until project reload.
	var open_box := HBoxContainer.new()
	open_box.add_child(_make_open_script_button(
			"Open state_template script",
			"Open the script defining state_template (the NetState subclass). Disabled when no template is assigned.",
			schema, "state_template"))
	open_box.add_child(_make_open_script_button(
			"Open command_template script",
			"Open the script defining command_template (the NetCommand subclass). Disabled when no template is assigned.",
			schema, "command_template"))
	add_custom_control(open_box)


func _make_open_script_button(text: String, tooltip: String, schema: NetSchema, prop_name: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.tooltip_text = tooltip
	# Click handler resolves the template AT PRESS TIME, not at button-build
	# time — so clearing+reassigning state_template doesn't strand the button
	# on the previous script.
	btn.pressed.connect(func():
		var res: Resource = schema.get(prop_name)
		if res == null:
			return
		var script: Script = res.get_script()
		if script != null:
			EditorInterface.edit_script(script))
	# Disabled state needs to track schema edits live. Refresh on schema.changed
	# so clearing a template grays the button immediately, and reassigning
	# enables it. The lambda captures `btn` (a Node — non-RefCounted Object),
	# so when the inspector rebuilds and frees the button, an undisconnected
	# schema.changed listener would fire the lambda with a freed capture and
	# spam "Lambda capture at index 0 was freed" errors. Disconnect on
	# tree_exiting (fires while btn is still valid, before final free).
	var refresh := func():
		if not is_instance_valid(btn):
			return
		var res: Resource = schema.get(prop_name)
		btn.disabled = res == null or res.get_script() == null
	refresh.call()
	schema.changed.connect(refresh)
	btn.tree_exiting.connect(func():
		if schema.changed.is_connected(refresh):
			schema.changed.disconnect(refresh))
	return btn


