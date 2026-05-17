extends NetworkDriver

# Role discrimination — derived from which Rust sockets are open. In listen
# mode both halves coexist; queries against process-level role pick the right
# accessor and entity-level role lives on NetPredictor.is_authoritative_instance.
enum Mode { CLIENT_ONLY, DEDICATED_SERVER, LISTEN_SERVER }


# CLI overrides for per-instance lag/loss/jitter simulation.
#
# Usage: pass args after `--` when launching Godot, or set per-instance
# `arguments` in project_metadata.cfg's `run_instances_config` so each
# launched window gets its own profile.
#
# Profile (applied first, then individual overrides on top). Accepts either
# --net-profile=NAME or --net-preset=NAME (alias for backward compat):
#   --net-profile=off|broadband|wifi-light|wifi-congested|mobile-average|mobile-bufferbloat
#
# Fine-tune (units: ms for lag/jitter/reorder-ms/dup-ms; percent*100 for
# loss/dup/reorder, matching the inspector knobs' integer scale):
#   --lag-send=N --lag-recv=N
#   --jitter-send=N --jitter-recv=N
#   --loss-send=N --loss-recv=N
#   --dup-send=N --dup-recv=N --dup-ms=N
#   --reorder-send=N --reorder-recv=N --reorder-ms=N
#
# Example for asymmetric two-client testing (server at 0, c1 ≈25ms RTT,
# c2 ≈60ms RTT + jitter + 1% loss):
#   server:   (no args)
#   client 1: --lag-send=12 --lag-recv=13 --jitter-send=2 --jitter-recv=2
#   client 2: --lag-send=30 --lag-recv=30 --jitter-send=15 --jitter-recv=15
#             --loss-send=1 --loss-recv=1
#
# CLI parsing runs after inspector defaults are applied, so any unspecified
# knob keeps whatever the .tscn or a preset configured.

@export_range(0, 1000) var fake_ping_lag_send: int:
	set(value):
		print("Setting fake ping lag send to %d" % value)
		fake_ping_lag_send = value
		set_fake_ping_lag_send(value)

@export_range(0, 1000) var fake_ping_lag_recv: int:
	set(value):
		print("Setting fake ping lag recv to %d" % value)
		fake_ping_lag_recv = value
		set_fake_ping_lag_recv(value)

@export_range(0, 1000) var fake_loss_send: int:
	set(value):
		print("Setting fake loss send to %d" % value)
		fake_loss_send = value
		set_fake_loss_send(value)

@export_range(0, 1000) var fake_loss_recv: int:
	set(value):
		print("Setting fake loss recv to %d" % value)
		fake_loss_recv = value
		set_fake_loss_recv(value)

@export_range(0, 1000) var fake_jitter_send: int:
	set(value):
		print("Setting fake jitter send to %d" % value)
		fake_jitter_send = value
		set_fake_jitter_send(value)

@export_range(0, 1000) var fake_jitter_recv: int:
	set(value):
		print("Setting fake jitter recv to %d" % value)
		fake_jitter_recv = value
		set_fake_jitter_recv(value)

@export_range(0, 1000) var fake_dup_send: int:
	set(value):
		print("Setting fake dup send to %d" % value)
		fake_dup_send = value
		set_fake_dup_send(value)

@export_range(0, 1000) var fake_dup_recv: int:
	set(value):
		print("Setting fake dup recv to %d" % value)
		fake_dup_recv = value
		set_fake_dup_recv(value)

@export_range(0, 1000) var fake_dup_ms_max: int:
	set(value):
		print("Setting fake dup ms max to %d" % value)
		fake_dup_ms_max = value
		set_fake_dup_ms_max(value)

@export_range(0, 1000) var fake_reorder_send: int:
	set(value):
		print("Setting fake reorder send to %d" % value)
		fake_reorder_send = value
		set_fake_reorder_send(value)

@export_range(0, 1000) var fake_reorder_recv: int:
	set(value):
		print("Setting fake reorder recv to %d" % value)
		fake_reorder_recv = value
		set_fake_reorder_recv(value)

