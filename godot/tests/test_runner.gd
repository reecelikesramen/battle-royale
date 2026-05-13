extends Node

# Headless test runner. Loaded as the main scene when invoking
#   NETCODE_TEST_MODE=1 godot --headless --path godot res://tests/test_runner.tscn
# Autoloads still boot, but net_session.gd short-circuits in test mode so no
# port is bound. After all tests run, the runner exits with code 0 (all pass)
# or 1 (any fail).

const TEST_SCRIPTS := [
	"res://tests/test_net_schema.gd",
	"res://tests/test_net_predictor_reflection.gd",
	"res://tests/test_sequence_math.gd",
	"res://tests/test_jitter_buffer.gd",
	"res://tests/test_snapshot_roundtrip.gd",
	"res://tests/test_net_replication.gd",
	"res://tests/test_lag_compensation.gd",
	"res://tests/test_player_state_packet.gd",
]


func _ready() -> void:
	print("=== Netcode test runner ===")
	var total_pass: int = 0
	var total_fail: int = 0
	var all_failures: Array[String] = []

	for path in TEST_SCRIPTS:
		var script: Script = load(path)
		if script == null:
			print("[SKIP] %s — failed to load" % path)
			continue
		print("\n-- %s --" % path.get_file())
		var instance = script.new()
		var result: Dictionary = instance.run()
		total_pass += result["passed"]
		total_fail += result["failed"]
		for f in result["failures"]:
			all_failures.append("%s :: %s" % [path.get_file(), f])

	print("\n=== Summary ===")
	print("Passed: %d" % total_pass)
	print("Failed: %d" % total_fail)
	if total_fail > 0:
		print("\nFailures:")
		for f in all_failures:
			print("  %s" % f)
		get_tree().quit(1)
	else:
		get_tree().quit(0)
