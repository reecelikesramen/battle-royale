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

var _last_shoot_state: Dictionary = {}  # peer_id -> bool
var _comp: NetLagCompensator


func _ready() -> void:
	if NetSession.is_server:
		_comp = NetLagCompensator.new()
		# Subscribe to player-predictor command_received signals as they spawn.
		# Predictors registered before us also need binding — walk current set.
		NetReplication.entity_registered.connect(_on_entity_registered)
		for entry in NetReplication.iter_entities():
			if entry[0] == PLAYER_SCHEMA_ID:
				_bind_predictor(entry[2])
	NetReliableHub.subscribe(Enums.ReliableTopic.HIT_CONFIRM, _on_hit_confirm)
	print("[SHOOT] handler ready is_server=%s" % NetSession.is_server)


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
	var peer_id: int = shooter.owner_id
	var was_shooting: bool = _last_shoot_state.get(peer_id, false)
	_last_shoot_state[peer_id] = input.shoot
	if not (input.shoot and not was_shooting):
		return
	if shooter.shadow_state == null:
		return
	var ray_origin: Vector3 = (shooter.shadow_state as PlayerState).pos + EYE_OFFSET
	var look: Vector2 = (shooter.shadow_state as PlayerState).look
	# look.x = pitch, look.y = yaw. Match player.gd update_camera basis order.
	var dir: Vector3 = Basis.from_euler(Vector3(look.x, look.y, 0.0)) * Vector3(0, 0, -1)
	var result: Variant = _comp.with_rewind(last_received_tick, _do_raycast.bind(ray_origin, dir, peer_id))
	if result == null:
		print("[SHOOT] peer=%d rewind_refused tick=%d" % [peer_id, last_received_tick])
		return
	var hit: Dictionary = result
	if hit.is_empty():
		print("[SHOOT] peer=%d miss" % peer_id)
		return
	var target: NetPredictor = NetReplication.get_entity(hit.schema_id, hit.entity_id) as NetPredictor
	if target == null or target.shadow_state == null:
		return
	var ts: PlayerState = target.shadow_state as PlayerState
	ts.health = maxi(0, ts.health - DAMAGE_PER_HIT)
	print("[SHOOT] peer=%d hit peer=%d dmg=%d remaining=%d" % [peer_id, hit.entity_id, DAMAGE_PER_HIT, ts.health])
	_broadcast_hit_confirm(peer_id, hit.entity_id, DAMAGE_PER_HIT, ts.health)


# Closure run while world is rewound. Iterates registered player predictors,
# tests a ray-segment against each shadow-positioned capsule (radius 0.5,
# half-height 1.0 — matches player capsule). Returns the nearest hit dict
# {schema_id, entity_id} or empty on miss. Skips self (shooter).
func _do_raycast(origin: Vector3, dir: Vector3, shooter_id: int) -> Dictionary:
	var best_t: float = RAY_LENGTH
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


# Reliable hub delivers two-arg (peer_id, payload) on server and one-arg
# (payload) on client. We only act on the client branch; server already
# logged inside _on_command.
func _on_hit_confirm(arg1, arg2 = null) -> void:
	if NetSession.is_server:
		return
	var payload: PackedByteArray = arg1 if arg2 == null else arg2
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
