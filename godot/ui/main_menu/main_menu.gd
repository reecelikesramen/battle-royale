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
# Tracks the most recent state pushed into _set_wake_button_state so the press
# handler can decide whether to wake the VM or connect to the live server.
var _wake_state := "offline"
# Debounce: wake-fn fetches gs://.../server-state.json with a 5s timeout on
# each GET. Cloud Run cold-starts + transient GCS hiccups can briefly return
# ready=false even when the server is healthy. If we just saw "running", give
# it one more probe (~5s sooner than the 15s cadence) before downgrading to
# "starting" — keeps the button from flickering green→yellow→green on a
# benign network blip.
var _wake_starting_strikes := 0
const WAKE_STARTING_STRIKES_NEEDED := 2
const WAKE_FAST_RETRY_S := 5.0

func _enter_tree() -> void:
	# Listen for id-assignment, not raw GNS connect. on_connect_to_server fires
	# the moment the GNS handshake finishes (before our app-level version
	# handshake), so jumping to the map there meant a build-mismatched client
	# would load the map + flop into spectator before the server kicked it.
	# handle_local_id_assignment only fires after the server admits us
	# (post-ServerHello/ClientHello), so the scene transition is gated on a
	# real "you're in the game" signal.
	NetClient.handle_local_id_assignment.connect(_on_local_id_assigned)
	NetClient.handle_disconnect_from_server.connect(set_disconnected_message)

func _exit_tree() -> void:
	NetClient.handle_local_id_assignment.disconnect(_on_local_id_assigned)
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

	_install_play_solo_button()
	_setup_wake_status_probe()
	_maybe_autoconnect()


# Adds a "Play Solo" button between Connect and FullScreen in the existing
# VBoxContainer. Done programmatically so the menu scene doesn't need editing.
func _install_play_solo_button() -> void:
	var vbox: Node = %ConnectButton.get_parent()
	var play_solo := Button.new()
	play_solo.text = "Play Solo"
	play_solo.pressed.connect(_on_play_solo_pressed)
	vbox.add_child(play_solo)
	vbox.move_child(play_solo, %ConnectButton.get_index() + 1)


func _on_play_solo_pressed() -> void:
	if NetSession.is_dedicated_server:
		push_error("Dedicated server cannot enter listen mode")
		return
	if NetSession.is_connected:
		push_error("Already connected; disconnect first")
		return
	NetClient.username = "Host_%d" % (Time.get_ticks_msec() % 10000)
	# Set flag + change scene. The map root _ready calls start_listen_mode
	# AFTER its child spawners have subscribed to NetReplication signals, so
	# the loopback handshake's on_peer_connect / id-assignment reach
	# subscribers instead of racing past them.
	NetSession.pending_listen_mode = true
	get_tree().change_scene_to_file(Constants.MAP_SCENE_PATH)


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
	# wake-fn returns `running: true` only when vm_status==RUNNING AND the
	# server-agent ready-state heartbeat reports the game has bound UDP.
	# vm_status alone (STAGING/PROVISIONING/RUNNING-without-ready) means the
	# VM is up but the game isn't yet — show "starting" so the user doesn't
	# flap from green-to-red between probes.
	if parsed.get("running", false):
		_wake_starting_strikes = 0
		_set_wake_button_state("running", "Server online")
		return
	var vm_status: String = parsed.get("vm_status", "")
	if vm_status in ["STAGING", "PROVISIONING", "RUNNING", "REPAIRING"]:
		# Debounce flap: don't downgrade running → starting on a single bad
		# probe. Schedule a faster retry so the user only sees a brief beat,
		# not a 15s yellow window for a one-off GCS hiccup.
		if _wake_state == "running":
			_wake_starting_strikes += 1
			if _wake_starting_strikes < WAKE_STARTING_STRIKES_NEEDED:
				_schedule_fast_retry()
				return
		_set_wake_button_state("starting", "Server starting...")
	else:
		_wake_starting_strikes = 0
		_set_wake_button_state("offline", "Wake server")


func _schedule_fast_retry() -> void:
	if _wake_probe_timer == null:
		return
	if _wake_probe_timer.time_left > WAKE_FAST_RETRY_S:
		_wake_probe_timer.start(WAKE_FAST_RETRY_S)


# `state` ∈ {"offline", "starting", "running"}.
func _set_wake_button_state(state: String, text: String) -> void:
	_wake_state = state
	%WakeButton.text = text
	match state:
		"running":
			# Click becomes a one-tap join to the playtest server — no need to
			# scroll up and retype the host into the IP field. _on_wake_button_pressed
			# branches on _wake_state to decide between wake-POST and connect.
			%WakeButton.disabled = false
			%WakeButton.modulate = SERVER_ONLINE_COLOR
		"starting":
			%WakeButton.disabled = true
			%WakeButton.modulate = Color(1.0, 0.85, 0.3)
		"offline":
			%WakeButton.disabled = _wake_in_progress
			%WakeButton.modulate = Color.WHITE


func _on_wake_button_pressed() -> void:
	# Green / "running" state: the VM is up AND the game has bound UDP, so the
	# button doubles as a "join" shortcut. Skips needing to type the playtest
	# host into the IP field.
	if _wake_state == "running":
		_connect_to_playtest_server()
		return
	if _wake_in_progress:
		return
	_wake_in_progress = true
	_set_wake_button_state("starting", "Waking server...")
	if _wake_action_http == null:
		_wake_action_http = HTTPRequest.new()
		add_child(_wake_action_http)
		_wake_action_http.request_completed.connect(_on_wake_action_completed)
	# Empty-body POST: Godot's HTTPRequest doesn't emit Content-Length by
	# default, and Google's HTTP frontend (Cloud Run / load balancer) rejects
	# such POSTs with 411 Length Required. Set it explicitly.
	var err := _wake_action_http.request(
		Constants.WAKE_FUNCTION_URL,
		PackedStringArray(["Content-Length: 0"]),
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
	# --listen is a CLI shortcut for headless / autotest entry into solo
	# listen-server mode. Equivalent to pressing the Play Solo button.
	if args.find("--listen") != -1:
		NetClient.username = "Host_%d" % (Time.get_ticks_msec() % 10000)
		NetSession.pending_listen_mode = true
		get_tree().call_deferred("change_scene_to_file", Constants.MAP_SCENE_PATH)
		print("Auto-starting listen mode")
		return
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


# Shortcut used by the WakeButton when it's green/"running". Same connect path
# as _on_connect_button_pressed but always targets the playtest host —
# the typed-in IP/port fields are ignored.
func _connect_to_playtest_server() -> void:
	if NetSession.is_dedicated_server:
		push_error("Server tried to connect")
		return
	if NetSession.is_connected:
		push_error("Client tried to connect twice")
		return
	var username: String = %UsernameEdit.text
	if username.is_empty():
		push_error("Username required before joining")
		return
	NetSession.start_client(Constants.DEFAULT_SERVER_HOST, Constants.DEFAULT_SERVER_PORT)
	NetClient.username = username
	print("Joining playtest server as %s" % username)


func _on_local_id_assigned(_id: int) -> void:
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
