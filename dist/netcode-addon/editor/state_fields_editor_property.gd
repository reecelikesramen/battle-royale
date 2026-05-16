@tool
class_name StateFieldsEditorProperty extends EditorProperty

# Custom inspector for NetSchema.state_fields. Field set is driven from
# state_template's @export vars (read-only — rename in the script, not here).
# Per-field codec config (quant / min / max / no_interp / predict) renders
# inline in one row each.
#
# Layout: a GridContainer with one column per knob aligns all rows so the
# SpinBox values, dropdown widths, and checkboxes line up like a table.
# The grid is wrapped in a ScrollContainer with custom_minimum_size = (0, 0)
# so the editor never forces the inspector pane wider — instead a horizontal
# scrollbar appears when the row exceeds available width. Above the scroll
# sits a fold button so the inspector entry can be collapsed.
#
# Auto-update model:
#   - _process polls state_template.get_property_list each editor frame; when
#     the field signature changes (name added, removed, renamed, retyped),
#     rebuilds the rows.
#   - On rebuild: missing fields get a fresh NetStateField with defaults;
#     a single orphan paired with a single new field is treated as a rename
#     and its codec config is transplanted across (so renames don't lose
#     hand-tuned quant/min/max); remaining orphans are auto-pruned. The user
#     never sees a stale "orphan" row.

const _SKIP_PROPS := [
	&"resource_local_to_scene",
	&"resource_path",
	&"resource_name",
	&"resource_scene_unique_id",
	&"script",
]


# Names matching this filter are storage/metadata props injected by Godot
# (e.g. `metadata/_custom_script_type` on a default-init NetState) — never
# user fields, never belong in state_fields.
static func _is_excluded_prop(prop_name: StringName) -> bool:
	if prop_name in _SKIP_PROPS:
		return true
	return (prop_name as String).begins_with("metadata/")

# Multi-line tooltip describing each Quant value. Surfaces on the dropdown.
const _QUANT_TOOLTIP := """Wire encoding for this field's value.

AUTO — Godot's generic put_var/get_var. Largest payload (typed header per
       value), no clamping. Use when bandwidth doesn't matter or for fields
       that don't fit the other modes.

QUANT8 — 1 byte per scalar axis. Value is mapped from [min_value, max_value]
       to [0, 255] on encode, inverted on decode. Lossy (~1/256 of range
       error). Set min/max accurately. Vectors quantize per-axis.

QUANT16 — 2 bytes per scalar axis. Same map as QUANT8 with [0, 65535] range.
       Far less loss (~1/65k of range). Good for positions in small worlds.

FLOAT32 — Raw IEEE-754 float, 4 bytes per axis. Lossless within float
       precision. Defaults for unbounded fields (positions in large worlds,
       velocity).

QUAT32 — Smallest-three quaternion encoding, 4 bytes total. Drops the
       largest component (reconstructed from unit-length constraint),
       packs the other three in 10 bits each plus a 2-bit index. ~1/512
       radian error. Use only for unit quaternions (orientations)."""

# Grid column count matches the per-row widget set:
# [name, type, quant, "min" label, min spin, "max" label, max spin,
#  no_interp, predict]
const _COLUMNS := 9

var _container: VBoxContainer
var _fold_btn: Button
var _scroll: ScrollContainer
var _grid: GridContainer
var _message_lbl: Label
var _schema: NetSchema
# Guard against re-entry: emit_changed -> editor writes prop back -> our
# _update_property fires -> would tear down + rebuild rows mid-edit. Setting
# _updating skips the rebuild for that round-trip.
var _updating: bool = false
# Signature of the last template shape we built rows for. Polled in _process
# so we can detect script-side renames without depending on Godot firing a
# notification.
var _last_template_signature: String = ""
# Persisted across rebuilds so collapse state survives auto-refresh.
var _collapsed: bool = false
# Cached field count for the fold button label without re-walking grid.
var _field_count: int = 0
# Per-template snapshot of state_fields configs (keyed by template instance_id).
# When the user reassigns state_template (clear + re-add, or undo back to a
# previously-used template), _rebuild_rows pre-restores from this cache before
# the destructive auto-sync wipes per-field configs. UndoRedo doesn't track
# our auto-sync mutations (we bypass EditorUndoRedoManager), so this cache is
# the substitute that gives intuitive "undo restores configs" behavior across
# template swaps within an editor session.
var _field_cache: Dictionary = {}


