@tool
class_name Grenade extends RigidBody3D

const STATE_FLYING := 0
const STATE_EXPLODING := 1
const STATE_DONE := 2

const EXPLOSION_DURATION := 0.4
const BLAST_RADIUS := 5.0
const BLAST_MAX_DAMAGE := 80
const DIRECT_HIT_RADIUS := 0.6  # grenade ~0.2 + player capsule 0.5 ≈ 0.7, slightly tight
const DIRECT_HIT_DAMAGE := 1
const DIRECT_HIT_MIN_SPEED := 3.0  # m/s — slow rolls / rests don't bonk for damage
const PLAYER_SCHEMA_ID := 1

# Peers already touched mid-flight — direct hit only applies once per grenade.
var _direct_hit_peers: Dictionary = {}
# Set true after blast damage applies (in EXPLODING transition).
var _blast_applied: bool = false
# Server-only: peer who threw this grenade. -1 = unknown. Excluded from
# direct-hit (you can't hand-bomb yourself) AND from blast damage in this
# scaffold pass — adjust later if self-damage on cooked grenades is desired.
var thrower_id: int = -1
# Self-damage gating: thrower is immune until grenade leaves an arming radius
# around them at least once. After arming, bounces back can hurt the thrower.
const THROWER_ARM_DISTANCE := 1.5
var _armed_for_thrower: bool = false

@onready var _net: NetPredictor = $NetPredictor
@onready var _shape: CollisionShape3D = $CollisionShape3D
@onready var _body: MeshInstance3D = $Body
@onready var _explosion: MeshInstance3D = $Explosion


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	if not _net.is_authoritative_instance:
		# Proxy instances are pure render targets — engine never simulates.
		# Collision shape stays disabled so the local thrower's visual
		# move_and_slide and any other peer's local physics never bump off the
		# replicated grenade (which would cause a visual divergence and a
		# reconcile snap). In listen mode the same scene has both a server-
		# auth grenade (collider live) and a client-proxy grenade (collider
		# disabled) under sibling parents — see Phase E.
		freeze = true
		freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		_shape.disabled = true
	elif NetSession.has_server_role and NetSession.has_client_role:
		# Listen mode: this auth grenade has a proxy sibling under ClientGrenades
		# at (nearly) the same world pose. Both rendering would show two grenades
		# per throw and two explosions per detonation. Hide the auth's visuals —
		# physics stays driven by the RigidBody3D shape, which is shape-resource-
		# based and unaffected by Node3D.visible. Mirrors dedicated-server mode
		# where the headless server has no rendering at all.
		visible = false


# Server hook: NetPredictor (archetype=REPLICATED) calls this once per gated
# physics tick (physics_hz / schema.tick_hz = 60Hz for grenades at 120Hz). The
# scaled `dt` is the wall-time covered by this firing, so time-based fields
# (fuse, explosion progress) advance regardless of the underlying physics
# rate. Game logic + scene→state copy + visual update + queue_free all live
# here; the framework broadcasts after this returns.
#
# Players run hot at 120Hz; grenades / props / ambient world objects run
# cooler so the server spends CPU on what matters. Jolt's RigidBody3D still
# integrates at the global physics rate — true sim-rate reduction would
# require porting to Node3D + manual ballistic integration, out of scope.
func _capture_state(state: GrenadeState, dt: float) -> void:
	match state.state:
		STATE_FLYING:
			state.pos = global_position
			state.velocity = linear_velocity
			state.rotation_quat = global_basis.get_rotation_quaternion()
			state.fuse_remaining -= dt
			_maybe_arm_for_thrower(global_position)
			_apply_direct_hits(global_position)
			if state.fuse_remaining <= 0.0:
				state.fuse_remaining = 0.0
				state.state = STATE_EXPLODING
				state.explosion_progress = 0.0
				state.velocity = Vector3.ZERO
				freeze = true
				freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
				if not _blast_applied:
					_apply_blast_damage(global_position)
					_blast_applied = true
		STATE_EXPLODING:
			state.explosion_progress += dt / EXPLOSION_DURATION
			if state.explosion_progress >= 1.0:
				state.explosion_progress = 1.0
				state.state = STATE_DONE
		STATE_DONE:
			pass
	_render_visuals(state)
	# queue_free defers to end-of-frame, so the framework's broadcast call
	# (which fires AFTER this hook returns) still sees the live entity. The
	# DONE state on the wire reaches clients and their own _proxy_apply
	# triggers their queue_free in sync.
	if state.state == STATE_DONE:
		queue_free()


# Schema-driven blending: NetPredictor (archetype=REPLICATED) inspects
# grenade_schema.tres.field_interp, pre-builds the blended state via
# NetProxyBlender (PREDICTED on pos w/ gravity, SLERP on rotation, DISCRETE
# on state, LERP on scalars), and hands it here. All this method does is
# push fields onto the scene.
func _proxy_apply(blended: GrenadeState, _from_state: NetState, _to_state: NetState, _delta: float) -> void:
	# Free as soon as either side of the buffer pair says the grenade is DONE.
	# blended.state via DISCRETE only flips to `to` at alpha >= 0.5; if `to` is
	# null (buffer drained, auth side already queue_freed and no future
	# snapshots are coming) DISCRETE falls back to `from`. Without this gate
	# the proxy can get stuck rendering its last EXPLODING frame forever — the
	# shared explosion material's alpha is the only thing keeping it invisible,
	# and a subsequent grenade's fade animation re-shows every stuck proxy at
	# its original world position. Belt-and-suspenders: check from_state too so
	# we free even before the blender mid-crosses to DONE.
	if _from_state != null and (_from_state as GrenadeState).state == STATE_DONE:
		queue_free()
		return
	global_position = blended.pos
	global_basis = Basis(blended.rotation_quat)
	_render_visuals(blended)
	if blended.state == STATE_DONE:
		queue_free()


