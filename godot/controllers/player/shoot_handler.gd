class_name ShootHandler extends Node3D

# Server-authoritative hitscan with lag-comp rewind. Subscribes to each player
# NetPredictor's typed command_received signal, edge-detects shoot on the
# decoded PlayerInput, rewinds every NetPredictor to the client-quoted server
# tick, fires a raycast from the shooter's *rewound* eye position, applies
# damage to the hit predictor's shadow_state.health, and broadcasts a
# HIT_CONFIRM reliable so the shooter (and target) can render feedback.
#
# Lag-comp pivot: last_received_tick (infra field on NetCommandPacket, passed
# alongside the decoded cmd) is the snapshot tick the client had loaded when
# they pulled the trigger; rewinding the world to that tick puts every player
# where the shooter saw them. Anti-cheat clamp lives inside NetLagCompensator.
#
# Caveats / next steps:
#   - Rewinding only mutates shadow_state. NetPredictor.shadow_state_applied
#     fires on rewind/restore; PlayerController subscribes (server-only) and
#     pushes shadow_state.pos onto its CharacterBody3D so the raycast actually
#     intersects rewound bodies.
#   - Eye height is hard-coded as PlayerController.global_position + EYE_OFFSET.
#   - No weapon model: fire rate, spread, damage tables not yet abstracted.

const PLAYER_SCHEMA_ID := 1
const EYE_OFFSET := Vector3(0.0, 1.7, 0.0)
const RAY_LENGTH := 200.0
const DAMAGE_PER_HIT := 10
const FIRE_RATE_RPM := 500.0
const FIRE_INTERVAL_US := int(60_000_000.0 / FIRE_RATE_RPM)  # 120000 us @ 500rpm
const TRACER_LIFETIME_SEC := 0.08
const TRACER_THICKNESS := 0.04          # cylinder radius (m)
# Muzzle offset relative to the shooter's *look basis* (X=right, Y=up, Z=back).
# Picked to land at hip / right-shoulder so tracers don't fill the face and
# don't drag along the floor when aiming downward.
const MUZZLE_LOCAL := Vector3(0.0, -0.20, -0.50)
const RESPAWN_DELAY_SEC := 10.0

var _last_fire_us: Dictionary = {}  # peer_id -> int (server-side rate limit)
var _comp: NetLagCompensator
var _tracer_root: Node3D
var _tracer_mat: ShaderMaterial
# Active tracers: list of { mi: MeshInstance3D, born_us: int, life_us: int }
var _active_tracers: Array = []
const _TRACER_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_opaque, cull_disabled, shadows_disabled;

uniform vec3 core_color : source_color = vec3(1.0, 0.95, 0.65);
uniform vec3 glow_color : source_color = vec3(1.0, 0.45, 0.10);
uniform float intensity : hint_range(0.0, 16.0) = 6.0;
instance uniform float alpha = 1.0;

