extends CharacterBody3D

@onready var camera: Camera3D = $CameraController/Camera3D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var crouch_shapecast: ShapeCast3D = $CrouchShapeCast3D
@onready var line_of_sight_mesh: Node3D = $LineOfSightMesh

@export var SPEED = 5.0
@export var JUMP_VELOCITY = 4.5
@export var TILT_LOWER_LIMIT = deg_to_rad(-90.0)
@export var TILT_UPPER_LIMIT = deg_to_rad(90.0)
@export var MOUSE_SENSITIVITY = 0.5
@export var TOGGLE_CROUCH: bool = true
@export_range(5, 10, 0.1) var CROUCH_SPEED = 7.0

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

func _input(event):
	if !is_authority: return

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
	if !is_authority: return

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
	if !is_authority: return

	# Add the gravity.
	if not is_on_floor():
		velocity += get_gravity() * delta
		
	_update_camera(delta)

	# Handle jump.
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Get the input direction and handle the movement/deceleration.
	# As good practice, you should replace UI actions with custom gameplay actions.
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()
	if direction:
		velocity.x = direction.x * SPEED
		velocity.z = direction.z * SPEED
	else:
		velocity.x = move_toward(velocity.x, 0, SPEED)
		velocity.z = move_toward(velocity.z, 0, SPEED)
	
	move_and_slide()
	
	LowLevelNetworkHandler.send_packet(GameStatePacket.create(_owner_id, position, _camera_rotation.x, _player_rotation.y, _is_crouching))


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


func get_sightline_unit_vector() -> Vector3:
	var camera_global_transform: Transform3D = camera.global_transform
	var sightline_vector: Vector3 = -camera_global_transform.basis.z
	return sightline_vector


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
	if is_authority: get_tree().change_scene_to_file("res://main_menu.tscn")
