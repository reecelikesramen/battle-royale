class_name PlayerController
extends CharacterBody3D

signal reconcile_network_debug(delta_pos: Vector3, delta_vel: Vector3, unacked_inputs: SequenceRingBuffer)

const TILT_LOWER_LIMIT: float = deg_to_rad(-90.0)
const TILT_UPPER_LIMIT: float = deg_to_rad(90.0)


@export_group("Movement Tunables")
@export var FRICTION: float = 8.0
@export var AIR_FRICTION: float = 0.5
@export var STOP_SPEED: float = 0.5
@export var TOGGLE_CROUCH: bool = false
@export var TOGGLE_PEEK: bool = false

@export_group("Camera Tunables")
@export var MOUSE_SENSITIVITY: float = 0.5

@onready var camera: Camera3D = $CameraController/Camera3D
@onready var tp_camera: Camera3D = $CameraController/ThirdPersonCamera3D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var animation_tree: AnimationTree = $AnimationTree
@onready var camera_animation_player: AnimationPlayer = $CameraAnimationPlayer
@onready var game_body: CharacterBody3D = $GameController
@onready var crouch_shapecast: ShapeCast3D = %CrouchShapeCast3D

var is_authority: bool:
	get: return !NetworkTransport.is_server && _owner_id == NetworkClient.id

var is_replaying_inputs: bool:
	get: return _net.is_replaying_inputs

var last_grounded_height: float = 0.0

var context := Enums.IntegrationContext.VISUAL
var input := PlayerInputContext.new()

# Networking state container. Phase 3: pure data store; Phase 4 will pull
# gather/simulate/apply hooks into it.
var _net := NetPredictor.new()

# Proxy properties so state machines and external scripts keep reading
# `player.game_*` while the data lives on NetPredictor.
var game_transform: Transform3D:
	get: return _net.game_transform
	set(v): _net.game_transform = v
var game_position: Vector3:
	get: return _net.game_transform.origin
	set(v): _net.game_position = v
var game_velocity: Vector3:
	get: return _net.game_velocity
	set(v): _net.game_velocity = v
var game_movement_state_id: int:
	get: return _net.game_movement_state_id
	set(v): _net.game_movement_state_id = v
var game_sequence_id: int:
	get: return _net.game_sequence_id
	set(v): _net.game_sequence_id = v

var _owner_id: int

# movement parameters
var _speed := 0.0
var _acceleration := 0.0

# x and y mouse input for accumulating mouse movement
var _x_mouse_input: float
var _y_mouse_input: float

# look absolute for camera and player rotation
var _look_abs := Vector2.ZERO
var _free_look_abs := Vector2.ZERO

# used only for toggle crouch, if not using toggle crouch always false
var _is_toggle_crouched := false
var _is_toggle_peeked_left := false
var _is_toggle_peeked_right := false

func _enter_tree() -> void:
	if _net.get_parent() == null:
		_net.name = "NetPredictor"
		_net.schema = PlayerSchema.build()
		_net.owner_id = _owner_id
		_net.entity_id = _owner_id
		_net.state_snapshot_received.connect(_on_state_snapshot_received)
		add_child(_net)

	NetworkServer.handle_player_input.connect(server_handle_player_input)


func _exit_tree() -> void:
	NetworkServer.handle_player_input.disconnect(server_handle_player_input)


func _ready():
	print("Player #%d spawned, named %s!" % [_owner_id, name])

	add_collision_exception_with(game_body)
	game_body.add_collision_exception_with(self)
	crouch_shapecast.add_exception(self)

	global_position = Constants.MAP_SPAWN
	game_position = global_position
	game_body.global_position = game_position
	
	if is_authority:
		camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		call_deferred("remove_child", %GUI)
		call_deferred("remove_child", $EscapeMenu)
		camera.call_deferred("remove_child", $CameraController/Camera3D/ReflectionProbe)
		if not NetworkTransport.is_server:
			call_deferred("remove_child", $GameController)


func _unhandled_input(event):
	if !is_authority:
		return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_x_mouse_input += -event.relative.x * MOUSE_SENSITIVITY
		_y_mouse_input += -event.relative.y * MOUSE_SENSITIVITY


func _input(event: InputEvent) -> void:
	if !is_authority:
		return
	
	if event.is_action_pressed("toggle_camera"):
		if camera.current:
			tp_camera.make_current()
		else:
			camera.make_current() 


