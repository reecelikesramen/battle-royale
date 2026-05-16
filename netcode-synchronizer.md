# NetSynchronizer — Body-Aware Prediction Extension

Status: design draft. Companion to `netcode-design.md`. No implementation yet.

This doc proposes extending `NetPredictor` (or extracting a `NetSynchronizer` peer) so the framework owns body-rewind semantics across multiple body shapes — eliminating the host's dual-`CharacterBody3D` workaround for prediction-with-replay without forcing a hand-rolled `move_and_slide` reimplementation.

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

## 8. Migration plan

### Phase 1: framework opt-in (no behavior change)

- Add `body: NodePath` export + `_resolve_body` + `_rewind_body` to `NetPredictor`
- Wire `_reconcile_replay` to call `_rewind_body` when `_body != null`
- Add editor validation: warn if `body` resolves to a non-supported type
- All existing entities (player, grenade) keep `body` empty → zero behavior change
- Ship + verify nothing regresses

### Phase 2: grenade migrates to NetReplicator (orthogonal cleanup)

- Switch grenade.tscn to use NetReplicator instead of NetPredictor
- Replace manual `_net.server_broadcast_snapshot(0)` with `_capture_state` hook
- Schema stays the same; framework calls `_capture_state` each gated tick
- Verify wire format unchanged

### Phase 3: player migrates to single body

- Set `NetPredictor.body = ^"."` (the root)
- Refactor `_simulate` to use root body's `move_and_slide` directly
- Refactor `_load_simulation_state` to only restore SM state (framework does body)
- Drop `_visualize`'s call to `move_and_slide` (visual integration redundant once shadow drives the only physics)
- Delete `GameController` from scene + its collider + duplicate animation tracks
- Adjust correction lerp targets if they were tuned for dual integration
- Smoke test reconcile under bad-net presets (`broadband`, `wifi-light`, packet loss)

### Phase 4 (optional, future)

- Explicit archetype enum on `NetSchema` (PREDICTED / SERVER_STATE_ONLY) replacing the inferred `command_template != null` check
- Fold `NetReplicator` back into `NetPredictor` (mode flag on schema) so there's one component
- Generalize `_rewind_body` strategies into a `NetBodyAdapter` Resource for the rare case where a host wants custom rewind (e.g. AnimatableBody3D with custom interpolation easing into rewind pose)

---

## 9. Risks & open questions

### Resolved

- **"Body will visibly jitter during replay"** → false; render samples post-physics, intermediate replay states are invisible
- **"Need to reimplement move_and_slide"** → no; framework only does teleport + flag refresh, host still calls `move_and_slide`

### Open

- **Jolt + `PhysicsServer3D.body_set_state` interaction.** Need to verify Jolt respects mid-physics-tick state writes on RigidBody3D without continuous-collision-detection objections. Test by rewinding a moving grenade and checking next step's collision response.
- **`reset_physics_interpolation` after CharacterBody3D rewind** — confirm the mesh interp uses the post-rewind pose as the new "previous" reference, not the pre-rewind pose.
- **Dummy `move_and_slide` cost on rewind.** Probably <50µs per call; profile under 16-player load. If hot, alternative is a raycast-only floor probe.
- **Lag-comp rewind ownership.** `NetLagCompensator` currently emits `shadow_state_applied` and the host pushes scene-graph updates. With body-aware synchronizer, lag-comp should call `_rewind_body` directly and the host signal becomes optional (for state-machine restoration only).
- **Soft-determinism under single-body.** Dual-body insulated the visual from sim divergence between platforms. Single-body means platform-specific `move_and_slide` differences show as correction lerps. Should be visually negligible given the existing snap+smooth thresholds, but worth measuring once after migration.
- **Visual smoothing across reconciles.** Today: visual body integrates between server snapshots, then corrections nudge it. After migration: shadow body integrates each tick, render_state = shadow with correction lerp folded in via `corrections[]` channels. Functionally equivalent, but the smoothing tunables (`smooth_rate`, `snap_threshold`) may need re-tuning since the input to the smoother is different (pure shadow rather than visual-physics-output).
- **State machine `logic_state` / `visual_state` split.** Stays. Even without dual body, this split is what keeps replay from yanking the animation pose backwards each reconcile. State machines drive AnimationTree parameters; pose is sampled at render time off the visual_state's ID.
- **Schema-level archetype declaration.** Tempting to add `@export var archetype: Archetype` to `NetSchema` for explicitness, but doing so doubles up with the existing `command_template != null` signal. Hold off until Phase 4 — keep two signals only if they diverge in meaning.

---

## 10. Non-goals

- Replacing `CharacterBody3D` with a Rust kinematic controller — possible long-term, but `move_and_slide` is "good enough" given soft-determinism tolerance
- Per-body custom integration loops inside the framework — host owns physics calls
- Determinism guarantees across OS/arch — already accepted as soft-determinism in `netcode-design.md` §0
- Client-authoritative entities — out of scope, server-authoritative everywhere
- Generalizing `NetReliable` / RPC paths — orthogonal to body synchronization

---

## 11. Decision summary (recommendation)

**Add `body: NodePath` to `NetPredictor`.** Composition over inheritance. Works across `CharacterBody3D` / `RigidBody3D` / `AnimatableBody3D` / `Node3D`. Default-empty preserves the current dual-body player. Opt-in migration: grenade first (cleanup, no semantic change), then player (drops `GameController`, halves animation tracks, removes broadphase entry).

Subclass route (`NetCharacterBody3D extends CharacterBody3D`) rejected: single-inheritance lock-in on the host, combinatorial parallel classes for each body shape, inverted ownership (body owns prediction lifecycle rather than the prediction component owning body discipline).

Implementation order: Phase 1 (framework opt-in, no regression), then Phase 2 (grenade — low risk), then Phase 3 (player — main payoff).
