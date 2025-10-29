extends CharacterBody3D

const SPEED = 5.0
const JUMP_VELOCITY = 4.5

@export var TILT_LOWER_LIMIT = deg_to_rad(-90.0)
@export var TILT_UPPER_LIMIT = deg_to_rad(90.0)
@export var CAMERA_CONTROLLER: Camera3D
@export var MOUSE_SENSITIVITY = 0.5
@export var ANIMATION_PLAYER: AnimationPlayer
@export var TOGGLE_CROUCH: bool = true
@export var CROUCH_SHAPECAST: Node3D
@export_range(5, 10, 0.1) var CROUCH_SPEED = 7.0

var _mouse_input: bool = false
var _mouse_rotation: Vector3 = Vector3()
var _rotation_input: float
var _tilt_input: float
var _player_rotation: Vector3
var _camera_rotation: Vector3
var _is_crouching: bool = false
var _do_uncrouch: bool = false

func _input(event):
	if event.is_action_pressed("exit"):
		get_tree().quit()
	if event.is_action_pressed("crouch") and TOGGLE_CROUCH:
		toggle_crouch()
	if event.is_action_pressed("crouch") and !TOGGLE_CROUCH:
		crouch(true)
	elif event.is_action_released("crouch") and !TOGGLE_CROUCH:
		crouch(false)

func _ready():
	if !TestGlobal.isServer():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	#CROUCH_SHAPECAST.add_excep
	
func _unhandled_input(event):
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
	
	CAMERA_CONTROLLER.transform.basis = Basis.from_euler(_camera_rotation)
	CAMERA_CONTROLLER.rotation.z = 0
	
	global_transform.basis = Basis.from_euler(_player_rotation)
	
	_rotation_input = 0.0
	_tilt_input = 0.0

func _physics_process(delta: float) -> void:
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
	
func crouch(state: bool):
	print("Colliding:", CROUCH_SHAPECAST.is_colliding())
	match state:
		true:
			ANIMATION_PLAYER.play("Crouch", -1, CROUCH_SPEED)
			_do_uncrouch = false
		false:
			if CROUCH_SHAPECAST.is_colliding():
				_do_uncrouch = true
			else:
				ANIMATION_PLAYER.play("Crouch", -1, -CROUCH_SPEED, true)

func toggle_crouch():
	print("Colliding:", CROUCH_SHAPECAST.is_colliding())
	if _is_crouching and CROUCH_SHAPECAST.is_colliding() == false:
		crouch(true)
	elif !_is_crouching:
		crouch(false)
	print(_is_crouching)

func _on_animation_player_animation_started(anim_name: StringName) -> void:
	if anim_name == "Crouch":
		_is_crouching = !_is_crouching


func _on_shape_cast_3d_collision_state_changed(is_colliding: bool) -> void:
	print(is_colliding)
	if !is_colliding and _do_uncrouch:
		ANIMATION_PLAYER.play("Crouch", -1, -CROUCH_SPEED, true)
