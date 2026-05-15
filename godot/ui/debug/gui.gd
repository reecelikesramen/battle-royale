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
var _hitmarker_until_us: int = 0
var _damage_until_us: int = 0
var _player: Node = null


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	_player = owner
	_build_hit_widgets()
	var sh: Node = get_tree().root.find_child("ShootHandler", true, false)
	if sh != null and sh.has_signal("hit_confirmed"):
		sh.hit_confirmed.connect(_on_hit_confirmed)
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

	_health_label = Label.new()
	_health_label.text = "HP 100"
	_health_label.add_theme_font_size_override("font_size", 20)
	_health_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	_health_label.position = Vector2(20, 600)
	_health_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_health_label)


func _on_hit_confirmed(shooter_id: int, target_id: int, damage: int, _remaining: int) -> void:
	var now_us: int = Time.get_ticks_usec()
	var local_id: int = NetClient.id
	if shooter_id == local_id:
		_hitmarker_until_us = now_us + int(HIT_FLASH_SEC * 1_000_000)
	if target_id == local_id:
		_damage_label.text = "-%d" % damage
		_damage_until_us = now_us + int(HIT_FLASH_SEC * 2.0 * 1_000_000)


func _process(_delta: float) -> void:
	var now_us: int = Time.get_ticks_usec()
	_hitmarker.modulate.a = 1.0 if now_us < _hitmarker_until_us else 0.0
	if now_us < _damage_until_us:
		var t: float = (_damage_until_us - now_us) / float(HIT_FLASH_SEC * 2.0 * 1_000_000)
		_damage_label.modulate.a = clampf(t, 0.0, 1.0)
	else:
		_damage_label.modulate.a = 0.0
	if _player != null and _player.has_method(&"get") and _player.get("_net") != null:
		var net: NetPredictor = _player._net
		if net != null and net.shadow_state != null:
			var hp: int = (net.shadow_state as PlayerState).health
			_health_label.text = "HP %d" % hp
	
func _input(event):
	if event.is_action_pressed("debug"):
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
