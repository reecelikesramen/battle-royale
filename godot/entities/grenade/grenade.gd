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

# Per-entity tick-rate gate. Server runs grenade game-logic + snapshot capture
# + broadcast every Nth physics tick, derived from project physics rate / the
# schema's tick_hz. This is how variable-rate entities work — players run hot
# (120Hz), grenades / world props run cooler (60Hz / 30Hz / etc.) so the server
# spends its CPU on what matters. Read at _ready so schema reload doesn't
# require a script restart.
#
# Note: Jolt's underlying RigidBody3D integration still runs at the global
# physics rate (currently 120Hz). For *true* simulation-rate reduction (no
# RigidBody integration on skipped ticks) the body would need to be ported to
# Node3D + manual ballistic integration with PhysicsServer raycasts. Worth
# doing for true performance scaling but out of scope for this pass — the
# wins here are already substantial: half the snapshot encodes, half the
# blast/direct-hit broadphase, half the wire bytes.
var _tick_every: int = 1
var _tick_ctr: int = 0


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
	# Schema's tick_hz declares the entity's logical simulation rate. Physics
	# runs at the project rate; gate this script's _physics_process to fire
	# only every (physics_hz / tick_hz) ticks.
	var physics_hz: int = ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 120)
	var sim_hz: int = _net.schema.tick_hz if _net != null and _net.schema != null else physics_hz
	_tick_every = maxi(1, physics_hz / maxi(1, sim_hz))


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if _net.shadow_state == null:
		return
	if not NetSession.is_server:
		return
	# Per-entity tick gate. Skip the cheap path early.
	_tick_ctr += 1
	if _tick_ctr < _tick_every:
		return
	_tick_ctr = 0
	# `delta` is one physics step; the gate accumulates _tick_every steps
	# between firings, so the effective dt for time-based fields is scaled.
	var dt: float = delta * float(_tick_every)
	var s: GrenadeState = _net.shadow_state as GrenadeState
	match s.state:
		STATE_FLYING:
			s.pos = global_position
			s.velocity = linear_velocity
			s.rotation_quat = global_basis.get_rotation_quaternion()
			s.fuse_remaining -= dt
			_maybe_arm_for_thrower(global_position)
			_apply_direct_hits(global_position)
			if s.fuse_remaining <= 0.0:
				s.fuse_remaining = 0.0
				s.state = STATE_EXPLODING
				s.explosion_progress = 0.0
				s.velocity = Vector3.ZERO
				freeze = true
				freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
				if not _blast_applied:
					_apply_blast_damage(global_position)
					_blast_applied = true
		STATE_EXPLODING:
			s.explosion_progress += dt / EXPLOSION_DURATION
			if s.explosion_progress >= 1.0:
				s.explosion_progress = 1.0
				s.state = STATE_DONE
		STATE_DONE:
			pass
	# One broadcast per gated tick — matches schema.tick_hz on the wire.
	_net.server_broadcast_snapshot(0)
	_render_visuals(s)
	if s.state == STATE_DONE:
		queue_free()


# Schema-driven blending: NetPredictor inspects grenade_schema.tres.field_interp,
# pre-builds the blended state via NetProxyBlender (PREDICTED on pos w/ gravity,
# SLERP on rotation, DISCRETE on state, LERP on scalars), and hands it here.
# All this method does is push fields onto the scene.
func _proxy_apply(blended: GrenadeState, _from_state: NetState, _to_state: NetState, _delta: float) -> void:
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
