class_name FPSController

extends CharacterBody3D

@export var TILT_LOWER_LIMIT: float = deg_to_rad(-90.0)
@export var TILT_UPPER_LIMIT: float = deg_to_rad(90.0)
@export var MOUSE_SENSITIVITY: float = 0.5

# reconciliation tunables
@export var SNAP_THRESHOLD_HORIZONTAL := 1.5
@export var SNAP_THRESHOLD_VERTICAL := 2.5
@export var CORRECTION_RATE_HORIZONTAL := 8.0
@export var CORRECTION_RATE_VERTICAL := 4.0
@export var POSITION_CORRECTION_DEADBAND_HORIZONTAL := 0.07
@export var POSITION_CORRECTION_DEADBAND_VERTICAL := 0.15

@export var VELOCITY_CORRECTION_THRESHOLD := 1.5
@export var VELOCITY_CORRECTION_RATE := 12.0
@export var VELOCITY_CORRECTION_DEADBAND := 0.2

# inputs_to_keep = ceil((max_expected_rtt_sec * input_rate_hz) * 2)
# const MAX_UNACKED_INPUTS: int = 128
# average_rtt_s + 3 * rtt_jitter_s + safety_margin
# const INPUT_EXPIRED_US: int = 200_000

@onready var camera: Camera3D = $CameraController/Camera3D
@onready var animation_player: AnimationPlayer = $AnimationPlayer

var is_authority: bool:
	get: return !LowLevelNetworkHandler.is_server && _owner_id == ClientNetworkGlobals.id

var current_frame_input: PlayerInputPacket = null

var context: Enums.IntegrationContext = Enums.IntegrationContext.VISUAL

var _owner_id: int

# movement parameters
var _speed := 0.0
var _acceleration := 0.0
var _deceleration := 0.0

# x and y mouse input for accumulating mouse movement
var _x_mouse_input: float
var _y_mouse_input: float

# look absolute for camera and player rotation
var _look_abs: Vector2 = Vector2()

# server authoritative game state
var game_transform: Transform3D = Transform3D()
var game_position: Vector3:
	get: return game_transform.origin
	set(value): game_transform.origin = value
var game_velocity: Vector3 = Vector3()
var game_movement_state_id: int = 0
var game_sequence_id: int = 65535
var _game_is_on_floor: bool = false

# networking data structures
var _server_input_queue := JitterBuffer.new()
var _player_state_buffer := SequenceRingBuffer.new()
var _input_sequence := PacketSequence.new()
var _unacked_inputs := SequenceRingBuffer.new()

func _enter_tree() -> void:
	ServerNetworkGlobals.handle_player_input.connect(server_handle_player_input)
	ClientNetworkGlobals.handle_player_state.connect(client_handle_player_state)


func _exit_tree() -> void:
	ServerNetworkGlobals.handle_player_input.disconnect(server_handle_player_input)
	ClientNetworkGlobals.handle_player_state.disconnect(client_handle_player_state)


func _ready():
	print("Player #%d spawned, named %s!" % [_owner_id, name])

	if is_authority:
		add_to_group("local_player")
		camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		call_deferred("remove_child", %GUI)
		camera.call_deferred("remove_child", $CameraController/Camera3D/ReflectionProbe)


func _unhandled_input(event):
	if !is_authority:
		return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_x_mouse_input += -event.relative.x * MOUSE_SENSITIVITY
		_y_mouse_input += -event.relative.y * MOUSE_SENSITIVITY


func _physics_process(delta: float) -> void:
	if is_authority:
		_client_authority_physics_step(delta)
	elif LowLevelNetworkHandler.is_server:
		_server_physics_step(delta)
	else:
		_client_remote_physics_step(delta)


func _server_physics_step(delta: float) -> void:
	var frames := _server_input_queue.consume()
	
	if frames.is_empty():
		#push_warning("No input frames to consume")
		return

	for frame in frames:
		assert(frame.packet is PlayerInputPacket, "Packet is not a PlayerInputPacket")
		assert(frame.delta > 0.0, "Delta is not positive")
		current_frame_input = frame.packet as PlayerInputPacket
		update_camera(current_frame_input.look_abs)
		$MovementStateMachine.physics_process(frame.delta)

	# if server broadcast player state
	var player_state := PlayerStatePacket.new()
	player_state.player_id = _owner_id
	player_state.last_input_sequence_id = frames[-1].packet.sequence_id
	player_state.timestamp_us = Time.get_ticks_usec()
	player_state.position = global_position
	player_state.look_abs = current_frame_input.look_abs
	player_state.velocity = velocity
	player_state.movement_state = $MovementStateMachine.get_state_id()
	LowLevelNetworkHandler.broadcast_packet(player_state.to_payload())


