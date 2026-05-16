# NetSynchronizer — Body-Aware Prediction Extension

Status: **Phases 1, 2, 4, 5 shipped (player on single body via framework-owned smoothing offset). Phase 6.1 + 6.2 shipped (explicit Archetype enum + NetReplicator folded into NetPredictor). Phase 6.3 (NetBodyAdapter) + 6.4 (per-field smoothing) deferred until a 2nd body type / 2nd predicted body type lands.** Companion to `netcode-design.md`. Active on branch `refactor/netcode-synchronizer` (worktree at `/Users/rholmdahl/Documents/game/first-test-synchronizer`).

This doc proposes extending `NetPredictor` (or extracting a `NetSynchronizer` peer) so the framework owns body-rewind semantics across multiple body shapes — eliminating the host's dual-`CharacterBody3D` workaround for prediction-with-replay without forcing a hand-rolled `move_and_slide` reimplementation.

## Phase tracker

| Phase | Status | Commit | Scope |
|---|---|---|---|
| 1. NetPredictor.body export + framework rewind primitive | ✅ done | `b826a8b` | Opt-in `body: NodePath`, `BodyKind` enum, `_rewind_body` for CharacterBody3D / RigidBody3D / AnimatableBody3D / Node3D, wired into `_reconcile_replay`. No behavior change for existing entities (default empty path). |
| 2. Grenade → NetReplicator | ✅ done | `f483cc3` | Grenade moved off NetPredictor + manual broadcast. NetReplicator gained server-tick gating; `_capture_state(state, delta)` contract. |
| 3. ~~Player single-body migration (naive)~~ | ❌ halted | — | Tracing revealed visual `move_and_slide` in `_visualize` is the smoothing mechanism, not redundant work. Original Phase 3 plan would lose reconcile smoothing. Replaced by Phase 4 below. |
| 4. Framework-owned visual smoothing offset | ✅ done | — | `_smoothing_offset_pos` + per-axis decay + canonical-snap shuffle in NetPredictor; new `SMOOTHED_OFFSET` mode on NetCorrection with validator. See §8 + §13. |
| 5. Player migration to single body | ✅ done | — | `body = ^".."` on player NetPredictor; GameController + dual-body animation tracks deleted; `IntegrationContext` collapsed; schema channels flipped to SMOOTHED_OFFSET on pos. See §9. |
| 6.1. Explicit Archetype enum | ✅ done | — | `NetSchema.Archetype { PREDICTED, REPLICATED, LOCAL_ONLY }` + `_validate_archetype` + `_validate_correction_modes` retargeted at archetype. See §10.1. |
| 6.2. Fold NetReplicator into NetPredictor | ✅ done | — | `_physics_process` dispatches by archetype; `_replicator_server_tick` folded in; `net_replicator.gd` deleted; grenade.tscn + schema migrated. See §10.2. |
| 6.3. NetBodyAdapter Resource | 🟦 deferred | — | Defer until 2nd non-CharacterBody3D / non-RigidBody3D body type lands. See §10.3. |
| 6.4. Per-field smoothing offset (velocity + rotation) | 🟦 deferred | — | Defer until 2nd predicted body type (vehicle). See §10.4. |
| 6.5. Editor-time decay preview | 🟦 deferred | — | QoL; not gating. See §10.5. |

**Test parity (Phases 1+2+4+5+6.1+6.2):** Worktree adds archetype validation tests (`archetype_missing_command_template` ERROR, `archetype_dead_command_template` WARNING, SMOOTHED_OFFSET-requires-PREDICTED, schema archetype sanity). The 1 pre-existing failure (`test_player_input_fields_user_authored: missing field: last_received_tick`) is unrelated to this work.

---

## 0. Motivation

Today the player uses **two `CharacterBody3D` nodes** under `PlayerController`:

- `PlayerController` (root) — visual body, integrated each frame with its own `move_and_slide`. Corrections lerp this toward shadow.
- `GameController` (child, `top_level=true`) — sim body, mutated by `_simulate` during live ticks and during reconcile replay.

This pattern exists because `CharacterBody3D.move_and_slide` is opaque (floor snap, slope angles, slide iterations, ceiling, platform velocity) and recovering a body's state mid-tick for replay is fragile. The sim body acts as a clean rewind puppet so the visual body never witnesses the K replay steps the framework runs after a snapshot ack.

Costs of dual-body:

- Two bodies in physics broadphase per player
- `add_collision_exception_with` bookkeeping
- Animation tracks duplicate every shape mutation (`VisualCollider:shape:height` AND `GameController/GameCollider:shape:height` per Crouch/Prone/Peek)
- ShootHandler must remember which body is "the player"
- State diverges silently if one body's mutation is missed in some code path

Goal: keep the prediction-with-replay guarantee but reduce to one body — without writing a custom slide algorithm.

---

## 1. Why single-body works (the misconception to clear)

Common objection: *"If the framework rewinds + replays K inputs each tick against the same body the player sees, the body must jitter."*

Untrue. Godot's frame loop is:

```
[all _physics_process invocations for this frame] → [_process] → [render]
```

Reconcile + replay + new sim tick all complete **inside one `_physics_process` invocation** of `NetPredictor`. The body teleports through K intermediate poses, but render never samples those intermediate poses — only the final post-tick pose is drawn. **No frame ever sees mid-replay state**, so there is nothing to jitter.

The body churns invisibly. Three real concerns remain, all manageable:

1. **`CharacterBody3D` cached flags.** `is_on_floor()` returns the value cached by the last `move_and_slide`. After a teleport-to-rewind-pos, this value is stale until the first replay step's `move_and_slide` runs. Mitigation: framework runs a dummy zero-motion `move_and_slide` after teleport to refresh flags before host's `_simulate` reads them.
2. **Godot physics interpolation.** When `physics_interpolation_mode = ON`, the renderer lerps mesh transform between two physics-tick poses. Across a rewind that lerp spans pre-rewind ↔ post-replay → visible jitter. Mitigation: framework calls `reset_physics_interpolation()` on the body after rewind.
3. **AnimationTree time / blend trees.** Already protected by your `_logic_state` vs `_visual_state` split — the state machines operate on IDs, not body transform. Migration preserves this.

None of these are showstoppers. They are framework discipline points, not host concerns.

---

## 2. Entity archetypes

The codebase has a single component class (`NetPredictor`). Phase 6.1 + 6.2 collapsed `NetReplicator` onto `NetPredictor` via an explicit `NetSchema.Archetype` enum {PREDICTED, REPLICATED, LOCAL_ONLY}. Historical text below references the pre-fold two-class layout.

