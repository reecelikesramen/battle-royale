class_name PlayerController
extends CharacterBody3D

# PlayerController hosts NetPredictor's hook callbacks. The NetPredictor child
# node (authored in player.tscn) owns the physics tick and per-role dispatch
# (authority / server / proxy). The framework now owns:
#   - correction smoothing (driven by schema.corrections; render_state flows
#     into _apply_state),
#   - server-side input fan-out (NetPredictor subscribes to
#     NetServer.handle_net_command itself and filters by (schema_id, entity_id, owner_id)),
#   - body rewind + visible-vs-canonical pos offset (Phase 4): NetPredictor.body
#     points at this controller (= "."), framework canonical-snaps before
#     _simulate and writes a smoothed visible pos after _apply_corrections.
# What stays here: input gathering, the logic+visual state machines + their
# movement helpers, camera glue, and proxy interp wiring.

signal reconcile_network_debug(delta_pos: Vector3, delta_vel: Vector3, unacked_inputs: SequenceRingBuffer)

const TILT_LOWER_LIMIT: float = deg_to_rad(-90.0)
const TILT_UPPER_LIMIT: float = deg_to_rad(90.0)


@export_group("Movement Tunables")
@export var FRICTION: float = 8.0
@export var AIR_FRICTION: float = 0.3
@export var STOP_SPEED: float = 0.5
@export var TOGGLE_CROUCH: bool = false
@export var TOGGLE_PEEK: bool = false

@export_group("Camera Tunables")
@export var MOUSE_SENSITIVITY: float = 0.5

const THROW_POWER := 12.0

@onready var camera: Camera3D = $CameraController/Camera3D
@onready var tp_camera: Camera3D = $CameraController/ThirdPersonCamera3D
@onready var animation_player: AnimationPlayer = $AnimationPlayer
@onready var animation_tree: AnimationTree = $AnimationTree
@onready var camera_animation_player: AnimationPlayer = $CameraAnimationPlayer
@onready var crouch_shapecast: ShapeCast3D = %CrouchShapeCast3D

# True when this instance is the one the local user sees + controls: own
# camera is current, input is gathered, debug HUDs render. Distinct from
# is_predicting (NetPredictor.is_local_authority): in listen mode the local
# proxy is_local_view=true (camera + input) but is_predicting=false (server-
# auth sibling owns simulation, this side is interp-only).
var is_local_view: bool:
	get: return !_net.is_authoritative_instance && _owner_id == NetClient.id

var is_replaying_inputs: bool:
	get: return _net.is_replaying_inputs

var last_grounded_height: float = 0.0

var input := PlayerInputContext.new()

# NetPredictor child node owns the tick. Authored in player.tscn so the schema
# is inspector-set and the framework lifecycle attaches automatically. Hooks
# below are duck-typed by NetPredictor via has_method().
@onready var _net: NetPredictor = $NetPredictor

var _owner_id: int

# movement parameters
var _speed := 0.0
var _acceleration := 0.0
# Scales raw move_left_right input before wish_dir is built. Sprint sets this
# below 1.0 so W+D produces a more forward-leaning travel direction (55–60°
# instead of 45°) rather than full-speed strafing while sprinting.
var _strafe_scale := 1.0

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

# Sprint key (shift) is dual-purpose: tap = toggle walk_mode, hold past
# SPRINT_HOLD_THRESHOLD_MS = sprint. Tracked entirely client-side; only the
# resulting cmd.sprint / cmd.walk_mode bits cross the wire.
const SPRINT_HOLD_THRESHOLD_MS := 130
var _walk_mode := false
var _shift_press_time_ms: int = -1
var _shift_did_sprint := false

