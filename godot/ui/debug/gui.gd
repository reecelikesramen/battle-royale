extends Control

var open: bool = false

# Hit feedback labels added programmatically so the .tscn doesn't churn.
# Hitmarker flashes mid-screen when local player shoots and connects;
# damage indicator flashes when local player takes damage; health label
# updates each frame from the local PlayerController's shadow_state.
const HIT_FLASH_SEC := 0.18
var _hitmarker: Label
var _damage_label: Label
var _health_label: Label
var _health_bar: ColorRect
var _health_bar_bg: ColorRect
var _death_label: Label
var _death_overlay: ColorRect
var _respawn_countdown_label: Label
var _hitmarker_until_us: int = 0
var _damage_until_us: int = 0
var _player: Node = null
# Authoritative HP override sourced from reliable events (HIT_CONFIRM,
# PLAYER_DIED, PLAYER_RESPAWN). -1 = no override, fall back to snapshot.
var _hp_reliable: int = -1
# Death countdown — starts at PLAYER_DIED receipt, cleared at PLAYER_RESPAWN.
const RESPAWN_COUNTDOWN_SEC := 10.0
var _death_at_us: int = -1


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	add_to_group("debug_hud")
	mouse_filter = Control.MOUSE_FILTER_PASS
	_player = owner
	_build_hit_widgets()
	var sh: Node = get_tree().root.find_child("ShootHandler", true, false)
	if sh != null and sh.has_signal("hit_confirmed"):
		sh.hit_confirmed.connect(_on_hit_confirmed)
		sh.player_died.connect(_on_player_died)
		sh.player_respawned.connect(_on_player_respawned)
	set_process(true)


func _build_hit_widgets() -> void:
	_hitmarker = Label.new()
	_hitmarker.text = "X"
	_hitmarker.add_theme_font_size_override("font_size", 32)
	_hitmarker.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	_hitmarker.anchor_left = 0.5
	_hitmarker.anchor_right = 0.5
	_hitmarker.anchor_top = 0.5
	_hitmarker.anchor_bottom = 0.5
	_hitmarker.offset_left = -10
	_hitmarker.offset_right = 10
	_hitmarker.offset_top = -20
	_hitmarker.offset_bottom = 20
	_hitmarker.modulate.a = 0.0
	_hitmarker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hitmarker)

	_damage_label = Label.new()
	_damage_label.text = "-10"
	_damage_label.add_theme_font_size_override("font_size", 28)
	_damage_label.add_theme_color_override("font_color", Color(1, 0.2, 0.2))
	_damage_label.anchor_left = 0.5
	_damage_label.anchor_right = 0.5
	_damage_label.anchor_top = 0.4
	_damage_label.anchor_bottom = 0.4
	_damage_label.offset_left = -40
	_damage_label.offset_right = 40
	_damage_label.modulate.a = 0.0
	_damage_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_damage_label)

	# Health: bar + label anchored to bottom-left so it stays in view at any res.
	_health_bar_bg = ColorRect.new()
	_health_bar_bg.color = Color(0.0, 0.0, 0.0, 0.55)
	_health_bar_bg.anchor_left = 0.0
	_health_bar_bg.anchor_right = 0.0
	_health_bar_bg.anchor_top = 1.0
	_health_bar_bg.anchor_bottom = 1.0
	_health_bar_bg.offset_left = 20
	_health_bar_bg.offset_right = 220
	_health_bar_bg.offset_top = -50
	_health_bar_bg.offset_bottom = -20
	_health_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_health_bar_bg)

	_health_bar = ColorRect.new()
	_health_bar.color = Color(0.85, 0.15, 0.15, 0.95)
	_health_bar.anchor_left = 0.0
	_health_bar.anchor_right = 0.0
	_health_bar.anchor_top = 1.0
	_health_bar.anchor_bottom = 1.0
	_health_bar.offset_left = 22
	_health_bar.offset_right = 218
	_health_bar.offset_top = -48
	_health_bar.offset_bottom = -22
	_health_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_health_bar)

	_health_label = Label.new()
	_health_label.text = "HP 100"
	_health_label.add_theme_font_size_override("font_size", 18)
	_health_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_health_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_health_label.add_theme_constant_override("outline_size", 4)
	_health_label.anchor_left = 0.0
	_health_label.anchor_right = 0.0
	_health_label.anchor_top = 1.0
	_health_label.anchor_bottom = 1.0
	_health_label.offset_left = 28
	_health_label.offset_right = 220
	_health_label.offset_top = -48
	_health_label.offset_bottom = -22
	_health_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_health_label)

	# Death overlay: full-screen opaque black, hides every other HUD widget by
	# being drawn last (top of child list). Added before the countdown label so
	# the label paints on top.
	_death_overlay = ColorRect.new()
	_death_overlay.color = Color(0, 0, 0, 1)
	_death_overlay.anchor_right = 1.0
	_death_overlay.anchor_bottom = 1.0
	_death_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_death_overlay.visible = false
	add_child(_death_overlay)

	_respawn_countdown_label = Label.new()
	_respawn_countdown_label.text = "10"
	_respawn_countdown_label.add_theme_font_size_override("font_size", 96)
	_respawn_countdown_label.add_theme_color_override("font_color", Color(1, 1, 1))
	_respawn_countdown_label.anchor_left = 0.5
	_respawn_countdown_label.anchor_right = 0.5
	_respawn_countdown_label.anchor_top = 0.5
	_respawn_countdown_label.anchor_bottom = 0.5
	_respawn_countdown_label.offset_left = -200
	_respawn_countdown_label.offset_right = 200
	_respawn_countdown_label.offset_top = -70
	_respawn_countdown_label.offset_bottom = 70
	_respawn_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_respawn_countdown_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_respawn_countdown_label.visible = false
	_respawn_countdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_respawn_countdown_label)

	# Legacy mid-screen "YOU DIED" — kept for non-local-death edge cases but
	# normally hidden behind the overlay. Could be removed later.
	_death_label = Label.new()
	_death_label.modulate.a = 0.0
	_death_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_death_label)