func _physics_process(delta: float) -> void:
	if is_authority:
		_client_authority_physics_step(delta)
	elif NetworkTransport.is_server:
		_server_physics_step(delta)
	else:
		_client_remote_physics_step(delta)


var _prev_server_input: PlayerInputPacket = null
func _server_physics_step(delta: float) -> void:
	var frames := _net.server_input_queue.consume()
	
	if frames.is_empty():
		#push_warning("No input frames to consume")
		return

	for frame in frames:
		assert(frame.packet is PlayerInputPacket, "Packet is not a PlayerInputPacket")
		assert(frame.delta > 0.0, "Delta is not positive")
		input.prev_input_packet = _prev_server_input
		_prev_server_input = frame.packet
		input.input_packet = frame.packet
		update_camera(input.input_packet.look_abs)
		context = Enums.IntegrationContext.GAME
		game_transform.basis = Basis.from_euler(Vector3(0, input.input_packet.look_abs.y, 0))
		%MovementStateMachine.run_logic(frame.delta)
		%PeekStateMachine.run_logic(frame.delta)
		context = Enums.IntegrationContext.VISUAL
		%MovementStateMachine.sync_visual()
		%MovementStateMachine.run_visual(frame.delta)
		%PeekStateMachine.sync_visual()
		%PeekStateMachine.run_visual(frame.delta)
		global_position = game_position
		velocity = game_velocity

	# Sync sim output into shadow_state, then broadcast the schema-driven
	# NetStatePacket. PlayerStatePacket retired in phase 6b.4.
	_sync_shadow_from_sim()
	_net.server_broadcast_snapshot(frames[-1].packet.sequence_id)


# After server-side sim writes into game_*/state-machines, mirror those into
# shadow_state so the NetStatePacket encoder reads from one place. shadow_state
# is now the authoritative server view of the entity.
func _sync_shadow_from_sim() -> void:
	var s: PlayerState = _net.shadow_state
	if s == null:
		return
	s.pos = game_position
	s.velocity = game_velocity
	s.look = input.input_packet.look_abs
	s.movement_state = %MovementStateMachine.get_logic_state_id()
	s.crouch_progress = %MovementStateMachine.crouch_progress
	s.prone_progress = %MovementStateMachine.prone_progress
	s.peek_state = %PeekStateMachine.get_logic_state_id()
	s.peek_progress = %PeekStateMachine.peek_progress


var _prev_client_input: PlayerInputPacket = null
func _client_authority_physics_step(delta: float) -> void:
	# camera movement integration
	var look := _free_look_abs if Input.is_action_pressed("free_look") else _look_abs
	look.x += _y_mouse_input * delta
	look.x = clamp(look.x, TILT_LOWER_LIMIT, TILT_UPPER_LIMIT)
	look.y += _x_mouse_input * delta
	
	if not Input.is_action_pressed("free_look"):
		_look_abs = look
		_free_look_abs = _free_look_abs.lerp(Vector2.ZERO, 0.5 * delta)
	else:
		_free_look_abs = look

	var player_input := PlayerInputPacket.new()
	player_input.sequence_id = _net.input_sequence.next()
	player_input.timestamp_us = Time.get_ticks_usec()
	player_input.move_forward_backward = Input.get_axis("move_forward", "move_backward")
	player_input.move_left_right = Input.get_axis("move_left", "move_right")
	if TOGGLE_PEEK:
		var left := Input.is_action_just_pressed("peek_left")
		var right := Input.is_action_just_pressed("peek_right")
		if left and right:
			_is_toggle_peeked_left = false
			_is_toggle_peeked_right = false
		elif left:
			_is_toggle_peeked_left = not _is_toggle_peeked_left
			_is_toggle_peeked_right = false
		elif right:
			_is_toggle_peeked_right = not _is_toggle_peeked_right
			_is_toggle_peeked_left = false
		player_input.peek_left_right = float(_is_toggle_peeked_right) - float(_is_toggle_peeked_left)
	else:
		player_input.peek_left_right = Input.get_axis("peek_left", "peek_right")
	player_input.look_abs = _look_abs
	player_input.jump = Input.is_action_pressed("jump")
	if TOGGLE_CROUCH:
		if Input.is_action_just_pressed("crouch"): _is_toggle_crouched = !_is_toggle_crouched
		player_input.crouch = _is_toggle_crouched
	else:
		player_input.crouch = Input.is_action_pressed("crouch")
	player_input.sprint = Input.is_action_pressed("sprint")
	player_input.prone = Input.is_action_pressed("prone")
	player_input.last_received_tick = _net.last_received_tick
	_net.unacked_inputs.insert(player_input.sequence_id, -1, player_input.timestamp_us, player_input)

	_net.input_redundancy_ring.append(player_input)
	if _net.input_redundancy_ring.size() > _net.INPUT_REDUNDANCY:
		_net.input_redundancy_ring.pop_front()
	for redundant_input in _net.input_redundancy_ring:
		NetworkTransport.send_packet(redundant_input.to_payload())

	input.prev_input_packet = _prev_client_input
	_prev_client_input = player_input
	input.input_packet = player_input

	# run prediction on authoritative copy
	context = Enums.IntegrationContext.GAME
	game_transform.basis = Basis.from_euler(Vector3(0, input.input_packet.look_abs.y, 0))
	%MovementStateMachine.run_logic(delta)
	%PeekStateMachine.run_logic(delta)

	context = Enums.IntegrationContext.VISUAL
	update_camera(input.input_packet.look_abs)
	%MovementStateMachine.sync_visual()
	%MovementStateMachine.run_visual(delta)
	%PeekStateMachine.sync_visual()
	%PeekStateMachine.run_visual(delta)

	_client_authority_reconcile_visual_state(delta)


