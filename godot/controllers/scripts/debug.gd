extends PanelContainer

@onready var property_container = %VBoxContainer
@onready var repeat_actions_button: Button = %RepeatActionsButton
var props = {}
@onready var chat_hide_timer: Timer = null

func _enter_tree() -> void:
	ClientNetworkGlobals.handle_chat.connect(chat_message_added)


func _exit_tree() -> void:
	ClientNetworkGlobals.handle_chat.disconnect(chat_message_added)


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	visible = false
	
	# set debug to client globals if the scene root (player) is authority
	var player = get_owner() as FPSController
	if !player.is_authority:
		print("%s not authority" % LowLevelNetworkHandler.is_server)
		return
	else:
		print("%s is authority" % LowLevelNetworkHandler.is_server)
		ClientNetworkGlobals.debug = self
	
	%ScrollContainer.visible = false
	if LowLevelNetworkHandler.is_dedicated_server:
		%ExitToMenuButton.visible = false

	# Timer to auto-hide chat when debug overlay is off
	chat_hide_timer = Timer.new()
	chat_hide_timer.one_shot = true
	chat_hide_timer.wait_time = 5.0
	add_child(chat_hide_timer)
	chat_hide_timer.timeout.connect(_on_chat_hide_timeout)


func _process(_delta) -> void:
	set_debug_property("FPS", Engine.get_frames_per_second())
	set_debug_property("Ping", "%d ms" % LowLevelNetworkHandler.client_ping)


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
	LowLevelNetworkHandler.disconnect_client()


func _on_quit_button_pressed() -> void:
	get_tree().quit()


func _on_chat_edit_text_submitted(new_text: String) -> void:
	%ChatEdit.text = ""
	_record_action_repeat_chat(new_text)
	var packet = ChatPacket.new()
	packet.username = ClientNetworkGlobals.username
	packet.message = new_text
	LowLevelNetworkHandler.send_packet(packet)


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


func _on_repeat_actions_button_toggled(toggled_on: bool) -> void:
	var player := get_tree().get_first_node_in_group("local_player")
	if player == null:
		_set_repeat_actions_button(false)
		return
	if !player.has_method("set_action_repeat"):
		_set_repeat_actions_button(false)
		return
	var applied: bool = player.set_action_repeat(toggled_on)
	if applied == toggled_on:
		return
	_set_repeat_actions_button(applied)


func _set_repeat_actions_button(state: bool) -> void:
	if repeat_actions_button == null:
		return
	if repeat_actions_button.button_pressed == state:
		return
	repeat_actions_button.set_pressed_no_signal(state)


func _record_action_repeat_chat(message: String) -> void:
	var player := get_tree().get_first_node_in_group("local_player")
	if player == null:
		return
	if !player.has_method("record_chat_event"):
		return
	player.record_chat_event(ClientNetworkGlobals.username, message)