func _client_authority_physics_step(delta: float) -> void:
	# camera movement integration
	_look_abs.x += _y_mouse_input * delta
	_look_abs.x = clamp(_look_abs.x, TILT_LOWER_LIMIT, TILT_UPPER_LIMIT)
	_look_abs.y += _x_mouse_input * delta

	var player_input := PlayerInputPacket.new()
	player_input.sequence_id = _input_sequence.next()
	player_input.timestamp_us = Time.get_ticks_usec()
	player_input.move_forward_backward = Input.get_axis("move_forward", "move_backward")
	player_input.move_left_right = Input.get_axis("move_left", "move_right")
	player_input.look_abs = _look_abs
	player_input.jump = Input.is_action_pressed("jump")
	player_input.crouch = Input.is_action_pressed("crouch")
	player_input.sprint = Input.is_action_pressed("sprint")
	_unacked_inputs.insert(player_input.sequence_id, -1, player_input.timestamp_us, player_input)
	LowLevelNetworkHandler.send_packet(player_input.to_payload())
	current_frame_input = player_input

	# run prediction on authoritative copy
	context = Enums.IntegrationContext.GAME
	game_transform.basis = Basis.from_euler(Vector3(0, player_input.look_abs.y, 0))
	$MovementStateMachine.physics_process(delta)

	context = Enums.IntegrationContext.VISUAL
	update_camera(player_input.look_abs)
	$MovementStateMachine.physics_process(delta)

	_client_authority_reconcile_visual_state(delta)


func _client_remote_physics_step(delta: float) -> void:
	var now_us := Time.get_ticks_usec()
	var interpolation_pair := _player_state_buffer.get_interpolation_pair(now_us);
	if !interpolation_pair.is_valid:
		return

	if interpolation_pair.to == null:
		var packet := interpolation_pair.from as PlayerStatePacket
		global_position = packet.position
		velocity = packet.velocity
		update_camera(packet.look_abs)
		$MovementStateMachine.set_state_by_id(packet.movement_state)
	else:
		var from: PlayerStatePacket = interpolation_pair.from as PlayerStatePacket
		var to: PlayerStatePacket = interpolation_pair.to as PlayerStatePacket
		var alpha := interpolation_pair.alpha
		var blended_pos := from.position.lerp(to.position, alpha)
		var blended_vel := from.velocity.lerp(to.velocity, alpha)
		var blended_look_abs := from.look_abs.lerp(to.look_abs, alpha)
		if interpolation_pair.extrapolation_s > 0.0:
			blended_pos += blended_vel * interpolation_pair.extrapolation_s
		global_position = blended_pos
		velocity = blended_vel
		update_camera(blended_look_abs)
		$MovementStateMachine.set_state_by_id(from.movement_state if alpha < 0.5 else to.movement_state)


func _client_authority_update_game_state(game_state: PlayerStatePacket) -> void:
	var delta := 1.0 / Engine.get_physics_ticks_per_second() as float
	game_sequence_id = game_state.last_input_sequence_id
	game_transform.origin = game_state.position
	game_transform.basis = Basis.from_euler(Vector3(0, game_state.look_abs.y, 0))
	game_velocity = game_state.velocity
	game_movement_state_id = game_state.movement_state

	context = Enums.IntegrationContext.GAME
	$MovementStateMachine.set_state_by_id(game_state.movement_state)

	for input: PlayerInputPacket in _unacked_inputs.get_starting_at(game_sequence_id + 1):
		current_frame_input = input
		game_transform.basis = Basis.from_euler(Vector3(0, input.look_abs.y, 0))
		$MovementStateMachine.physics_process(delta)
	
	_client_authority_reconcile_visual_state(delta)
	context = Enums.IntegrationContext.VISUAL