# Crouch/prone tiredness (CS2-style). Each crouch/prone *edge* (going down,
# starting to stand up) adds TIREDNESS_BUMP to a shared 0..1 scalar; the value
# linearly decays to 0 over TIREDNESS_DECAY_SEC seconds of inactivity. Slowdown
# is quadratic: slowdown(t) = 1 + 2*t*t. With TIREDNESS_BUMP=0.35 a single
# crouch cycle (down + stand-up) accumulates to ~0.7 = ~2x slowdown on the
# way up. Two cycles back-to-back saturate at 1.0 = 3x.
#
# Peak-hold: every bump AND every completion event (full-crouch, full-prone,
# full-stood-up) pushes the decay-start anchor `now + TIREDNESS_PEAK_HOLD_SEC`,
# so tiredness sits at its peak briefly instead of immediately decaying. Without
# this you'd never actually see 3x — the up-transition would average to ~2.8x.
const TIREDNESS_DECAY_SEC := 3.0
const TIREDNESS_BUMP := 0.25
const TIREDNESS_PEAK_HOLD_SEC := 0.25
# First crouch/prone is penalty-free both ways (down + up = 2 bumps). The pool
# refills (and tiredness resets to 0) once decay brings slowdown below 1.05x —
# tiredness < TIREDNESS_RESET_THRESHOLD corresponds to slowdown = 1 + 2*t² < 1.05.
const TIREDNESS_INITIAL_FREE_BUMPS := 2
const TIREDNESS_RESET_THRESHOLD := 0.158
# Outside crouch/prone, decay is gated until the player either moves fast enough
# or has been moving continuously long enough. WalkMovementState.SPEED is 2.0;
# 75% of that is 1.5. Continuous-motion threshold is 0.5s.
const TIREDNESS_RELEASE_SPEED := 1.5
const TIREDNESS_RELEASE_CONTINUOUS_US := 500_000
# Toggle to dump detailed trace prints. Cheap, but spammy — disable for normal play.
const TIREDNESS_DEBUG := true
# Sample tiredness in _physics_process every TIREDNESS_LOG_INTERVAL_TICKS so
# decay is observable even outside crouch/prone state machines.
const TIREDNESS_LOG_INTERVAL_TICKS := 30  # at 60Hz, ~2 lines/sec
# Shoot-flow trace prints. [SHOOT-LOCAL] on trigger edge, [SHOOT-AUTH] on
# server when command resolves, [SHOOT-RENDER] on client when tracer arrives.
# Keep on while diagnosing high-latency shoot feel; flip to false for normal play.
const SHOOT_DEBUG := true
# Trigger-edge timestamp for the local client. Read by ShootHandler to compute
# the end-to-end "trigger pulled -> tracer rendered" delay.
var _last_shoot_pressed: bool = false
var _shoot_local_edge_us: int = -1
var _tiredness_base: float = 0.0
# Decay only begins at-or-after this timestamp. Bumps/completion-holds push it
# forward; outside any hold, decay runs purely off wall clock.
var _tiredness_decay_starts_at_us: int = 0
var _tiredness_log_ctr: int = 0
# Wall-clock timestamp when the player started moving meaningfully (horiz speed
# > 0.1 m/s) outside crouch/prone. Reset to 0 when stationary or while in
# crouch/prone state. Used to gate tiredness decay release.
var _movement_started_us: int = 0
# Free-bump pool: while > 0, bump_tiredness is a no-op (logs free-skip). Reset
# to TIREDNESS_INITIAL_FREE_BUMPS once tiredness decays below RESET_THRESHOLD.
var _free_bumps_remaining: int = TIREDNESS_INITIAL_FREE_BUMPS


func _enter_tree() -> void:
	# NetPredictor is a static .tscn child with schema preset; we only fill in
	# the per-spawn identity. Parent _enter_tree fires before the child's
	# _ready, so the predictor sees these values when it registers itself with
	# NetReplication. Spawner sets _owner_id before add_child(player).
	var net: NetPredictor = $NetPredictor
	net.owner_id = _owner_id
	net.entity_id = _owner_id
	# Server-only: when NetLagCompensator rewinds/restores shadow_state, push
	# pos onto the CharacterBody3D so ShootHandler's raycast intersects rewound
	# bodies. Live state restoration also fires this; harmless when shadow == scene.
	if net.is_authoritative_instance:
		net.shadow_state_applied.connect(_on_shadow_state_applied)


