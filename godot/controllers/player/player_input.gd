class_name PlayerInput extends RefCounted

var input_packet: PlayerInputPacket = null
var prev_input_packet: PlayerInputPacket = null

func is_sprinting() -> bool:
	return input_packet.sprint

func is_sprint_just_pressed() -> bool:
	return input_packet.sprint and not prev_input_packet.sprint

func is_crouching() -> bool:
	return input_packet.crouch

func is_crouch_just_pressed() -> bool:
	return input_packet.crouch and not prev_input_packet.crouch

func is_jumping() -> bool:
	return input_packet.jump

func is_jump_just_pressed() -> bool:
	return input_packet.jump and not prev_input_packet.jump

func is_prone() -> bool:
	return input_packet.prone

func is_prone_just_pressed() -> bool:
	return input_packet.prone and not prev_input_packet.prone

func is_peeking_left() -> bool:
	return input_packet.peek_left_right < 0

func is_peeking_right() -> bool:
	return input_packet.peek_left_right > 0
