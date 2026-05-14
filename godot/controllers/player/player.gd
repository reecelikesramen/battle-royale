class_name PlayerController
extends CharacterBody3D

# PlayerController hosts NetPredictor's hook callbacks. The NetPredictor child
# node (authored in player.tscn) owns the physics tick and per-role dispatch
# (authority / server / proxy). The framework now also owns:
#   - correction smoothing (driven by schema.corrections; render_state flows
#     into _apply_state),
#   - server-side input fan-out (NetPredictor subscribes to
#     NetServer.handle_player_input itself and filters by owner_id).
# What stays here: input gathering, the dual-context (VISUAL/GAME) state
# machines + their movement helpers, camera glue, and proxy interp wiring.

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
	get: return !NetSession.is_server && _owner_id == NetClient.id

var is_replaying_inputs: bool:
	get: return _net.is_replaying_inputs

var last_grounded_height: float = 0.0

var context := Enums.IntegrationContext.VISUAL
var input := PlayerInputContext.new()

# NetPredictor child node owns the tick. Authored in player.tscn so the schema
# is inspector-set and the framework lifecycle attaches automatically. Hooks
# below are duck-typed by NetPredictor via has_method().
@onready var _net: NetPredictor = $NetPredictor

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
	# NetPredictor is a static .tscn child with schema preset; we only fill in
	# the per-spawn identity. Parent _enter_tree fires before the child's
	# _ready, so the predictor sees these values when it registers itself with
	# NetReplication. Spawner sets _owner_id before add_child(player).
	var net: NetPredictor = $NetPredictor
	net.owner_id = _owner_id
	net.entity_id = _owner_id


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
		if not NetSession.is_server:
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


# === NetPredictor hooks ===========================================================
# Each hook is invoked by NetPredictor via has_method() duck-typing. Order
# inside _physics_process is: gather -> simulate -> apply_state -> visualize
# -> apply_corrections (authority); consume queue -> simulate per frame ->
# apply_state -> broadcast (server); proxy_apply (proxy).

func _gather_command(delta: float) -> PlayerInputPacket:
	# Integrate accumulated mouse delta into look. _free_look_abs decays back to
	# zero when free-look is released so the camera resnaps.
	var look := _free_look_abs if Input.is_action_pressed("free_look") else _look_abs
	look.x += _y_mouse_input * delta
	look.x = clamp(look.x, TILT_LOWER_LIMIT, TILT_UPPER_LIMIT)
	look.y += _x_mouse_input * delta

	if not Input.is_action_pressed("free_look"):
		_look_abs = look
		_free_look_abs = _free_look_abs.lerp(Vector2.ZERO, 0.5 * delta)
	else:
		_free_look_abs = look

	var cmd := PlayerInputPacket.new()
	cmd.sequence_id = _net.input_sequence.next()
	cmd.timestamp_us = Time.get_ticks_usec()
	cmd.move_forward_backward = Input.get_axis("move_forward", "move_backward")
	cmd.move_left_right = Input.get_axis("move_left", "move_right")
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
		cmd.peek_left_right = float(_is_toggle_peeked_right) - float(_is_toggle_peeked_left)
	else:
		cmd.peek_left_right = Input.get_axis("peek_left", "peek_right")
	cmd.look_abs = _look_abs
	cmd.jump = Input.is_action_pressed("jump")
	if TOGGLE_CROUCH:
		if Input.is_action_just_pressed("crouch"): _is_toggle_crouched = !_is_toggle_crouched
		cmd.crouch = _is_toggle_crouched
	else:
		cmd.crouch = Input.is_action_pressed("crouch")
	cmd.sprint = Input.is_action_pressed("sprint")
	cmd.prone = Input.is_action_pressed("prone")
	cmd.last_received_tick = _net.last_received_tick
	return cmd


# Advance shadow_state forward by one cmd. State machines read player.input for
# edge detection, so we bind the context (prev / current) before stepping.
# Used in authority live ticks, server ticks, and replay after snapshot ack —
# must therefore be idempotent for a given (state, cmd) pair.
func _simulate(state: PlayerState, cmd: PlayerInputPacket, delta: float) -> void:
	input.prev_input_packet = _net.previous_cmd
	input.input_packet = cmd

	context = Enums.IntegrationContext.GAME
	game_transform.basis = Basis.from_euler(Vector3(0, cmd.look_abs.y, 0))
	%MovementStateMachine.run_logic(delta)
	%PeekStateMachine.run_logic(delta)

	state.pos = game_position
	state.velocity = game_velocity
	state.look = cmd.look_abs
	state.movement_state = %MovementStateMachine.get_logic_state_id()
	state.peek_state = %PeekStateMachine.get_logic_state_id()
	state.crouch_progress = %MovementStateMachine.crouch_progress
	state.prone_progress = %MovementStateMachine.prone_progress
	state.peek_progress = %PeekStateMachine.peek_progress


