extends CharacterBody3D

@onready var camera: Camera3D = $CameraController/Camera3D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var crouch_shapecast: ShapeCast3D = $CrouchShapeCast3D

@export var SPEED = 5.0
@export var JUMP_VELOCITY = 4.5
@export var TILT_LOWER_LIMIT = deg_to_rad(-90.0)
@export var TILT_UPPER_LIMIT = deg_to_rad(90.0)
@export var MOUSE_SENSITIVITY = 0.5
@export var TOGGLE_CROUCH: bool = true
@export_range(5, 10, 0.1) var CROUCH_SPEED = 7.0

const ACTION_REPEAT_WINDOW_MS := 10000

class FrameInput:
	var timestamp_ms: int = 0
	var move: Vector2 = Vector2.ZERO
	var mouse: Vector2 = Vector2.ZERO
	var jump_pressed: bool = false
	var crouch_pressed: bool = false
	var crouch_released: bool = false
	var sequence_id: int = -1
	var crouch_held: bool = false
	var was_on_floor: bool = false
	var look_abs: Vector2 = Vector2.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var delta: float = 0.0

class ChatEvent:
	var timestamp_ms: int = 0
	var username: String = ""
	var message: String = ""

var is_authority: bool:
	get: return !LowLevelNetworkHandler.is_server && _owner_id == ClientNetworkGlobals.id

var _owner_id: int
var _mouse_input: bool = false
var _mouse_rotation: Vector3 = Vector3()
var _rotation_input: float
var _tilt_input: float
var _player_rotation: Vector3
var _camera_rotation: Vector3
var _is_crouching: bool = false
var _do_uncrouch: bool = false
var _action_repeat_active: bool = false
var _recorded_frames: Array[FrameInput] = []
var _play_start_ms: int = 0
var _playback_duration_ms: int = 0
var _recorded_chat_events: Array[ChatEvent] = []
var _recording_start_ms: int = 0
var _current_loop_time: int = 0
var _last_playback_loop_time: int = -1
var _server_input_queue: Array[FrameInput] = []
var _server_last_frame: FrameInput
var _server_last_received_timestamp_ms: int = -1
var _telemetry_last_report_ms: int = 0
var _pending_state_timestamp_ms: int = 0
var _pending_state_position: Vector3 = Vector3.ZERO
var _pending_state_velocity: Vector3 = Vector3.ZERO
var _pending_state_camera_rotation: float = 0.0
var _pending_state_player_rotation: float = 0.0
var _pending_state_crouching: bool = false
var _target_crouch_state: bool = false
var _desired_crouch_state: bool = false
var _crouch_trust_expires_ms: int = 0
var _has_pending_state: bool = false
var _input_sequence: int = -1
var _last_server_ack_sequence: int = -1
var _state_buffer: Array[Dictionary] = []
var _state_buffer_delay_ms: int = 0
var _server_last_sequence_id: int = -1

const RECONCILE_SNAP_THRESHOLD := 1.5
const RECONCILE_BLEND_ALPHA := 0.3
const SEQUENCE_MODULO := 65536
const SEQUENCE_HALF_RANGE := SEQUENCE_MODULO / 2
const STATE_BUFFER_MIN_DELAY_MS := 33
const STATE_BUFFER_MAX_SIZE := 8
const STATE_BUFFER_MAX_DELAY_MS := 150
const SERVER_MAX_FRAMES_PER_TICK := 4
const SERVER_INPUT_QUEUE_MAX := 64
const SERVER_LOOK_DELTA_LIMIT := TAU * 1.5
const TELEMETRY_INTERVAL_MS := 2000
const CROUCH_TRUST_WINDOW_MS := 150

func _input(event):
	if !is_authority:
		return
	if _action_repeat_active:
		return

	if event.is_action_pressed("exit") and Engine.is_editor_hint():
		get_tree().quit()
	if event.is_action_pressed("crouch") and TOGGLE_CROUCH:
		toggle_crouch()
	if event.is_action_pressed("crouch") and !TOGGLE_CROUCH:
		crouch(true)
	elif event.is_action_released("crouch") and !TOGGLE_CROUCH:
		crouch(false)