| Archetype | Inputs | Server sims | Client predicts | Client proxies | Examples in repo |
|---|---|---|---|---|---|
| **Predicted command-driven (PCD)** | yes (client→server) | yes | yes (authority) | yes (others) | Player |
| **Server-state-only (SSO)** | no | yes | no | yes (all clients) | Grenade, doors, props, NPC AI, vehicles in "ghost" mode |
| **Server command-driven (SCD)** | yes (server-internal) | yes | no | yes | Server-AI driven NPC if you want explicit cmd records for replay determinism. *No current usage.* |
| **Local-only** | n/a | n/a | n/a | n/a | UI entities, debug overlays — no synchronizer at all |

Inferred today from `command_template`:
- `command_template != null` → PCD
- `command_template == null` → SSO (NetReplicator subclass) OR SSO-manual (grenade, uses NetPredictor without command, broadcasts itself)

The grenade is currently misclassified: it uses `NetPredictor` because that's where snapshot codec + broadcast live, but conceptually it's SSO. `NetReplicator` was built for this case but the grenade pre-dated it and bypassed it. Migration should regularize this.

---

## 3. Body-shape catalog

What does the body do during simulation, and what does rewind look like?

| Body type | Server integration | Predict-viable? | Rewind cost |
|---|---|---|---|
| **`CharacterBody3D`** | host calls `move_and_slide()` in `_simulate` | Yes — kinematic, deterministic given identical inputs (modulo soft-determinism drift) | transform + velocity + dummy `move_and_slide` (floor flags) + `reset_physics_interpolation` |
| **`RigidBody3D` default** | engine integrates each physics step | **No** — non-deterministic across platforms; engine integrates at global rate regardless of synchronizer gate | `PhysicsServer3D.body_set_state(BODY_STATE_TRANSFORM/LINEAR_VELOCITY/ANGULAR_VELOCITY)` + `reset_physics_interpolation` |
| **`RigidBody3D` with `custom_integrator=true`** | host overrides `_integrate_forces(state)`; engine collides but doesn't integrate forces | Yes — host owns integration math | same as RigidBody default, but rewind also resets host-tracked tunables |
| **`AnimatableBody3D`** | host writes `global_transform`; engine sweeps next step for kinematic collisions | Yes for kinematic-driven entities | `global_transform` only |
| **`Node3D` + manual ballistic** | host integrates pose + uses `PhysicsDirectSpaceState3D.intersect_ray`/`_shape` for collision queries | Yes — fully under host control | `global_transform` + host's internal velocity field |
| **`StaticBody3D`** | rare predict candidate; discrete state changes (door open/closed) | No prediction, just SSO with infrequent updates (often better served by reliable RPC) | `global_transform` only |
| **`Area3D`** | no physics state, just trigger membership | Server-only; clients receive AOI events via reliable hub instead | n/a |

Predict viability rule of thumb: if integration is **deterministic** (host computes velocity, host applies it) → predict-safe. If engine integrates dynamics → SSO only.

The grenade is RigidBody3D default — correct that it's SSO. The player is CharacterBody3D — correct that it's PCD.

---

## 4. Ownership decisions

Who calls what, after the proposed change:

| Concern | Owner |
|---|---|
| `_gather_command` | host (PCD only) |
| Velocity math (gravity, wishdir, friction) | host (in `_simulate`) |
| Integration call (`move_and_slide` / `_integrate_forces` / manual ballistic) | host (in `_simulate`) — host knows the body type, framework does not need to |
| Snapshot capture for SSO (no `_simulate`) | host (`_capture_state` hook) |
| Body teleport on rewind | **framework** (new) |
| Floor-flag refresh / physics-interp reset | **framework** (new) |
| Replay loop driving `_simulate` K times | framework (already does) |
| Snapshot encode / decode / delta / keyframe | framework (already does) |
| Proxy interp (field_interp blending) | framework (already does) |
| Correction smoothing on render_state | framework (already does, via `corrections` channel config) |
| `_apply_state` / `_apply_corrections` / `_capture_render_state` writes to scene | host |
| `_proxy_apply` writes blended state to scene | host (or pure field_interp if no host hook) |

Key delta from today: **framework owns rewind**. Host stops needing a separate rewind body (`game_body`) because the synchronizer guarantees the host's body is at the correct rewound state when `_simulate` is called during replay.

Host stays in charge of physics call inside `_simulate` because:
- The integration shape varies per body type (move_and_slide vs custom_integrator vs raycast ballistic), and forcing framework dispatch would either limit the set of supported bodies or grow a combinatorial per-type API
- The host already has type information for the body (`extends CharacterBody3D`, etc.) — single inheritance gives this for free
- Velocity math is gameplay logic (acceleration, jump, crouch tunables) — framework has no business with it

---

## 5. Proposed extension

### 5.1 Surface change to `NetPredictor`

Add one export. Default-empty preserves all current behavior.

```gdscript
# net_predictor.gd
## Optional path to the simulated body. When set, the framework owns
## rewind discipline (transform + velocity reset, physics-interp reset,
## CharacterBody3D floor-flag refresh) for this body around replay,
## reconcile, and lag-compensation rewinds. When unset, host owns all
## body manipulation (current behavior — supports the dual-body player
## pattern during migration).
@export var body: NodePath = ^""
```

At `_ready`, resolve once and remember the body type:

```gdscript
enum BodyKind { NONE, CHAR_BODY, RIGID_BODY, ANIMATABLE_BODY, NODE3D }

var _body: Node = null
var _body_kind: BodyKind = BodyKind.NONE

func _resolve_body() -> void:
    if body.is_empty():
        return
    _body = get_node_or_null(body)
    if _body == null:
        push_warning("NetPredictor.body path '%s' did not resolve" % body)
        return
    if _body is CharacterBody3D:    _body_kind = BodyKind.CHAR_BODY
    elif _body is RigidBody3D:      _body_kind = BodyKind.RIGID_BODY
    elif _body is AnimatableBody3D: _body_kind = BodyKind.ANIMATABLE_BODY
    elif _body is Node3D:           _body_kind = BodyKind.NODE3D
```

### 5.2 The rewind primitive