func _on_shadow_state_applied() -> void:
	# Server-side lag-comp rewind / restore: push pos+velocity onto the root
	# body so any non-analytical query at the rewound tick sees the right pose.
	# (ShootHandler / Grenade hit detection are analytical against
	# shadow_state.pos, so this is belt-and-suspenders today; kept for any
	# future physics-based path that wants the scene rewound.)
	var s: PlayerState = _net.shadow_state as PlayerState
	if s == null:
		return
	global_position = s.pos
	velocity = s.velocity


func _ready():
	print("Player #%d spawned, named %s!" % [_owner_id, name])

	crouch_shapecast.add_exception(self)

	global_position = Constants.MAP_SPAWN

	if is_local_view:
		camera.make_current()
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		call_deferred("remove_child", %GUI)
		call_deferred("remove_child", $EscapeMenu)
		camera.call_deferred("remove_child", $CameraController/Camera3D/ReflectionProbe)


func _unhandled_input(event):
	if !is_local_view:
		return

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_x_mouse_input += -event.relative.x * MOUSE_SENSITIVITY
		_y_mouse_input += -event.relative.y * MOUSE_SENSITIVITY


func _input(event: InputEvent) -> void:
	if !is_local_view:
		return
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		return

	if event.is_action_pressed("toggle_camera"):
		if camera.current:
			tp_camera.make_current()
		else:
			camera.make_current()

	if event.is_action_pressed("throw_grenade"):
		if not _is_locally_dead():
			_send_grenade_throw()


func _send_grenade_throw() -> void:
	var fwd := -camera.global_basis.z
	var origin := camera.global_position + fwd * 0.3
	var velocity := fwd * THROW_POWER
	var sp := StreamPeerBuffer.new()
	sp.put_float(origin.x); sp.put_float(origin.y); sp.put_float(origin.z)
	sp.put_float(velocity.x); sp.put_float(velocity.y); sp.put_float(velocity.z)
	NetReliableHub.send(Enums.ReliableTopic.THROW_GRENADE, sp.data_array)
	print("[GRENADE] client sent throw origin=%v vel=%v" % [origin, velocity])


# === NetPredictor hooks ===========================================================
# Each hook is invoked by NetPredictor via has_method() duck-typing. Order
# inside _physics_process is: gather -> simulate -> apply_state -> visualize
# -> apply_corrections (authority); consume queue -> simulate per frame ->
# apply_state -> broadcast (server); proxy_apply (proxy).

# Populate shadow/render state at spawn so they match the scene before tick 1.
# Without this, NetState defaults (pos=0, movement_state=0) disagree with the
# scene (MAP_SPAWN, INITIAL_STATE) until tick 1's _simulate overwrites them.
# NetPredictor calls this twice — once for shadow_state, once for render_state.
func _seed_state(state: PlayerState) -> void:
	state.pos = Constants.MAP_SPAWN
	state.velocity = Vector3.ZERO
	state.movement_state = %MovementStateMachine.state_to_id.get(
			%MovementStateMachine.INITIAL_STATE.name, 0)
	state.peek_state = %PeekStateMachine.state_to_id.get(
			%PeekStateMachine.INITIAL_STATE.name, 0)


