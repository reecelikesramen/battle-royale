extends Control

var ip_regex = RegEx.new()
var num_regex = RegEx.new()

func _enter_tree() -> void:
	NetworkTransport.on_connect_to_server.connect(_on_connect_to_server)
	NetworkClient.handle_disconnect_from_server.connect(set_disconnected_message)

func _exit_tree() -> void:
	NetworkTransport.on_connect_to_server.disconnect(_on_connect_to_server)
	NetworkClient.handle_disconnect_from_server.disconnect(set_disconnected_message)

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if NetworkTransport.is_dedicated_server:
		get_tree().call_deferred("change_scene_to_file", Constants.MAP_SCENE_PATH)
		return
	
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	set_disconnected_message()
	
	if OS.get_name() == "macOS":
		get_window().content_scale_factor = 1.5
	
	if ip_regex.compile("^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$") != OK:
		push_error("IP regex failed to compile")
	if num_regex.compile("^\\d+$") != OK:
		push_error("Numeric regex failed to compile")


func _on_quit_button_pressed() -> void:
	get_tree().quit()


func _on_ip_address_text_changed(new_text: String) -> void:
	connection_changed(new_text, %PortEdit.text)


func _on_port_text_changed(new_text: String) -> void:
	connection_changed(%IPAddressEdit.text, new_text)


func _on_username_edit_text_changed(_new_text: String) -> void:
	connection_changed(%IPAddressEdit.text, %PortEdit.text)


func connection_changed(ip_address: String, port: String) -> void:
	if !ip_address.is_empty() and !ip_regex.search(ip_address):
		push_error("Invalid IP address: '`%s'" % ip_address)
		%ConnectButton.disabled = true
		return
		
	if !port.is_empty() and !num_regex.search(port):
		push_error("Invalid port: '%s'" % port)
		%ConnectButton.disabled = true
		return

	var username = %UsernameEdit.text
	if username.is_empty():
		%ConnectButton.disabled = true
		return

	%ConnectButton.disabled = false


func _on_connect_button_pressed() -> void:
	if NetworkTransport.is_dedicated_server:
		push_error("Server tried to connect")
		return
		
	var ip_address = %IPAddressEdit.text if !%IPAddressEdit.text.is_empty() else "127.0.0.1"
	var port = int(%PortEdit.text) if !%PortEdit.text.is_empty() else 45876

	if !NetworkTransport.is_connected:
		NetworkTransport.start_client(ip_address, port)
		NetworkClient.username = %UsernameEdit.text
		print("Client started")
	else:
		push_error("Client tried to connect twice")


func _on_connect_to_server() -> void:
	get_tree().change_scene_to_file(Constants.MAP_SCENE_PATH)


func _on_full_screen_button_toggled(toggled_on: bool) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if toggled_on else DisplayServer.WINDOW_MODE_WINDOWED)


func set_disconnected_message() -> void:
	if !NetworkClient._disconnected_message.is_empty():
		%DisconnectedLabel.text = NetworkClient._disconnected_message
		NetworkClient._disconnected_message = ""
		%DisconnectedLabel.visible = true
	else:
		%DisconnectedLabel.visible = false
