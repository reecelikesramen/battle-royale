class_name TestBase extends RefCounted

# Tiny assertion library so individual test scripts stay declarative. Each test
# script extends TestBase and exposes `test_*` methods; the runner discovers
# them via get_method_list().

var _failures: Array[String] = []
var _current_test: String = ""

func run() -> Dictionary:
	var passed: int = 0
	var failed: int = 0
	for m in get_method_list():
		var name: String = m.name
		if not name.begins_with("test_"):
			continue
		_current_test = name
		var before := _failures.size()
		call(name)
		if _failures.size() == before:
			passed += 1
			print("  [PASS] %s" % name)
		else:
			failed += 1
			print("  [FAIL] %s" % name)
	return {"passed": passed, "failed": failed, "failures": _failures}


func assert_eq(actual, expected, msg: String = "") -> void:
	if not _values_equal(actual, expected):
		_fail("expected %s, got %s%s" % [expected, actual, _msg(msg)])


func assert_neq(actual, expected, msg: String = "") -> void:
	if _values_equal(actual, expected):
		_fail("expected != %s, got %s%s" % [expected, actual, _msg(msg)])


func assert_true(cond: bool, msg: String = "") -> void:
	if not cond:
		_fail("expected true%s" % _msg(msg))


func assert_false(cond: bool, msg: String = "") -> void:
	if cond:
		_fail("expected false%s" % _msg(msg))


func assert_null(value, msg: String = "") -> void:
	if value != null:
		_fail("expected null, got %s%s" % [value, _msg(msg)])


func assert_not_null(value, msg: String = "") -> void:
	if value == null:
		_fail("expected non-null%s" % _msg(msg))


func assert_approx(actual: float, expected: float, tolerance: float = 0.0001, msg: String = "") -> void:
	if absf(actual - expected) > tolerance:
		_fail("expected ~= %f (+/- %f), got %f%s" % [expected, tolerance, actual, _msg(msg)])


func assert_vec3_approx(actual: Vector3, expected: Vector3, tolerance: float = 0.0001, msg: String = "") -> void:
	if (actual - expected).length() > tolerance:
		_fail("expected ~= %s (+/- %f), got %s%s" % [expected, tolerance, actual, _msg(msg)])


func _values_equal(a, b) -> bool:
	# typed_array equality in GDScript is reference-based for many cases;
	# accept either == or stringified equality as a pragmatic comparison.
	if typeof(a) != typeof(b):
		return false
	if a is PackedByteArray and b is PackedByteArray:
		if a.size() != b.size():
			return false
		for i in a.size():
			if a[i] != b[i]:
				return false
		return true
	return a == b


func _fail(reason: String) -> void:
	var formatted := "    %s: %s" % [_current_test, reason]
	_failures.append(formatted)
	print(formatted)


func _msg(extra: String) -> String:
	if extra.is_empty():
		return ""
	return " (%s)" % extra
