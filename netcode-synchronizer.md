# NetSynchronizer — Body-Aware Prediction Extension

Status: **Phases 1 + 2 shipped. Phase 3 (player single-body migration) replanned as Phase 4 after discovering the dual-body smoothing dependency.** Companion to `netcode-design.md`. Active on branch `refactor/netcode-synchronizer` (worktree at `/Users/rholmdahl/Documents/game/first-test-synchronizer`).

This doc proposes extending `NetPredictor` (or extracting a `NetSynchronizer` peer) so the framework owns body-rewind semantics across multiple body shapes — eliminating the host's dual-`CharacterBody3D` workaround for prediction-with-replay without forcing a hand-rolled `move_and_slide` reimplementation.

## Phase tracker

| Phase | Status | Commit | Scope |
|---|---|---|---|
| 1. NetPredictor.body export + framework rewind primitive | ✅ done | `b826a8b` | Opt-in `body: NodePath`, `BodyKind` enum, `_rewind_body` for CharacterBody3D / RigidBody3D / AnimatableBody3D / Node3D, wired into `_reconcile_replay`. No behavior change for existing entities (default empty path). |
| 2. Grenade → NetReplicator | ✅ done | `f483cc3` | Grenade moved off NetPredictor + manual broadcast. NetReplicator gained server-tick gating; `_capture_state(state, delta)` contract. |
| 3. ~~Player single-body migration (naive)~~ | ❌ halted | — | Tracing revealed visual `move_and_slide` in `_visualize` is the smoothing mechanism, not redundant work. Original Phase 3 plan would lose reconcile smoothing. Replaced by Phase 4 below. |
| 4. Framework-owned visual smoothing offset | 🚧 planned | — | Add `_smoothing_offset_pos` + decay + body-shuffle to NetPredictor so single-body prediction preserves reconcile smoothing. See §8 below. |
| 5. Player migration to single body | 🚧 planned | — | After Phase 4: set `body = ^"."` on player, drop GameController + duplicate animation tracks + `_visualize` move_and_slide + cache proxy props. See §10. |

**Test parity (Phase 1 + 2):** 117/118 in worktree, identical to main. The 1 pre-existing failure (`test_player_input_fields_user_authored: missing field: last_received_tick`) is unrelated to this work.

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

The current codebase has two component classes (`NetPredictor` and `NetReplicator`). The synchronizer design recognizes four archetypes; the framework collapses them onto NetPredictor with explicit mode.

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

### 8.3 Per-tick rhythm — the one subtle bit

`move_and_slide()` reads `body.global_position` as its integration start. If we leave the body at `shadow.pos + offset` (visible pos), the next `_simulate` integrates from the wrong start and `shadow.pos` diverges from the canonical predicted trajectory.

The framework does a tiny body shuffle around each `_simulate`:

```gdscript
func _authority_tick(delta):
    # Snap body to canonical so move_and_slide integrates from the truth
    body.global_position = shadow.pos
    # Host integrates: writes velocity, calls move_and_slide, updates shadow.pos
    host._simulate(shadow, cmd, delta)
    # body now at new shadow.pos
    
    # Decay offset
    _smoothing_offset_pos = _smoothing_offset_pos.lerp(
        Vector3.ZERO, 1.0 - exp(-decay_rate * delta))
    
    # Snap body back to visible
    body.global_position = shadow.pos + _smoothing_offset_pos
    body.reset_physics_interpolation()
    
    # Host animations / visual SMs — body pos is now visible-pos
    host._apply_state(shadow)
    host._visualize(delta, shadow)
```

Two cheap property writes per tick. Compared to dual-body the savings are:

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
- `reset_physics_interpolation()` calls at the shuffle points
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

The framework reinterprets these as offset-decay knobs when a new mode flag (`SMOOTHED_OFFSET` vs the existing `RENDER_LERP`) is set on the channel. Existing math (`exp(-smooth_rate * delta)` lerp factor, snap_threshold gate) carries over with semantics preserved — just driven from one offset variable instead of a separate render_state field.

