extends Node

var _file: FileAccess
var enabled := false

func _ready() -> void:
	var path := "user://net_debug.log"
	_file = FileAccess.open(path, FileAccess.WRITE_READ)
	if _file:
		_file.seek_end() # append
		print("Logging to: %s" % path)


func log(msg: String) -> void:
	if !enabled:
		return
	if _file:
		_file.store_line("%s %s" % [Time.get_datetime_string_from_system(), msg])