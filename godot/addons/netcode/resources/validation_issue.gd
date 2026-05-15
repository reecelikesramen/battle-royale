@tool
class_name ValidationIssue extends RefCounted

# Structured issue emitted by NetSchema.validate(). Three severities so callers
# can filter: editor-time NetPredictor warnings show >= WARNING, startup
# NetReplication push_error gates on ERROR.
#
# `location` is a human-readable path into the schema (e.g.
# "corrections[horizontal].fields[0]") for jump-to in future inspector UI.
# `category` is a stable StringName so tests + decorators key off it without
# matching message text.

enum Severity { ERROR, WARNING, INFO }

var severity: Severity = Severity.WARNING
var category: StringName = &""
var message: String = ""
var location: String = ""


static func make(sev: Severity, cat: StringName, loc: String, msg: String) -> ValidationIssue:
	var i := ValidationIssue.new()
	i.severity = sev
	i.category = cat
	i.location = loc
	i.message = msg
	return i


func severity_name() -> String:
	match severity:
		Severity.ERROR: return "ERROR"
		Severity.WARNING: return "WARNING"
		Severity.INFO: return "INFO"
	return "?"


func to_string_line() -> String:
	if location == "":
		return "[%s] %s" % [severity_name(), message]
	return "[%s] %s: %s" % [severity_name(), location, message]
