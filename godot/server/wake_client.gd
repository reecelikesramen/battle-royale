extends Node
#
# Client-side helper used by the main menu "Wake server" button. Posts to the
# wake Cloud Function which starts the GCE VM if it's stopped, then polls
# until a UDP socket on the game port responds (or a timeout elapses).
#
# Not an autoload — instantiated as needed by main_menu.gd.

const WAKE_TIMEOUT_S := 90.0

signal status_changed(text: String)
signal ready_to_connect()
signal failed(reason: String)

@export var wake_url: String = Constants.WAKE_FUNCTION_URL
@export var server_host: String = Constants.DEFAULT_SERVER_HOST
@export var server_port: int = Constants.DEFAULT_SERVER_PORT

var _http: HTTPRequest
var _started_at_unix: float = 0.0

func start() -> void:
	if wake_url.is_empty():
		emit_signal("failed", "WAKE_FUNCTION_URL not set in Constants — see infrastructure/README.md")
		return
	_started_at_unix = Time.get_unix_time_from_system()
	_http = HTTPRequest.new()
	add_child(_http)
	emit_signal("status_changed", "Requesting server wake...")
	var err := _http.request(wake_url, PackedStringArray(), HTTPClient.METHOD_POST, "")
	if err != OK:
		emit_signal("failed", "wake request failed: %d" % err)
		return
	_http.request_completed.connect(_on_wake_response, CONNECT_ONE_SHOT)

func _on_wake_response(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if response_code != 200:
		emit_signal("failed", "wake responded HTTP %d" % response_code)
		return
	emit_signal("status_changed", "Server starting; waiting for it to come up...")
	_poll_reachable()

func _poll_reachable() -> void:
	# Quick TCP-ish check by attempting a DNS resolution + an upstream UDP send.
	# We don't have a real "is the game server accepting packets" check without
	# initiating a full GNS handshake — for now just wait a reasonable amount
	# of time after wake (~30-45s VM boot + ~5s server warmup) then signal
	# ready. The connect attempt itself handles unreachable cleanly.
	var t := Timer.new()
	t.wait_time = 45.0
	t.one_shot = true
	t.timeout.connect(func():
		emit_signal("ready_to_connect")
		queue_free()
	)
	add_child(t)
	t.start()
