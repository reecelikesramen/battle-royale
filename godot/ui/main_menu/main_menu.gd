extends Control

const WAKE_PROBE_INTERVAL_S := 15.0
# Green-on-disabled style used when the server is up; the disabled-but-coloured
# look tells the player "you can't click this, but it's not broken — it's a
# confirmation that the server is online".
const SERVER_ONLINE_COLOR := Color(0.35, 0.75, 0.35)

var ip_regex = RegEx.new()
var num_regex = RegEx.new()
var _wake_probe_http: HTTPRequest
var _wake_action_http: HTTPRequest
var _wake_probe_timer: Timer
var _wake_in_progress := false

func _enter_tree() -> void:
	NetSession.on_connect_to_server.connect(_on_connect_to_server)
	NetClient.handle_disconnect_from_server.connect(set_disconnected_message)

func _exit_tree() -> void:
	NetSession.on_connect_to_server.disconnect(_on_connect_to_server)
	NetClient.handle_disconnect_from_server.disconnect(set_disconnected_message)

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if NetSession.is_dedicated_server:
		get_tree().call_deferred("change_scene_to_file", Constants.MAP_SCENE_PATH)
		return

	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	set_disconnected_message()

	if OS.get_name() == "macOS":
		get_window().content_scale_factor = 1.5

	# Accept either an IPv4 literal or a DNS hostname (RFC-952 / 1123 subset).
	# Cloud server lives at playtest.server.pywire.dev — bare IPv4 still works.
	if ip_regex.compile("^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$|^(?=.{1,253}$)(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(?:\\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$") != OK:
		push_error("IP/host regex failed to compile")
	if num_regex.compile("^\\d+$") != OK:
		push_error("Numeric regex failed to compile")

	_setup_wake_status_probe()

	_maybe_autoconnect()


# ───────────────────────────── Wake-server probe ────────────────────────────
# Polls the wake Cloud Function with GET (read-only, no side effects) to colour
# the WakeButton. POST is reserved for the actual wake action — only fires on
# button press, so background polls never accidentally start the VM.
func _setup_wake_status_probe() -> void:
	if Constants.WAKE_FUNCTION_URL.is_empty():
		%WakeButton.text = "Wake server (not configured)"
		return
	_wake_probe_http = HTTPRequest.new()
	add_child(_wake_probe_http)
	_wake_probe_http.request_completed.connect(_on_wake_probe_completed)

	_wake_probe_timer = Timer.new()
	_wake_probe_timer.wait_time = WAKE_PROBE_INTERVAL_S
	_wake_probe_timer.autostart = false
	_wake_probe_timer.timeout.connect(_wake_probe_request)
	add_child(_wake_probe_timer)

	_wake_probe_request()
	_wake_probe_timer.start()


func _wake_probe_request() -> void:
	if _wake_in_progress:
		return
	if _wake_probe_http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	var err := _wake_probe_http.request(
		Constants.WAKE_FUNCTION_URL,
		PackedStringArray(),
		HTTPClient.METHOD_GET,
		""
	)
	if err != OK:
		_set_wake_button_state("offline", "Wake server")


func _on_wake_probe_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code != 200:
		_set_wake_button_state("offline", "Wake server")
		return
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) != TYPE_DICTIONARY:
		_set_wake_button_state("offline", "Wake server")
		return
	if parsed.get("running", false):
		_set_wake_button_state("running", "Server online")
	else:
		_set_wake_button_state("offline", "Wake server")


# `state` ∈ {"offline", "starting", "running"}.
func _set_wake_button_state(state: String, text: String) -> void:
	%WakeButton.text = text
	match state:
		"running":
			# Disabled-but-coloured: user can't click (no work to do), but the
			# green tint communicates "server is up and connect will work".
			%WakeButton.disabled = true
			%WakeButton.modulate = SERVER_ONLINE_COLOR
		"starting":
			%WakeButton.disabled = true
			%WakeButton.modulate = Color(1.0, 0.85, 0.3)
		"offline":
			%WakeButton.disabled = _wake_in_progress
			%WakeButton.modulate = Color.WHITE


