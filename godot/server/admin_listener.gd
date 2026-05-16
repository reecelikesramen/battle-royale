extends Node
#
# Server-only autoload. Opens a localhost-only TCP listener on port 45877.
# Accepts newline-delimited JSON commands from the co-located server-agent
# process; nothing on the public internet can reach this socket because the
# game-server-udp firewall only opens UDP/45876, and SSH is restricted.
#
# Commands:
#   {"cmd": "shutdown_for_update", "drain_s": 30, "target_version": "v1.0.3"}
#     - broadcasts ADMIN_TOPIC payload to all clients via NetReliableHub
#     - waits drain_s seconds for clients to disconnect
#     - quits the process; systemd respawns it with the latest version
#
# All admin topic ids are above ADMIN_TOPIC_BASE to avoid collision with any
# in-game reliable RPCs (which use small ints today).

const ADMIN_PORT := 45877
const ADMIN_TOPIC_BASE := 100_000
const ADMIN_TOPIC_RESTART := ADMIN_TOPIC_BASE + 0

var _server: TCPServer
var _clients: Array[StreamPeerTCP] = []

func _ready() -> void:
	if not NetSession.is_dedicated_server:
		queue_free()
		return
	_server = TCPServer.new()
	var err := _server.listen(ADMIN_PORT, "127.0.0.1")
	if err != OK:
		push_warning("admin_listener: failed to bind 127.0.0.1:%d (err=%d)" % [ADMIN_PORT, err])
		return
	set_process(true)
	print("admin_listener: listening on 127.0.0.1:", ADMIN_PORT)

func _process(_dt: float) -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		_clients.append(_server.take_connection())
	# Service each client.
	for c in _clients.duplicate():
		c.poll()
		if c.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_clients.erase(c)
			continue
		var available: int = c.get_available_bytes()
		if available <= 0:
			continue
		var buf: Array = c.get_data(available)
		if buf[0] != OK:
			continue
		var text := (buf[1] as PackedByteArray).get_string_from_utf8()
		for line in text.split("\n"):
			line = line.strip_edges()
			if line.is_empty():
				continue
			_handle_command(c, line)
		_clients.erase(c)

func _handle_command(c: StreamPeerTCP, line: String) -> void:
	var json := JSON.new()
	if json.parse(line) != OK or typeof(json.data) != TYPE_DICTIONARY:
		push_warning("admin_listener: bad command JSON: %s" % line)
		_reply(c, '{"ok":false,"error":"bad_json"}')
		return
	var cmd_dict: Dictionary = json.data
	var cmd: String = cmd_dict.get("cmd", "")
	match cmd:
		"shutdown_for_update":
			var drain_s: int = int(cmd_dict.get("drain_s", 30))
			var target: String = cmd_dict.get("target_version", "")
			print("admin_listener: shutdown_for_update target=%s drain=%ds" % [target, drain_s])
			_reply(c, '{"ok":true}')
			_announce_and_quit(drain_s, target)
		"ping":
			# Probed by server-agent's ready_state thread every few seconds.
			# `ready` flips true once the GNS server socket is bound — wake-fn
			# uses this (via the GCS state object the agent writes) to gate the
			# main-menu Wake button's "Server online" state on actual game
			# readiness, not just VM-status RUNNING.
			var version := ""
			if FileAccess.file_exists("res://VERSION.txt"):
				version = FileAccess.get_file_as_string("res://VERSION.txt").strip_edges()
			var resp := {
				"ok": true,
				"ready": NetSession.is_server and NetSession.is_connected,
				"version": version,
				"sha": Constants.get_build_sha(),
			}
			_reply(c, JSON.stringify(resp))
		_:
			_reply(c, '{"ok":false,"error":"unknown_cmd"}')

func _reply(c: StreamPeerTCP, text: String) -> void:
	c.put_data((text + "\n").to_utf8_buffer())

func _announce_and_quit(drain_s: int, target_version: String) -> void:
	# Tell every connected client to return to the menu. The payload is JSON
	# so the client side can show "Server restarting → v1.0.3" UX.
	var payload := JSON.stringify({"target_version": target_version, "drain_s": drain_s})
	NetReliableHub.broadcast(ADMIN_TOPIC_RESTART, payload.to_utf8_buffer())

	# Give clients drain_s seconds to gracefully disconnect, then quit.
	var t := Timer.new()
	t.wait_time = max(1.0, float(drain_s))
	t.one_shot = true
	t.timeout.connect(func():
		print("admin_listener: drain complete, quitting")
		get_tree().quit()
	)
	add_child(t)
	t.start()
