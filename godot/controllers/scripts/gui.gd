extends Control

var open: bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	
func _input(event):
	if event.is_action_pressed("debug"):
		open = !open
		if open:
			mouse_filter = Control.MOUSE_FILTER_STOP
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			mouse_filter = Control.MOUSE_FILTER_PASS
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
