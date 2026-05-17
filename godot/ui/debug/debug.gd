extends PanelContainer

@onready var property_container = %VBoxContainer
@onready var chat_hide_timer: Timer = null

var props = {}

var player: PlayerController:
	get: return owner as PlayerController

func _enter_tree() -> void:
	# Phase 9b: chat now travels over NetReliableHub instead of a dedicated
	# ChatPacket. Payload format below in _encode_chat_payload.
	NetReliableHub.subscribe(Enums.ReliableTopic.CHAT, _on_chat_payload)


func _exit_tree() -> void:
	NetReliableHub.unsubscribe(Enums.ReliableTopic.CHAT, _on_chat_payload)


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	visible = false

	# Listen-server has both roles; the HUD lives on the client side. Dedicated
	# server returns early since it has no rendering.
	if not NetSession.has_client_role:
		return

	if not player or not player.is_local_view:
		return
	
	NetClient.debug = self
	%ScrollContainer.visible = false

	# Timer to auto-hide chat when debug overlay is off
	chat_hide_timer = Timer.new()
	chat_hide_timer.one_shot = true
	chat_hide_timer.wait_time = 5.0
	add_child(chat_hide_timer)
	chat_hide_timer.timeout.connect(_on_chat_hide_timeout)


func _process(_delta) -> void:
	set_debug_property("FPS", Engine.get_frames_per_second())
	set_debug_property("Ping", "%d ms" % NetSession.client_ping)


func _input(event):
	if event.is_action_pressed("debug"):
		visible = !visible
		if visible:
			# When debug is on, keep chat always visible
			_show_chat()
			if chat_hide_timer:
				chat_hide_timer.stop()
		else:
			# When debug is off, schedule auto-hide
			_schedule_chat_hide()


func set_debug_property(title: String, value):
	if title not in props:
		props[title] = Label.new()
		property_container.add_child(props[title])
	var property = props[title]
	property.name = title
	property.text = "%s: %s" % [title, value]


func _on_exit_to_menu_button_pressed() -> void:
	NetSession.shutdown_all()


func _on_quit_button_pressed() -> void:
	get_tree().quit()


func _on_chat_edit_text_submitted(new_text: String) -> void:
	%ChatEdit.text = ""
	var payload := _encode_chat_payload(NetClient.username, new_text)
	NetReliableHub.send(Enums.ReliableTopic.CHAT, payload)


# Payload layout: put_string(username) then put_string(message). Variant-
# tagged via put_string under the hood — postcard is not used here because the
# wire-level NetReliablePacket already pays its serialization cost.
static func _encode_chat_payload(username: String, message: String) -> PackedByteArray:
	var sp := StreamPeerBuffer.new()
	sp.put_string(username)
	sp.put_string(message)
	return sp.data_array


static func _decode_chat_payload(payload: PackedByteArray) -> Array:
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	return [sp.get_string(), sp.get_string()]


func _on_chat_payload(payload: PackedByteArray) -> void:
	var parts: Array = _decode_chat_payload(payload)
	_append_chat_line(parts[0], parts[1])


func _append_chat_line(username: String, message: String) -> void:
	%ScrollContainer.visible = true
	var new_chat = %ChatMessagePrototype.duplicate()
	new_chat.text = "<%s> %s" % [username, message]
	new_chat.visible = true
	print("New chat: %s" % new_chat.text)
	%ChatVBox.add_child(new_chat)
	%ChatVBox.move_child(new_chat, 0)
	%ScrollContainer.custom_minimum_size.y = clamp(31 * %ChatVBox.get_children().size(), 0, 31 * 6)

	# Show chat (and fade in if animation exists), then schedule hide if debug is off
	_show_chat()
	_schedule_chat_hide()


func _show_chat() -> void:
	%ScrollContainer.visible = true


func _schedule_chat_hide() -> void:
	# Only auto-hide when debug overlay is off
	if visible:
		return
	if chat_hide_timer:
		chat_hide_timer.start(5.0)


func _on_chat_hide_timeout() -> void:
	# If debug got enabled meanwhile, do nothing
	if visible:
		return
	%ScrollContainer.visible = false
