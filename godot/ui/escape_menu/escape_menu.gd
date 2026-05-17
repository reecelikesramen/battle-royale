extends ToggleUI


const REBINDABLE_ACTIONS: Array[Dictionary] = [
	{ "group": "Movement", "actions": ["move_forward", "move_backward", "move_left", "move_right"] },
	{ "group": "Actions",  "actions": ["jump", "crouch", "sprint", "prone", "free_look"] },
	{ "group": "Combat",   "actions": ["shoot", "scope", "throw_grenade"] },
	{ "group": "View",     "actions": ["toggle_camera", "peek_left", "peek_right"] },
	{ "group": "Chat",     "actions": ["toggle_chat"] },
]

const ACTION_DISPLAY_NAMES: Dictionary = {
	"move_forward":   "Move Forward",
	"move_backward":  "Move Backward",
	"move_left":      "Move Left",
	"move_right":     "Move Right",
	"jump":           "Jump",
	"crouch":         "Crouch",
	"sprint":         "Sprint",
	"prone":          "Prone",
	"free_look":      "Free Look",
	"shoot":          "Shoot",
	"scope":          "Scope / ADS",
	"throw_grenade":  "Throw Grenade",
	"toggle_camera":  "Toggle Camera",
	"peek_left":      "Peek Left",
	"peek_right":     "Peek Right",
	"toggle_chat":    "Toggle Chat",
}

var _options_visible := false
var _rebinding_action: StringName = ""
var _rebinding_button: Button = null

@onready var _content_vbox: VBoxContainer = $VBoxContainer/OptionsAreaHBox/ContentPanel/ContentMargin/ContentScroll/ContentVBox


func _ready() -> void:
	super._ready()
	add_to_group("escape_menu")
	get_window().focus_exited.connect(_on_window_focus_lost)
	get_window().focus_entered.connect(_on_window_focus_gained)
	$VBoxContainer/OptionsAreaHBox.visible = _options_visible


func _input(event: InputEvent) -> void:
	if _rebinding_action == "":
		super._input(event)
		return
	if event is InputEventKey and event.physical_keycode == KEY_ESCAPE and event.pressed:
		_cancel_rebind()
		get_viewport().set_input_as_handled()
		return
	var is_key: bool = event is InputEventKey and event.pressed and not event.echo
	var is_mouse: bool = event is InputEventMouseButton and event.pressed
	if not (is_key or is_mouse):
		return
	_confirm_rebind(event)
	get_viewport().set_input_as_handled()


func _on_open() -> void:
	if not is_inside_tree():
		return
	for node in get_tree().get_nodes_in_group("debug_hud"):
		if node.has_method("force_close"):
			node.force_close()


func _on_window_focus_lost() -> void:
	if not open:
		open = true


# Godot releases MOUSE_MODE_CAPTURED on focus loss and restores it on regain.
# That restore fights us when escape menu is open (we want VISIBLE) — user sees
# the menu but with an invisible captured cursor. Re-assert VISIBLE here so the
# menu's mouse state survives an alt-tab round-trip. Deferred because Godot's
# internal restore runs after this signal handler.
func _on_window_focus_gained() -> void:
	if open and SHOW_MOUSE:
		call_deferred("_force_visible_cursor")


func _force_visible_cursor() -> void:
	if open and SHOW_MOUSE:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)


func _on_options_button_pressed() -> void:
	_options_visible = not _options_visible
	if not _options_visible:
		_cancel_rebind()
	$VBoxContainer/OptionsAreaHBox.visible = _options_visible


func _on_exit_button_pressed() -> void:
	NetSession.disconnect_client()


func _on_gameplay_settings_button_pressed() -> void:
	_show_keybindings()


func _on_display_settings_button_pressed() -> void:
	_show_coming_soon("Display")


func _on_graphics_settings_button_pressed() -> void:
	_show_coming_soon("Graphics")


func _on_audio_settings_button_pressed() -> void:
	_show_coming_soon("Audio")


func _clear_content() -> void:
	for child in _content_vbox.get_children():
		child.queue_free()


func _show_coming_soon(category: String) -> void:
	_cancel_rebind()
	_clear_content()
	var lbl := Label.new()
	lbl.text = "%s settings — Coming soon" % category
	lbl.add_theme_font_size_override("font_size", 18)
	_content_vbox.add_child(lbl)