func _init() -> void:
	_container = VBoxContainer.new()
	_container.add_theme_constant_override("separation", 4)
	add_child(_container)
	# Pin container under the EditorProperty's main row so it occupies the
	# wide area below the property label (instead of squeezing into the
	# value column).
	set_bottom_editor(_container)

	_fold_btn = Button.new()
	_fold_btn.flat = true
	_fold_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_fold_btn.pressed.connect(_toggle_collapsed)
	_container.add_child(_fold_btn)

	# Wrap the grid in a ScrollContainer so wide content doesn't force the
	# inspector pane to grow horizontally. custom_minimum_size = (0, 0)
	# tells the layout engine "I can be tiny" — without that, Container
	# min-size propagation pushes our width up the parent chain until the
	# whole inspector resizes to fit. The H scroll mode only shows when the
	# inner grid actually overflows; V scroll is disabled because the fold
	# button is the right "collapse the whole thing" affordance, not a
	# scrollbar.
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.custom_minimum_size = Vector2(0, 0)
	_container.add_child(_scroll)

	_grid = GridContainer.new()
	_grid.columns = _COLUMNS
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 3)
	_scroll.add_child(_grid)

	_message_lbl = Label.new()
	_message_lbl.visible = false
	_container.add_child(_message_lbl)

	# Editor-time polling for script-shape changes. set_process works on @tool
	# nodes in the editor; the cost is one get_property_list call per frame
	# while the schema is selected.
	set_process(true)

	_refresh_fold_ui()


func _update_property() -> void:
	if _updating:
		return
	_schema = get_edited_object() as NetSchema
	_last_template_signature = _compute_template_signature()
	_rebuild_rows()


func _process(_delta: float) -> void:
	# Do NOT early-out on null state_template — clearing the template needs to
	# also trigger a rebuild (signature changes to "" → rows wipe). The old
	# guard left orphan rows visible until project reload.
	if _updating or _schema == null:
		return
	var sig := _compute_template_signature()
	if sig != _last_template_signature:
		_last_template_signature = sig
		_rebuild_rows()


