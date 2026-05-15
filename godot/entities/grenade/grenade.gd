@tool
class_name Grenade extends RigidBody3D

const STATE_FLYING := 0
const STATE_EXPLODING := 1
const STATE_DONE := 2

const EXPLOSION_DURATION := 0.4

@onready var _net: NetPredictor = $NetPredictor
@onready var _shape: CollisionShape3D = $CollisionShape3D
@onready var _body: MeshInstance3D = $Body
@onready var _explosion: MeshInstance3D = $Explosion


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if not NetSession.is_server:
		# Clients are pure render targets — engine never simulates. Collision
		# shape stays disabled so the local thrower's visual move_and_slide and
		# any other peer's local physics never bump off the replicated grenade
		# (which would cause a visual divergence and a reconcile snap).
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		_shape.disabled = true


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _net.shadow_state == null:
		return
	if not NetSession.is_server:
		return
	var s: GrenadeState = _net.shadow_state as GrenadeState
	match s.state:
		STATE_FLYING:
			s.pos = global_position
			s.rotation_quat = global_basis.get_rotation_quaternion()
			s.fuse_remaining -= delta
			if s.fuse_remaining <= 0.0:
				s.fuse_remaining = 0.0
				s.state = STATE_EXPLODING
				s.explosion_progress = 0.0
				freeze = true
				freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		STATE_EXPLODING:
			s.explosion_progress += delta / EXPLOSION_DURATION
			if s.explosion_progress >= 1.0:
				s.explosion_progress = 1.0
				s.state = STATE_DONE
		STATE_DONE:
			pass
	_net.server_broadcast_snapshot(0)
	_render_visuals(s)
	if s.state == STATE_DONE:
		queue_free()


func _proxy_apply(from_state: NetState, to_state: NetState, alpha: float, _extrapolation_s: float, _delta: float) -> void:
	var from_g: GrenadeState = from_state as GrenadeState
	var blended := GrenadeState.new()
	if to_state == null:
		blended.pos = from_g.pos
		blended.rotation_quat = from_g.rotation_quat
		blended.state = from_g.state
		blended.fuse_remaining = from_g.fuse_remaining
		blended.explosion_progress = from_g.explosion_progress
	else:
		var to_g: GrenadeState = to_state as GrenadeState
		blended.pos = from_g.pos.lerp(to_g.pos, alpha)
		blended.rotation_quat = from_g.rotation_quat.slerp(to_g.rotation_quat, alpha)
		blended.state = to_g.state if alpha >= 0.5 else from_g.state
		blended.fuse_remaining = to_g.fuse_remaining
		blended.explosion_progress = lerp(from_g.explosion_progress, to_g.explosion_progress, alpha)
	global_position = blended.pos
	global_basis = Basis(blended.rotation_quat)
	_render_visuals(blended)
	if blended.state == STATE_DONE:
		queue_free()


func _render_visuals(s: GrenadeState) -> void:
	var flying := s.state == STATE_FLYING
	var exploding := s.state == STATE_EXPLODING
	_body.visible = flying
	_explosion.visible = exploding
	# Server owns the collider; clients keep it permanently disabled (set in
	# _ready). Toggling here from the client would re-enable it on FLYING.
	if NetSession.is_server:
		_shape.disabled = not flying
	if exploding:
		var scale_now: float = lerp(0.2, 3.0, clamp(s.explosion_progress, 0.0, 1.0))
		_explosion.scale = Vector3(scale_now, scale_now, scale_now)
		var mat: StandardMaterial3D = _explosion.material_override as StandardMaterial3D
		if mat:
			var c: Color = mat.albedo_color
			c.a = lerp(1.0, 0.0, clamp(s.explosion_progress, 0.0, 1.0))
			mat.albedo_color = c