func _show_keybindings() -> void:
	_cancel_rebind()
	_clear_content()
	for group_def in REBINDABLE_ACTIONS:
		var header := Label.new()
		header.text = group_def["group"]
		header.add_theme_font_size_override("font_size", 14)
		header.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_content_vbox.add_child(header)
		for action_name in group_def["actions"]:
			_content_vbox.add_child(_build_keybind_row(action_name))
		var spacer := Control.new()
		spacer.custom_minimum_size = Vector2(0, 8)
		_content_vbox.add_child(spacer)


func _build_keybind_row(action_name: StringName) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.custom_minimum_size = Vector2(0, 34)
	row.add_theme_constant_override("separation", 6)

	var name_lbl := Label.new()
	name_lbl.text = ACTION_DISPLAY_NAMES.get(action_name, action_name)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_lbl)

	var binding_btn := Button.new()
	binding_btn.text = _get_action_binding_string(action_name)
	binding_btn.custom_minimum_size = Vector2(150, 0)
	binding_btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_style_binding_button(binding_btn, false)
	binding_btn.pressed.connect(func(): _start_rebind(action_name, binding_btn))
	row.add_child(binding_btn)

	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.custom_minimum_size = Vector2(34, 0)
	reset_btn.tooltip_text = "Reset to default"
	reset_btn.pressed.connect(func(): _reset_action(action_name, binding_btn))
	row.add_child(reset_btn)

	return row


func _style_binding_button(btn: Button, active: bool) -> void:
	var border_col := Color(0.4, 0.65, 1.0) if active else Color(0.35, 0.35, 0.35)
	var bg_col := Color(0.1, 0.15, 0.22) if active else Color(0.14, 0.14, 0.14)
	var border_w := 2 if active else 1
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var s := StyleBoxFlat.new()
		s.bg_color = bg_col.lightened(0.04) if state == "hover" else bg_col
		s.border_color = border_col
		s.set_border_width_all(border_w)
		s.set_corner_radius_all(3)
		s.content_margin_left = 8
		s.content_margin_right = 8
		s.content_margin_top = 4
		s.content_margin_bottom = 4
		btn.add_theme_stylebox_override(state, s)


func _get_action_binding_string(action_name: StringName) -> String:
	var events := InputMap.action_get_events(action_name)
	if events.is_empty():
		return "[unbound]"
	var ev := events[0]
	if ev is InputEventKey:
		return OS.get_keycode_string(ev.get_physical_keycode_with_modifiers())
	elif ev is InputEventMouseButton:
		match ev.button_index:
			MOUSE_BUTTON_LEFT:   return "Mouse 1"
			MOUSE_BUTTON_RIGHT:  return "Mouse 2"
			MOUSE_BUTTON_MIDDLE: return "Mouse 3"
			_: return "Mouse %d" % ev.button_index
	return ev.as_text()


func _start_rebind(action_name: StringName, btn: Button) -> void:
	if _rebinding_action != "":
		_cancel_rebind()
	_rebinding_action = action_name
	_rebinding_button = btn
	btn.text = "Press a key…"
	_style_binding_button(btn, true)


func _cancel_rebind() -> void:
	if _rebinding_button != null:
		_rebinding_button.text = _get_action_binding_string(_rebinding_action)
		_style_binding_button(_rebinding_button, false)
	_rebinding_action = ""
	_rebinding_button = null


func _confirm_rebind(event: InputEvent) -> void:
	InputMap.action_erase_events(_rebinding_action)
	InputMap.action_add_event(_rebinding_action, event)
	_rebinding_button.text = _get_action_binding_string(_rebinding_action)
	_style_binding_button(_rebinding_button, false)
	_rebinding_action = ""
	_rebinding_button = null


func _reset_action(action_name: StringName, btn: Button) -> void:
	if _rebinding_action == action_name:
		_cancel_rebind()
	InputMap.action_erase_events(action_name)
	var default: Dictionary = ProjectSettings.get_setting("input/" + action_name, {})
	for event in default.get("events", []):
		InputMap.action_add_event(action_name, event)
	btn.text = _get_action_binding_string(action_name)