# A deterministic string capturing the template's @export shape (names +
# types). When this differs from the last build we know the script was edited
# and need to re-render.
func _compute_template_signature() -> String:
	if _schema == null or _schema.state_template == null:
		return ""
	var parts: PackedStringArray = PackedStringArray()
	for prop in _schema.state_template.get_property_list():
		if (prop.usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		if (prop.usage & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		if (prop.usage & PROPERTY_USAGE_GROUP) != 0:
			continue
		if _is_excluded_prop(prop.name):
			continue
		parts.append("%s:%d" % [prop.name, prop.type])
	return "|".join(parts)


func _toggle_collapsed() -> void:
	_collapsed = not _collapsed
	_refresh_fold_ui()


# Single source of truth for the fold button text and the scroll/message
# visibility. Called on collapse toggle and after every rebuild.
func _refresh_fold_ui() -> void:
	var arrow := "▶" if _collapsed else "▼"
	_fold_btn.text = "%s %d fields" % [arrow, _field_count]
	# Scroll (with rows) shows only when expanded AND there are rows to show.
	_scroll.visible = not _collapsed and _field_count > 0
	# Message label shows when there's no content to display (no schema /
	# template) — fold state doesn't hide an explanatory message.
	_message_lbl.visible = _message_lbl.text != "" and _field_count == 0


func _rebuild_rows() -> void:
	for child in _grid.get_children():
		child.queue_free()
	_message_lbl.text = ""
	_field_count = 0

	if _schema == null:
		_show_message("No schema bound.", Color(0.7, 0.7, 0.7))
		return
	if _schema.state_template == null:
		_show_message("state_template is unset — set it to configure field codec.",
				Color(1.0, 0.65, 0.2))
		return

	var template_fields: Array = _template_fields(_schema.state_template)
	var template_names: Array[StringName] = []
	for entry in template_fields:
		template_names.append(entry.name)

	# Restore configs from the per-template cache before the destructive sync
	# below has a chance to default-init them. Keyed by the template's instance
	# id — Godot's UndoRedo restores the same Resource instance on undo, so
	# this hits when the user undoes a "remove template" or re-assigns the same
	# template after clearing it.
	var template_key: int = _schema.state_template.get_instance_id()
	var cached: Dictionary = _field_cache.get(template_key, {})
	var restore_dirty := false
	for k in template_names:
		if not _schema.state_fields.has(k) and cached.has(k):
			_schema.state_fields[k] = cached[k]
			restore_dirty = true

	# Reconcile state_fields with the script. Always-on cleanup so the user
	# never sees a manual orphan row.
	var orphans: Array[StringName] = []
	for k in _schema.state_fields.keys():
		if not k in template_names:
			orphans.append(k)
	var new_fields: Array[StringName] = []
	for k in template_names:
		if not _schema.state_fields.has(k):
			new_fields.append(k)

	var dirty := false
	# Rename heuristic: a single orphan paired with a single new field is
	# almost always a rename — transplant the codec config so the user
	# doesn't have to redial quant/min/max after every variable rename.
	if orphans.size() == 1 and new_fields.size() == 1:
		_schema.state_fields[new_fields[0]] = _schema.state_fields[orphans[0]]
		_schema.state_fields.erase(orphans[0])
		orphans.clear()
		new_fields.clear()
		dirty = true

	# Default-init any remaining new fields so each row has a backing entry.
	for k in new_fields:
		_schema.state_fields[k] = NetStateField.new()
		dirty = true

	# Auto-prune leftover orphans. No red rows, no manual ✕ button required.
	for k in orphans:
		_schema.state_fields.erase(k)
		dirty = true

	# Render rows in declaration order so the inspector mirrors the script's
	# top-to-bottom layout. (Hash + wire codec also walk in this order.)
	for entry in template_fields:
		_add_row(entry.name, entry.type_label, _schema.state_fields[entry.name])

	_field_count = template_fields.size()
	_refresh_fold_ui()

	# Snapshot final per-field configs for restoration on future template
	# swaps/undos. Take it AFTER the destructive sync so the cache reflects
	# what the user currently sees (not pre-prune state).
	var snapshot: Dictionary = {}
	for k in template_names:
		if _schema.state_fields.has(k):
			snapshot[k] = _schema.state_fields[k]
	_field_cache[template_key] = snapshot

	if dirty or restore_dirty:
		_schema.emit_changed()


func _show_message(text: String, color: Color) -> void:
	_message_lbl.text = text
	_message_lbl.add_theme_color_override("font_color", color)
	_field_count = 0
	_refresh_fold_ui()


func _template_fields(probe: Resource) -> Array:
	var fields: Array = []
	for prop in probe.get_property_list():
		if (prop.usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		if (prop.usage & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		if (prop.usage & PROPERTY_USAGE_GROUP) != 0:
			continue
		if _is_excluded_prop(prop.name):
			continue
		fields.append({
			"name": StringName(prop.name),
			"type_label": _type_label(prop.type)
		})
	return fields


func _type_label(t: int) -> String:
	match t:
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_STRING_NAME: return "StringName"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR4: return "Vector4"
		TYPE_QUATERNION: return "Quaternion"
		TYPE_COLOR: return "Color"
		_: return "Variant"


# Add one row's worth of widgets to the GridContainer (in column order).
func _add_row(field_name: StringName, type_label: String,
		cfg: NetStateField) -> void:
	# Column 1: field name
	var name_lbl := Label.new()
	name_lbl.text = str(field_name)
	_grid.add_child(name_lbl)

	# Column 2: type (dim)
	var type_lbl := Label.new()
	type_lbl.text = type_label
	type_lbl.modulate = Color(0.65, 0.65, 0.65)
	_grid.add_child(type_lbl)

	# Column 3: Quant dropdown. Sticky hover popup via _attach_hover_popup —
	# standard tooltip_text would dismiss when the mouse tries to move into it,
	# making scrollable overflowed content unreachable. The popup mirrors the
	# inspector property tooltip behavior (child_refs, etc.) — stays visible
	# while cursor is over either the dropdown or the popup itself.
	var quant_btn := OptionButton.new()
	for q_name in ["AUTO", "QUANT8", "QUANT16", "FLOAT32", "QUAT32"]:
		quant_btn.add_item(q_name)
	quant_btn.selected = cfg.quant
	quant_btn.item_selected.connect(func(idx: int):
		cfg.quant = idx
		_commit())
	_grid.add_child(quant_btn)
	_attach_hover_popup(quant_btn, _QUANT_TOOLTIP)

	# Column 4: "min" label
	_grid.add_child(_make_inline_label("min"))

	# Column 5: min SpinBox
	var min_box := SpinBox.new()
	min_box.allow_lesser = true
	min_box.allow_greater = true
	min_box.step = 0.01
	min_box.value = cfg.min_value
	min_box.custom_minimum_size = Vector2(80, 0)
	min_box.tooltip_text = "Lower bound for QUANT8/QUANT16 range mapping. Ignored for AUTO/FLOAT32/QUAT32."
	min_box.value_changed.connect(func(v: float):
		cfg.min_value = v
		_commit())
	_grid.add_child(min_box)

	# Column 6: "max" label
	_grid.add_child(_make_inline_label("max"))

	# Column 7: max SpinBox
	var max_box := SpinBox.new()
	max_box.allow_lesser = true
	max_box.allow_greater = true
	max_box.step = 0.01
	max_box.value = cfg.max_value
	max_box.custom_minimum_size = Vector2(80, 0)
	max_box.tooltip_text = "Upper bound for QUANT8/QUANT16 range mapping. Ignored for AUTO/FLOAT32/QUAT32."
	max_box.value_changed.connect(func(v: float):
		cfg.max_value = v
		_commit())
	_grid.add_child(max_box)

	# Column 8: no_interp
	var no_interp_btn := CheckBox.new()
	no_interp_btn.text = "no_interp"
	no_interp_btn.button_pressed = cfg.no_interp
	no_interp_btn.tooltip_text = "Proxy interpolation uses the freshest value with no easing. Useful for booleans, state IDs, and any field where intermediate interpolated values would be nonsense."
	no_interp_btn.toggled.connect(func(pressed: bool):
		cfg.no_interp = pressed
		_commit())
	_grid.add_child(no_interp_btn)

	# Column 9: predict
	var predict_btn := CheckBox.new()
	predict_btn.text = "predict"
	predict_btn.button_pressed = cfg.predict
	predict_btn.tooltip_text = "When off, field replicates to proxies only; predicted (locally-authoritative) entities skip it on replay. Use for cosmetics derived from other fields."
	predict_btn.toggled.connect(func(pressed: bool):
		cfg.predict = pressed
		_commit())
	_grid.add_child(predict_btn)


func _make_inline_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.modulate = Color(0.7, 0.7, 0.7)
	return lbl


# Sticky hover popup. Mirrors the inspector property tooltip behavior used by
# child_refs etc. — hovering the target for the standard tooltip delay shows a
# PopupPanel below it; the popup stays visible while the cursor is over either
# the target or the popup; cursor leaving both for a short grace period hides
# it. Replaces tooltip_text on widgets whose description overflows the screen.
#
# One shared popup per editor-property instance, reused across all attached
# targets. Generation counters cancel pending show/hide tasks across signal
# transitions so rapid hover-in/out doesn't leave the popup in an odd state.
const _HOVER_SHOW_DELAY: float = 0.5
const _HOVER_HIDE_DELAY: float = 0.2
const _HOVER_POPUP_SIZE := Vector2(680, 480)
const _HOVER_LABEL_WIDTH: float = 640.0  # narrower than scroll to leave vbar room

var _hover_popup: PopupPanel
var _hover_popup_label: Label
var _hover_popup_scroll: ScrollContainer
var _hover_target: Control
var _hover_show_gen: int = 0
var _hover_hide_gen: int = 0


# Attach sticky hover popup behavior to a control. Replaces tooltip_text —
# don't also set tooltip_text on the target or both will fire.
#
# Special case for OptionButton: its native dropdown menu competes with our
# popup for focus, and `mouse_exited` fires when the native menu pops open.
# Without intervention, our schedule_hover_hide races with the native popup
# and either (a) closes our popup ~0.2s after the user clicks the dropdown
# or (b) the focus juggling closes the native dropdown ~0.3s in. Listening
# to `pressed` + `get_popup().about_to_popup` lets us force-hide our popup
# and cancel any pending show the instant the native menu is invoked, so
# the two never overlap.
func _attach_hover_popup(target: Control, text: String) -> void:
	target.mouse_entered.connect(_on_hover_enter.bind(target, text))
	target.mouse_exited.connect(_on_hover_exit)
	if target is OptionButton:
		var ob: OptionButton = target
		ob.pressed.connect(_force_hide_hover_popup)
		ob.get_popup().about_to_popup.connect(_force_hide_hover_popup)


func _force_hide_hover_popup() -> void:
	# Bump both generations so any pending await timeout (show or hide) bails
	# when it resumes — otherwise a delayed show would re-open the popup over
	# the native menu.
	_hover_show_gen += 1
	_hover_hide_gen += 1
	_hover_target = null
	if _hover_popup and is_instance_valid(_hover_popup) and _hover_popup.visible:
		_hover_popup.hide()


func _ensure_hover_popup() -> void:
	if _hover_popup and is_instance_valid(_hover_popup):
		return
	_hover_popup = PopupPanel.new()
	_hover_popup_scroll = ScrollContainer.new()
	_hover_popup_scroll.custom_minimum_size = _HOVER_POPUP_SIZE
	_hover_popup_label = Label.new()
	_hover_popup_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hover_popup_label.custom_minimum_size.x = _HOVER_LABEL_WIDTH
	_hover_popup_scroll.add_child(_hover_popup_label)
	_hover_popup.add_child(_hover_popup_scroll)
	# Cursor entering/leaving the popup is tracked at the Window level — not
	# on the inner ScrollContainer. ScrollContainer.mouse_exited fires when the
	# cursor enters the scrollbar child (the scrollbar has its own mouse
	# filter), which would dismiss the popup the moment the user tried to use
	# it. Window.mouse_entered/exited track the whole popup region instead.
	_hover_popup.mouse_entered.connect(_cancel_hover_hide)
	_hover_popup.mouse_exited.connect(_schedule_hover_hide)
	add_child(_hover_popup)


func _on_hover_enter(target: Control, text: String) -> void:
	# Skip entirely when the target's own dropdown is open — competing popups
	# steal focus from each other and cause the native menu to close ~0.3s
	# after the click.
	if target is OptionButton and (target as OptionButton).get_popup().visible:
		return
	_cancel_hover_hide()
	_hover_target = target
	_hover_show_gen += 1
	var gen: int = _hover_show_gen
	await get_tree().create_timer(_HOVER_SHOW_DELAY).timeout
	# Bail if mouse left before delay elapsed, or another target took over,
	# or the target's native menu opened during the delay.
	if gen != _hover_show_gen or _hover_target != target:
		return
	if target is OptionButton and (target as OptionButton).get_popup().visible:
		return
	_ensure_hover_popup()
	_hover_popup_label.text = text
	var pos: Vector2i = Vector2i(target.get_screen_position() + Vector2(0, target.size.y + 4))
	_hover_popup.position = pos
	_hover_popup.popup()


func _on_hover_exit() -> void:
	_hover_target = null
	_hover_show_gen += 1  # cancel any pending show
	_schedule_hover_hide()


func _schedule_hover_hide() -> void:
	_hover_hide_gen += 1
	var gen: int = _hover_hide_gen
	await get_tree().create_timer(_HOVER_HIDE_DELAY).timeout
	if gen != _hover_hide_gen:
		return
	if _hover_popup and is_instance_valid(_hover_popup) and _hover_popup.visible:
		_hover_popup.hide()


func _cancel_hover_hide() -> void:
	_hover_hide_gen += 1


func _commit() -> void:
	# Tell the editor the property changed (marks the resource dirty for save).
	# Mutating cfg in place doesn't bump references but does need an explicit
	# emit_changed to flag the .tres for re-serialization.
	_updating = true
	emit_changed(get_edited_property(), _schema.state_fields)
	_schema.emit_changed()
	_updating = false