func _enter_tree() -> void:
	ServerNetworkGlobals.handle_player_input.connect(server_handle_player_input)
	ClientNetworkGlobals.handle_player_state.connect(client_handle_player_state)


func _exit_tree() -> void:
	ServerNetworkGlobals.handle_player_input.disconnect(server_handle_player_input)
	ClientNetworkGlobals.handle_player_state.disconnect(client_handle_player_state)


func _ready():
	print("Player #%d spawned, named %s!" % [_owner_id, name])
	_target_crouch_state = _is_crouching
	_desired_crouch_state = _is_crouching
	_crouch_trust_expires_ms = 0
	if !LowLevelNetworkHandler.is_dedicated_server:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if is_authority:
		add_to_group("local_player")
		camera.make_current()
		_spawn_randomly_in_world()
	else:
		call_deferred("remove_child", %GUI)
		$CameraController/Camera3D.call_deferred("remove_child", $CameraController/Camera3D/ReflectionProbe)


func _spawn_randomly_in_world() -> void:
	randomize()
	var space_state := get_world_3d().direct_space_state
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = 1.4
	var half_height := (capsule.height * 0.5) + capsule.radius
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = capsule
	params.collide_with_areas = false
	params.collide_with_bodies = true
	var attempts := 24
	while attempts > 0:
		attempts -= 1
		var x := randf_range(-10.0, 10.0)
		var z := randf_range(-10.0, 10.0)
		var ray_from := Vector3(x, 50.0, z)
		var ray_to := Vector3(x, -50.0, z)
		var ray_params := PhysicsRayQueryParameters3D.create(ray_from, ray_to)
		ray_params.collide_with_areas = false
		var hit := space_state.intersect_ray(ray_params)
		if hit.is_empty():
			continue
		var y: float = float(hit.position.y) + half_height
		var candidate_transform := Transform3D(Basis.IDENTITY, Vector3(x, y, z))
		params.transform = candidate_transform
		var collisions := space_state.intersect_shape(params, 1)
		if collisions.is_empty():
			global_transform.origin = candidate_transform.origin
			return


func _unhandled_input(event):
	if !is_authority:
		return
	if _action_repeat_active:
		return

	_mouse_input = event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
	if _mouse_input:
		_rotation_input += -event.relative.x * MOUSE_SENSITIVITY
		_tilt_input += -event.relative.y * MOUSE_SENSITIVITY


func _update_camera(delta: float) -> void:
	_mouse_rotation.x += _tilt_input * delta
	_mouse_rotation.x = clamp(_mouse_rotation.x, TILT_LOWER_LIMIT, TILT_UPPER_LIMIT)
	_mouse_rotation.y += _rotation_input * delta
	
	_player_rotation.y = _mouse_rotation.y
	_camera_rotation.x = _mouse_rotation.x
	
	camera.transform.basis = Basis.from_euler(_camera_rotation)
	camera.rotation.z = 0
	
	global_transform.basis = Basis.from_euler(_player_rotation)
	
	_rotation_input = 0.0
	_tilt_input = 0.0


func _physics_process(delta: float) -> void:
	if LowLevelNetworkHandler.is_server:
		_server_physics_step(delta)
		return

	if !is_authority:
		_apply_authoritative_transform(delta)
		return

	if !is_on_floor():
		velocity += get_gravity() * delta

	var now_ms := Time.get_ticks_msec()
	var live_frame := _make_frame_input(now_ms)
	live_frame.delta = delta
	var frame_to_apply := live_frame
	var apply_crouch_actions := false

	if _action_repeat_active:
		var playback_frame := _get_playback_frame(now_ms)
		if playback_frame:
			frame_to_apply = playback_frame
			apply_crouch_actions = true
			_replay_chat_events(_current_loop_time)
		else:
			_action_repeat_active = false
			_last_playback_loop_time = -1
			_current_loop_time = 0

	_apply_frame(frame_to_apply, delta, apply_crouch_actions)
	live_frame.look_abs = Vector2(_camera_rotation.x, _player_rotation.y)
	live_frame.velocity = velocity

	if !_action_repeat_active:
		_send_player_input(now_ms, live_frame)
		_record_frame(live_frame)

	move_and_slide()
	_apply_authoritative_transform(delta)
	_emit_telemetry(now_ms)