func _client_authority_reconcile_visual_state(delta: float) -> void:
	var delta_pos := game_position - global_position
	var horizontal_err := Vector2(delta_pos.x, delta_pos.z)
	var horizontal_err_mag := horizontal_err.length()
	var vertical_err := absf(delta_pos.y)

	var color_pos := Color()
	color_pos.r = delta_pos.x
	color_pos.g = delta_pos.z
	color_pos.b = delta_pos.y
	$CameraController/Camera3D/DeltaPos.color = color_pos

	var delta_vel := game_velocity - velocity
	var horizontal_vel_err := Vector2(delta_vel.x, delta_vel.z)
	var horizontal_vel_err_mag := horizontal_vel_err.length()

	var color_vel := Color()
	color_vel.r = delta_vel.x
	color_vel.g = delta_vel.z
	color_vel.b = delta_vel.y
	$CameraController/Camera3D/DeltaVel.color = color_vel

	$CameraController/Camera3D/InputBuffer.text = "Inputs Size: %d\nInputs Oldest: %d\nInputs Newest: %d\nInputs Buffer Delay: %d" % [_unacked_inputs.size(), _unacked_inputs.oldest_sequence_id(), _unacked_inputs.newest_sequence_id(), _unacked_inputs.buffer_delay_us()]

	# TODO: maybe even give snap to game state a lerp so its not instant
	# Snap or lerp to horizontal game position
	if horizontal_err_mag > SNAP_THRESHOLD_HORIZONTAL:
		global_position.x = game_position.x
		global_position.z = game_position.z
	else:
		var pos_alpha := _correction_alpha(
			delta,
			horizontal_err_mag,
			SNAP_THRESHOLD_HORIZONTAL,
			CORRECTION_RATE_HORIZONTAL,
			POSITION_CORRECTION_DEADBAND_HORIZONTAL
		)
		global_position.x = lerp(global_position.x, game_position.x, pos_alpha)
		global_position.z = lerp(global_position.z, game_position.z, pos_alpha)

	# Snap or lerp to vertical game position
	if vertical_err > SNAP_THRESHOLD_VERTICAL:
		global_position.y = game_position.y
		velocity.y = game_velocity.y
	else:
		var vert_alpha := _correction_alpha(
			delta,
			vertical_err,
			SNAP_THRESHOLD_VERTICAL,
			CORRECTION_RATE_VERTICAL,
			POSITION_CORRECTION_DEADBAND_VERTICAL
		)
		global_position.y = lerp(global_position.y, game_position.y, vert_alpha)
		velocity.y = lerp(velocity.y, game_velocity.y, vert_alpha)

	# lerp to horizontal game velocity
	var vel_alpha := _correction_alpha(
		delta,
		horizontal_vel_err_mag,
		VELOCITY_CORRECTION_THRESHOLD,
		VELOCITY_CORRECTION_RATE,
		VELOCITY_CORRECTION_DEADBAND,
	)
	velocity.x = lerp(velocity.x, game_velocity.x, vel_alpha)
	velocity.z = lerp(velocity.z, game_velocity.z, vel_alpha)


func _correction_alpha(
	delta: float,
	error_mag: float,
	snap_threshold: float,
	rate: float,
	deadband: float) -> float:
	if error_mag <= deadband:
		return 0.0
	
	var normalized: float = clamp(
		(error_mag - deadband) / max(snap_threshold - deadband, 0.001),
		0.0,
		1.0
	)
	return 1.0 - exp(-rate * delta * normalized)

func set_parameters(speed: float, acceleration: float, deceleration: float) -> void:
	_speed = speed
	_acceleration = acceleration
	_deceleration = deceleration


func on_floor(ctx: Enums.IntegrationContext) -> bool:
	if ctx == Enums.IntegrationContext.VISUAL:
		return is_on_floor()
	else:
		return _game_is_on_floor


# persistent local vars for performance
var _player_rotation: Vector3 = Vector3.ZERO
var _camera_rotation: Vector3 = Vector3.ZERO
func update_camera(look_abs: Vector2) -> void:
	_player_rotation.y = look_abs.y
	_camera_rotation.x = look_abs.x
	
	camera.transform.basis = Basis.from_euler(_camera_rotation)
	camera.rotation.z = 0
	
	global_transform.basis = Basis.from_euler(_player_rotation)

	# reset input integration
	_x_mouse_input = 0.0
	_y_mouse_input = 0.0