func _gather_command(delta: float) -> PlayerInput:
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED:
		var cmd := PlayerInput.new()
		cmd.look_abs = _look_abs
		return cmd
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

	var cmd := PlayerInput.new()
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
	# Tap-vs-hold shift: tap toggles walk_mode, hold engages sprint after threshold.
	var shift_pressed := Input.is_action_pressed("sprint")
	var shift_just_pressed := Input.is_action_just_pressed("sprint")
	var shift_just_released := Input.is_action_just_released("sprint")
	var now_ms := Time.get_ticks_msec()
	if shift_just_pressed:
		_shift_press_time_ms = now_ms
		_shift_did_sprint = false
	var sprint_active := false
	if shift_pressed and _shift_press_time_ms >= 0 \
			and now_ms - _shift_press_time_ms >= SPRINT_HOLD_THRESHOLD_MS:
		sprint_active = true
		_shift_did_sprint = true
	if shift_just_released:
		if not _shift_did_sprint:
			_walk_mode = not _walk_mode
		_shift_press_time_ms = -1
		_shift_did_sprint = false
	cmd.sprint = sprint_active
	cmd.walk_mode = _walk_mode
	cmd.prone = Input.is_action_pressed("prone")
	cmd.shoot = Input.is_action_pressed("shoot")
	# Rising-edge timestamp for shoot. ShootHandler.[SHOOT-RENDER] reads this on
	# tracer arrival to compute trigger-to-tracer latency on the local shooter.
	if cmd.shoot and not _last_shoot_pressed:
		_shoot_local_edge_us = Time.get_ticks_usec()
		if SHOOT_DEBUG:
			print("[SHOOT-LOCAL t=%d us look=%s]" % [_shoot_local_edge_us, _look_abs])
	_last_shoot_pressed = cmd.shoot
	cmd.scope = Input.is_action_pressed("scope")
	# While dead, drop all actionable input. Look angles stay so we don't snap
	# the view at the moment of death; server also gates damage/throw on health.
	if _is_locally_dead():
		cmd.move_forward_backward = 0.0
		cmd.move_left_right = 0.0
		cmd.jump = false
		cmd.crouch = false
		cmd.prone = false
		cmd.sprint = false
		cmd.walk_mode = false
		cmd.peek_left_right = 0.0
		cmd.shoot = false
		cmd.scope = false

	return cmd


func _physics_process(_delta: float) -> void:
	if is_local_view:
		_update_tiredness_release_gate()


# While outside crouch/prone, refresh the tiredness hold anchor every tick
# UNTIL the player either reaches TIREDNESS_RELEASE_SPEED (75% of walk top
# speed) or has been moving continuously for TIREDNESS_RELEASE_CONTINUOUS_US.
# This keeps the slowdown pinned at peak through small steps / camera nudges
# right after standing up, so decay only kicks in once the player commits to
# moving. Crouch/prone states do their own per-tick refresh.
func _update_tiredness_release_gate() -> void:
	# Reset-when-cooled: once tiredness has decayed below the threshold (slowdown
	# < 1.05x), snap tiredness back to 0 and refill the free-bump pool so the
	# next crouch/prone is penalty-free again. Done outside crouch/prone to avoid
	# stomping a peak-hold that's about to be re-bumped.
	var cur: StringName = %MovementStateMachine.current_state
	if cur != &"CrouchMovementState" and cur != &"ProneMovementState":
		if _free_bumps_remaining < TIREDNESS_INITIAL_FREE_BUMPS:
			var t: float = current_tiredness()
			if t > 0.0 and t < TIREDNESS_RESET_THRESHOLD:
				_tiredness_base = 0.0
				_tiredness_decay_starts_at_us = 0
				_free_bumps_remaining = TIREDNESS_INITIAL_FREE_BUMPS
				if TIREDNESS_DEBUG:
					print("[TIRED reset] slowdown cooled below 1.05x (tired=%.3f) — pool refilled" % t)
	if cur == &"CrouchMovementState" or cur == &"ProneMovementState":
		_movement_started_us = 0
		return
	var horiz: float = Vector2(velocity.x, velocity.z).length()
	if horiz > 0.1:
		if _movement_started_us == 0:
			_movement_started_us = Time.get_ticks_usec()
	else:
		_movement_started_us = 0
	var released: bool = horiz >= TIREDNESS_RELEASE_SPEED
	if not released and _movement_started_us != 0:
		released = Time.get_ticks_usec() - _movement_started_us >= TIREDNESS_RELEASE_CONTINUOUS_US
	if not released:
		tiredness_refresh_hold()