func _server_physics_step(delta: float) -> void:
	var now_ms := Time.get_ticks_msec()
	var frames: Array[FrameInput] = []
	var processed := 0

	while processed < SERVER_MAX_FRAMES_PER_TICK:
		var frame := _consume_server_frame(now_ms, false)
		if frame == null:
			break
		frames.append(frame)
		processed += 1

	if frames.is_empty():
		var repeat_frame := _consume_server_frame(now_ms, true)
		if repeat_frame != null:
			frames.append(repeat_frame)

	for frame in frames:
		var frame_delta := frame.delta
		if frame_delta <= 0.0:
			frame_delta = delta
		if !is_on_floor():
			velocity += get_gravity() * frame_delta
		_apply_frame(frame, frame_delta, true)
		move_and_slide()

	_broadcast_server_state(now_ms)
	_emit_telemetry(now_ms)


func _consume_server_frame(now_ms: int, allow_repeat: bool) -> FrameInput:
	if !_server_input_queue.is_empty():
		var frame := _server_input_queue[0]
		_server_input_queue.remove_at(0)
		_server_last_frame = frame
		_server_last_sequence_id = frame.sequence_id
		return frame

	if allow_repeat and _server_last_frame != null:
		var repeat_frame := FrameInput.new()
		repeat_frame.timestamp_ms = now_ms
		repeat_frame.move = _server_last_frame.move
		repeat_frame.mouse = Vector2.ZERO
		repeat_frame.jump_pressed = false
		repeat_frame.crouch_pressed = false
		repeat_frame.crouch_released = false
		repeat_frame.crouch_held = _server_last_frame.crouch_held
		repeat_frame.was_on_floor = false
		repeat_frame.look_abs = _server_last_frame.look_abs
		repeat_frame.velocity = _server_last_frame.velocity
		repeat_frame.sequence_id = _server_last_frame.sequence_id
		repeat_frame.delta = float(max(1, now_ms - _server_last_frame.timestamp_ms)) / 1000.0
		_server_last_sequence_id = repeat_frame.sequence_id
		_server_last_frame = repeat_frame
		return repeat_frame

	return null


func _broadcast_server_state(timestamp_ms: int) -> void:
	if !LowLevelNetworkHandler.is_server:
		return
	if _server_last_sequence_id < 0:
		return

	var state_packet := PlayerStatePacket.new()
	state_packet.id = _owner_id
	state_packet.last_input_sequence_id = _server_last_sequence_id % SEQUENCE_MODULO
	state_packet.timestamp_ms = timestamp_ms
	state_packet.position = global_position
	state_packet.rotation = Vector2(_camera_rotation.x, _player_rotation.y)
	state_packet.is_crouching = _is_crouching
	state_packet.velocity = velocity
	LowLevelNetworkHandler.broadcast_packet(state_packet.to_payload())



func _apply_authoritative_transform(delta: float) -> void:
	if is_authority:
		_apply_local_reconciliation()
	else:
		_apply_remote_interpolation(delta)