func _on_wake_button_pressed() -> void:
	if _wake_in_progress:
		return
	_wake_in_progress = true
	_set_wake_button_state("starting", "Waking server...")
	if _wake_action_http == null:
		_wake_action_http = HTTPRequest.new()
		add_child(_wake_action_http)
		_wake_action_http.request_completed.connect(_on_wake_action_completed)
	var err := _wake_action_http.request(
		Constants.WAKE_FUNCTION_URL,
		PackedStringArray(),
		HTTPClient.METHOD_POST,
		""
	)
	if err != OK:
		_wake_in_progress = false
		_set_wake_button_state("offline", "Wake server (request failed)")


func _on_wake_action_completed(_result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	_wake_in_progress = false
	if response_code != 200:
		_set_wake_button_state("offline", "Wake server (HTTP %d)" % response_code)
		return
	# VM boot + game-server warmup takes ~30-60s. Keep polling on the existing
	# 15s timer; when the probe sees `running: true` the button flips green.
	_set_wake_button_state("starting", "Server starting, ~45s...")


# Skip the menu and connect immediately. Honors any of:
#   -- --client [ip] [port] [username]     # legacy form used by run-debug.sh
#   -- --autojoin                          # localhost:45876, auto username
#   -- --autojoin <ip>                     # custom host, default port
#   -- --autojoin <ip:port>                # custom host + port shorthand
#   -- --autojoin <ip> <port> [username]   # explicit form
# Drop into Godot's editor "Main Run Args" (Project Settings → Editor → Run)
# or pass via the CLI: `godot --path godot/ -- --autojoin` to bypass the menu.
func _maybe_autoconnect() -> void:
	var args := OS.get_cmdline_user_args()
	var idx := args.find("--client")
	if idx == -1:
		idx = args.find("--autojoin")
	if idx == -1:
		return

	var ip := "127.0.0.1"
	var port := 45876
	var username := "AutoClient_%d" % (Time.get_ticks_msec() % 10000)
	if idx + 1 < args.size() and not args[idx + 1].begins_with("--"):
		var first: String = args[idx + 1]
		# Accept `ip:port` shorthand or bare ip
		if ":" in first:
			var parts := first.split(":")
			ip = parts[0]
			if parts.size() > 1:
				port = int(parts[1])
		else:
			ip = first
	if idx + 2 < args.size() and not args[idx + 2].begins_with("--") \
			and not (":" in args[idx + 1]):
		port = int(args[idx + 2])
	if idx + 3 < args.size() and not args[idx + 3].begins_with("--"):
		username = args[idx + 3]

	NetClient.username = username
	NetSession.start_client(ip, port)
	print("Auto-connecting to %s:%d as %s" % [ip, port, username])


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
	if NetSession.is_dedicated_server:
		push_error("Server tried to connect")
		return
		
	var ip_address = %IPAddressEdit.text if !%IPAddressEdit.text.is_empty() else Constants.DEFAULT_SERVER_HOST
	var port = int(%PortEdit.text) if !%PortEdit.text.is_empty() else Constants.DEFAULT_SERVER_PORT

	if !NetSession.is_connected:
		NetSession.start_client(ip_address, port)
		NetClient.username = %UsernameEdit.text
		print("Client started")
	else:
		push_error("Client tried to connect twice")


func _on_connect_to_server() -> void:
	get_tree().change_scene_to_file(Constants.MAP_SCENE_PATH)


func _on_full_screen_button_toggled(toggled_on: bool) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if toggled_on else DisplayServer.WINDOW_MODE_WINDOWED)


func set_disconnected_message() -> void:
	if !NetClient._disconnected_message.is_empty():
		%DisconnectedLabel.text = NetClient._disconnected_message
		NetClient._disconnected_message = ""
		%DisconnectedLabel.visible = true
	else:
		%DisconnectedLabel.visible = false