# Snap the sim representation (game_* + state machine logic pointers) to
# state ahead of replay. Without this, replay's first _simulate call would
# advance forward from the last predicted tick instead of the freshly-acked
# server tick.
func _load_simulation_state(state: PlayerState) -> void:
	game_transform.origin = state.pos
	game_transform.basis = Basis.from_euler(Vector3(0, state.look.y, 0))
	game_velocity = state.velocity
	game_movement_state_id = state.movement_state

	context = Enums.IntegrationContext.GAME
	%MovementStateMachine.set_logic_state_by_id(state.movement_state)
	%PeekStateMachine.set_logic_state_by_id(state.peek_state)


# Visual-side alignment from shadow. On the server this is the only scene
# write (no smoothing, no separate visual physics). On the client authority,
# we *do not* touch pos/velocity here — visual physics runs in _visualize and
# corrections in _apply_corrections will pull the scene toward shadow. Camera
# + state-machine sync_visual fires here so visual_physics sees the updated
# visual state when it runs next.
func _apply_state(state: PlayerState) -> void:
	if NetSession.is_server:
		global_position = state.pos
		velocity = state.velocity
		%MovementStateMachine.sync_visual()
		%PeekStateMachine.sync_visual()
		return
	context = Enums.IntegrationContext.VISUAL
	update_camera(state.look)
	%MovementStateMachine.sync_visual()
	%PeekStateMachine.sync_visual()


# Animation / visual SM physics. Runs after _apply_state; reads input bound by
# _simulate. Skipped on the server (headless).
func _visualize(delta: float, _state: PlayerState) -> void:
	if NetSession.is_server:
		return
	context = Enums.IntegrationContext.VISUAL
	%MovementStateMachine.run_visual(delta)
	%PeekStateMachine.run_visual(delta)


# Bridge scene -> typed Resource for the framework's corrections pass. Called
# *after* visual physics has mutated global_position / velocity, so render
# captures the visual-integrated state. The framework then lerps this toward
# shadow_state per schema.corrections, and we get the smoothed result back via
# _apply_corrections.
func _capture_render_state(state: PlayerState) -> void:
	state.pos = global_position
	state.velocity = velocity
	state.look = _look_abs
	state.movement_state = %MovementStateMachine.get_logic_state_id()
	state.peek_state = %PeekStateMachine.get_logic_state_id()
	state.crouch_progress = %MovementStateMachine.crouch_progress
	state.prone_progress = %MovementStateMachine.prone_progress
	state.peek_progress = %PeekStateMachine.peek_progress


# Write the framework-smoothed render_state back to the scene. Symmetric to
# _capture_render_state. Skipped on the server (no smoothing path there).
# Emits the debug signal here so subscribers see the same pre/post deltas the
# old hand-coded loop produced.
func _apply_corrections(state: PlayerState) -> void:
	if NetSession.is_server:
		return
	var shadow: PlayerState = _net.shadow_state as PlayerState
	if shadow != null:
		reconcile_network_debug.emit(
				shadow.pos - global_position,
				shadow.velocity - velocity,
				_net.unacked_inputs)
	global_position = state.pos
	velocity = state.velocity


# Remote proxy: framework has already fetched the interp pair from the state
# buffer. We blend pos / velocity / look, then drive visual SMs via state ids
# + progress fields. extrapolation_s > 0 when the buffer is empty in the
# future direction.
func _proxy_apply(from_state, to_state, alpha: float, extrapolation_s: float, delta: float) -> void:
	if to_state == null:
		var s: PlayerState = from_state as PlayerState
		global_position = s.pos
		velocity = s.velocity
		update_camera(s.look)
		%MovementStateMachine.set_visual_state_by_id(s.movement_state)
		# Only Crouch/Prone states have `progress`. Gate on visual state name
		# rather than `progress > 0.0` so quantization noise can't push a write
		# onto a state with no progress field.
		var msm_visual: StringName = %MovementStateMachine._visual_state.name
		if msm_visual == &"CrouchMovementState":
			%MovementStateMachine._visual_state.progress = s.crouch_progress
		elif msm_visual == &"ProneMovementState":
			%MovementStateMachine._visual_state.progress = s.prone_progress
		%MovementStateMachine.run_visual(delta)
		%PeekStateMachine.set_visual_state_by_id(s.peek_state)
		# Only PeekState carries a `progress` field; writing to NotPeekState's
		# script would explode. QUANT8 [-1,1] on peek_progress also can't
		# encode 0 exactly (quant noise hovers ~±0.004), so the legacy
		# `!= 0.0` guard isn't safe — gate on the state itself.
		if %PeekStateMachine._visual_state.name == &"PeekState":
			%PeekStateMachine._visual_state.progress = s.peek_progress
		%PeekStateMachine.run_visual(delta)
	else:
		var from_s: PlayerState = from_state as PlayerState
		var to_s: PlayerState = to_state as PlayerState
		var blended_pos := from_s.pos.lerp(to_s.pos, alpha)
		var blended_vel := from_s.velocity.lerp(to_s.velocity, alpha)
		var blended_look := from_s.look.lerp(to_s.look, alpha)
		if extrapolation_s > 0.0:
			blended_pos += blended_vel * extrapolation_s
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


# === Movement helpers (called by state machines) =================================

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


func despawn() -> void:
	print("I'm (%s) being despawned!" % name)
	if is_authority: get_tree().change_scene_to_file(Constants.MAIN_MENU_SCENE_PATH)