func _apply_local_reconciliation() -> void:
	if !_has_pending_state:
		return

	var previous_position := global_position
	var previous_velocity := velocity
	var previous_mouse_rotation := _mouse_rotation
	var previous_player_rotation := _player_rotation

	var position_error := _pending_state_position - global_position
	var snap_to_server := position_error.length() > RECONCILE_SNAP_THRESHOLD

	global_position = _pending_state_position
	velocity = _pending_state_velocity
	_mouse_rotation.x = _pending_state_camera_rotation
	_mouse_rotation.y = _pending_state_player_rotation
	_camera_rotation.x = _mouse_rotation.x
	_player_rotation.y = _mouse_rotation.y
	camera.transform.basis = Basis.from_euler(Vector3(_camera_rotation.x, 0, 0))
	camera.rotation.z = 0
	global_transform.basis = Basis.from_euler(Vector3(0, _player_rotation.y, 0))

	var now_ms := Time.get_ticks_msec()
	var server_crouch := _pending_state_crouching
	if server_crouch != _desired_crouch_state and now_ms > _crouch_trust_expires_ms:
		_desired_crouch_state = server_crouch
		_crouch_trust_expires_ms = now_ms
		_apply_crouch_state(server_crouch, true)
	else:
		if _target_crouch_state != _desired_crouch_state:
			_apply_crouch_state(_desired_crouch_state)

	var reconciled_position := global_position
	var reconciled_velocity := velocity
	var reconciled_mouse_rotation := _mouse_rotation
	var reconciled_player_rotation := _player_rotation

	for frame in _recorded_frames:
		var frame_delta := frame.delta
		if frame_delta <= 0.0:
			frame_delta = 1.0 / Engine.get_physics_ticks_per_second()
		if frame.was_on_floor:
			velocity.y = 0.0
		else:
			velocity += get_gravity() * frame_delta
		_apply_frame(frame, frame_delta, false)
		global_position += velocity * frame_delta
		reconciled_position = global_position
		reconciled_velocity = velocity
		reconciled_mouse_rotation = _mouse_rotation
		reconciled_player_rotation = _player_rotation

	var blend_alpha := 1.0 if snap_to_server else RECONCILE_BLEND_ALPHA

	global_position = previous_position.lerp(reconciled_position, blend_alpha)
	velocity = previous_velocity.lerp(reconciled_velocity, blend_alpha)
	_mouse_rotation.x = lerp_angle(previous_mouse_rotation.x, reconciled_mouse_rotation.x, blend_alpha)
	_mouse_rotation.y = lerp_angle(previous_mouse_rotation.y, reconciled_mouse_rotation.y, blend_alpha)
	_camera_rotation.x = _mouse_rotation.x
	_player_rotation.y = lerp_angle(previous_player_rotation.y, reconciled_player_rotation.y, blend_alpha)
	camera.transform.basis = Basis.from_euler(Vector3(_camera_rotation.x, 0, 0))
	camera.rotation.z = 0
	global_transform.basis = Basis.from_euler(Vector3(0, _player_rotation.y, 0))

	_rotation_input = 0.0
	_tilt_input = 0.0
	_has_pending_state = false


func _apply_remote_interpolation(_delta: float) -> void:
	if _state_buffer.is_empty():
		return
	if _state_buffer.size() == 1:
		_apply_remote_snapshot(_state_buffer[0])
		return

	var delay_ms: int = clamp(_state_buffer_delay_ms, STATE_BUFFER_MIN_DELAY_MS, STATE_BUFFER_MAX_DELAY_MS)

	var now_ms: int = Time.get_ticks_msec()
	var target_time: int = now_ms - delay_ms

	while _state_buffer.size() >= 3 and target_time > int(_state_buffer[1]["timestamp"]):
		_state_buffer.remove_at(0)

	if _state_buffer.size() == 1:
		_apply_remote_snapshot(_state_buffer[0])
		return

	var from_state: Dictionary = _state_buffer[0]
	var to_state: Dictionary = _state_buffer[1]
	var from_time: int = int(from_state["timestamp"])
	var to_time: int = int(to_state["timestamp"])
	var span: int = max(1, to_time - from_time)
	var alpha: float = clamp(float(target_time - from_time) / float(span), 0.0, 1.0)

	var from_pos: Vector3 = from_state["position"]
	var to_pos: Vector3 = to_state["position"]
	var blended_pos := from_pos.lerp(to_pos, alpha)
	var from_vel: Vector3 = from_state.get("velocity", Vector3.ZERO)
	var to_vel: Vector3 = to_state.get("velocity", Vector3.ZERO)
	var blended_vel := from_vel.lerp(to_vel, alpha)
	var extra_ms := float(target_time - to_time)
	if extra_ms > 0.0:
		blended_pos += blended_vel * (extra_ms / 1000.0)
	global_position = blended_pos
	velocity = blended_vel

	var from_rot: Vector2 = from_state["rotation"]
	var to_rot: Vector2 = to_state["rotation"]
	_mouse_rotation.x = lerp_angle(from_rot.x, to_rot.x, alpha)
	_mouse_rotation.y = lerp_angle(from_rot.y, to_rot.y, alpha)
	_camera_rotation.x = _mouse_rotation.x
	_player_rotation.y = _mouse_rotation.y
	camera.transform.basis = Basis.from_euler(Vector3(_camera_rotation.x, 0, 0))
	camera.rotation.z = 0
	global_transform.basis = Basis.from_euler(Vector3(0, _player_rotation.y, 0))

	var crouch_from := bool(from_state["is_crouching"])
	var crouch_to := bool(to_state["is_crouching"])
	set_crouch(crouch_to if alpha >= 0.5 else crouch_from)

	_rotation_input = 0.0
	_tilt_input = 0.0