func _process(_delta: float) -> void:
	if not TIREDNESS_DEBUG or not is_local_view:
		return
	_tiredness_log_ctr += 1
	if _tiredness_log_ctr < TIREDNESS_LOG_INTERVAL_TICKS:
		return
	_tiredness_log_ctr = 0
	var t: float = current_tiredness()
	var now: int = Time.get_ticks_usec()
	var in_hold: bool = now < _tiredness_decay_starts_at_us
	# Skip the line when there's nothing happening: no accumulated tiredness, no
	# active hold, no slowdown. Was firing constantly with base=0 current=0
	# slowdown=1.00x and drowning every other log.
	if _tiredness_base <= 0.001 and t <= 0.001 and not in_hold and tiredness_slowdown() <= 1.001:
		return
	var hold_remaining_ms: int = (_tiredness_decay_starts_at_us - now) / 1000 if in_hold else 0
	print("[TIRED tick] base=%.3f  current=%.3f  slowdown=%.2fx  hold=%s%s" % [
			_tiredness_base, t, tiredness_slowdown(),
			"yes" if in_hold else "no",
			("(%dms left)" % hold_remaining_ms) if in_hold else ""])


func _is_locally_dead() -> bool:
	if _net == null or _net.shadow_state == null:
		return false
	return (_net.shadow_state as PlayerState).health <= 0


# Wall-clock tiredness; identical on server + client modulo small clock drift
# (acceptable for transition-speed feel — reconcile will smooth any progress
# divergence). Replicate in PlayerState if drift becomes visible.
func current_tiredness() -> float:
	var now: int = Time.get_ticks_usec()
	if now < _tiredness_decay_starts_at_us:
		# Inside a peak-hold window — value is frozen at base.
		return clampf(_tiredness_base, 0.0, 1.0)
	var elapsed_s: float = float(now - _tiredness_decay_starts_at_us) / 1_000_000.0
	var decayed: float = _tiredness_base - (elapsed_s / TIREDNESS_DECAY_SEC)
	return clampf(decayed, 0.0, 1.0)


# Each call adds TIREDNESS_BUMP onto the current (decayed) tiredness, snapshots
# the new value as the base, and pushes the decay anchor TIREDNESS_PEAK_HOLD_SEC
# into the future so the new peak holds briefly before decay resumes.
func bump_tiredness(reason: String = "") -> void:
	if _free_bumps_remaining > 0:
		_free_bumps_remaining -= 1
		if TIREDNESS_DEBUG:
			print("[TIRED free] reason=%s  no increment (free pool remaining=%d)" % [
					reason, _free_bumps_remaining])
		return
	var before: float = current_tiredness()
	_tiredness_base = clampf(before + TIREDNESS_BUMP, 0.0, 1.0)
	_tiredness_decay_starts_at_us = Time.get_ticks_usec() + int(TIREDNESS_PEAK_HOLD_SEC * 1_000_000)
	if TIREDNESS_DEBUG:
		print("[TIRED bump] reason=%s  before=%.3f  +%.3f  -> base=%.3f  hold=%.2fs  slowdown=%.2fx" % [
				reason, before, TIREDNESS_BUMP, _tiredness_base, TIREDNESS_PEAK_HOLD_SEC, tiredness_slowdown()])


# Per-tick "freeze" used while a crouch/prone state is active so the peak
# slowdown actually persists through the whole transition + 0.25s grace after
# the state exits. Silent (no log) because it fires every tick. Snapshots the
# (frozen-or-decayed) current value into the base so the next decay window
# starts from exactly the visible value.
func tiredness_refresh_hold() -> void:
	_tiredness_base = current_tiredness()
	_tiredness_decay_starts_at_us = Time.get_ticks_usec() + int(TIREDNESS_PEAK_HOLD_SEC * 1_000_000)


# Loud version — refresh + log. Called at notable boundary events only
# (full crouch, full prone, fully stood up) for traceability.
func tiredness_hold_peak(reason: String = "") -> void:
	var snapshot: float = current_tiredness()
	tiredness_refresh_hold()
	if TIREDNESS_DEBUG:
		print("[TIRED hold] reason=%s  base=%.3f  hold=%.2fs  slowdown=%.2fx" % [
				reason, snapshot, TIREDNESS_PEAK_HOLD_SEC, tiredness_slowdown()])