func _client_remote_physics_step(delta: float) -> void:
	var now_us := Time.get_ticks_usec()
	var interpolation_pair := _net.player_state_buffer.get_interpolation_pair(now_us);
	if not interpolation_pair.is_valid:
		return

	if interpolation_pair.to == null:
		var s: PlayerState = interpolation_pair.from as PlayerState
		global_position = s.pos
		velocity = s.velocity
		update_camera(s.look)
		%MovementStateMachine.set_visual_state_by_id(s.movement_state)
		assert(not (s.crouch_progress > 0.0 and s.prone_progress > 0.0), "shadow state should not have non-zero crouch AND prone progress")
		if s.crouch_progress > 0.0:
			%MovementStateMachine._visual_state.progress = s.crouch_progress
		elif s.prone_progress > 0.0:
			%MovementStateMachine._visual_state.progress = s.prone_progress
		%MovementStateMachine.run_visual(delta)
		%PeekStateMachine.set_visual_state_by_id(s.peek_state)
		if s.peek_progress != 0.0:
			%PeekStateMachine._visual_state.progress = s.peek_progress
		%PeekStateMachine.run_visual(delta)
	else:
		var from_s: PlayerState = interpolation_pair.from as PlayerState
		var to_s: PlayerState = interpolation_pair.to as PlayerState
		var alpha := interpolation_pair.alpha
		var blended_pos := from_s.pos.lerp(to_s.pos, alpha)
		var blended_vel := from_s.velocity.lerp(to_s.velocity, alpha)
		var blended_look := from_s.look.lerp(to_s.look, alpha)
		if interpolation_pair.extrapolation_s > 0.0:
			blended_pos += blended_vel * interpolation_pair.extrapolation_s
		global_position = blended_pos
		velocity = blended_vel
		update_camera(blended_look)
		%MovementStateMachine.set_visual_state_by_id(from_s.movement_state if alpha < 0.5 else to_s.movement_state)
		if %MovementStateMachine._visual_state.name == &"CrouchMovementState":
			%MovementStateMachine._visual_state.progress = lerp(from_s.crouch_progress, to_s.crouch_progress, alpha)
		elif %MovementStateMachine._visual_state.name == &"ProneMovementState":
			%MovementStateMachine._visual_state.progress = lerp(from_s.prone_progress, to_s.prone_progress, alpha)
		%MovementStateMachine.run_visual(delta)
		%PeekStateMachine.set_visual_state_by_id(from_s.peek_state if alpha < 0.5 else to_s.peek_state)
		if %PeekStateMachine._visual_state.name == &"PeekState":
			%PeekStateMachine._visual_state.progress = lerp(from_s.peek_progress, to_s.peek_progress, alpha)
		%PeekStateMachine.run_visual(delta)


# NetPredictor fires this after decoding an inbound NetStatePacket. is_authority
# clients ack inputs + replay; remote-proxy clients buffer a duplicate of the
# state for interpolation. Server is_authority is false and is_server is true,
# so neither branch runs server-side.
func _on_state_snapshot_received(state: PlayerState, last_input_seq: int, _new_tick: int) -> void:
	if is_authority:
		_net.last_received_tick = _new_tick
		_net.unacked_inputs.prune_up_to(last_input_seq)
		if PacketSequence.is_newer(last_input_seq, game_sequence_id):
			_client_authority_update_game_state(state, last_input_seq)
	elif not NetworkTransport.is_server:
		# duplicate() so the buffer doesn't share storage with the in-place
		# decoded shadow_state (next packet would clobber buffered entries).
		_net.player_state_buffer.insert(last_input_seq, Time.get_ticks_usec(), NetTimeline.server_now_us(), state.duplicate())