func _apply_remote_snapshot(snapshot: Dictionary) -> void:
	global_position = snapshot.get("position", global_position)
	var _rotation: Vector2 = snapshot.get("rotation", Vector2.ZERO)
	_mouse_rotation.x = _rotation.x
	_mouse_rotation.y = _rotation.y
	_camera_rotation.x = _mouse_rotation.x
	_player_rotation.y = _mouse_rotation.y
	camera.transform.basis = Basis.from_euler(Vector3(_camera_rotation.x, 0, 0))
	camera.rotation.z = 0
	global_transform.basis = Basis.from_euler(Vector3(0, _player_rotation.y, 0))
	set_crouch(snapshot.get("is_crouching", _is_crouching))
	velocity = snapshot.get("velocity", velocity)
	_rotation_input = 0.0
	_tilt_input = 0.0


func _emit_telemetry(now_ms: int) -> void:
	if now_ms - _telemetry_last_report_ms < TELEMETRY_INTERVAL_MS:
		return
	_telemetry_last_report_ms = now_ms
	if LowLevelNetworkHandler.is_server:
		print("Telemetry[server:%s] queue=%d last_seq=%d" % [name, _server_input_queue.size(), _server_last_sequence_id])
	elif is_authority:
		print("Telemetry[client:%s] recorded=%d buffer=%d delay=%dms" % [name, _recorded_frames.size(), _state_buffer.size(), _state_buffer_delay_ms])
func _append_remote_state(player_state: PlayerStatePacket) -> void:
	var snapshot := {
		"timestamp": int(player_state.timestamp_ms),
		"position": player_state.position,
		"rotation": player_state.rotation,
		"is_crouching": player_state.is_crouching,
		"velocity": player_state.velocity,
	}
	if !_state_buffer.is_empty():
		var last_timestamp := int(_state_buffer[_state_buffer.size() - 1]["timestamp"])
		if snapshot["timestamp"] <= last_timestamp:
			return
	_state_buffer.append(snapshot)

	if _state_buffer.size() >= 2:
		var count := _state_buffer.size()
		var delta := int(_state_buffer[count - 1]["timestamp"]) - int(_state_buffer[count - 2]["timestamp"])
		if delta > 0:
			_state_buffer_delay_ms = clamp(delta, STATE_BUFFER_MIN_DELAY_MS, STATE_BUFFER_MAX_DELAY_MS)

	while _state_buffer.size() > STATE_BUFFER_MAX_SIZE:
		_state_buffer.remove_at(0)


func _prune_acknowledged_frames(ack_sequence: int) -> void:
	if ack_sequence < 0:
		return
	while !_recorded_frames.is_empty():
		var frame := _recorded_frames[0]
		if frame.sequence_id < 0:
			break
		if !_sequence_is_newer_or_equal(ack_sequence, frame.sequence_id):
			break
		_recorded_frames.remove_at(0)


func _sequence_diff(a: int, b: int) -> int:
	var diff := a - b
	if diff > SEQUENCE_HALF_RANGE:
		diff -= SEQUENCE_MODULO
	elif diff < -SEQUENCE_HALF_RANGE:
		diff += SEQUENCE_MODULO
	return diff


func _sequence_is_newer(a: int, b: int) -> bool:
	if b < 0:
		return true
	return _sequence_diff(a, b) > 0


func _sequence_is_newer_or_equal(a: int, b: int) -> bool:
	return a == b or _sequence_is_newer(a, b)