# Slowdown multiplier in [1.0, 3.0]. slowdown(0)=1, slowdown(0.5)=1.5,
# slowdown(1)=3. Quadratic. Tune by changing the coefficient.
func tiredness_slowdown() -> float:
	var t: float = current_tiredness()
	return 1.0 + 2.0 * t * t


# Advance shadow_state forward by one cmd. State machines read player.input for
# edge detection, so we bind the context (prev / current) before stepping.
# Used in authority live ticks, server ticks, and replay after snapshot ack —
# must therefore be idempotent for a given (state, cmd) pair.
func _simulate(state: PlayerState, cmd: PlayerInput, delta: float) -> void:
	# Dead short-circuit: pin to the graveyard, kill velocity, leave state
	# machines untouched (no logic ticks while dead so gravity/transitions
	# don't run). Look stays current so look_abs returning at respawn isn't
	# jarring. ShootHandler._respawn_player overwrites pos+health, then this
	# branch stops gating and normal simulation resumes.
	if state.health <= 0:
		state.pos = Constants.GRAVEYARD
		state.velocity = Vector3.ZERO
		global_position = Constants.GRAVEYARD
		velocity = Vector3.ZERO
		state.look = cmd.look_abs
		# state.movement_state / peek_state / *_progress all stay at last value
		# so the proxy/visual representation doesn't churn on the graveyard.
		return
	# Tick 1: NetPredictor.previous_cmd is null until the framework records it
	# at the end of the first authority tick. Use current cmd as its own
	# predecessor so edge helpers (is_jump_just_pressed etc.) return false
	# instead of null-dereffing prev_input_packet.
	input.prev_input_packet = _net.previous_cmd if _net.previous_cmd != null else cmd
	input.input_packet = cmd

	# Body yaw drives wish-dir math in update_movement; pitch lives on the
	# camera (not the body). Phase 4 has already canonical-snapped the body to
	# shadow.pos before this hook ran, so move_and_slide integrates from the
	# authoritative origin.
	global_basis = Basis.from_euler(Vector3(0, cmd.look_abs.y, 0))
	%MovementStateMachine.run_logic(delta)
	%PeekStateMachine.run_logic(delta)

	state.pos = global_position
	state.velocity = velocity
	state.look = cmd.look_abs
	state.movement_state = %MovementStateMachine.get_logic_state_id()
	state.peek_state = %PeekStateMachine.get_logic_state_id()
	state.crouch_progress = %MovementStateMachine.crouch_progress
	state.prone_progress = %MovementStateMachine.prone_progress
	state.peek_progress = %PeekStateMachine.peek_progress


# Snap the state-machine + animation-progress representation to state ahead of
# replay. Framework rewinds the body (transform + velocity) before this hook
# runs, so all we restore here is non-body sim state.
func _load_simulation_state(state: PlayerState) -> void:
	# Restore animation progress BEFORE set_logic_state_by_id. Reconcile
	# semantics: the replay must start from the *server-confirmed* state, not
	# the client's stale prediction. Without this restore, replay's first
	# logic_physics call advances from whatever progress the client had at the
	# moment reconcile fired, and the K replay steps accumulate on top of that —
	# producing a "game state bounce" visible 1:1 in the model (camera/skeleton
	# jitter). Restoring here makes replay deterministic: progress at start of
	# replay matches the snapshot, replay re-fires the K predicted steps, and
	# the post-replay value equals the client's prediction.
	%MovementStateMachine.crouch_progress = state.crouch_progress
	%MovementStateMachine.prone_progress = state.prone_progress
	%PeekStateMachine.peek_progress = state.peek_progress
	%MovementStateMachine.set_logic_state_by_id(state.movement_state)
	%PeekStateMachine.set_logic_state_by_id(state.peek_state)