void fragment() {
    // Fade radially around the cylinder shell using the view-space normal:
    // edges (silhouette) glow, the line center reads bright core.
    float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
    float core = pow(facing, 6.0);                 // tight bright core
    float halo = pow(1.0 - facing, 2.0) * 0.7;     // soft outer glow
    // Length taper: heavy fade near the origin (UV.y ~ 0) so the shooter's
    // face isn't filled with their own tracer, soft fade at the far end.
    // CylinderMesh: bottom (v=0) is aligned with start (= muzzle), top (v=1)
    // with the endpoint after the orient-to-dir basis we apply on the host.
    float near_origin = smoothstep(0.0, 0.70, UV.y);     // invisible for first 70% → tracer reads in the distance only
    float far_end = smoothstep(1.0, 0.92, UV.y);         // soft fade at the very end
    float taper = near_origin * far_end;
    vec3 col = mix(glow_color, core_color, core);
    ALBEDO = col * intensity * (core + halo) * taper;
    ALPHA = clamp((core + halo) * taper * alpha, 0.0, 1.0);
}
"""


func _ready() -> void:
	# Render-side subscriptions: these payloads only ever reach the client lane
	# (server is the broadcaster, never the receiver). subscribe_client gives
	# us payload-only callbacks and skips the listen-mode double-fire.
	NetReliableHub.subscribe_client(Enums.ReliableTopic.HIT_CONFIRM, _on_hit_confirm)
	NetReliableHub.subscribe_client(Enums.ReliableTopic.SHOT_FIRED, _on_shot_fired)
	NetReliableHub.subscribe_client(Enums.ReliableTopic.PLAYER_DIED, _on_player_died)
	NetReliableHub.subscribe_client(Enums.ReliableTopic.PLAYER_RESPAWN, _on_player_respawn)
	tree_exiting.connect(_unsubscribe_all)
	NetSession.when_roles_ready(_finish_setup)


func _finish_setup() -> void:
	if NetSession.has_server_role:
		_comp = NetLagCompensator.new()
		# Subscribe to player-predictor command_received signals as they spawn.
		# Predictors registered before us also need binding — walk current set.
		NetReplication.entity_registered.connect(_on_entity_registered)
		for entry in NetReplication.iter_entities():
			if entry[0] == PLAYER_SCHEMA_ID:
				_bind_predictor(entry[2])
	if NetSession.has_client_role:
		_tracer_root = Node3D.new()
		_tracer_root.name = "TracerRoot"
		add_child(_tracer_root)
		var shader := Shader.new()
		shader.code = _TRACER_SHADER
		_tracer_mat = ShaderMaterial.new()
		_tracer_mat.shader = shader
		set_process(true)
	print("[SHOOT] handler ready mode=%d" % NetSession.mode)


func _unsubscribe_all() -> void:
	NetReliableHub.unsubscribe(Enums.ReliableTopic.HIT_CONFIRM, _on_hit_confirm)
	NetReliableHub.unsubscribe(Enums.ReliableTopic.SHOT_FIRED, _on_shot_fired)
	NetReliableHub.unsubscribe(Enums.ReliableTopic.PLAYER_DIED, _on_player_died)
	NetReliableHub.unsubscribe(Enums.ReliableTopic.PLAYER_RESPAWN, _on_player_respawn)


func _on_entity_registered(schema_id: int, entity_id: int) -> void:
	if schema_id != PLAYER_SCHEMA_ID:
		return
	var pred: NetPredictor = NetReplication.get_entity(schema_id, entity_id)
	if pred != null:
		_bind_predictor(pred)


func _bind_predictor(pred: NetPredictor) -> void:
	if not pred.command_received.is_connected(_on_command):
		pred.command_received.connect(_on_command.bind(pred))


func _on_command(cmd: NetCommand, _sequence_id: int, _timestamp_us: int, last_received_tick: int, shooter: NetPredictor) -> void:
	var input: PlayerInput = cmd as PlayerInput
	if not input.shoot:
		return
	var peer_id: int = shooter.owner_id
	if shooter.shadow_state == null:
		return
	# Dead players can't shoot. shadow_state.health==0 → ignore.
	var sstate: PlayerState = shooter.shadow_state as PlayerState
	if sstate.health <= 0:
		return
	# Server-side fire rate limit. 500 rpm = 120ms between shots.
	var now_us: int = Time.get_ticks_usec()
	var last_us: int = _last_fire_us.get(peer_id, 0)
	if now_us - last_us < FIRE_INTERVAL_US:
		return
	_last_fire_us[peer_id] = now_us
	var ray_origin: Vector3 = sstate.pos + EYE_OFFSET
	var look: Vector2 = sstate.look
	# look.x = pitch, look.y = yaw. Match player.gd update_camera basis order.
	var look_basis: Basis = Basis.from_euler(Vector3(look.x, look.y, 0.0))
	var dir: Vector3 = look_basis * Vector3(0, 0, -1)
	# Wall raycast (world geometry only) — caps how far the bullet can reach.
	# Player capsule tests in _do_raycast then reject any candidate beyond this
	# distance, so you can't shoot through walls. The tracer endpoint also
	# clamps to wall_hit so the streak terminates on the wall.
	var wall_dist: float = _world_raycast_distance(ray_origin, dir, RAY_LENGTH)
	var result: Variant = _comp.with_rewind(last_received_tick, _do_raycast.bind(ray_origin, dir, peer_id, wall_dist))
	if result == null:
		print("[SHOOT] peer=%d rewind_refused tick=%d" % [peer_id, last_received_tick])
		return
	var hit: Dictionary = result
	var endpoint: Vector3 = ray_origin + dir * wall_dist
	# Wire format: send the RAW bullet ray (eye → endpoint). Drawing the cylinder
	# directly along this line guarantees the visible tracer always follows the
	# bullet trajectory. The shader fades the first 70% near the origin, so the
	# shooter doesn't see their own muzzle blast — no offset hackery needed.
	if hit.is_empty():
		_broadcast_shot_fired(peer_id, ray_origin, endpoint)
		return
	var target: NetPredictor = NetReplication.get_entity(hit.schema_id, hit.entity_id) as NetPredictor
	if target == null or target.shadow_state == null:
		_broadcast_shot_fired(peer_id, ray_origin, endpoint)
		return
	var ts: PlayerState = target.shadow_state as PlayerState
	if ts.health <= 0:
		_broadcast_shot_fired(peer_id, ray_origin, endpoint)
		return
	# Approximate hit endpoint to target capsule center (good enough for tracer).
	var hit_pos: Vector3 = ts.pos + Vector3(0, 1.0, 0)
	_broadcast_shot_fired(peer_id, ray_origin, hit_pos)
	ts.health = maxi(0, ts.health - DAMAGE_PER_HIT)
	print("[SHOOT] peer=%d hit peer=%d dmg=%d remaining=%d" % [peer_id, hit.entity_id, DAMAGE_PER_HIT, ts.health])
	_broadcast_hit_confirm(peer_id, hit.entity_id, DAMAGE_PER_HIT, ts.health)
	if ts.health <= 0:
		_handle_kill(peer_id, hit.entity_id, target)


# Server-side world raycast that ignores all player bodies. Returns the
# distance to the first wall/floor/static obstruction, or `max_dist` on miss.
# Used to cap bullet penetration and grenade blast LOS.
func _world_raycast_distance(origin: Vector3, dir: Vector3, max_dist: float) -> float:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null:
		return max_dist
	var params := PhysicsRayQueryParameters3D.create(origin, origin + dir * max_dist)
	params.collide_with_bodies = true
	params.collide_with_areas = false
	params.exclude = _player_body_rids()
	var hit: Dictionary = space.intersect_ray(params)
	if hit.is_empty():
		return max_dist
	return origin.distance_to(hit.position)


func _player_body_rids() -> Array[RID]:
	var rids: Array[RID] = []
	for entry in NetReplication.iter_entities():
		if entry[0] != PLAYER_SCHEMA_ID:
			continue
		var pred: NetPredictor = entry[2]
		var host = pred.host
		if host == null:
			continue
		if host is CollisionObject3D:
			rids.append((host as CollisionObject3D).get_rid())
		var gc: Node = host.get_node_or_null("GameController")
		if gc is CollisionObject3D:
			rids.append((gc as CollisionObject3D).get_rid())
	return rids


# Closure run while world is rewound. Iterates registered player predictors,
# tests a ray-segment against each shadow-positioned capsule (radius 0.5,
# half-height 1.0 — matches player capsule). Returns the nearest hit dict
# {schema_id, entity_id} or empty on miss. Skips self (shooter).
func _do_raycast(origin: Vector3, dir: Vector3, shooter_id: int, max_t: float = RAY_LENGTH) -> Dictionary:
	var best_t: float = max_t
	var best_id: int = -1
	for entry in NetReplication.iter_entities():
		var schema_id: int = entry[0]
		var entity_id: int = entry[1]
		if schema_id != PLAYER_SCHEMA_ID or entity_id == shooter_id:
			continue
		var pred: NetPredictor = entry[2]
		if pred.shadow_state == null:
			continue
		var ts: PlayerState = pred.shadow_state as PlayerState
		var t: float = _ray_vs_capsule(origin, dir, ts.pos + Vector3(0, 1.0, 0), 1.0, 0.5)
		if t > 0.0 and t < best_t:
			best_t = t
			best_id = entity_id
	if best_id < 0:
		return {}
	return {"schema_id": PLAYER_SCHEMA_ID, "entity_id": best_id}


# Ray-vs-capsule (axis-aligned vertical). Capsule = cylinder + two hemispheres.
# Returns nearest t along (origin + t*dir), or -1 on miss.
static func _ray_vs_capsule(o: Vector3, d: Vector3, c: Vector3, half_h: float, r: float) -> float:
	# Reduce to ray-vs-cylinder in xz, clamp to capped segment, fall back to
	# ray-vs-sphere on each hemisphere if outside the cylinder slab.
	var d_xz := Vector2(d.x, d.z)
	var o_xz := Vector2(o.x - c.x, o.z - c.z)
	var a: float = d_xz.length_squared()
	var b: float = 2.0 * o_xz.dot(d_xz)
	var k: float = o_xz.length_squared() - r * r
	var t_cyl: float = -1.0
	if a > 0.0001:
		var disc: float = b * b - 4.0 * a * k
		if disc >= 0.0:
			var sq: float = sqrt(disc)
			var t0: float = (-b - sq) / (2.0 * a)
			if t0 > 0.0:
				var y: float = o.y + d.y * t0
				if y >= c.y - half_h and y <= c.y + half_h:
					t_cyl = t0
	var t_top: float = _ray_vs_sphere(o, d, c + Vector3(0, half_h, 0), r)
	var t_bot: float = _ray_vs_sphere(o, d, c - Vector3(0, half_h, 0), r)
	var best: float = -1.0
	for cand in [t_cyl, t_top, t_bot]:
		if cand > 0.0 and (best < 0.0 or cand < best):
			best = cand
	return best


static func _ray_vs_sphere(o: Vector3, d: Vector3, c: Vector3, r: float) -> float:
	var oc: Vector3 = o - c
	var b: float = oc.dot(d)
	var k: float = oc.length_squared() - r * r
	var disc: float = b * b - k
	if disc < 0.0:
		return -1.0
	var t: float = -b - sqrt(disc)
	return t if t > 0.0 else -1.0


func _broadcast_hit_confirm(shooter_id: int, target_id: int, damage: int, remaining_health: int) -> void:
	var sp := StreamPeerBuffer.new()
	sp.put_u16(shooter_id)
	sp.put_u16(target_id)
	sp.put_u16(damage)
	sp.put_u16(remaining_health)
	NetReliableHub.broadcast(Enums.ReliableTopic.HIT_CONFIRM, sp.data_array)


func _on_hit_confirm(payload: PackedByteArray) -> void:
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var shooter_id: int = sp.get_u16()
	var target_id: int = sp.get_u16()
	var damage: int = sp.get_u16()
	var remaining: int = sp.get_u16()
	if shooter_id == NetClient.id:
		print("[SHOOT] HIT peer=%d dmg=%d (target_hp=%d)" % [target_id, damage, remaining])
	if target_id == NetClient.id:
		print("[SHOOT] TAKEN dmg=%d from peer=%d (hp=%d)" % [damage, shooter_id, remaining])
	hit_confirmed.emit(shooter_id, target_id, damage, remaining)


# Global signal any UI can hook (GUI hitmarker, damage indicator, kill feed).
signal hit_confirmed(shooter_id: int, target_id: int, damage: int, remaining_health: int)
signal player_died(victim_id: int, killer_id: int)
signal player_respawned(victim_id: int, pos: Vector3)


# ---- Tracer broadcast/render ----------------------------------------------

func _broadcast_shot_fired(shooter_id: int, origin: Vector3, endpoint: Vector3) -> void:
	var sp := StreamPeerBuffer.new()
	sp.put_u16(shooter_id)
	sp.put_float(origin.x); sp.put_float(origin.y); sp.put_float(origin.z)
	sp.put_float(endpoint.x); sp.put_float(endpoint.y); sp.put_float(endpoint.z)
	NetReliableHub.broadcast(Enums.ReliableTopic.SHOT_FIRED, sp.data_array)


func _on_shot_fired(payload: PackedByteArray) -> void:
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var shooter_id: int = sp.get_u16()
	var o := Vector3(sp.get_float(), sp.get_float(), sp.get_float())
	var e := Vector3(sp.get_float(), sp.get_float(), sp.get_float())
	# Local shooter: shift the whole ray so it originates at the *visual* camera
	# position rather than the server's authoritative eye anchor. Both ends move
	# by the same delta, so the direction (= bullet trajectory) stays identical.
	# Shader near-origin fade hides the segment close to the camera so the
	# shooter doesn't see their own tracer in their face.
	if shooter_id == NetClient.id and NetClient.player != null:
		var cam: Camera3D = NetClient.player.get_node_or_null("CameraController/Camera3D")
		if cam != null:
			var delta: Vector3 = cam.global_position - o
			o += delta
			e += delta
	_spawn_tracer(o, e)


func _spawn_tracer(o: Vector3, e: Vector3) -> void:
	if _tracer_root == null:
		return
	var dir: Vector3 = e - o
	var full_len: float = dir.length()
	if full_len < 0.1:
		return
	dir /= full_len
	var start: Vector3 = o
	var seg_len: float = full_len
	var cyl := CylinderMesh.new()
	cyl.top_radius = TRACER_THICKNESS
	cyl.bottom_radius = TRACER_THICKNESS
	cyl.height = seg_len
	cyl.radial_segments = 8
	cyl.rings = 1
	cyl.material = _tracer_mat
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Build the world-space transform first; add_child binds it as-is. Setting
	# global_* before add_child stores them as local on a parentless node and
	# can land at the wrong world location once parented.
	var mid: Vector3 = start + dir * (seg_len * 0.5)
	var basis: Basis
	var up := Vector3.UP
	var dot: float = up.dot(dir)
	if dot > 0.9999:
		basis = Basis.IDENTITY
	elif dot < -0.9999:
		basis = Basis(Vector3.RIGHT, PI)
	else:
		var axis: Vector3 = up.cross(dir).normalized()
		var angle: float = acos(clamp(dot, -1.0, 1.0))
		basis = Basis(axis, angle)
	_tracer_root.add_child(mi)
	mi.global_transform = Transform3D(basis, mid)
	_active_tracers.append({
		"mi": mi,
		"born_us": Time.get_ticks_usec(),
		"life_us": int(TRACER_LIFETIME_SEC * 1_000_000),
	})


func _process(_delta: float) -> void:
	if _active_tracers.is_empty():
		return
	var now_us: int = Time.get_ticks_usec()
	var i: int = _active_tracers.size() - 1
	while i >= 0:
		var entry: Dictionary = _active_tracers[i]
		var elapsed: int = now_us - entry.born_us
		if elapsed >= entry.life_us:
			(entry.mi as Node).queue_free()
			_active_tracers.remove_at(i)
		else:
			# Fade out near end of lifetime via the shader's `alpha` uniform.
			var t: float = float(elapsed) / float(entry.life_us)
			var fade: float = clamp(1.0 - t, 0.0, 1.0)
			(entry.mi as MeshInstance3D).set_instance_shader_parameter("alpha", fade)
		i -= 1


# ---- Death / respawn ------------------------------------------------------

func _handle_kill(killer_id: int, victim_id: int, victim: NetPredictor) -> void:
	print("[SHOOT] KILL killer=%d victim=%d" % [killer_id, victim_id])
	_broadcast_player_died(victim_id, killer_id)
	get_tree().create_timer(RESPAWN_DELAY_SEC).timeout.connect(_respawn_player.bind(victim_id, victim))


func _respawn_player(victim_id: int, victim: NetPredictor) -> void:
	if not is_instance_valid(victim) or victim.shadow_state == null:
		return
	var ts: PlayerState = victim.shadow_state as PlayerState
	var spawn: Vector3 = Constants.MAP_SPAWN
	ts.pos = spawn
	ts.velocity = Vector3.ZERO
	ts.health = 100
	victim.apply_shadow_state_to_scene()
	_broadcast_player_respawn(victim_id, spawn)


func _broadcast_player_died(victim_id: int, killer_id: int) -> void:
	var sp := StreamPeerBuffer.new()
	sp.put_u16(victim_id)
	sp.put_u16(maxi(killer_id, 0))  # 0 sentinel for environmental kills (grenade)
	NetReliableHub.broadcast(Enums.ReliableTopic.PLAYER_DIED, sp.data_array)


func _broadcast_player_respawn(victim_id: int, pos: Vector3) -> void:
	var sp := StreamPeerBuffer.new()
	sp.put_u16(victim_id)
	sp.put_float(pos.x); sp.put_float(pos.y); sp.put_float(pos.z)
	NetReliableHub.broadcast(Enums.ReliableTopic.PLAYER_RESPAWN, sp.data_array)


func _on_player_died(payload: PackedByteArray) -> void:
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var victim_id: int = sp.get_u16()
	var killer_id: int = sp.get_u16()
	print("[SHOOT] DIED victim=%d killer=%d" % [victim_id, killer_id])
	player_died.emit(victim_id, killer_id)


func _on_player_respawn(payload: PackedByteArray) -> void:
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var victim_id: int = sp.get_u16()
	var pos := Vector3(sp.get_float(), sp.get_float(), sp.get_float())
	print("[SHOOT] RESPAWN victim=%d pos=%s" % [victim_id, pos])
	player_respawned.emit(victim_id, pos)


# Public hook for grenade / other damage sources. Server-only.
func apply_damage(victim_id: int, damage: int, attacker_id: int = -1) -> void:
	if not NetSession.has_server_role:
		return
	var victim: NetPredictor = NetReplication.get_entity(PLAYER_SCHEMA_ID, victim_id) as NetPredictor
	if victim == null or victim.shadow_state == null:
		return
	var ts: PlayerState = victim.shadow_state as PlayerState
	if ts.health <= 0:
		return
	ts.health = maxi(0, ts.health - damage)
	print("[SHOOT] damage victim=%d dmg=%d remaining=%d (src=%d)" % [victim_id, damage, ts.health, attacker_id])
	_broadcast_hit_confirm(maxi(attacker_id, 0), victim_id, damage, ts.health)
	if ts.health <= 0:
		_handle_kill(attacker_id, victim_id, victim)