func _enqueue_server_input(packet: PlayerInputPacket) -> void:
	var sequence_id := int(packet.sequence_id)
	if !_sequence_is_newer(sequence_id, _server_last_sequence_id):
		return
	for existing in _server_input_queue:
		if existing.sequence_id == sequence_id:
			return

	var frame := FrameInput.new()
	var timestamp_ms := int(packet.timestamp_ms)
	frame.timestamp_ms = timestamp_ms
	frame.sequence_id = sequence_id
	frame.move = Vector2(packet.move_right - packet.move_left, packet.move_backward - packet.move_forward)
	frame.mouse = packet.look_delta
	frame.jump_pressed = packet.jump_pressed
	frame.crouch_pressed = packet.crouch_pressed
	frame.crouch_released = packet.crouch_released
	frame.crouch_held = packet.crouch_held
	frame.was_on_floor = packet.was_on_floor
	frame.look_abs = packet.look_abs
	frame.velocity = packet.velocity
	if _server_last_received_timestamp_ms >= 0:
		var diff_ms: int = max(1, timestamp_ms - _server_last_received_timestamp_ms)
		frame.delta = float(diff_ms) / 1000.0
	else:
		frame.delta = 1.0 / Engine.get_physics_ticks_per_second()
	_server_last_received_timestamp_ms = timestamp_ms

	var insert_index := _server_input_queue.size()
	for i in range(_server_input_queue.size()):
		if _sequence_is_newer(_server_input_queue[i].sequence_id, sequence_id):
			insert_index = i
			break
	_server_input_queue.insert(insert_index, frame)
	while _server_input_queue.size() > SERVER_INPUT_QUEUE_MAX:
		_server_input_queue.remove_at(0)


func _make_frame_input(now_ms: int) -> FrameInput:
	var frame := FrameInput.new()
	frame.timestamp_ms = now_ms
	frame.move = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	frame.mouse = Vector2(_rotation_input, _tilt_input)
	frame.jump_pressed = Input.is_action_just_pressed("jump")
	frame.crouch_pressed = Input.is_action_just_pressed("crouch")
	frame.crouch_released = Input.is_action_just_released("crouch")
	frame.crouch_held = Input.is_action_pressed("crouch")
	frame.was_on_floor = is_on_floor()
	frame.look_abs = Vector2(_camera_rotation.x, _player_rotation.y)
	frame.velocity = velocity
	return frame


