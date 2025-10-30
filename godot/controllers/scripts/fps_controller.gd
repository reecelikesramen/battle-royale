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
	ServerNetworkGlobals.handle_game_state.connect(server_handle_game_state)
	ClientNetworkGlobals.handle_game_state.connect(client_handle_game_state)


func _exit_tree() -> void:
	ServerNetworkGlobals.handle_game_state.disconnect(server_handle_game_state)
	ClientNetworkGlobals.handle_game_state.disconnect(client_handle_game_state)


func _ready():
	print("Player #%d spawned, named %s!" % [_owner_id, name])
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
		_rotation_input = -event.relative.x * MOUSE_SENSITIVITY
		_tilt_input = -event.relative.y * MOUSE_SENSITIVITY


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
	if !is_authority:
		return

	if !is_on_floor():
		velocity += get_gravity() * delta

	var now_ms := Time.get_ticks_msec()
	var live_frame := _make_frame_input(now_ms)
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

	if !_action_repeat_active:
		_record_frame(live_frame)

	move_and_slide()
	LowLevelNetworkHandler.send_packet(GameStatePacket.create(_owner_id, position, _camera_rotation.x, _player_rotation.y, _is_crouching))


func _make_frame_input(now_ms: int) -> FrameInput:
	var frame := FrameInput.new()
	frame.timestamp_ms = now_ms
	frame.move = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	frame.mouse = Vector2(_rotation_input, _tilt_input)
	frame.jump_pressed = Input.is_action_just_pressed("jump")
	frame.crouch_pressed = Input.is_action_just_pressed("crouch")
	frame.crouch_released = Input.is_action_just_released("crouch")
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

	_rotation_input = frame.mouse.x
	_tilt_input = frame.mouse.y
	_update_camera(delta)

	if frame.jump_pressed and is_on_floor():
		velocity.y = JUMP_VELOCITY

	var direction := (transform.basis * Vector3(frame.move.x, 0, frame.move.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)


func _record_frame(frame: FrameInput) -> void:
	if frame == null:
		return

	_recorded_frames.append(frame)
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
			LowLevelNetworkHandler.send_packet(ChatPacket.create(event.username, event.message))


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


func crouch(state: bool):
	print("Colliding:", crouch_shapecast.is_colliding())
	match state:
		true:
			animation_player.play("Crouch", -1, CROUCH_SPEED)
			_do_uncrouch = false
		false:
			if crouch_shapecast.is_colliding():
				_do_uncrouch = true
			else:
				animation_player.play("Crouch", -1, -CROUCH_SPEED, true)


func set_crouch(state: bool):
	if _is_crouching != state:
		crouch(state)


func toggle_crouch():
	print("Colliding:", crouch_shapecast.is_colliding())
	if _is_crouching and crouch_shapecast.is_colliding() == false:
		crouch(true)
	elif !_is_crouching:
		crouch(false)
	print(_is_crouching)


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


func server_handle_game_state(peer_id: int, game_state: GameStatePacket) -> void:
	if _owner_id != peer_id:
		return

	global_position = game_state.player_position
	set_crouch(game_state.is_crouching)
	camera.transform.basis = Basis.from_euler(Vector3(game_state.camera_rotation, 0, 0))
	camera.rotation.z = 0
	
	global_transform.basis = Basis.from_euler(Vector3(0, game_state.player_rotation, 0))
	LowLevelNetworkHandler.broadcast_packet(game_state.to_payload())


func client_handle_game_state(game_state: GameStatePacket) -> void:
	if is_authority || _owner_id != game_state.id: return

	global_position = game_state.player_position
	set_crouch(game_state.is_crouching)
	camera.transform.basis = Basis.from_euler(Vector3(game_state.camera_rotation, 0, 0))
	camera.rotation.z = 0
	
	global_transform.basis = Basis.from_euler(Vector3(0, game_state.player_rotation, 0))


func _on_animation_player_animation_started(anim_name: StringName) -> void:
	if anim_name == "Crouch":
		_is_crouching = !_is_crouching


func _on_shape_cast_3d_collision_state_changed(is_colliding: bool) -> void:
	print(is_colliding)
	if !is_colliding and _do_uncrouch:
		animation_player.play("Crouch", -1, -CROUCH_SPEED, true)


func despawn() -> void:
	print("I'm (%s) being despawned!" % name)
	set_action_repeat(false)
	if is_authority: get_tree().change_scene_to_file("res://main_menu.tscn")
