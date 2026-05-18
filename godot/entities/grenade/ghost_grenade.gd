class_name GhostGrenade extends RigidBody3D

# Local-only, non-networked grenade visual that the thrower sees the instant
# they press throw_grenade. The server's real grenade arrives ~RTT later via
# NetState; when it does, GrenadeSpawner.try_match_ghost pops the matching
# ghost and calls hide_for_real() so the real grenade's render takes over.
#
# Anti-cheat: this entity has NO damage logic. Damage is applied exclusively
# by the server-side Grenade. If the server rejects a throw (cooldown / dead),
# the ghost still flies and visually detonates — user sees a fake grenade that
# did nothing. Rare; bounded by GrenadeSpawner.MAX_LOCAL_GHOSTS.

const STATE_FLYING := 0
const STATE_EXPLODING := 1
const STATE_DONE := 2

const FUSE_SEC := 3.0
const EXPLOSION_DURATION := 0.4

var spawn_time_us: int = 0
var _state: int = STATE_FLYING
var _fuse_remaining: float = FUSE_SEC
var _explosion_progress: float = 0.0
# Once matched, visuals are hidden but the body keeps simulating so blast
# timing stays consistent even if the real grenade's state stream drops.
var _hidden_for_real: bool = false

@onready var _body: MeshInstance3D = $Body
@onready var _explosion: MeshInstance3D = $Explosion
@onready var _shape: CollisionShape3D = $CollisionShape3D


func setup(origin: Vector3, velocity: Vector3) -> void:
	spawn_time_us = Time.get_ticks_usec()
	global_position = origin
	linear_velocity = velocity
	angular_velocity = Vector3(
			randf_range(-8.0, 8.0),
			randf_range(-8.0, 8.0),
			randf_range(-8.0, 8.0))


func _physics_process(delta: float) -> void:
	match _state:
		STATE_FLYING:
			_fuse_remaining -= delta
			if _fuse_remaining <= 0.0:
				_fuse_remaining = 0.0
				_state = STATE_EXPLODING
				_explosion_progress = 0.0
				linear_velocity = Vector3.ZERO
				freeze = true
				freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
				_shape.disabled = true
		STATE_EXPLODING:
			_explosion_progress += delta / EXPLOSION_DURATION
			if _explosion_progress >= 1.0:
				_state = STATE_DONE
				queue_free()
				return
	_render()


func _render() -> void:
	if _hidden_for_real:
		_body.visible = false
		_explosion.visible = false
		return
	var flying := _state == STATE_FLYING
	var exploding := _state == STATE_EXPLODING
	_body.visible = flying
	_explosion.visible = exploding
	if exploding:
		var scale_now: float = lerp(0.2, 3.0, clamp(_explosion_progress, 0.0, 1.0))
		_explosion.scale = Vector3(scale_now, scale_now, scale_now)
		var mat: StandardMaterial3D = _explosion.material_override as StandardMaterial3D
		if mat:
			var c: Color = mat.albedo_color
			c.a = lerp(1.0, 0.0, clamp(_explosion_progress, 0.0, 1.0))
			mat.albedo_color = c


# Called by GrenadeSpawner when the server's real grenade is matched to this
# ghost. Visuals go off; physics keeps stepping until fuse expires so the
# ghost self-cleans on the same schedule the real one would have.
func hide_for_real() -> void:
	_hidden_for_real = true
	_body.visible = false
	_explosion.visible = false
