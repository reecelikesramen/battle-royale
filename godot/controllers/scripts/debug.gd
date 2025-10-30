extends PanelContainer

@onready var property_container = %VBoxContainer
var props = {}

func _enter_tree() -> void:
	ClientNetworkGlobals.handle_chat.connect(chat_message_added)


func _exit_tree() -> void:
	ClientNetworkGlobals.handle_chat.disconnect(chat_message_added)


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	visible = false
	%ScrollContainer.visible = false
	if LowLevelNetworkHandler.is_dedicated_server:
		%ExitToMenuButton.visible = false


func _process(_delta) -> void:
	set_debug_property("FPS", Engine.get_frames_per_second())


func _input(event):
	if event.is_action_pressed("debug"):
		visible = !visible


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
	LowLevelNetworkHandler.send_packet(ChatPacket.create(ClientNetworkGlobals.username, new_text))


func chat_message_added(packet: ChatPacket):
	%ScrollContainer.visible = true
	var new_chat = %ChatMessagePrototype.duplicate()
	new_chat.text = "<%s> %s" % [packet.username, packet.message]
	new_chat.visible = true
	print("New chat: %s" % new_chat.text)
	%ChatVBox.add_child(new_chat)
	%ChatVBox.move_child(new_chat, 0)
	%ScrollContainer.custom_minimum_size.y = clamp(31 * %ChatVBox.get_children().size(), 0, 31 * 6)