func _maybe_arm_for_thrower(grenade_pos: Vector3) -> void:
	if _armed_for_thrower or thrower_id < 0:
		return
	var pred: NetPredictor = NetReplication.get_entity(PLAYER_SCHEMA_ID, thrower_id) as NetPredictor
	if pred == null or pred.shadow_state == null:
		return
	var thrower_pos: Vector3 = (pred.shadow_state as PlayerState).pos + Vector3(0, 1.0, 0)
	if grenade_pos.distance_to(thrower_pos) >= THROWER_ARM_DISTANCE:
		_armed_for_thrower = true


func _apply_direct_hits(grenade_pos: Vector3) -> void:
	if linear_velocity.length() < DIRECT_HIT_MIN_SPEED:
		return
	var sh: ShootHandler = get_tree().root.find_child("ShootHandler", true, false) as ShootHandler
	if sh == null:
		return
	for entry in NetReplication.iter_entities():
		if entry[0] != PLAYER_SCHEMA_ID:
			continue
		var pid: int = entry[1]
		if pid == thrower_id and not _armed_for_thrower:
			continue
		if _direct_hit_peers.has(pid):
			continue
		var pred: NetPredictor = entry[2]
		if pred.shadow_state == null:
			continue
		var ts: PlayerState = pred.shadow_state as PlayerState
		var capsule_center: Vector3 = ts.pos + Vector3(0, 1.0, 0)
		# Approx capsule-vs-sphere: clamp grenade_y into [center-1, center+1] then xz distance check.
		var clamped_y: float = clamp(grenade_pos.y, capsule_center.y - 1.0, capsule_center.y + 1.0)
		var p := Vector3(capsule_center.x, clamped_y, capsule_center.z)
		if grenade_pos.distance_to(p) <= DIRECT_HIT_RADIUS + 0.5:
			_direct_hit_peers[pid] = true
			sh.apply_damage(pid, DIRECT_HIT_DAMAGE, -1)


func _apply_blast_damage(center: Vector3) -> void:
	var sh: ShootHandler = get_tree().root.find_child("ShootHandler", true, false) as ShootHandler
	if sh == null:
		return
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	var player_rids: Array[RID] = []
	if space != null:
		for entry in NetReplication.iter_entities():
			if entry[0] != PLAYER_SCHEMA_ID:
				continue
			var pred: NetPredictor = entry[2]
			var host = pred.host
			if host is CollisionObject3D:
				player_rids.append((host as CollisionObject3D).get_rid())
			var gc: Node = host.get_node_or_null("GameController")
			if gc is CollisionObject3D:
				player_rids.append((gc as CollisionObject3D).get_rid())
	for entry in NetReplication.iter_entities():
		if entry[0] != PLAYER_SCHEMA_ID:
			continue
		var pid: int = entry[1]
		if pid == thrower_id and not _armed_for_thrower:
			continue
		var pred: NetPredictor = entry[2]
		if pred.shadow_state == null:
			continue
		var ts: PlayerState = pred.shadow_state as PlayerState
		var pp: Vector3 = ts.pos + Vector3(0, 1.0, 0)
		var dist: float = center.distance_to(pp)
		if dist >= BLAST_RADIUS:
			continue
		# Line-of-sight check: raycast from grenade center to player capsule
		# center, excluding all player bodies so we only hit world geometry.
		# Wall in between → no damage (effect still plays client-side).
		if space != null:
			var params := PhysicsRayQueryParameters3D.create(center, pp)
			params.collide_with_bodies = true
			params.collide_with_areas = false
			params.exclude = player_rids
			var blocked: Dictionary = space.intersect_ray(params)
			if not blocked.is_empty():
				continue
		var falloff: float = 1.0 - (dist / BLAST_RADIUS)
		var dmg: int = int(round(BLAST_MAX_DAMAGE * falloff))
		if dmg <= 0:
			continue
		sh.apply_damage(pid, dmg, -1)


func _render_visuals(s: GrenadeState) -> void:
	var flying := s.state == STATE_FLYING
	var exploding := s.state == STATE_EXPLODING
	_body.visible = flying
	_explosion.visible = exploding
	# Authoritative instance owns the collider; proxy instances keep it
	# permanently disabled (set in _ready). Toggling here from a proxy would
	# re-enable it on FLYING.
	if _net.is_authoritative_instance:
		_shape.disabled = not flying
	if exploding:
		var scale_now: float = lerp(0.2, 3.0, clamp(s.explosion_progress, 0.0, 1.0))
		_explosion.scale = Vector3(scale_now, scale_now, scale_now)
		var mat: StandardMaterial3D = _explosion.material_override as StandardMaterial3D
		if mat:
			var c: Color = mat.albedo_color
			c.a = lerp(1.0, 0.0, clamp(s.explosion_progress, 0.0, 1.0))
			mat.albedo_color = c