@export_range(0, 1000) var fake_reorder_ms: int:
	set(value):
		print("Setting fake reorder ms to %d" % value)
		fake_reorder_ms = value
		set_fake_reorder_ms(value)

enum LoadTestingPreset {
	OFF,
	BROADBAND,
	WIFI_LIGHT,
	WIFI_CONGESTED,
	MOBILE_AVERAGE,
	MOBILE_BUFFERBLOAT,
}

func _apply_load_testing_preset(preset: LoadTestingPreset) -> void:
	match preset:
		LoadTestingPreset.OFF:
			print("Applying load testing preset: OFF")
			fake_ping_lag_send = 0
			fake_ping_lag_recv = 0
			fake_loss_send = 0
			fake_loss_recv = 0
			fake_jitter_send = 0
			fake_jitter_recv = 0
			fake_dup_send = 0
			fake_dup_recv = 0
			fake_dup_ms_max = 0
			fake_reorder_send = 0
			fake_reorder_recv = 0
			fake_reorder_ms = 0
		LoadTestingPreset.BROADBAND:
			print("Applying load testing preset: BROADBAND")
			fake_ping_lag_send = 25
			fake_ping_lag_recv = 25
			fake_loss_send = 0
			fake_loss_recv = 0
			fake_jitter_send = 5
			fake_jitter_recv = 5
			fake_dup_send = 0
			fake_dup_recv = 0
			fake_dup_ms_max = 60
			fake_reorder_send = 0
			fake_reorder_recv = 0
			fake_reorder_ms = 30
		LoadTestingPreset.WIFI_LIGHT:
			print("Applying load testing preset: WIFI_LIGHT")
			fake_ping_lag_send = 40
			fake_ping_lag_recv = 40
			fake_loss_send = 0
			fake_loss_recv = 0
			fake_jitter_send = 12
			fake_jitter_recv = 12
			fake_dup_send = 0
			fake_dup_recv = 0
			fake_dup_ms_max = 0
			fake_reorder_send = 0
			fake_reorder_recv = 0
			fake_reorder_ms = 0
		LoadTestingPreset.WIFI_CONGESTED:
			print("Applying load testing preset: WIFI_CONGESTED")
			fake_ping_lag_send = 65
			fake_ping_lag_recv = 65
			fake_loss_send = 1
			fake_loss_recv = 1
			fake_jitter_send = 20
			fake_jitter_recv = 20
			fake_dup_send = 1
			fake_dup_recv = 1
			fake_dup_ms_max = 110
			fake_reorder_send = 2
			fake_reorder_recv = 2
			fake_reorder_ms = 70
		LoadTestingPreset.MOBILE_AVERAGE:
			print("Applying load testing preset: MOBILE_AVERAGE")
			fake_ping_lag_send = 100
			fake_ping_lag_recv = 100
			fake_loss_send = 2
			fake_loss_recv = 2
			fake_jitter_send = 30
			fake_jitter_recv = 30
			fake_dup_send = 1
			fake_dup_recv = 1
			fake_dup_ms_max = 150
			fake_reorder_send = 3
			fake_reorder_recv = 3
			fake_reorder_ms = 110
		LoadTestingPreset.MOBILE_BUFFERBLOAT:
			print("Applying load testing preset: MOBILE_BUFFERBLOAT")
			fake_ping_lag_send = 140
			fake_ping_lag_recv = 140
			fake_loss_send = 3
			fake_loss_recv = 3
			fake_jitter_send = 45
			fake_jitter_recv = 45
			fake_dup_send = 2
			fake_dup_recv = 2
			fake_dup_ms_max = 190
			fake_reorder_send = 5
			fake_reorder_recv = 5
			fake_reorder_ms = 150


@export var load_testing_off: bool:
	get: return false
	set(value):
		if !value:
			return
		_apply_load_testing_preset(LoadTestingPreset.OFF)
		set_deferred("load_testing_off", false)