func _client_authority_update_game_state(state: PlayerState, last_input_seq: int) -> void:
	var delta := NetTimeline.tick_delta()
	game_sequence_id = last_input_seq
	game_transform.origin = state.pos
	game_transform.basis = Basis.from_euler(Vector3(0, state.look.y, 0))
	game_velocity = state.velocity
	game_movement_state_id = state.movement_state

	context = Enums.IntegrationContext.GAME
	%MovementStateMachine.set_logic_state_by_id(state.movement_state)
	%PeekStateMachine.set_logic_state_by_id(state.peek_state)

	_net.is_replaying_inputs = true
	var inputs := _net.unacked_inputs.get_starting_at(game_sequence_id)
	for i in range(1, inputs.size()):
		input.prev_input_packet = inputs[i - 1]
		input.input_packet = inputs[i]
		game_transform.basis = Basis.from_euler(Vector3(0, input.input_packet.look_abs.y, 0))
		%MovementStateMachine.run_logic(delta)
		%PeekStateMachine.run_logic(delta)
	_net.is_replaying_inputs = false

	context = Enums.IntegrationContext.VISUAL
	_client_authority_reconcile_visual_state(delta)


# TODO: reconcile state_progress?
func _client_authority_reconcile_visual_state(delta: float) -> void:
	var delta_pos := game_position - global_position
	var horizontal_err := Vector2(delta_pos.x, delta_pos.z)
	var horizontal_err_mag := horizontal_err.length()
	var vertical_err := absf(delta_pos.y)

	var delta_vel := game_velocity - velocity
	var horizontal_vel_err := Vector2(delta_vel.x, delta_vel.z)
	var horizontal_vel_err_mag := horizontal_vel_err.length()

	reconcile_network_debug.emit(delta_pos, delta_vel, _net.unacked_inputs)

	var horiz := _net.schema.find_correction(&"horizontal")
	var vert := _net.schema.find_correction(&"vertical")
	var vel_h := _net.schema.find_correction(&"velocity_horizontal")

	# Snap or lerp to horizontal game position
	if horizontal_err_mag > horiz.snap_threshold:
		global_position.x = game_position.x
		global_position.z = game_position.z
	else:
		var pos_alpha := _net.correction_alpha(
			delta,
			horizontal_err_mag,
			horiz.snap_threshold,
			horiz.smooth_rate,
			horiz.deadband,
		)
		global_position.x = lerp(global_position.x, game_position.x, pos_alpha)
		global_position.z = lerp(global_position.z, game_position.z, pos_alpha)

	# Snap or lerp to vertical game position
	if vertical_err > vert.snap_threshold:
		global_position.y = game_position.y
		velocity.y = game_velocity.y
	else:
		var vert_alpha := _net.correction_alpha(
			delta,
			vertical_err,
			vert.snap_threshold,
			vert.smooth_rate,
			vert.deadband,
		)
		global_position.y = lerp(global_position.y, game_position.y, vert_alpha)
		velocity.y = lerp(velocity.y, game_velocity.y, vert_alpha)

	# lerp to horizontal game velocity
	var vel_alpha := _net.correction_alpha(
		delta,
		horizontal_vel_err_mag,
		vel_h.snap_threshold,
		vel_h.smooth_rate,
		vel_h.deadband,
	)
	velocity.x = lerp(velocity.x, game_velocity.x, vel_alpha)
	velocity.z = lerp(velocity.z, game_velocity.z, vel_alpha)


func set_parameters(speed: float, acceleration: float) -> void:
	_speed = speed
	_acceleration = acceleration


func on_floor(ctx: Enums.IntegrationContext) -> bool:
	if ctx == Enums.IntegrationContext.VISUAL:
		return is_on_floor()
	else:
		var _on_floor := game_body.is_on_floor()
		if _on_floor:
			last_grounded_height = game_body.global_position.y
		return _on_floor