# Visual-side alignment from shadow. On the server this is the only scene
# write (no smoothing, no separate visual physics). On the client authority,
# we *do not* touch pos/velocity here — visual physics runs in _visualize and
# corrections in _apply_corrections will pull the scene toward shadow. Camera
# + state-machine sync_visual fires here so visual_physics sees the updated
# visual state when it runs next.
func _apply_state(state: PlayerState) -> void:
	_set_dead_visual(state.health <= 0)
	# Dead players are pinned to the graveyard regardless of role/authority so
	# reconcile smoothing can't drag the scene through the world toward the
	# off-map position. Snap directly; visual_physics is short-circuited too.
	if state.health <= 0:
		global_position = Constants.GRAVEYARD
		velocity = Vector3.ZERO
		return
	if _net.is_authoritative_instance:
		global_position = state.pos
		velocity = state.velocity
		global_transform.basis = Basis.from_euler(Vector3(0, state.look.y, 0))
		# Sync visual SMs so AnimationTree transitions fire (crouch/prone/peek
		# pose visible on server-side render). _visualize is gated off on the
		# server so visual_physics doesn't run; we drive the AnimationTree
		# seek_requests from shadow directly here instead.
		%MovementStateMachine.sync_visual()
		%PeekStateMachine.sync_visual()
		animation_tree.set("parameters/CrouchTimeSeek/seek_request", state.crouch_progress)
		animation_tree.set("parameters/ProneTimeSeek/seek_request", state.prone_progress)
		animation_tree.set("parameters/PeekTimeSeek/seek_request", absf(state.peek_progress))
		animation_tree.set("parameters/Add Peek/add_amount",
				-1.0 if state.peek_progress < 0.0 else 1.0)
		return
	update_camera(state.look)
	%MovementStateMachine.sync_visual()
	%PeekStateMachine.sync_visual()


# Animation-progress / SFX advance. Phase 5: visual_physics no longer runs
# move_and_slide — the framework writes the visible pos via the smoothing
# offset path. State scripts retain visual_physics only for animation seek
# updates (CrouchTimeSeek, ProneTimeSeek, etc.). Skipped on the server.
func _visualize(delta: float, _state: PlayerState) -> void:
	if _net.is_authoritative_instance:
		return
	%MovementStateMachine.run_visual(delta)
	%PeekStateMachine.run_visual(delta)


# Bridge scene -> typed Resource for the framework's corrections pass. Called
# after _visualize, before _corrections_pass. Phase 5: pos/velocity are owned
# by the framework's SMOOTHED_OFFSET path (see schema.corrections) so the host
# only captures animation-progress / state-machine ids.
func _capture_render_state(state: PlayerState) -> void:
	state.look = _look_abs
	state.movement_state = %MovementStateMachine.get_logic_state_id()
	state.peek_state = %PeekStateMachine.get_logic_state_id()
	state.crouch_progress = %MovementStateMachine.crouch_progress
	state.prone_progress = %MovementStateMachine.prone_progress
	state.peek_progress = %PeekStateMachine.peek_progress


# Phase 5: framework writes the visible body pos via the smoothing-offset
# path; this hook is debug-only. Emit the reconcile signal so the network
# debug overlay still sees pre-corrections deltas.
func _apply_corrections(_state: PlayerState) -> void:
	if _net.is_authoritative_instance:
		return
	var shadow: PlayerState = _net.shadow_state as PlayerState
	if shadow != null:
		reconcile_network_debug.emit(
				shadow.pos - global_position,
				shadow.velocity - velocity,
				_net.unacked_inputs)


# Remote proxy: framework has already fetched the interp pair from the state
# buffer. We blend pos / velocity / look, then drive visual SMs via state ids
# + progress fields. extrapolation_s > 0 when the buffer is empty in the
# future direction.
func _proxy_apply(from_state, to_state, alpha: float, extrapolation_s: float, _segment_s: float, delta: float) -> void:
	# Remote proxy visibility: hide once health hits 0 so other clients see
	# dead players vanish in lockstep with the death overlay on the victim.
	var proxy_hp: int = (from_state as PlayerState).health
	if to_state != null:
		proxy_hp = (to_state as PlayerState).health if alpha >= 0.5 else proxy_hp
	_set_dead_visual(proxy_hp <= 0)
	if proxy_hp <= 0:
		global_position = Constants.GRAVEYARD
		velocity = Vector3.ZERO
		return
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

