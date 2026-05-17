class_name PlayerInputContext extends RefCounted

# Per-tick edge-detection wrapper over two consecutive PlayerInput frames.
# Phase 6: now typed against the schema-driven PlayerInput Resource — wire
# bytes are stamped/decoded by NetPredictor; game code only sees typed cmds.

var input_packet: PlayerInput = null
var prev_input_packet: PlayerInput = null

func is_sprinting() -> bool:
	return input_packet.sprint

# Sprint requires forward input. get_axis("move_forward","move_backward") yields
# negative when W is held, so forward == move_forward_backward < 0. Used by all
# sprint entry/maintain checks so sideways or backward sprinting isn't allowed.
func is_sprinting_forward() -> bool:
	return input_packet.sprint and input_packet.move_forward_backward < 0.0

func is_sprint_just_pressed() -> bool:
	return input_packet.sprint and not prev_input_packet.sprint

func is_walk_mode() -> bool:
	return input_packet.walk_mode

func is_crouching() -> bool:
	return input_packet.crouch

func is_crouch_just_pressed() -> bool:
	return input_packet.crouch and not prev_input_packet.crouch

func is_jump_just_pressed() -> bool:
	return input_packet.jump and not prev_input_packet.jump

func is_prone_just_pressed() -> bool:
	return input_packet.prone and not prev_input_packet.prone

func is_peeking_left() -> bool:
	return input_packet.peek_left_right < 0

func is_peeking_right() -> bool:
	return input_packet.peek_left_right > 0

func is_shoot_just_pressed() -> bool:
	return input_packet.shoot and not prev_input_packet.shoot