```gdscript
# Snap the body to the pose carried in `state`. Called by:
#   - _reconcile_replay (authority)        — before stepping unacked inputs
#   - handle_net_state_packet on proxies   — when field_interp is empty and
#       host wants framework-driven snap (opt-in via a schema flag, TBD)
#   - NetLagCompensator (server)           — rewind + restore for hitscan
#
# Host's _load_simulation_state still runs *after* this for state-machine
# / animation-tree restoration that the framework can't see.
func _rewind_body(state: NetState) -> void:
    if _body == null or state == null:
        return
    match _body_kind:
        BodyKind.CHAR_BODY:
            var cb := _body as CharacterBody3D
            cb.global_position = state.pos
            cb.velocity = state.velocity
            cb.reset_physics_interpolation()
            # Floor flag refresh: zero-motion move_and_slide updates
            # is_on_floor / get_floor_normal so the first replay step
            # doesn't read a stale value from the live frame's move.
            var v := cb.velocity
            cb.velocity = Vector3.ZERO
            cb.move_and_slide()
            cb.velocity = v
        BodyKind.RIGID_BODY:
            var rb := _body as RigidBody3D
            var rid := rb.get_rid()
            PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM,
                    Transform3D(state.get(&"rotation_quat") if &"rotation_quat" in state, state.pos))
            PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY,
                    state.velocity)
            if &"angular_velocity" in state:
                PhysicsServer3D.body_set_state(rid,
                        PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY,
                        state.angular_velocity)
            rb.reset_physics_interpolation()
        BodyKind.ANIMATABLE_BODY, BodyKind.NODE3D:
            _body.global_position = state.pos
            if &"rotation_quat" in state:
                _body.global_basis = Basis(state.rotation_quat)
            _body.reset_physics_interpolation()
        BodyKind.NONE:
            return
```

Field-name presence checks (`&"rotation_quat" in state`) keep the rewind tolerant of schemas that don't replicate rotation/angular velocity — common for capsule players where rotation is camera-driven and not part of state.

### 5.3 Reconcile-replay path with rewind delegated

```gdscript
func _reconcile_replay(new_sequence_id: int) -> void:
    game_sequence_id = new_sequence_id
    is_replaying_inputs = true
    # NEW: framework rewinds the body. Host's _load_simulation_state
    # runs after, for things the framework can't see (state machine ids,
    # animation progress, etc.).
    _rewind_body(shadow_state)
    if host and host.has_method(&"_load_simulation_state"):
        host._load_simulation_state(shadow_state)
    # ... existing replay loop unchanged ...
```

Host's `_load_simulation_state` shrinks from "rewind everything" to "restore non-body sim state":

```gdscript
# Before
func _load_simulation_state(state: PlayerState) -> void:
    game_transform.origin = state.pos
    game_transform.basis = ...
    game_velocity = state.velocity
    game_movement_state_id = state.movement_state
    %MovementStateMachine.crouch_progress = state.crouch_progress
    %MovementStateMachine.set_logic_state_by_id(state.movement_state)
    # ...

# After (body fields owned by framework)
func _load_simulation_state(state: PlayerState) -> void:
    %MovementStateMachine.crouch_progress = state.crouch_progress
    %MovementStateMachine.prone_progress = state.prone_progress
    %PeekStateMachine.peek_progress = state.peek_progress
    %MovementStateMachine.set_logic_state_by_id(state.movement_state)
    %PeekStateMachine.set_logic_state_by_id(state.peek_state)
```

---

## 6. Host responsibilities per archetype

After the change, with `body: NodePath` set, host hooks shrink:

### 6.1 PCD (player)

Required: `_gather_command`, `_simulate`, `_apply_state`, `_visualize`, `_apply_corrections`, `_capture_render_state`, `_proxy_apply` (or pure field_interp), `_seed_state`, `_load_simulation_state` (non-body restore only).

`_simulate` body (illustrative):
```gdscript
func _simulate(state: PlayerState, cmd: PlayerInput, delta: float) -> void:
    # body is the player's CharacterBody3D — same node as the host now,
    # since we dropped GameController.
    input.prev_input_packet = ...
    input.input_packet = cmd
    %MovementStateMachine.run_logic(delta)  # writes velocity into the body
    move_and_slide()                          # body's own method (self)
    state.pos = global_position
    state.velocity = velocity
    state.movement_state = %MovementStateMachine.get_logic_state_id()
    # ...
```

Visual integration disappears: there is no separate visual body. `_visualize` runs animation state machines but does NOT call `move_and_slide` on a second body. `_apply_corrections` writes corrected pos directly onto `global_position` (already does this — line 630 of `player.gd`).

### 6.2 SSO with engine-integrated body (grenade)

Required: `_capture_state(state)` reading body → state. Optional `_proxy_apply` if schema's `field_interp` doesn't cover it.

```gdscript
# grenade.gd
func _physics_process(delta: float) -> void:
    if not NetSession.is_server: return
    # gated by _tick_every (existing pattern)
    var s: GrenadeState = _net.shadow_state
    s.pos = global_position           # engine integrated us
    s.velocity = linear_velocity
    s.rotation_quat = global_basis.get_rotation_quaternion()
    s.fuse_remaining -= dt
    # ... game logic on s.state ...
    _net.server_broadcast_snapshot(0)
```

Alternative cleaner: use NetReplicator base and let it call `_capture_state` for you each gated tick. Grenade was hand-rolled before NetReplicator stabilized.

### 6.3 SSO with manual ballistic (Node3D projectile / NPC AI)

Required: own `_physics_process` integration + `_capture_state`. Framework's rewind unused on server (no replay). Clients use schema's `field_interp` (PREDICTED with velocity + acceleration) to render smoothly.

### 6.4 Local-only

No synchronizer node. Out of scope.

---

## 7. What this fixes for the player (concretely)

After migration with `body` set to the root `CharacterBody3D`:

- Delete `GameController` and its `GameCollider` from `player.tscn`
- Delete duplicate animation tracks (`GameController/GameCollider:shape:height`, `:position`, `:rotation`, `/PlaceholderMesh:mesh:height`) from Crouch / PeekLeft / PeekRight / Prone2 / RESET
- Delete `add_collision_exception_with(game_body)` and friends from `_ready`
- Delete `game_transform` / `game_position` / `game_velocity` / `game_movement_state_id` / `game_sequence_id` proxy properties from `PlayerController` — sim writes/reads the root body directly
- `update_velocity(ctx)` collapses: no GAME vs VISUAL branch; one call to `move_and_slide()`
- `_visualize` stops calling `move_and_slide` — animation SMs continue advancing visual state (logic_state vs visual_state split still useful for animation graph driving), they just don't integrate a second body
- ShootHandler unambiguous: the body IS the hitbox (and lag-comp rewind already operates against analytical capsules via shadow_state, so no change there)

What stays:
- `_logic_state` / `_visual_state` split on state machines — orthogonal to bodies, still useful for animation
- All correction smoothing, prediction error tunables, snap thresholds — these operate on render_state vs shadow_state, framework-driven
- `shadow_state_applied` signal flow for NetLagCompensator — gets rewired to write the root body instead of game_body

---

## 8. Phase 4 — framework-owned visual smoothing offset

### 8.1 What killed the naive Phase 3

