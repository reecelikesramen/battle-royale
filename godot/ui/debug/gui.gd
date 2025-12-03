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


func _on_fps_controller_reconcile_network_debug(delta_pos: Vector3, delta_vel: Vector3, unacked_inputs: SequenceRingBuffer) -> void:
	var color_pos := Color()
	color_pos.r = delta_pos.x
	color_pos.g = delta_pos.z
	color_pos.b = delta_pos.y
	$NetworkDebug/DeltaPos.color = color_pos

	var color_vel := Color()
	color_vel.r = delta_vel.x
	color_vel.g = delta_vel.z
	color_vel.b = delta_vel.y
	$NetworkDebug/DeltaVel.color = color_vel

	$NetworkDebug/InputBuffer.text = "Inputs Size: %d\nInputs Oldest: %d\nInputs Newest: %d\nInputs Buffer Delay: %d" % [unacked_inputs.size(), unacked_inputs.oldest_sequence_id(), unacked_inputs.newest_sequence_id(), unacked_inputs.buffer_delay_us()]