Open question: do we add a `mode` enum on `NetCorrection` or default predicted entities to `SMOOTHED_OFFSET` and leave server-state-only entities on `RENDER_LERP`? Probably explicit enum on the channel; predicted player and future vehicles set it; grenade (server-state) leaves it.

### 8.6 Concrete framework changes for Phase 4

In `addons/netcode/components/net_predictor.gd`:

1. Add `var _smoothing_offset_pos: Vector3 = Vector3.ZERO` (authority-only).
2. Add the body shuffle around `_simulate` inside `_authority_tick` (~10 lines).
3. In `_reconcile_replay`: capture `pre_visible_pos` before the existing `_rewind_body` call; after the replay loop, compute `_smoothing_offset_pos = pre_visible_pos - shadow.pos`, snap-clamp, and re-write body.
4. Per-tick decay step inside `_authority_tick`.
5. Editor warning when a `SMOOTHED_OFFSET` correction channel exists but `body` is unset.

In `addons/netcode/resources/net_correction.gd`:

1. Add `enum Mode { RENDER_LERP, SMOOTHED_OFFSET }` and `@export var mode: Mode = Mode.RENDER_LERP`.
2. Update validation: `SMOOTHED_OFFSET` channels must only reference fields named in a fixed set (`pos` for now; later `velocity` / `rotation_quat` if generalized).

Optional generalization for later: `_smoothing_offsets: Dictionary[StringName, Variant]` keyed by field name so velocity / rotation can opt in. Keep Phase 4 scoped to `pos` only.

---

## 9. Phase 5 — player migration to single body

After Phase 4 lands, the player migrates with these specific deletions:

In `godot/controllers/player/player.tscn`:

- Set `NetPredictor.body = NodePath(".")` (= root PlayerController)
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
- Drop `_visualize`'s `MovementStateMachine.run_visual` movement integration calls; keep AnimationTree sync, peek SM, etc.
- Drop `_capture_render_state`'s `state.pos = global_position` / `state.velocity = velocity` (framework owns smoothing-offset path); keep animation-progress captures
- Drop `_apply_corrections`'s `global_position = state.pos` write (framework writes body via offset path)
- Drop `Enums.IntegrationContext.GAME` vs `VISUAL` distinction in movement helpers (`update_movement`, `update_gravity`, `on_floor`, `update_velocity` collapse to one path)

In `addons/netcode/components/net_predictor.gd`:

- Delete the `game_transform` / `game_position` / `game_velocity` / `game_movement_state_id` / `game_sequence_id` host-cache vars (only player used them; Phase 5 removes that use)

In `godot/entities/player/player_schema.tres`:

- Add `mode = SMOOTHED_OFFSET` to the `pos` correction channel
- Tune `smooth_rate` and `snap_threshold` against bad-net presets

**Smoke tests for Phase 5:**

- 0 ping: no visible difference vs current behavior
- `broadband` preset: small reconciles smooth invisibly
- `wifi-light` preset: larger reconciles smooth without snap unless > snap_threshold
- Hard packet loss: large desyncs snap cleanly (offset exceeds threshold → zeroed)
- First-person view: camera moves with body (= visible pos = shadow + offset). No view jitter on reconcile.
- Third-person: visible body smooth, no obvious teleport

---

## 10. Phase 6 (future, optional)

- Explicit archetype enum on `NetSchema` (PREDICTED / SERVER_STATE_ONLY) replacing the inferred `command_template != null` check
- Fold `NetReplicator` back into `NetPredictor` (mode flag on schema) so there's one component
- Generalize `_rewind_body` strategies into a `NetBodyAdapter` Resource for AnimatableBody3D / Node3D custom rewinds
- Per-field smoothing offset (extend `_smoothing_offset_pos: Vector3` → `_smoothing_offsets: Dictionary`) for velocity + rotation smoothing

---

## 11. Risks & open questions

### Resolved by Phase 1/2 shipping