func _apply_frame(frame: FrameInput, delta: float, apply_crouch_actions: bool) -> void:
	if frame == null:
		return

	if apply_crouch_actions:
		if TOGGLE_CROUCH:
			if frame.crouch_pressed:
				toggle_crouch()
		else:
			if frame.crouch_pressed:
				crouch(true)
			if frame.crouch_released:
				crouch(false)

	var use_absolute_look := apply_crouch_actions
	if use_absolute_look:
		var safe_delta: float = max(delta, 0.0001)
		var desired_pitch: float = clamp(frame.look_abs.x, TILT_LOWER_LIMIT, TILT_UPPER_LIMIT)
		var desired_yaw: float = frame.look_abs.y
		var yaw_delta: float = wrapf(desired_yaw - _mouse_rotation.y, -PI, PI)
		yaw_delta = clamp(yaw_delta, -SERVER_LOOK_DELTA_LIMIT, SERVER_LOOK_DELTA_LIMIT)
		var pitch_delta: float = clamp(desired_pitch - _mouse_rotation.x, -SERVER_LOOK_DELTA_LIMIT, SERVER_LOOK_DELTA_LIMIT)
		_rotation_input = yaw_delta / safe_delta
		_tilt_input = pitch_delta / safe_delta
	else:
		_rotation_input = frame.mouse.x
		_tilt_input = frame.mouse.y
	_update_camera(delta)
	if use_absolute_look:
		_mouse_rotation.x = clamp(frame.look_abs.x, TILT_LOWER_LIMIT, TILT_UPPER_LIMIT)
		_mouse_rotation.y = wrapf(frame.look_abs.y, -PI, PI)
		_camera_rotation.x = _mouse_rotation.x
		_player_rotation.y = _mouse_rotation.y
		camera.transform.basis = Basis.from_euler(Vector3(_camera_rotation.x, 0, 0))
		camera.rotation.z = 0
		global_transform.basis = Basis.from_euler(Vector3(0, _player_rotation.y, 0))
		frame.look_abs = Vector2(_mouse_rotation.x, _mouse_rotation.y)

	if frame.jump_pressed and (is_on_floor() or frame.was_on_floor):
		velocity.y = JUMP_VELOCITY

	var direction := (transform.basis * Vector3(frame.move.x, 0, frame.move.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)


func _send_player_input(timestamp_ms: int, frame: FrameInput) -> void:
	var move_forward_strength := Input.get_action_strength("move_forward")
	var move_backward_strength := Input.get_action_strength("move_backward")
	var move_left_strength := Input.get_action_strength("move_left")
	var move_right_strength := Input.get_action_strength("move_right")

	_input_sequence = (_input_sequence + 1) % SEQUENCE_MODULO
	frame.sequence_id = _input_sequence
	
	var input_packet := PlayerInputPacket.new()
	input_packet.id = _owner_id
	input_packet.sequence_id = frame.sequence_id
	input_packet.timestamp_ms = timestamp_ms
	input_packet.move_forward = move_forward_strength
	input_packet.move_backward = move_backward_strength
	input_packet.move_left = move_left_strength
	input_packet.move_right = move_right_strength
	input_packet.look_delta = frame.mouse
	input_packet.jump_pressed = frame.jump_pressed
	input_packet.crouch_pressed = frame.crouch_pressed
	input_packet.crouch_released = frame.crouch_released
	input_packet.look_abs = frame.look_abs
	input_packet.velocity = frame.velocity
	input_packet.crouch_held = frame.crouch_held
	input_packet.was_on_floor = frame.was_on_floor
	LowLevelNetworkHandler.send_packet(input_packet.to_payload())


func _record_frame(frame: FrameInput) -> void:
	if frame == null:
		return

	_recorded_frames.append(frame)
	_prune_acknowledged_frames(_last_server_ack_sequence)
	_prune_old_frames(frame.timestamp_ms)
	_prune_old_chat_events(frame.timestamp_ms)


func _prune_old_frames(now_ms: int) -> void:
	var cutoff := now_ms - ACTION_REPEAT_WINDOW_MS
	while !_recorded_frames.is_empty() and _recorded_frames[0].timestamp_ms < cutoff:
		_recorded_frames.remove_at(0)


func _prune_old_chat_events(now_ms: int) -> void:
	var cutoff := now_ms - ACTION_REPEAT_WINDOW_MS
	while !_recorded_chat_events.is_empty() and _recorded_chat_events[0].timestamp_ms < cutoff:
		_recorded_chat_events.remove_at(0)


func record_chat_event(username: String, message: String) -> void:
	if !is_authority:
		return
	if _action_repeat_active:
		return

	var event := ChatEvent.new()
	event.timestamp_ms = Time.get_ticks_msec()
	event.username = username
	event.message = message
	_recorded_chat_events.append(event)
	_prune_old_chat_events(event.timestamp_ms)


func _replay_chat_events(loop_time: int) -> void:
	if _playback_duration_ms <= 0:
		_last_playback_loop_time = loop_time
		return
	if _recorded_chat_events.is_empty():
		_last_playback_loop_time = loop_time
		return
	if _last_playback_loop_time == -1:
		_last_playback_loop_time = loop_time
		return
	if loop_time == _last_playback_loop_time:
		return

	if loop_time > _last_playback_loop_time:
		_send_chats_in_range(_last_playback_loop_time, loop_time)
	else:
		_send_chats_in_range(_last_playback_loop_time, _playback_duration_ms)
		_send_chats_in_range(0, loop_time)

	_last_playback_loop_time = loop_time


func _send_chats_in_range(start_time: int, end_time: int) -> void:
	if _recording_start_ms == 0:
		return
	for event in _recorded_chat_events:
		var relative := event.timestamp_ms - _recording_start_ms
		if relative < 0:
			continue
		if relative > _playback_duration_ms:
			continue
		if relative >= start_time and relative <= end_time:
			var chat_packet := ChatPacket.new()
			chat_packet.username = event.username
			chat_packet.message = event.message
			LowLevelNetworkHandler.send_packet(chat_packet.to_payload())


func _get_playback_frame(now_ms: int) -> FrameInput:
	if _recorded_frames.size() < 2:
		return null
	if _playback_duration_ms <= 0:
		return null

	var elapsed := now_ms - _play_start_ms
	if elapsed < 0:
		elapsed = 0
	var loop_time := elapsed % _playback_duration_ms
	_current_loop_time = loop_time
	var target_timestamp := _recorded_frames[0].timestamp_ms + loop_time
	for frame in _recorded_frames:
		if frame.timestamp_ms >= target_timestamp:
			return frame
	return _recorded_frames[_recorded_frames.size() - 1]


func _can_uncrouch() -> bool:
	return !crouch_shapecast.is_colliding()


func _apply_crouch_state(target: bool, force: bool = false) -> void:
	_target_crouch_state = target

	if _is_crouching == target:
		_do_uncrouch = false
		if !force:
			return
		if !target:
			return
	
	if target:
		if _is_crouching and !force:
			return
		_is_crouching = true
		_do_uncrouch = false
		animation_player.play("Crouch", -1, CROUCH_SPEED)
		return

	if !_is_crouching and !force:
		_do_uncrouch = false
		return

	if force or _can_uncrouch():
		_is_crouching = false
		_do_uncrouch = false
		animation_player.play("Crouch", -1, -CROUCH_SPEED, true)
	else:
		_do_uncrouch = true


func _request_crouch_state(target: bool) -> void:
	if is_authority:
		_desired_crouch_state = target
		_crouch_trust_expires_ms = Time.get_ticks_msec() + CROUCH_TRUST_WINDOW_MS
	_apply_crouch_state(target)


func crouch(state: bool):
	_request_crouch_state(state)


func set_crouch(state: bool):
	_apply_crouch_state(state, true)


func toggle_crouch():
	_request_crouch_state(!_desired_crouch_state)


func set_action_repeat(active: bool) -> bool:
	if active == _action_repeat_active:
		return _action_repeat_active

	if !active:
		_action_repeat_active = false
		_play_start_ms = 0
		_playback_duration_ms = 0
		_last_playback_loop_time = -1
		_current_loop_time = 0
		_recording_start_ms = 0
		return false

	if _recorded_frames.size() < 2:
		return false

	var first := _recorded_frames[0]
	var last := _recorded_frames[_recorded_frames.size() - 1]
	var duration := last.timestamp_ms - first.timestamp_ms
	if duration <= 0:
		return false

	_action_repeat_active = true
	_playback_duration_ms = duration
	_play_start_ms = Time.get_ticks_msec()
	_recording_start_ms = first.timestamp_ms
	_last_playback_loop_time = -1
	_current_loop_time = 0
	return true


func get_sightline_unit_vector() -> Vector3:
	var camera_global_transform: Transform3D = camera.global_transform
	var sightline_vector: Vector3 = -camera_global_transform.basis.z
	return sightline_vector


func server_handle_player_input(peer_id: int, input_packet: PlayerInputPacket) -> void:
	if !LowLevelNetworkHandler.is_server:
		return
	if input_packet.id != _owner_id:
		return
	if peer_id != input_packet.id:
		return

	_enqueue_server_input(input_packet)


func client_handle_player_state(player_state: PlayerStatePacket) -> void:
	if LowLevelNetworkHandler.is_server:
		return
	if _owner_id != player_state.id:
		return

	var ack_sequence := int(player_state.last_input_sequence_id)
	if is_authority:
		if _sequence_is_newer(ack_sequence, _last_server_ack_sequence):
			_last_server_ack_sequence = ack_sequence
			_prune_acknowledged_frames(_last_server_ack_sequence)
		if player_state.timestamp_ms < _pending_state_timestamp_ms:
			return
		_pending_state_timestamp_ms = int(player_state.timestamp_ms)
		_pending_state_position = player_state.position
		_pending_state_velocity = player_state.velocity
		_pending_state_camera_rotation = float(player_state.rotation.x)
		_pending_state_player_rotation = float(player_state.rotation.y)
		_pending_state_crouching = player_state.is_crouching
		_has_pending_state = true
	else:
		_append_remote_state(player_state)


func _on_animation_player_animation_started(anim_name: StringName) -> void:
	if anim_name == "Crouch":
		_is_crouching = _target_crouch_state


func _on_shape_cast_3d_collision_state_changed(is_colliding: bool) -> void:
	if !is_colliding and _do_uncrouch:
		_apply_crouch_state(false, true)


func despawn() -> void:
	print("I'm (%s) being despawned!" % name)
	set_action_repeat(false)
	if is_authority: get_tree().change_scene_to_file("res://main_menu.tscn")