func _on_hit_confirmed(shooter_id: int, target_id: int, damage: int, remaining: int) -> void:
	var now_us: int = Time.get_ticks_usec()
	var local_id: int = NetClient.id
	if shooter_id == local_id:
		_hitmarker_until_us = now_us + int(HIT_FLASH_SEC * 1_000_000)
	if target_id == local_id:
		_damage_label.text = "-%d" % damage
		_damage_until_us = now_us + int(HIT_FLASH_SEC * 2.0 * 1_000_000)
		# Reliable transport: trust this remaining-health over the next snapshot
		# so a dropped state packet can't leave the HUD reading stale HP.
		_hp_reliable = remaining


func _on_player_died(victim_id: int, _killer_id: int) -> void:
	if victim_id == NetClient.id:
		_hp_reliable = 0
		_death_at_us = Time.get_ticks_usec()


func _on_player_respawned(victim_id: int, _pos: Vector3) -> void:
	if victim_id == NetClient.id:
		_hp_reliable = 100
		_death_at_us = -1


func _process(_delta: float) -> void:
	var now_us: int = Time.get_ticks_usec()
	_hitmarker.modulate.a = 1.0 if now_us < _hitmarker_until_us else 0.0
	if now_us < _damage_until_us:
		var t: float = (_damage_until_us - now_us) / float(HIT_FLASH_SEC * 2.0 * 1_000_000)
		_damage_label.modulate.a = clampf(t, 0.0, 1.0)
	else:
		_damage_label.modulate.a = 0.0
	var hp: int = 100
	if _player != null and _player.has_method(&"get") and _player.get("_net") != null:
		var net: NetPredictor = _player._net
		if net != null and net.shadow_state != null:
			hp = (net.shadow_state as PlayerState).health
			if _hp_reliable >= 0:
				if hp == _hp_reliable:
					_hp_reliable = -1
				else:
					hp = _hp_reliable
			_health_label.text = "HP %d" % hp
			var frac: float = clampf(hp / 100.0, 0.0, 1.0)
			_health_bar.offset_right = 22 + 196 * frac
			_health_bar.color = Color(1.0 - frac, frac, 0.15, 0.95)

	# Local death overlay: full black + countdown only. Everything else hidden.
	# Drives off _death_at_us so we get a stable 10s timer independent of any
	# snapshot health-flicker around respawn.
	var is_dead: bool = _death_at_us >= 0 or hp <= 0
	if is_dead and _death_at_us < 0:
		# Health snapshot says dead but PLAYER_DIED hasn't landed yet — start
		# countdown locally so the user never sees a frame of "dead but no UI".
		_death_at_us = now_us
	if is_dead:
		var elapsed_s: float = float(now_us - _death_at_us) / 1_000_000.0
		var remaining: float = max(0.0, RESPAWN_COUNTDOWN_SEC - elapsed_s)
		_respawn_countdown_label.text = "%d" % int(ceil(remaining))
		_death_overlay.visible = true
		_respawn_countdown_label.visible = true
		_hitmarker.visible = false
		_damage_label.visible = false
		_health_label.visible = false
		_health_bar.visible = false
		_health_bar_bg.visible = false
	else:
		_death_overlay.visible = false
		_respawn_countdown_label.visible = false
		_hitmarker.visible = true
		_damage_label.visible = true
		_health_label.visible = true
		_health_bar.visible = true
		_health_bar_bg.visible = true
	
func force_close() -> void:
	if not open:
		return
	open = false
	mouse_filter = Control.MOUSE_FILTER_PASS
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _input(event):
	if event.is_action_pressed("debug"):
		if not open:
			for node in get_tree().get_nodes_in_group("escape_menu"):
				if node.get("open") == true:
					return
		open = !open
		if open:
			mouse_filter = Control.MOUSE_FILTER_STOP
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			mouse_filter = Control.MOUSE_FILTER_PASS
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _on_fps_controller_reconcile_network_debug(delta_pos: Vector3, delta_vel: Vector3, unacked_inputs: SequenceRingBuffer) -> void:
	var color_pos := Color()
	color_pos.r = delta_pos.x
	color_pos.g = delta_pos.z
	color_pos.b = delta_pos.y
	$NetworkDebug/DeltaPos.color = color_pos

	var color_vel := Color()
	color_vel.r = delta_vel.x
	color_vel.g = delta_vel.z
	color_vel.b = delta_vel.y
	$NetworkDebug/DeltaVel.color = color_vel

	$NetworkDebug/InputBuffer.text = "Inputs Size: %d\nInputs Oldest: %d\nInputs Newest: %d\nInputs Buffer Delay: %d" % [unacked_inputs.size(), unacked_inputs.oldest_sequence_id(), unacked_inputs.newest_sequence_id(), unacked_inputs.buffer_delay_us()]
