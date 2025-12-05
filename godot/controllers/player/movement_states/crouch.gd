extends MovementState

@export var SPEED := 3.0
@export var ACCELERATION := 50.0
@export_range(1, 6, 0.1) var CROUCH_SPEED := 4.0
@export_range(1, 6, 0.1) var UNCROUCH_SPEED := 6.0

const CROUCH_ANIM := &"Crouch"
const RESET_ANIM := &"RESET"

var progress := 0.0

var _wants_to_uncrouch := false
var _crouch_anim_length := 0.0

var _crouch_shapecast: ShapeCast3D:
	get: return player.crouch_shapecast

func _ready() -> void:
	await owner.ready
	var anim := animation_player.get_animation(CROUCH_ANIM)
	if anim:
		_crouch_anim_length = anim.length


func logic_enter() -> void:
	player.set_parameters(SPEED, ACCELERATION)
	if not player.is_replaying_inputs:
		progress = 0.0
		_wants_to_uncrouch = false
	# if player.is_authority: print("logic enter, progress: ", progress)


func visual_exit() -> void:
	if animation_player.has_animation(RESET_ANIM):
		animation_player.play(RESET_ANIM)
	else:
		animation_player.stop()
	animation_player.speed_scale = 1.0
	# if player.is_authority: print("visual exit, progress: ", progress)


func logic_physics(delta: float) -> void:
	player.update_gravity(delta, Enums.IntegrationContext.GAME)
	player.update_movement(delta, Enums.IntegrationContext.GAME)
	player.update_velocity(Enums.IntegrationContext.GAME)

	if player.is_replaying_inputs:
		return
	
	if _wants_to_uncrouch and not _crouch_shapecast.is_colliding():
		progress -= delta * UNCROUCH_SPEED
	else:
		progress += delta * CROUCH_SPEED
		
	
	progress = clampf(progress, 0.0, _crouch_anim_length)
	# if player.is_authority: print("logic physics, progress: ", progress)


func logic_transitions() -> void:
	_wants_to_uncrouch = !player.input.is_crouching()
	
	# TODO: make work with crouch jump
	if not player.on_floor(Enums.IntegrationContext.GAME):
		_wants_to_uncrouch = true

	if _wants_to_uncrouch and progress <= 0.0:
		# Block uncrouch if hitting ceiling
		if _crouch_shapecast and _crouch_shapecast.is_colliding():
			return
			
		transition.emit(&"IdleMovementState")


func visual_physics(delta: float) -> void:
	if !is_remote_player:
		player.update_gravity(delta, Enums.IntegrationContext.VISUAL)
		player.update_movement(delta, Enums.IntegrationContext.VISUAL)
		player.update_velocity(Enums.IntegrationContext.VISUAL)
		
	# Sync animation to logic progress
	if animation_player.current_animation != CROUCH_ANIM:
		animation_player.play(CROUCH_ANIM)
	animation_player.seek(progress, true)
	# if player.is_authority: print("visual physics, progress: ", progress)