The original Phase 3 plan (set `body = ^"."` on player, drop `_visualize`'s `move_and_slide`, framework rewinds root body during reconcile) **looks** like it should work because §1 of this doc established that intra-tick body churn is invisible to render.

Reading the actual code path during a reconcile event showed the problem: **the visual `move_and_slide` in `_visualize` is the smoothing mechanism, not redundant work.**

The dual-body trick today:

1. `_simulate` (GAME ctx) runs `game_body.move_and_slide()` → `shadow.pos`. This is the canonical predicted trajectory.
2. `_visualize` (VISUAL ctx) runs `move_and_slide()` on the root body **independently** — same wishdir, same gravity, same friction, but starting from the root's *own* previous position.
3. `_capture_render_state` reads the root body into `render_state`.
4. `_corrections_pass` lerps `render_state` toward `shadow_state` per `NetCorrection` channel config.
5. `_apply_corrections` writes `render_state` back to the root body.

At 0 ping the two bodies produce identical trajectories (deterministic given identical inputs), so render = shadow, corrections lerp is identity, no work happens — visually identical to single-body.

**Under reconcile:** `_reconcile_replay` rewinds `game_body` to the acked pos and replays K inputs → `game_body` teleports to new-predicted-current. **Root body is untouched.** Next tick the root continues from where the player was *seeing* themselves (= old-predicted), the corrections pass sees the delta against new-shadow, and the lerp pulls the root toward shadow over many ticks. That's the smoothing.

Naive Phase 3 collapses this: with one body, `_capture_render_state` reads `body.global_position` which is the *post-reconcile* position. `render_state = shadow_state` always → corrections are identity → reconcile becomes a visible visual snap. Players would see themselves teleport on every snapshot mismatch.

### 8.2 The visual-offset pattern (CS:GO / Source equivalent)

Replace the parallel-body smoothing with a single vector of state on `NetPredictor`:

```gdscript
# Authority-only state, additive to shadow.pos when writing the body.
var _smoothing_offset_pos: Vector3 = Vector3.ZERO
```

**Per-tick invariant** (authority): `body.global_position = shadow.pos + _smoothing_offset_pos`. At 0 ping with no reconcile the offset stays zero — body sits exactly at shadow, identical to single-body behavior.

**Per-tick decay:**

```gdscript
_smoothing_offset_pos = _smoothing_offset_pos.lerp(
    Vector3.ZERO,
    1.0 - exp(-decay_rate * delta))
```

**Reconcile preservation** — this is the load-bearing move:

```gdscript
# In _reconcile_replay, BEFORE the framework rewinds the body:
var pre_visible_pos: Vector3 = body.global_position

# Framework rewinds body to shadow_acked + runs replay loop.
# After replay: shadow.pos = new_predicted_current, body.pos = new_predicted_current.

# Compute offset that preserves visible pose:
_smoothing_offset_pos = pre_visible_pos - shadow.pos

# Optional safety: huge desyncs hard-snap instead of dragging
if _smoothing_offset_pos.length() > snap_threshold:
    _smoothing_offset_pos = Vector3.ZERO

# Body returns to where the player was seeing themselves:
body.global_position = shadow.pos + _smoothing_offset_pos
```

Over the next N ticks the offset decays to zero → body smoothly converges from old-predicted toward new-predicted trajectory. This is **structurally identical** to today's dual-body smoothing, just stored as one vector instead of as a parallel scene-graph trajectory.

### 8.3 Per-tick rhythm — the full `_authority_tick` order

`move_and_slide()` reads `body.global_position` as its integration start. If we leave the body at `shadow.pos + offset` (visible pos), the next `_simulate` integrates from the wrong start and `shadow.pos` diverges from the canonical predicted trajectory. The framework brackets the existing `_authority_tick` chain with a canonical-snap (pre-sim) and a visible-snap (post-corrections):

```gdscript
func _authority_tick(delta):
    var cmd = host._gather_command(delta)
    # ... encode cmd, send w/ redundancy ...

    # 1. Snap body to canonical so move_and_slide integrates from the truth,
    #    not from last tick's visible position.
    body.global_position = shadow.pos

    # 2. Host integrates. _simulate calls move_and_slide on body and writes
    #    state.pos = body.global_position. Body now at new shadow.pos.
    host._simulate(shadow, cmd, delta)

    # 3. Visual state (camera orient, animation seek). Phase 5 hosts: no
    #    pos/velocity writes here.
    host._apply_state(shadow)

    # 4. Animation tree advance. Phase 5 hosts: no move_and_slide in
    #    run_visual; animation progress only.
    host._visualize(delta, shadow)

    # 5. Capture non-pos/velocity render fields (animation progress).
    host._capture_render_state(render)

    # 6. Lerp render→shadow on schema.corrections. pos channels in
    #    SMOOTHED_OFFSET mode are skipped here (framework owns them).
    _corrections_pass(delta)
    host._apply_corrections(render)

    # 7. Decay offset, write visible pos onto body so renderer samples
    #    shadow+offset this frame. Camera (grandchild of body) auto-follows.
    _smoothing_offset_pos = _smoothing_offset_pos.lerp(
        Vector3.ZERO, 1.0 - exp(-decay_rate * delta))
    body.global_position = shadow.pos + _smoothing_offset_pos
```

Velocity stays at the post-`move_and_slide` value (canonical). No per-tick `reset_physics_interpolation()` — see §8.6.

Compared to dual-body the savings are:

- 1 body removed from broadphase
- 1 `move_and_slide()` removed per tick (the VISUAL one)
- 0 animation-track duplication
- 0 `add_collision_exception_with` bookkeeping
- 0 host-side `game_*` proxy properties

Net win in CPU and scene complexity. The dual-body wasn't paying for itself except as the smoothing mechanism, and the offset variable replicates that mechanism in 5 lines.

### 8.4 Framework-owned vs game-owned

**Framework owns:**
- `_smoothing_offset_pos` lifecycle (init, decay, reconcile capture, snap-clamp)
- The body-position shuffle around `_simulate`
- `reset_physics_interpolation()` calls on snap-clamp events only (see §8.6)
- Snap-on-huge-divergence threshold

**Game still owns:**
- `_simulate` body — velocity math, gravity, `move_and_slide()` call (framework can't know which integrator)
- `_apply_state` — animations, camera glue, visual SM sync
- Schema config — decay rate + snap threshold (lives in a `NetCorrection` channel for `pos`)
- Per-field opt-in semantics

**No game-specific code for the smoothing itself.** Every predicted entity (player, future vehicles, anything client-authoritative-with-prediction) gets it free.

### 8.5 Integration with existing `NetCorrection` config

The existing channel resource already has the right knobs:

```
NetCorrection {
    name: "horizontal"
    fields: ["pos.xz"]
    snap_threshold: 2.0   # offset magnitude beyond which we hard-snap
    smooth_rate: 8.0      # exponential decay rate
    deadband: 0.005       # below this, just zero the offset
}
```

The framework reinterprets these as offset-decay knobs when a new mode flag (`SMOOTHED_OFFSET` vs the existing `RENDER_LERP`) is set on the channel.

**Math semantics differ between modes (knobs same):**

- **RENDER_LERP** (today): each tick computes a fresh `err = shadow_field - render_field`; alpha derived as `correction_alpha(err / snap_threshold, smooth_rate, delta)` — larger errors close faster, no state carries between ticks.
- **SMOOTHED_OFFSET** (Phase 4): offset captured once on reconcile, decayed each tick at fixed rate `exp(-smooth_rate * delta)` — closing duration is constant regardless of magnitude (up to the snap clamp). State carries between ticks.

SMOOTHED_OFFSET is what competitive FPS engines (CS:GO, Source) use for predicted entities — consistent feel and predictable settle time. RENDER_LERP stays the default for animation-progress scalars and any non-predicted entity where magnitude-scaled closing is what you want.

Decision: explicit `mode` enum on the channel. Predicted player and future vehicles opt in; grenade (server-state-only) leaves it at RENDER_LERP.

### 8.6 Concrete framework changes for Phase 4

In `addons/netcode/components/net_predictor.gd`:

1. Add `var _smoothing_offset_pos: Vector3 = Vector3.ZERO` (authority-only).
2. Add the canonical-snap (pre-`_simulate`) and visible-snap (post-`_apply_corrections`) inside `_authority_tick` per §8.3.
3. In `_reconcile_replay`: capture `pre_visible_pos` before the existing `_rewind_body` call; after the replay loop, compute `_smoothing_offset_pos = pre_visible_pos - shadow.pos`, snap-clamp, and re-write body. Call `body.reset_physics_interpolation()` here (offset just changed discontinuously).
4. Per-tick decay step inside `_authority_tick`. **Do NOT call `body.reset_physics_interpolation()` on the per-tick visible-pos write** — Godot's physics interp interpolates between consecutive end-of-tick poses, both following `shadow + offset`, so the interp is naturally smooth.
5. Editor warning when a `SMOOTHED_OFFSET` correction channel exists but `body` is unset.
6. Reset rule summary: `body.reset_physics_interpolation()` fires **only** when the offset hard-snaps (length > snap_threshold → zeroed) or on first capture in `_reconcile_replay`. Continuous decay never needs it.

In `addons/netcode/resources/net_correction.gd`:

1. Add `enum Mode { RENDER_LERP, SMOOTHED_OFFSET }` and `@export var mode: Mode = Mode.RENDER_LERP`.
2. Update validation: `SMOOTHED_OFFSET` channels must only reference fields named in a fixed set (`pos` for now; later `velocity` / `rotation_quat` if generalized). Additionally: valid only on schemas with `command_template != null` (predicted entities) — server-state-only schemas should stay on RENDER_LERP.

In `_corrections_pass`: skip channels whose `mode == SMOOTHED_OFFSET` (framework owns those fields directly via the offset path; the lerp would erase the offset).

Optional generalization for later: `_smoothing_offsets: Dictionary[StringName, Variant]` keyed by field name so velocity / rotation can opt in. Keep Phase 4 scoped to `pos` only.

### 8.7 Alternative considered: VisualRoot Node3D

A more CS:GO-faithful design would keep the body at canonical pose permanently and reparent all visuals (mesh, camera, hands) under a `VisualRoot: Node3D` sibling that sits at `body.global_position + _smoothing_offset_pos`. Body never teleports; renderer samples the VisualRoot.

Pros: physics queries from other actors always see the body at canonical pose (no soft-determinism from intra-tick teleports). Cleaner conceptual separation between sim and presentation.

Cons: every visual node in `player.tscn` reparents under VisualRoot. Animation tracks currently targeting `VisualCollider`, `CameraController` (siblings of the root body) need re-pathing under VisualRoot. Higher scene refactor cost.

**Rejected for body-shuffle.** Body's intra-tick teleport spans <5cm during the typical ~250ms decay window; cross-actor physics query drift is within the soft-determinism budget. Revisit only if cross-player collision queries show artifacts in playtest.

---

## 9. Phase 5 — player migration to single body

After Phase 4 lands, the player migrates as a series of mechanical edits. The conceptual decisions (modes, refactor route, renames) are below; the per-file deletion checklist follows in §9.4.

### 9.1 Per-channel mode assignment in `player_schema.tres`

| Channel | Field | Mode | Notes |
|---|---|---|---|
| horizontal | `pos.xz` | `SMOOTHED_OFFSET` | smooth_rate ~8/s, snap_threshold ~2.0m |
| vertical | `pos.y` | `SMOOTHED_OFFSET` | smooth_rate ~10/s, snap_threshold ~1.5m. Consider `always_snap` if ledge-pop semantics are preferred |
| velocity | `velocity` | `always_snap = true` | snap on reconcile (FPS standard, see §11 ruling) |
| movement | `movement_state` | `always_snap = true` | discrete int |
| peek | `peek_state` | `always_snap = true` | discrete int |
| crouch_anim | `crouch_progress` | `RENDER_LERP` | smooth_rate ~12/s |
| prone_anim | `prone_progress` | `RENDER_LERP` | smooth_rate ~12/s |
| peek_anim | `peek_progress` | `RENDER_LERP` | smooth_rate ~12/s |

Rate values are starting points — tune against `wifi-light` / `wifi-loaded` net presets in playtest.

### 9.2 `_visualize` refactor route

Today `_visualize` → `MovementStateMachine.run_visual(delta)` → each visual state's `visual_physics(delta)` → some call `update_velocity(VISUAL)` → `move_and_slide()` on the root body. This is the load-bearing visual move that Phase 4's offset replaces.

Phase 5 collapse:

1. Delete `Enums.IntegrationContext` entirely. Drop the `ctx` parameter from `update_movement`, `update_gravity`, `on_floor`, `update_velocity`.
2. Collapse `update_velocity` to a single line: `func update_velocity(): move_and_slide()`. No GAME branch, no `game_body`, no `game_transform` proxies.
3. `_simulate` still calls `update_velocity()` (via the state machine's logic chain) once per tick on the root body.
4. Movement state scripts retain `visual_physics(delta)` for animation/SFX logic only — they stop calling `update_velocity`. `run_visual` becomes a pure animation-progress advance.

### 9.3 Mechanical renames after dropping `game_*` proxies

- `player.gd:365` `_update_tiredness_release_gate`: `Vector2(game_velocity.x, game_velocity.z)` → `Vector2(velocity.x, velocity.z)`.
- `shoot_handler.gd:204-206` (and `grenade.gd:159-161`): `get_node_or_null("GameController")` returns null after Phase 5; existing null-guards handle it transparently. No code change required.
- `player.gd:163` `_on_shadow_state_applied`: drop `game_body.global_position`, `game_position`, `game_velocity` writes; keep `global_position = s.pos` + `velocity = s.velocity`. Lag-comp's hit path uses analytical capsules against `shadow_state.pos` (see §11), not the scene, so this handler may be deletable entirely. Confirm post-migration.

### 9.4 Per-file deletion checklist

In `godot/controllers/player/player.tscn`:

- Set `NetPredictor.body = NodePath("..")` — NetPredictor is a child of PlayerController, so `..` resolves to the root body. (`NodePath(".")` would resolve to NetPredictor itself, which is a Node, not a Node3D, and would fail body resolution.)
- Delete the `[node name="GameController"]` block and all child nodes (`GameCollider`, `PlaceholderMesh`, `CrouchShapeCast3D`)
- Delete duplicate animation tracks in Crouch / PeekLeft / PeekRight / Prone2 / RESET animations:
  - `GameController/GameCollider:shape:height`
  - `GameController/GameCollider:position`
  - `GameController/GameCollider:rotation`
  - `GameController/GameCollider/PlaceholderMesh:mesh:height`

In `godot/controllers/player/player.gd`:

- Delete `@onready var game_body` + all `add_collision_exception_with(game_body)` calls
- Delete `game_transform` / `game_position` / `game_velocity` / `game_movement_state_id` / `game_sequence_id` proxy properties (NetPredictor will drop these too — see below)
- Refactor `_simulate`: use `self` (root) for `move_and_slide`, write `state.pos = global_position`
- Refactor `_load_simulation_state`: keep only state-machine + animation-progress restoration (drop the body-pos / basis / velocity writes — framework owns)
- Refactor `_visualize` per §9.2 — animation-only, no `move_and_slide`
- Drop `_capture_render_state`'s `state.pos = global_position` / `state.velocity = velocity` (framework owns smoothing-offset path); keep animation-progress captures
- Drop `_apply_corrections`'s `global_position = state.pos` write (framework writes body via offset path)
- Drop `Enums.IntegrationContext.GAME` vs `VISUAL` distinction per §9.2 (movement helpers collapse to one path)
- Apply mechanical renames per §9.3

In `addons/netcode/components/net_predictor.gd`:

- Delete the `game_transform` / `game_position` / `game_velocity` / `game_movement_state_id` / `game_sequence_id` host-cache vars (only player used them; Phase 5 removes that use)

In `godot/entities/player/player_schema.tres`:

- Apply per-channel mode assignment per §9.1

**Smoke tests for Phase 5:**

- 0 ping: no visible difference vs current behavior
- `broadband` preset: small reconciles smooth invisibly
- `wifi-light` preset: larger reconciles smooth without snap unless > snap_threshold
- Hard packet loss: large desyncs snap cleanly (offset exceeds threshold → zeroed)
- First-person view: camera moves with body (= visible pos = shadow + offset). No view jitter on reconcile.
- Third-person: visible body smooth, no obvious teleport

---

## 10. Phase 6 (future, optional)

Deferred refinements ordered by friction-to-value. None blocks Phase 4+5 ship; all are well-scoped now that the `body` export + SMOOTHED_OFFSET path are in production. Cross-references are to file:line in the post-Phase-5 worktree.

### 10.1 Explicit archetype enum on NetSchema ✅ shipped

`enum Archetype { PREDICTED, REPLICATED, LOCAL_ONLY }` lives on `net_schema.gd` with `@export var archetype: Archetype = Archetype.PREDICTED`. Implicit `command_template != null` gates are now explicit archetype checks:

- `net_predictor.gd::_ready`: subscribes to `NetServer.handle_net_command` when `schema.archetype == PREDICTED and NetSession.is_server`.
- `net_predictor.gd::_physics_process`: dispatches by archetype — PREDICTED + server runs `_server_tick` (input drain); REPLICATED + server runs `_replicator_server_tick` (`_capture_state`); LOCAL_ONLY skips all network branches.
- `net_predictor.gd::handle_net_state_packet`: REPLICATED skips the unacked-prune + reconcile path; every non-server peer buffers for interp.
- `net_schema.gd::_validate_archetype` (new): ERRORS on PREDICTED + null command_template; WARNINGs on REPLICATED/LOCAL_ONLY + non-null command_template (dead config).
- `net_schema.gd::_validate_correction_modes`: SMOOTHED_OFFSET requires `archetype == PREDICTED` (not the old null-template check).
- `compute_hash`: appends `archetype=<int>` so server/client mismatch is caught at startup.

`.tres` migration: schemas default to `PREDICTED` (matches the old null-template-means-predicted-too convention — player schema needed no edit). REPLICATED schemas add `archetype = 1` (grenade_schema.tres).

### 10.2 Fold NetReplicator into NetPredictor ✅ shipped

`net_replicator.gd` deleted. `NetPredictor._physics_process` dispatches by archetype; the PREDICTED branch keeps the existing `_server_tick` input-drain loop, the REPLICATED branch calls the new `_replicator_server_tick(delta)` which invokes `host._capture_state(state, delta)` and broadcasts. Host hook contract preserved:

| Archetype | Server hook | Client hook |
|---|---|---|
| PREDICTED (player) | `_simulate(state, cmd, dt)` per-frame loop | `_simulate` + `_apply_state` + `_visualize` |
| REPLICATED (grenade) | `_capture_state(state, dt)` once per gated tick | `_proxy_apply(blended, ...)` |

Migration done:

1. `_server_tick` split — PREDICTED dispatches to the existing input-drain loop; REPLICATED dispatches to `_replicator_server_tick`.
2. `handle_net_state_packet` skips the unacked-prune branch when `schema.archetype != PREDICTED` — every receiver buffers for interp.
3. `net_replicator.gd` + `.uid` deleted.
4. `grenade.tscn`: `NetReplicator` node renamed to `NetPredictor`, script path swapped, `archetype = 1` set on `grenade_schema.tres`.
5. Tests (`test_net_replicator.gd`) retargeted at `NetPredictor` + grenade_schema; class still exercises the REPLICATED behavior path.

One mental model: one component, one schema, one archetype flag.

### 10.3 NetBodyAdapter Resource for custom body shapes

`net_predictor.gd::_rewind_body` (line ~1083) dispatches on `BodyKind` with four hardcoded branches (CHAR_BODY, RIGID_BODY, ANIMATABLE_BODY, NODE3D). The AnimatableBody3D + Node3D branches are byte-identical (both transform-only). Custom integrators — Node3D with manual ballistic integration, NPC AI with bespoke physics, anything that needs to invalidate a custom cache on rewind — currently can't extend without forking the framework.

Pluggable strategy via an inspector-exposed Resource:

```gdscript
class_name NetBodyAdapter extends Resource

# Called by NetPredictor before host code in _reconcile_replay; framework hands
# the resolved body + the shadow state and the adapter writes whatever scene
# state it owns.
func rewind(body: Node3D, state: NetState) -> void: ...

# Optional: called after _simulate to read scene state back into render_state.
# Default no-op; PCD hosts implement _capture_render_state instead.
func capture(body: Node3D, state: NetState) -> void: ...
```

`NetPredictor` exposes `@export var body_adapter: NetBodyAdapter` alongside the existing `body: NodePath`. When set, the adapter's `rewind` replaces the built-in BodyKind dispatch. Ship four default adapters matching today's BodyKinds; custom hosts plug their own (`BallisticNode3DAdapter`, `AICharacterAdapter`, etc.).

Mostly relevant once NPC AI lands. Defer until the second non-CharacterBody3D / non-RigidBody3D body shape appears.

### 10.4 Per-field smoothing offset (velocity + rotation)

Today `_smoothing_offset_pos: Vector3` smooths the `pos` field only. The validator (`net_schema.gd::_validate_correction_modes`) explicitly errors on non-`pos` fields with a "Phase 4 scope" message. Generalization touch points:

1. `var _smoothing_offsets: Dictionary[StringName, Variant] = {}`. Keyed by field name; value type matches the field's runtime type (Vector3 for pos / velocity, Quaternion for rotation_quat).
2. `_walk_smoothing_offset_pos_axes` (line ~1633) becomes per-field. Quaternion decay needs `slerp(offset, Quaternion.IDENTITY, alpha)`, not lerp-toward-zero.
3. `_authority_tick` canonical-snap and visible-snap loop over the dict — Vector3 fields write to `global_position`, Quaternion to `global_basis`, velocity to `body.velocity` (CharacterBody3D) or `body.linear_velocity` (RigidBody3D).
4. Validator allow-list extends from `{pos}` to `{pos, velocity, rotation_quat, angular_velocity}`.

Per-field priority:

- **Velocity:** already overridden to `always_snap = true` per §11 ruling — competitive FPS practice, snap on reconcile. SMOOTHED_OFFSET on velocity only matters for vehicles / swim physics where snap-to-server is visibly jarring. Defer until such an entity ships.
- **Rotation:** matters for vehicles + any predicted entity where yaw misprediction snaps the body. Current player yaw is camera-driven (set in `_simulate` from `cmd.look_abs.y`, transmitted in every command), so rotation desync at 0 ping is zero. Defer.

Scope when the second predicted body type lands.

### 10.5 Editor-time SMOOTHED_OFFSET decay preview

Phase 4 tuning lives in three knobs per channel: `snap_threshold`, `smooth_rate`, `deadband`. Without runtime preview, tuning means: hit reconcile via the fake-lag knobs in NetSession, eyeball the smoothness, adjust, repeat. An inspector-side widget could plot the decay curve `1 - exp(-smooth_rate * t)` and show "decay to deadband in X.YYs" — turning blind tuning into a one-glance check.

Low priority; QoL win after the first tuning session.

---

## 11. Risks & open questions

### Resolved by Phase 1/2 shipping

- **"Body will visibly jitter during replay"** → confirmed false; intermediate replay states never render
- **"Need to reimplement move_and_slide"** → confirmed no; framework only does teleport + flag refresh, host still calls `move_and_slide`
- **`reset_physics_interpolation` after CharacterBody3D rewind** → tests pass; mesh interp uses post-rewind as reference
- **Jolt + `PhysicsServer3D.body_set_state` on RigidBody3D** → grenade migration runs with no visible artifact at 0 ping

### Discovered while planning Phase 3 (now reflected in Phase 4 design)

- **Dual-body is load-bearing for reconcile smoothing.** Visual `move_and_slide` in `_visualize` IS the smoothing mechanism, not redundant work. Single-body migration must replace it with explicit offset bookkeeping.

### Resolved by Phase 4/5 audit + implementation

- **First-person camera with offset.** Camera is grandchild of body (`body → CameraController → Camera3D`), so it automatically inherits the offset. Smooth view during reconcile is the expected behavior in CS:GO / Source-style engines. No extra wiring needed.
- **Lag-comp rewind ownership.** Hit detection uses analytical capsules against `shadow_state.pos` (`shoot_handler.gd:226 _ray_vs_capsule`), NOT physics scene rewind. The `apply_shadow_state_to_scene` signal exists for a possible future physics-based path, but current code never reads the scene for hit verification. Phase 4/5 cannot introduce hit/no-hit divergence — the competitive path is fully decoupled from visual smoothing.
- **Soft-determinism under single-body.** Accepted per `netcode-design.md` §0. Offset bounds visible drift; reconciles handle any cross-platform `move_and_slide` divergence. Measure once after migration but not a blocker.
- **Velocity smoothing.** Resolved: `always_snap = true` on the velocity channel. Reasons:
  - Velocity is never rendered directly — feeds animation blends, camera bob, tiredness gate; all tolerant of single-tick snap.
  - CS:GO / Source / Quake all snap velocity on reconcile; smoothing produces phantom-acceleration artifacts that lag input.
  - Hit detection reads server-side `shadow_state.velocity` for the lag-comp interp alpha, not client visible velocity, so smoothing it cannot improve registration.
- **State machine `logic_state` / `visual_state` split.** Stays. The split keeps replay from yanking animation pose backward on reconcile; it's orthogonal to body count and remains useful post-migration. State machines drive AnimationTree parameters; pose samples at render time off the `visual_state` ID.
- **Body resolution for non-predicted entities.** SSO entities that set `body` (grenade does not today but a future SSO RigidBody3D might) get framework rewind (`_rewind_body` via `PhysicsServer3D.body_set_state` for Jolt-safe RigidBody3D restoration) but skip the SMOOTHED_OFFSET path entirely — gated on `_has_smoothed_offset_pos_channel` which validation forbids on schemas with `command_template == null`. Rewind without smoothing is the correct behavior for SSO.
- **CrouchShapeCast3D reparenting.** Phase 5 moved CrouchShapeCast3D from `GameController` (top_level=true at world coords) to root `PlayerController` (also at world coords). Local transform `(0, 1.5, 0)` preserved → cast still occupies y=1.5m..2.0m above the body root, i.e. head height as before. Confirmed via headless scene load; in-editor gameplay test still pending (§13).
- **Velocity channel is render-side cosmetic after Phase 5.** `always_snap` on the velocity channel forces `render_state.velocity = shadow_state.velocity` in `_corrections_pass`, but `player.gd::_apply_corrections` is debug-only now (just emits the reconcile signal). The actual body velocity is owned by `_simulate`'s `move_and_slide()`. The velocity channel exists to claim the field for touched-axis bookkeeping (so the field doesn't fall through to the "snap every untouched field" branch which would do the same thing). Drop the channel entirely as a possible cleanup; functionally identical.

### Remaining open

- **`is_on_floor()` reads outside `_physics_process`.** Post-Phase-5, state machine `logic_transitions` / `logic_physics` (`crouch.gd:131`, `prone.gd:106`, all eight movement states + peek) read `player.on_floor()` from inside `_simulate` — body at canonical pos, flags correct. UI / debug reads (`ui/debug/debug.gd` overlay, `gui.gd`) happen during `_process` after Phase 4's visible-snap write, so they see flags computed against the offset position. Divergence is one tick stale + at most `_smoothing_offset_pos.length()` meters of perpendicular-to-floor offset. Unlikely to flip the boolean visibly. Cache `_cached_grounded: bool` inside `_simulate` and route external reads through it if it ever does. Defer.
- **`_on_shadow_state_applied` is load-bearing for respawn.** Earlier audit (pre-Phase-6 cleanup pass) suspected the handler was belt-and-suspenders for lag-comp scene rewrite — true for the hit detection path (analytical capsules against `shadow_state.pos`, see `shoot_handler.gd::_ray_vs_capsule`). But `shoot_handler.gd::_respawn_player` (line 422) mutates `shadow_state.pos` to the spawn location and calls `apply_shadow_state_to_scene()`; without the handler, `CharacterBody3D.global_position` stays at the death pose, the next `_simulate` reads stale `global_position`, and `move_and_slide` integrates from the wrong origin — overwriting the spawn pos on writeback. Keep the handler; framework's `apply_shadow_state_to_scene` signal stays as the canonical "scene needs to follow shadow_state" hook.
- **In-editor gameplay verification.** Headless parse + 117/118 test runner pass after Phase 5, but no playthrough confirming visible smoothness across the standard net presets (`broadband` / `wifi-light` / `wifi-loaded` / `lossy`). The Phase 5 schema flip is reversible (revert mode + always_snap on `player_schema.tres`) if smoothness regresses; framework code stays intact for SSO entities. Smoke-test items live in §9.4.
- **Offset oscillation at the snap_threshold boundary.** If reconcile error sits near `snap_threshold` (e.g. 2.0m) and bounces between 1.99 and 2.01 across adjacent reconciles, each crossing triggers snap-clamp + `reset_physics_interpolation`. Per-tick exp decay + deadband floor both pull the magnitude monotonically downward, so sustained oscillation is unlikely; worst case is one extra reset call per occurrence. Add hysteresis (snap at `snap_threshold * 1.1`, unsnap at `snap_threshold`) only if observed in playtest.
- **Double-reset_physics_interpolation when reconcile arrives mid-frame.** `_reconcile_replay` always resets; `_authority_tick` resets only on per-tick snap-clamp events. If both fire the same physics step (reconcile inside `handle_net_state_packet` followed by `_authority_tick` whose decay step then snap-clamps an axis), reset gets called twice. Godot collapses redundant calls inside one frame at the rendering server; no functional issue. Worth a profile-test if reset cost ever surfaces.

---

## 12. Non-goals

- Replacing `CharacterBody3D` with a Rust kinematic controller — possible long-term, but `move_and_slide` is "good enough" given soft-determinism tolerance
- Per-body custom integration loops inside the framework — host owns physics calls
- Determinism guarantees across OS/arch — already accepted as soft-determinism in `netcode-design.md` §0
- Client-authoritative entities — out of scope, server-authoritative everywhere
- Generalizing `NetReliable` / RPC paths — orthogonal to body synchronization

---

## 13. Decision summary

**Phases 1, 2, 4, 5, 6.1, 6.2 are shipped.** NetPredictor has the body-rewind primitive (Phase 1); grenade migrated to the SSO/REPLICATED path with framework-driven tick gating (Phase 2). Framework-owned smoothing offset with SMOOTHED_OFFSET correction mode + per-axis decay landed (Phase 4); player migrated to a single CharacterBody3D using that offset, IntegrationContext collapsed (Phase 5). Explicit `Archetype` enum + folded NetReplicator into NetPredictor with archetype-driven dispatch (Phase 6.1 + 6.2).

**Phase 4 scope (concrete):**

1. `addons/netcode/components/net_predictor.gd`: add `_smoothing_offset_pos: Vector3`; insert canonical-snap before `_simulate` and visible-snap after `_apply_corrections` inside `_authority_tick` per §8.3; per-tick decay step; offset capture + snap-clamp in `_reconcile_replay` with `reset_physics_interpolation()` gated to snap events only (§8.6).
2. `addons/netcode/resources/net_correction.gd`: add `enum Mode { RENDER_LERP, SMOOTHED_OFFSET }` and `@export var mode: Mode = Mode.RENDER_LERP`; validation that SMOOTHED_OFFSET channels reference `pos` only and only on schemas with `command_template != null` (predicted entities).
3. `addons/netcode/components/net_predictor.gd::_corrections_pass`: skip channels whose `mode == SMOOTHED_OFFSET` (framework owns those fields directly via the offset path).
4. Editor warning when a SMOOTHED_OFFSET channel exists but `body` is unset.

No host changes needed to land Phase 4 — player keeps dual-body until Phase 5 flips the schema modes.

**Phase 5 scope:** set `body = ^".."` (parent path — NetPredictor is a child of PlayerController so `..` resolves to the root body) on `player.tscn`, delete GameController + duplicate animation tracks, collapse IntegrationContext per §9.2, mode-flip the channels per §9.1, apply mechanical renames per §9.3. Land framework changes first; flip schema modes last so tests can confirm zero regression at each step.

Subclass route (`NetCharacterBody3D extends CharacterBody3D`) remains rejected: single-inheritance lock-in on the host, combinatorial parallel classes for each body shape, inverted ownership.

When picking up the work post-compaction: Phase 4 framework code is the next concrete step. Start in `addons/netcode/components/net_predictor.gd` and `addons/netcode/resources/net_correction.gd`. Don't touch player.gd / player.tscn until Phase 4 lands and tests confirm zero regression at default-empty body.