@export var load_testing_broadband: bool:
	get: return false
	set(value):
		if !value:
			return
		_apply_load_testing_preset(LoadTestingPreset.BROADBAND)
		set_deferred("load_testing_broadband", false)

@export var load_testing_wifi_light: bool:
	get: return false
	set(value):
		if !value:
			return
		_apply_load_testing_preset(LoadTestingPreset.WIFI_LIGHT)
		set_deferred("load_testing_wifi_light", false)

@export var load_testing_wifi_congested: bool:
	get: return false
	set(value):
		if !value:
			return
		_apply_load_testing_preset(LoadTestingPreset.WIFI_CONGESTED)
		set_deferred("load_testing_wifi_congested", false)

@export var load_testing_mobile_average: bool:
	get: return false
	set(value):
		if !value:
			return
		_apply_load_testing_preset(LoadTestingPreset.MOBILE_AVERAGE)
		set_deferred("load_testing_mobile_average", false)

@export var load_testing_mobile_bufferbloat: bool:
	get: return false
	set(value):
		if !value:
			return
		_apply_load_testing_preset(LoadTestingPreset.MOBILE_BUFFERBLOAT)
		set_deferred("load_testing_mobile_bufferbloat", false)


var is_dedicated_server: bool:
	get: return "--server" in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server")

# True when launched as a single-process listen-server (CLI `--listen` or via
# the "Play Solo" menu button). Distinct from `is_dedicated_server` (headless,
# no client) and from pure client mode.
var is_listen_mode_requested: bool:
	get: return "--listen" in OS.get_cmdline_user_args()

# Race-safe boot handoff for listen mode. Main menu sets this before changing
# scene to the map; the map's root _ready (which runs AFTER spawners' _ready
# subscribe to NetReplication signals, since Godot calls _ready bottom-up)
# consumes the flag and triggers start_listen_mode. Eliminates the window where
# the loopback handshake fires on_peer_connect / IdAssignmentPacket before
# spawners are subscribed.
var pending_listen_mode: bool = false

# Role surface — use these instead of reading `is_server` directly. In listen
# mode both halves are true; the backward-compat `is_server` alias still
# returns true (server side is dominant), and entity-level role goes on
# NetPredictor.is_authoritative_instance.
var has_server_role: bool:
	get: return has_server()

var has_client_role: bool:
	get: return has_client()

var mode: Mode:
	get:
		if has_server_role and has_client_role:
			return Mode.LISTEN_SERVER
		elif has_server_role:
			return Mode.DEDICATED_SERVER
		else:
			return Mode.CLIENT_ONLY

# Test runner sets NETCODE_TEST_MODE=1 so headless startup doesn't bind the
# server port; tests instantiate their own minimal scaffolding.
var is_test_mode: bool:
	get: return OS.has_environment("NETCODE_TEST_MODE")


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if is_test_mode:
		return
	if is_dedicated_server:
		start_server_default()
		# Re-push the inspector defaults: starting the server resets some GNS
		# internals, so we have to set them again here.
		_reapply_fake_state()
	# CLI overrides run last so per-instance flags can override either the
	# scene defaults or a preset that was applied above.
	_apply_cli_lag_overrides()


# Listen-server boot: spins up both server + client sockets on 127.0.0.1 in
# the same process. Callers (Play Solo menu button, map scene _ready) invoke
# this once spawners are subscribed to NetReplication signals, so spawn
# packets that fire during the loopback handshake reach the right handlers.
func start_listen_mode(port: int = 45876) -> void:
	print("[NetSession] starting listen mode on 127.0.0.1:%d" % port)
	start_listen(port)
	_reapply_fake_state()


