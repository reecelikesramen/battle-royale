extends PanelContainer

@onready var property_container = %VBoxContainer
@onready var repeat_actions_button: Button = %RepeatActionsButton
@onready var chat_hide_timer: Timer = null

var props = {}

var player: PlayerController:
	get: return NetworkClient.player

func _enter_tree() -> void:
	NetworkClient.handle_chat.connect(chat_message_added)


func _exit_tree() -> void:
	NetworkClient.handle_chat.disconnect(chat_message_added)


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	visible = false
	
	if NetworkTransport.is_server:
		return
	
	if not player or not player.is_authority:
		return
	
	NetworkClient.debug = self
	%ScrollContainer.visible = false

	# Timer to auto-hide chat when debug overlay is off
	chat_hide_timer = Timer.new()
	chat_hide_timer.one_shot = true
	chat_hide_timer.wait_time = 5.0
	add_child(chat_hide_timer)
	chat_hide_timer.timeout.connect(_on_chat_hide_timeout)


func _process(_delta) -> void:
	set_debug_property("FPS", Engine.get_frames_per_second())
	set_debug_property("Ping", "%d ms" % NetworkTransport.client_ping)


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
	NetworkTransport.disconnect_client()


func _on_quit_button_pressed() -> void:
	get_tree().quit()


func _on_chat_edit_text_submitted(new_text: String) -> void:
	%ChatEdit.text = ""
	var packet = ChatPacket.new()
	packet.username = NetworkClient.username
	packet.message = new_text
	NetworkTransport.send_packet(packet)


func chat_message_added(packet: ChatPacket):
	%ScrollContainer.visible = true
	var new_chat = %ChatMessagePrototype.duplicate()
	new_chat.text = "<%s> %s" % [packet.username, packet.message]
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