func update_gravity(delta: float, ctx: Enums.IntegrationContext) -> void:
	if ctx == Enums.IntegrationContext.VISUAL:
		velocity += get_gravity() * delta
	else:
		game_velocity += get_gravity() * delta


var _input_dir := Vector2.ZERO
func update_movement(ctx: Enums.IntegrationContext) -> void:
	_input_dir.x = current_frame_input.move_left_right
	_input_dir.y = current_frame_input.move_forward_backward
	
	var _basis := transform.basis if ctx == Enums.IntegrationContext.VISUAL else game_transform.basis
	var direction = (_basis * Vector3(_input_dir.x, 0, _input_dir.y)).normalized()

	if direction:
		if ctx == Enums.IntegrationContext.VISUAL:
			velocity.x = lerp(velocity.x, direction.x * _speed, _acceleration)
			velocity.z = lerp(velocity.z, direction.z * _speed, _acceleration)
		else:
			game_velocity.x = lerp(game_velocity.x, direction.x * _speed, _acceleration)
			game_velocity.z = lerp(game_velocity.z, direction.z * _speed, _acceleration)
	else:
		# TODO: fix this logic, axes come to rest at different rates; not at same time, feels clunky
		if ctx == Enums.IntegrationContext.VISUAL:
			velocity.x = move_toward(velocity.x, 0, _deceleration)
			velocity.z = move_toward(velocity.z, 0, _deceleration)
		else:
			game_velocity.x = move_toward(game_velocity.x, 0, _deceleration)
			game_velocity.z = move_toward(game_velocity.z, 0, _deceleration)


const MAX_SLIDES := 4 # Engine.max_physics_steps_per_frame

@onready var _body_rid := get_rid()
var _game_physics_result := PhysicsTestMotionResult3D.new()
func update_velocity(ctx: Enums.IntegrationContext) -> void:
	if ctx == Enums.IntegrationContext.VISUAL:
		move_and_slide()
	else:
		_game_is_on_floor = false
		var delta := 1.0 / Engine.get_physics_ticks_per_second() as float
		var remaining_motion := game_velocity * delta
		for i in MAX_SLIDES:
			if remaining_motion.is_zero_approx():
				break

			# TODO: move delta out of this function
			var params := PhysicsTestMotionParameters3D.new()
			params.motion = remaining_motion
			params.from = game_transform
			
			var collided := PhysicsServer3D.body_test_motion(_body_rid, params, _game_physics_result)
			game_transform.origin += _game_physics_result.get_travel()

			if !collided:
				_game_is_on_floor = false
				break

			game_velocity = game_velocity.slide(_game_physics_result.get_collision_normal(0))
			remaining_motion = _game_physics_result.get_remainder()
			for j in range(_game_physics_result.get_collision_count()):
				if _game_physics_result.get_collision_normal(j).dot(up_direction) >= cos(floor_max_angle):
					_game_is_on_floor = true
					break


func server_handle_player_input(peer_id: int, input_packet: PlayerInputPacket) -> void:
	# server only
	assert(LowLevelNetworkHandler.is_server)

	# not owner
	if peer_id != _owner_id:
		return

	_server_input_queue.enqueue(input_packet.sequence_id, input_packet.timestamp_us, input_packet)


func client_handle_player_state(player_state: PlayerStatePacket) -> void:
	# client only
	assert(!LowLevelNetworkHandler.is_server)

	# not owner
	if _owner_id != player_state.player_id:
		return

	if is_authority:
		var ack_sequence := player_state.last_input_sequence_id
		_unacked_inputs.prune_up_to(ack_sequence)
		if PacketSequence.is_newer(ack_sequence, game_sequence_id):
			_client_authority_update_game_state(player_state)
	else:
		#if _owner_id == 0:
			#print("Size: %d | Oldest: %d | Newest: %d | Delay US: %d" % [_player_state_buffer.size(), _player_state_buffer.oldest_sequence_id(), _player_state_buffer.newest_sequence_id(), _player_state_buffer.buffer_delay_us()])
		_player_state_buffer.insert(player_state.last_input_sequence_id, Time.get_ticks_usec(), player_state.timestamp_us, player_state)


func despawn() -> void:
	print("I'm (%s) being despawned!" % name)
	if is_authority: get_tree().change_scene_to_file("res://main_menu.tscn")