# Pushes every fake_* value through its property setter (which proxies into
# NetworkDriver). Used after start_server_default() resets GNS state and as a
# helper after preset / CLI overrides change multiple knobs.
func _reapply_fake_state() -> void:
	set_fake_ping_lag_send(fake_ping_lag_send)
	set_fake_ping_lag_recv(fake_ping_lag_recv)
	set_fake_loss_send(fake_loss_send)
	set_fake_loss_recv(fake_loss_recv)
	set_fake_jitter_send(fake_jitter_send)
	set_fake_jitter_recv(fake_jitter_recv)
	set_fake_dup_send(fake_dup_send)
	set_fake_dup_recv(fake_dup_recv)
	set_fake_dup_ms_max(fake_dup_ms_max)
	set_fake_reorder_send(fake_reorder_send)
	set_fake_reorder_recv(fake_reorder_recv)
	set_fake_reorder_ms(fake_reorder_ms)


# Parses --net-preset=NAME and individual --foo=N overrides from
# OS.get_cmdline_user_args(). Preset (if present) applies first as a baseline;
# remaining --foo=N flags override individual knobs on top. Unknown args are
# silently skipped so this is safe to mix with the existing `--server` flag.
const _PRESET_MAP := {
	"off": LoadTestingPreset.OFF,
	"broadband": LoadTestingPreset.BROADBAND,
	"wifi-light": LoadTestingPreset.WIFI_LIGHT,
	"wifi-congested": LoadTestingPreset.WIFI_CONGESTED,
	"mobile-average": LoadTestingPreset.MOBILE_AVERAGE,
	"mobile-bufferbloat": LoadTestingPreset.MOBILE_BUFFERBLOAT,
}

const _OVERRIDE_KEYS := {
	"lag-send": "fake_ping_lag_send",
	"lag-recv": "fake_ping_lag_recv",
	"loss-send": "fake_loss_send",
	"loss-recv": "fake_loss_recv",
	"jitter-send": "fake_jitter_send",
	"jitter-recv": "fake_jitter_recv",
	"dup-send": "fake_dup_send",
	"dup-recv": "fake_dup_recv",
	"dup-ms": "fake_dup_ms_max",
	"reorder-send": "fake_reorder_send",
	"reorder-recv": "fake_reorder_recv",
	"reorder-ms": "fake_reorder_ms",
}


func _apply_cli_lag_overrides() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.is_empty():
		return
	var applied: Array[String] = []
	var unknown: Array[String] = []
	# First pass: profile (so individual overrides can layer on top).
	for arg in args:
		var parsed := _parse_kv(arg)
		if parsed.is_empty():
			continue
		if parsed.key != "net-profile" and parsed.key != "net-preset":
			continue
		if _PRESET_MAP.has(parsed.value):
			_apply_load_testing_preset(_PRESET_MAP[parsed.value])
			applied.append("profile=%s" % parsed.value)
		else:
			push_warning("[NetSession] unknown --%s value '%s' (valid: %s)" % [
					parsed.key, parsed.value, ", ".join(_PRESET_MAP.keys())])
	# Second pass: individual overrides.
	for arg in args:
		var parsed := _parse_kv(arg)
		if parsed.is_empty():
			continue
		if parsed.key == "net-profile" or parsed.key == "net-preset" or parsed.key == "server":
			continue
		if not _OVERRIDE_KEYS.has(parsed.key):
			unknown.append(arg)
			continue
		var prop_name: String = _OVERRIDE_KEYS[parsed.key]
		set(prop_name, int(parsed.value))
		applied.append("%s=%d" % [parsed.key, int(parsed.value)])
	# Always log so a typo (no matches) is visible instead of silently ignored.
	if not applied.is_empty():
		print("[NetSession] CLI lag overrides applied: %s" % ", ".join(applied))
	if not unknown.is_empty():
		push_warning("[NetSession] CLI args unrecognized: %s" % ", ".join(unknown))


# "--key=value" -> {key: "key", value: "value"}. Returns {} for anything else.
static func _parse_kv(arg: String) -> Dictionary:
	if not arg.begins_with("--"):
		return {}
	var eq := arg.find("=")
	if eq < 0:
		return {}
	return {"key": arg.substr(2, eq - 2), "value": arg.substr(eq + 1)}


func _notification(what):
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		shutdown_all()