func set_parameters(speed: float, acceleration: float, strafe_scale: float = 1.0) -> void:
	_speed = speed
	_acceleration = acceleration
	_strafe_scale = strafe_scale


func on_floor() -> bool:
	var grounded := is_on_floor()
	if grounded:
		last_grounded_height = global_position.y
	return grounded


# persistent local vars for performance
var _player_rotation: Vector3 = Vector3.ZERO
var _camera_rotation: Vector3 = Vector3.ZERO
func update_camera(look_abs: Vector2) -> void:
	_player_rotation.y = look_abs.y
	_camera_rotation.x = look_abs.x
	# Only drive $CameraController.basis from free_look when free_look is
	# actively engaged or still decaying. When neither, the AnimationTree's
	# peek animation owns CameraController:rotation (lean transform) — writing
	# basis here unconditionally would nuke that animation each tick, killing
	# first-person peek visuals.
	if is_local_view and (Input.is_action_pressed("free_look") \
			or _free_look_abs.length_squared() > 0.0001):
		var free_look := Vector3(_free_look_abs.x, _free_look_abs.y, 0.0)
		$CameraController.basis = Basis.from_euler(free_look)

	camera.transform.basis = Basis.from_euler(_camera_rotation)
	camera.rotation.z = 0
	tp_camera.transform.basis = Basis.from_euler(_camera_rotation)
	tp_camera.rotation.z = 0

	if is_local_view:
		global_transform.basis = Basis.from_euler(_player_rotation)
	else:
		global_transform.basis = Basis.from_euler(Vector3(0, look_abs.y, 0))

	# reset input integration
	_x_mouse_input = 0.0
	_y_mouse_input = 0.0


func update_gravity(delta: float) -> void:
	velocity += get_gravity() * delta


func update_movement(delta: float) -> void:
	var _input_dir := Vector2(
		input.input_packet.move_left_right * _strafe_scale,
		input.input_packet.move_forward_backward,
	)

	var wish_dir := (transform.basis * Vector3(_input_dir.x, 0, _input_dir.y)).normalized()

	var grounded := on_floor()
	var horizontal_vel := Vector3(velocity.x, 0, velocity.z)
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

	velocity.x = horizontal_vel.x
	velocity.z = horizontal_vel.z


func update_velocity() -> void:
	move_and_slide()


func despawn() -> void:
	print("I'm (%s) being despawned!" % name)
	if is_local_view: get_tree().change_scene_to_file(Constants.MAIN_MENU_SCENE_PATH)


# Toggle dead visual: hide capsule + collision mesh while dead. CameraController
# stays active so the local view keeps rendering (over the dead-overlay HUD).
var _dead_visual_state: bool = false

func _set_dead_visual(dead: bool) -> void:
	if dead == _dead_visual_state:
		return
	_dead_visual_state = dead
	var vc: Node = get_node_or_null("VisualCollider")
	# First-person hands (under camera) — hide them too so dead spectator camera
	# isn't waving floating hands. (Local death also drops a full-screen black
	# overlay in the HUD, so this is mostly belt-and-suspenders.)
	var fp_hands: Node = get_node_or_null("CameraController/Camera3D/Sketchfab_Scene")
	var los: Node = get_node_or_null("CameraController/Camera3D/LineOfSightMesh")
	if vc != null:
		vc.visible = not dead
	if fp_hands != null:
		fp_hands.visible = not dead
	if los != null:
		los.visible = not dead
	# Note: physics collisions stay enabled (ShootHandler uses analytical capsule
	# tests against shadow_state, not physics raycasts, and we want the corpse
	# to keep standing on the floor until respawn snaps it).