# persistent local vars for performance
var _player_rotation: Vector3 = Vector3.ZERO
var _camera_rotation: Vector3 = Vector3.ZERO
func update_camera(look_abs: Vector2) -> void:
	_player_rotation.y = look_abs.y
	_camera_rotation.x = look_abs.x
	if is_authority:
		var free_look := Vector3(_free_look_abs.x, _free_look_abs.y, 0.0)
		print(free_look)
		$CameraController.basis = Basis.from_euler(free_look)
	
	camera.transform.basis = Basis.from_euler(_camera_rotation)
	camera.rotation.z = 0
	tp_camera.transform.basis = Basis.from_euler(_camera_rotation)
	tp_camera.rotation.z = 0
	
	global_transform.basis = Basis.from_euler(_player_rotation)

	# reset input integration
	_x_mouse_input = 0.0
	_y_mouse_input = 0.0


func update_gravity(delta: float, ctx: Enums.IntegrationContext) -> void:
	if ctx == Enums.IntegrationContext.VISUAL:
		velocity += get_gravity() * delta
	else:
		game_velocity += get_gravity() * delta


func update_movement(delta: float, ctx: Enums.IntegrationContext) -> void:
	var _input_dir := Vector2(
		input.input_packet.move_left_right,
		input.input_packet.move_forward_backward,
	)
	
	var _basis := transform.basis if ctx == Enums.IntegrationContext.VISUAL else game_transform.basis
	var wish_dir := (_basis * Vector3(_input_dir.x, 0, _input_dir.y)).normalized()

	var grounded := on_floor(ctx)
	var vel := velocity if ctx == Enums.IntegrationContext.VISUAL else game_velocity
	var horizontal_vel := Vector3(vel.x, 0, vel.z)
	var speed := horizontal_vel.length()
	var friction := FRICTION if grounded else AIR_FRICTION

	if not is_zero_approx(speed):
		var drop := speed * friction * delta
		horizontal_vel *= maxf(speed - drop, 0.0) / speed

	if not wish_dir.is_zero_approx():
		var curr_speed_in_wish_dir := horizontal_vel.dot(wish_dir)
		var add_speed := clampf(_speed - curr_speed_in_wish_dir, 0.0, _acceleration * delta)
		horizontal_vel += wish_dir * add_speed
	elif grounded and speed < STOP_SPEED:
		horizontal_vel = Vector3.ZERO
		
	if ctx == Enums.IntegrationContext.VISUAL:
		velocity.x = horizontal_vel.x
		velocity.z = horizontal_vel.z
	else:
		game_velocity.x = horizontal_vel.x
		game_velocity.z = horizontal_vel.z

	# if direction:
	# 	if ctx == Enums.IntegrationContext.VISUAL:
	# 		velocity.x = lerp(velocity.x, direction.x * _speed, _acceleration)
	# 		velocity.z = lerp(velocity.z, direction.z * _speed, _acceleration)
	# 	else:
	# 		game_velocity.x = lerp(game_velocity.x, direction.x * _speed, _acceleration)
	# 		game_velocity.z = lerp(game_velocity.z, direction.z * _speed, _acceleration)
	# else:
	# 	# TODO: fix this logic, axes come to rest at different rates; not at same time, feels clunky
	# 	if ctx == Enums.IntegrationContext.VISUAL:
	# 		velocity.x = move_toward(velocity.x, 0, _deceleration)
	# 		velocity.z = move_toward(velocity.z, 0, _deceleration)
	# 	else:
	# 		game_velocity.x = move_toward(game_velocity.x, 0, _deceleration)
	# 		game_velocity.z = move_toward(game_velocity.z, 0, _deceleration)


const MAX_SLIDES := 4 # Engine.max_physics_steps_per_frame

func update_velocity(ctx: Enums.IntegrationContext) -> void:
	if ctx == Enums.IntegrationContext.VISUAL:
		move_and_slide()
	else:
		game_body.velocity = game_velocity
		game_body.global_transform = game_transform

		game_body.move_and_slide()

		game_velocity = game_body.velocity
		game_transform = game_body.global_transform


func server_handle_player_input(peer_id: int, input_packet: PlayerInputPacket) -> void:
	# server only
	assert(NetworkTransport.is_server)

	# not owner
	if peer_id != _owner_id:
		return

	_net.server_input_queue.enqueue(input_packet.sequence_id, input_packet.timestamp_us, input_packet)


func despawn() -> void:
	print("I'm (%s) being despawned!" % name)
	if is_authority: get_tree().change_scene_to_file(Constants.MAIN_MENU_SCENE_PATH)