- **"Body will visibly jitter during replay"** → confirmed false; intermediate replay states never render
- **"Need to reimplement move_and_slide"** → confirmed no; framework only does teleport + flag refresh, host still calls `move_and_slide`
- **`reset_physics_interpolation` after CharacterBody3D rewind** → tests pass; mesh interp uses post-rewind as reference
- **Jolt + `PhysicsServer3D.body_set_state` on RigidBody3D** → grenade migration runs with no visible artifact at 0 ping

### Discovered while planning Phase 3 (now reflected in Phase 4 design)

- **Dual-body is load-bearing for reconcile smoothing.** Visual `move_and_slide` in `_visualize` IS the smoothing mechanism, not redundant work. Single-body migration must replace it with explicit offset bookkeeping.

### Open for Phase 4 / Phase 5

- **First-person camera with offset.** Camera is child of root body. With offset applied, the camera position offsets too — the player view smoothly converges instead of snapping. Theoretically an improvement over today's setup, but requires real-world validation under bad-net presets.
- **`is_on_floor()` reads outside `_physics_process`.** State machines run inside `_simulate` during the canonical-pos window, so they're safe. But anything reading body pos *outside* `_physics_process` (UI, debug overlay) sees visible-pos. Need to audit reads.
- **Velocity smoothing.** Visible velocity won't match visible motion in the ticks following a reconcile. At decay rate 8/s the offset converges in ~250ms so probably invisible, but worth testing.
- **Soft-determinism under single-body.** Dual-body insulated visual from sim divergence between platforms. Single-body means platform-specific `move_and_slide` differences show up as offset values. Should be visually negligible given snap/smooth thresholds, but measure once after migration.
- **Lag-comp rewind ownership.** `NetLagCompensator` currently emits `shadow_state_applied` and the host pushes scene-graph updates. With body-aware synchronizer + smoothing offset, lag-comp should call `_rewind_body` directly without invoking the smoothing path (lag-comp rewinds are temporary, server-side, not visible-pose-relevant).
- **State machine `logic_state` / `visual_state` split.** Stays. Even without dual body, this split is what keeps replay from yanking the animation pose backwards each reconcile. State machines drive AnimationTree parameters; pose is sampled at render time off the visual_state's ID.

---

## 12. Non-goals

- Replacing `CharacterBody3D` with a Rust kinematic controller — possible long-term, but `move_and_slide` is "good enough" given soft-determinism tolerance
- Per-body custom integration loops inside the framework — host owns physics calls
- Determinism guarantees across OS/arch — already accepted as soft-determinism in `netcode-design.md` §0
- Client-authoritative entities — out of scope, server-authoritative everywhere
- Generalizing `NetReliable` / RPC paths — orthogonal to body synchronization

---

## 13. Decision summary

**Phase 1 + 2 are shipped** (`b826a8b`, `f483cc3`). NetPredictor has the body-rewind primitive; grenade has migrated to NetReplicator + framework-driven tick gating.

**Phase 4 is the next active piece**: add the visual smoothing offset to NetPredictor + a `SMOOTHED_OFFSET` mode on NetCorrection. ~80-120 lines of framework code, no host changes required to land it. Player keeps dual-body until Phase 5.

**Phase 5 migrates the player to single body** with `body = ^"."` and offset-smoothed reconcile. ~200 lines of player.gd deleted, several scene-graph deletions. Behavior preserved by Phase 4's smoothing mechanism.

Subclass route (`NetCharacterBody3D extends CharacterBody3D`) remains rejected: single-inheritance lock-in on the host, combinatorial parallel classes for each body shape, inverted ownership.

When picking up the work post-compaction: Phase 4 framework code is the next concrete step. Start in `addons/netcode/components/net_predictor.gd` (`_authority_tick` + `_reconcile_replay` + new `_smoothing_offset_pos` field) and `addons/netcode/resources/net_correction.gd` (mode enum + validation). Don't touch player.gd / player.tscn until Phase 4 lands and tests confirm zero regression at default-empty body.
