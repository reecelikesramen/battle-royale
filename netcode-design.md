# Netcode Generalization & Addon Split — Plan

Status doc for refactoring the current player-specific netcode into a generalized framework, then extracting that framework as a standalone Godot addon. Resume here after compact.

---

## 0. Decisions made (locked in)

These came out of the design discussion and are not up for debate without explicit revisit:

- **Composition over inheritance.** Networked entities are *any* `Node` type (CharacterBody3D, RigidBody3D, StaticBody3D, Node). Netcode lifecycle lives in `NetPredictor` / `NetReplicator` / `NetReliable` *component child nodes*. No `extends NetPredictedEntity` base class.
- **Typed Resource state + command.** User authors `PlayerState extends NetState` and `PlayerInput extends NetCommand` as pure data Resources with `@export var` fields only. Zero metadata in those `.gd` files.
- **Inspector-authored schema.** `NetSchema` is a `Resource` saved as `.tres` (or inline on the NetPredictor node). Carries: state/command class refs, tick + snapshot rates, per-field metadata (quantization, predict flag, no_interp), correction channels, child node refs for SM / AnimTree replication. **All network metadata lives here, not in code.**
- **No custom `@annotations`.** Confirmed impossible without engine fork (`valid_annotations` is a hard-coded `static HashMap` in `gdscript_parser.cpp`). Editor-first authoring uses `@export` + dropdowns, not custom annotations.
- **Single transport (GNS via Rust).** Reliable and unreliable both ride the existing `NetworkDriver` over GNS lanes. No second networking runtime.
- **Server-authoritative, all entities.** No client authority for now. Lag compensation lives on the server via historical state buffer + rewind.
- **Soft-determinism.** `move_and_slide` is not bit-deterministic across Win/Mac/Linux. Accept residual drift; snap-correct via correction channels. Same model CS2 uses in practice.
- **Configurable tick rate.** No hard-coded 128Hz. `tick_hz` and `snapshot_hz` are schema settings; interp window is a float multiplier on snapshot interval (not enum 0/1/2).
- **Addon-ready.** All framework code targets being extracted to `addons/netcode/`. Game-side code imports from `addons/netcode/...` only.

---

## 1. Final architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│  Game scene (project-specific)                                       │
│                                                                      │
│   Player (CharacterBody3D)                                           │
│   ├── CameraController, AnimationTree, SMs, etc.                     │
│   └── NetPredictor                          ← framework component    │
│         root = ".."                                                   │
│         schema = preload("res://schemas/player_predicted.tres")      │
│                                                                      │
│   Door (StaticBody3D)                                                │
│   └── NetReplicator                                                  │
│         schema = preload("res://schemas/door_replicated.tres")       │
│                                                                      │
│   Inventory (Node)                                                   │
│   └── NetReliable                                                    │
│         schema = preload("res://schemas/inventory_reliable.tres")    │
└─────────────────────────────┬────────────────────────────────────────┘
                              │
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│  addons/netcode/  (the addon)                                        │
│                                                                      │
│  components/                                                         │
│    NetPredictor.gd         — predicted entities                      │
│    NetReplicator.gd        — replicate-only entities                 │
│    NetReliable.gd          — reliable RPC / state                    │
│                                                                      │
│  resources/                                                          │
│    NetSchema.gd            — main config Resource                    │
│    NetState.gd             — base class for state Resources          │
│    NetCommand.gd           — base class for command Resources        │
│    NetFieldConfig.gd       — per-field metadata                      │
│    NetCorrection.gd        — reconcile channel                       │
│    NetChildRef.gd          — child SM / AnimTree refs                │
│                                                                      │
│  core/  (autoloads)                                                  │
│    NetSession.gd           — peers, ids, handshake                   │
│    NetReplication.gd       — entity registry, snapshot dispatch      │
│    NetTimeline.gd          — server tick clock, interp window        │
│    NetReliableHub.gd       — reliable RPC routing                    │
│    NetDebug.gd             — overlay, graphs                         │
│                                                                      │
│  editor/                                                             │
│    NetSchemaInspectorPlugin.gd  — dropdowns, generate-fields button  │
│                                                                      │
│  rust/  (gdextension binary, prebuilt per-platform)                  │
│    NetworkDriver (GNS sockets)                                       │
│    SequenceRingBuffer, JitterBuffer, PacketSequence                  │
│    Schema-driven snapshot codec (delta encoding, quantization)       │
│                                                                      │
│  netcode.gdextension                                                 │
│  plugin.cfg                                                          │
└──────────────────────────────────────────────────────────────────────┘
```

---

## 2. The data flow

```
LIVE TICK (local authority):
  NetPredictor._physics_process(delta)
    ├─ cmd = NetCommand.new()
    ├─ root._gather_command(cmd)              # user code
    ├─ root._simulate(_shadow_state, cmd, delta)  # user code
    ├─ _apply_corrections(delta)               # smooths render toward shadow
    └─ root._apply_state(_render_state)        # user code: writes node properties

SERVER TICK:
  NetPredictor._tick_server(delta)
    ├─ frames = _server_input_queue.consume()
    ├─ for frame: root._simulate(_shadow_state, frame.packet, frame.delta)
    ├─ root._apply_state(_shadow_state)
    └─ broadcast NetStatePacket (delta-encoded vs per-client baseline)

RECONCILE (authority receives server snapshot):
  NetPredictor.handle_state_packet(packet)
    ├─ _shadow_state = packet.state           # snap shadow to server
    ├─ prune acked inputs
    ├─ for unacked: root._simulate(_shadow_state, cmd, dt)  # replay
    └─ _apply_corrections; root._apply_state

PROXY TICK (remote entity on client):
  NetPredictor._tick_proxy(delta)
    ├─ render_us = NetTimeline.render_time_us()  # now - interp_window
    ├─ pair = _state_buffer.get_interpolation_pair(render_us)
    ├─ interp_state = lerp(pair.from, pair.to, alpha) per field
    ├─ root._apply_state(interp_state)
    └─ root._visualize(delta, interp_state)   # one-shot SFX/VFX
```

`_shadow_state` and `_render_state` are typed Resource instances of `schema.state_class`. The user's `_simulate` mutates the typed Resource directly — `state.pos = ...`. Framework encodes/decodes via reflection against `schema.state_fields` configs.

---

## 3. User-facing API surface

### 3.1 What a game dev writes per entity

1. **State Resource** (`player_state.gd`)
   ```gdscript
   class_name PlayerState extends NetState
   @export var pos: Vector3
   @export var velocity: Vector3
   @export var look: Vector2
   ```

2. **Command Resource** (`player_input.gd`)
   ```gdscript
   class_name PlayerInput extends NetCommand
   @export var move_fb: float
   @export var move_lr: float
   @export var look: Vector2
   @export var jump: bool
   # …
   ```

3. **Entity controller** — extends *anything* (CharacterBody3D, RigidBody3D, Node)
   ```gdscript
   class_name PlayerController extends CharacterBody3D
   
   func _seed_state(state: PlayerState) -> void: ...
   func _gather_command(cmd: PlayerInput) -> void: ...
   func _simulate(state: PlayerState, cmd: PlayerInput, delta: float) -> void: ...
   func _apply_state(state: PlayerState) -> void: ...
   func _visualize(delta: float, state: PlayerState) -> void: pass  # optional
   ```

4. **Schema `.tres`** — authored in inspector. References state/command classes, lists field configs, correction channels, rates.

5. **Scene** — add `NetPredictor` as child, set `root` and `schema`.

No code references the netcode addon except the type names of base classes (`NetState`, `NetCommand`) and component nodes. Hot-swappable.

### 3.2 Component family

| Component | Purpose | Use cases |
|---|---|---|
| `NetPredictor` | Client-side prediction + server-side authority + replay | Player, car, grenade, turret |
| `NetReplicator` | Server-auth snapshot replication, no prediction | Doors, lights, AI, world props |
| `NetReliable` | Reliable RPCs + reliable field replication | Inventory, scoreboard, match state |

Same scene pattern (child node with `root` + `schema`) for all three.

---

## 4. Addon package split

### 4.1 Source-of-truth layout (final state)

```
addons/netcode/
├── plugin.cfg
├── netcode.gd                          (EditorPlugin entry)
├── netcode.gdextension                 (Rust binary refs per-platform)
├── bin/
│   ├── libnetcode.linux.x86_64.so
│   ├── libnetcode.windows.x86_64.dll
│   └── libnetcode.macos.universal.dylib
├── components/
│   ├── net_predictor.gd
│   ├── net_replicator.gd
│   └── net_reliable.gd
├── resources/
│   ├── net_schema.gd
│   ├── net_state.gd
│   ├── net_command.gd
│   ├── net_field_config.gd
│   ├── net_correction.gd
│   └── net_child_ref.gd
├── core/
│   ├── net_session.gd                  (autoload)
│   ├── net_replication.gd              (autoload)
│   ├── net_timeline.gd                 (autoload)
│   ├── net_reliable_hub.gd             (autoload)
│   └── net_debug.gd                    (autoload)
├── editor/
│   ├── net_schema_inspector_plugin.gd
│   └── icons/
└── docs/
    └── README.md
```

### 4.2 What stays project-side

```
res://
├── entities/
│   ├── player/
│   │   ├── player_controller.gd
│   │   ├── player_state.gd
│   │   ├── player_input.gd
│   │   └── player.tscn                 (Player + NetPredictor child)
│   └── …
├── netcode_config/                     (project's chosen schemas)
│   └── schemas/
│       ├── player_predicted.tres
│       ├── car_predicted.tres
│       └── …
└── game-specific stuff (UI, levels, etc.)
```

### 4.3 Rust source location during dev

The Rust crate stays at `rust/` in the project repo during development. For the addon distribution:

1. Build prebuilt binaries via CI (`build-rust` job already exists in `.github/workflows/godot-google-ci.yml`)
2. Copy `librust.*` from `rust/target/release/` to `addons/netcode/bin/` with platform-suffixed names
3. Optional: open-source the Rust crate separately (`netcode-gns-rs`) so addon users can rebuild if needed

For the game project itself, keep `rust/` and the addon's `bin/` in sync via a `make-addon` script.

### 4.4 Addon dependencies

- **No GDScript autoload dependencies on project code.** Autoloads in `addons/netcode/core/` may only reference other addon files.
- **Project's `project.godot` autoload section** registers the addon's autoloads under fixed names: `NetSession`, `NetReplication`, `NetTimeline`, `NetReliableHub`, `NetDebug`.
- **Rust binary** is the only platform-dependent piece. Ship one `.dylib` / `.so` / `.dll` per supported platform.

### 4.5 Licensing / distribution

- Code: MIT or Apache-2.0 (permissive, addon market expects this)
- Rust binary: same as crate
- Discuss commercial dual-license later if pursuing sale; for now permissive FOSS is fine

---

## 5. Migration plan — phased refactor

Each phase ships independently. Test after every phase before moving to the next.

### Phase 1 — Foundation (no behavior changes)
**Deliverables:**
- Add server tick clock (`u32` monotonic at 128Hz) + handshake sync into `NetworkTransport` / `NetSession`
- Add `NetTimeline` autoload with `tick_hz`, `snapshot_hz`, `interp_window_ratio`, `render_time_us()`
- Move tick rate constants out of hard-coded `128` references; read from autoload

**Why first:** every later phase depends on a server tick. Easy win, no breaking changes.

**Files touched:**
- `rust/src/network_driver.rs` (add tick clock packet field)
- `godot/autoload/network/network_transport.gd`
- new: `godot/addons/netcode/core/net_timeline.gd` (or temporary location, will move in phase 7)

### Phase 2 — Input redundancy + staleness drop
**Deliverables:**
- `PlayerInputPacket` carries last 3-6 inputs not just current
- Server dedupes by sequence_id
- Drop inputs older than `MAX_INPUT_AGE_TICKS` (200ms @ 128Hz = 26 ticks; expose as schema config later)

**Why now:** ~20 lines of work, big loss-resilience win, totally orthogonal to refactor.

### Phase 3 — Extract reconcile into base predictor
**Deliverables:**
- Create `NetPredictor.gd` component with current player reconcile logic intact (still hardcoded horizontal/vertical for now)
- Move `_unacked_inputs`, `_player_state_buffer`, `_server_input_queue`, `game_*` shadow vars from `player.gd` into `NetPredictor`
- Player becomes thin: gather + simulate + apply_state. Schema not yet introduced.

**Why now:** pure refactor, no schema yet, just relocates code. Validates the composition model on current behavior.

### Phase 4 — Introduce typed state/command Resources
**Deliverables:**
- `NetState` base Resource class
- `NetCommand` base Resource class
- `PlayerState extends NetState` with `@export var pos/velocity/look`
- `PlayerInput extends NetCommand` with `@export var` fields (move from current `PlayerInputPacket`)
- `NetPredictor` reflects on state class via `get_property_list()`, allocates instances
- Wire codec in Rust still uses hand-defined `define_packet!` for now; will swap in phase 6

**Why now:** Decouples user code from packet types. After this phase, user touches only typed Resources.

### Phase 5 — Schema-driven correction channels
**Deliverables:**
- `NetSchema` Resource + `NetFieldConfig` + `NetCorrection`
- First `.tres`: `player_predicted.tres` with horizontal/vertical/look corrections
- `NetPredictor._apply_corrections` reads from schema instead of hard-coded `SNAP_THRESHOLD_*`
- Player controller's reconcile tunables get deleted from the script; they live in the .tres

**Why now:** Last refactor before delta encoding. After this, everything user-tunable is in `.tres`.

### Phase 6 — Schema-driven wire codec (Rust side)
**Deliverables:**
- New Rust `SchemaDescriptor` type built from a registered schema at runtime
- Replace per-packet `define_packet!` with `NetStatePacket { schema_id, entity_id, last_input_seq, dirty_mask, payload_bytes }`
- Quantization handled per `NetFieldConfig.quant`
- **Delta encoding + per-client baselines** (biggest bandwidth win)
- Client ACKs via `last_received_tick` field in input packets

**Why now:** Biggest perf win, but depends on schemas existing.

### Phase 7 — Split into addon
**Deliverables:**
- Move all `Net*` files into `godot/addons/netcode/`
- Rename: `network_transport.gd` → `addons/netcode/core/net_session.gd` (or similar)
- Project's `project.godot` autoload section rewritten to point at addon paths
- Build script: `make-addon.sh` that copies Rust libs from `rust/target/release/` to `addons/netcode/bin/`
- `plugin.cfg`, `netcode.gdextension` files
- Verify the addon works in a fresh empty Godot project (smoke test)

**Why now:** All the refactoring is done. Pure file moves + path updates.

### Phase 8 — State machine + animation tree replication
**Deliverables:**
- `NetChildRef` schema entries auto-register `MovementStateMachine`, `PeekStateMachine`, `AnimationTree`
- `NetStateMachine` wrapper adopts current logic/visual dual-pointer pattern
- AnimationTree parameter list configured in schema; framework reads `tree.get(path)` on auth, writes on proxies
- Delete `crouch_progress` / `prone_progress` / `peek_progress` fields from `PlayerState` (auto-derived from active state's `@net var progress`)

**Why now:** Big cleanup of player-specific packet fields. Validates the auto-sync layer end to end.

### Phase 9 — Reliable RPC layer + NetReliable component
**Deliverables:**
- `NetReliable` component
- `NetReliableHub` autoload for routing
- Inventory entity as the first user
- Idempotency keys + bundling
- Spawn-ordering against snapshots (snapshots carry `min_spawn_seq`, buffered until satisfied)

**Why now:** Inventory work unblocks all UI-driven game features.

### Phase 10 — Lag compensation
**Deliverables:**
- Per-entity historical state ring buffer on server (last ~250ms, 32 ticks @ 128Hz)
- `LagCompensator.rewind_to(client_tick)` snapshot restore
- Hit detection wrapper that auto-rewinds opponents
- Configurable per-server max rewind window (anti-cheat hardening)

**Why now:** Needed before serious shooter playtesting. Foundation for hit detection.

### Phase 11 — Interest management (deferred)
Skip until 16+ player tests show bandwidth pressure. `PeerVisibilityFilter`-style per-peer field gating.

### Phase 12 — Steam integration (deferred)
Replace `gns-rs` link with Steamworks SDK `SteamNetworkingSockets` when Steam launch nears. Same API surface, gains SDR routing. No application code changes.

---

## 6. Bandwidth + perf targets

- **Target**: 16-player shooter, 120ms ping, ~2% loss, no visible stuttering.
- **Tickrate**: 128Hz physics, 64Hz snapshot send (configurable).
- **Bandwidth ceiling per client downstream**: ~250 Kbps after delta encoding (~190 Kbps typical).
- **Interp window default**: 1.0 × snapshot interval (= 15.6ms @ 64Hz).
- **Lag-comp window**: 250ms.
- **Reliable RPC budget**: <5/s/client steady state.

---

## 7. Comparison to netfox (for reference)

| Feature | netfox | This plan |
|---|---|---|
| Inheritance lock | None (`RollbackSynchronizer` is child node) | None (`NetPredictor` is child node) — convergent design |
| Field declaration | `Array[String]` of NodePath:property | `@export var` on typed Resource + `.tres` field configs |
| Type safety | Runtime string resolution | Typed @export, IDE autocomplete |
| Transport | ENet via MultiplayerAPI | GNS (Rust) |
| Quantization | None | Per-field via `NetFieldConfig.quant` |
| Delta encoding | Yes (`enable_diff_states`) | Yes (phase 6) |
| Lag compensation | No | Yes (phase 10) |
| Interp window | Fixed | Float multiplier, runtime-adjustable |
| Schema authoring | Inspector array of strings | Inspector + `.tres` Resources with dropdowns |
| Market position | Free, GDScript, casual coop | High-perf shooter, Rust dep OK |

Convergent on the architecture; differentiated on performance ceiling and type safety.

---

## 8. Open questions to resolve during refactor

1. **Sub-axis correction field syntax**: `"pos.xz"` vs `"pos.x"` + `"pos.z"` as separate entries vs a packed enum. Going with `"pos.xz"` for now (parser splits on `.`).
2. **`NetState` snapshot copy** — deep copy via `duplicate()`? Faster custom path? Profile before optimizing.
3. **Animation tree parameter discovery** — runtime via `AnimationTree.get_property_list()` vs editor scan baking. Probably runtime is fine; ~50 params at most.
4. **State machine state-id stability** — currently uses child index. Need a stable ordinal (explicit `state_id` export on each State?) to survive reordering nodes in editor.
5. **Multi-NetPredictor per entity** — useful for layered prediction (e.g., player + held-weapon state)? Or one schema per entity, period? Lean: one per entity for v1.
6. **Spawn replication** — server sends `EntitySpawnPacket` reliable, includes entity_id + scene path + initial state. Snapshot stream carries `min_spawn_seq` to enforce ordering.
7. **Schema versioning** — wire format hash baked into handshake so mismatched schemas refuse to connect rather than corrupt state.

---

## 9. Refactor work sequence (concrete next steps)

When resuming the refactor:

1. Commit / verify current code state is clean (or stash pre-existing player.gd/scene changes)
2. Create branch `refactor/netcode-foundations`
3. Phase 1: server tick clock + `NetTimeline` autoload
4. Validate against current single-player + multi-client connect flow
5. Phase 2: input redundancy
6. Phase 3: extract `NetPredictor` (largest single PR; player.gd halves in size)
7. Continue down the phase list

Stop after each phase, smoke test, commit. Phase 3 is the riskiest because it's the structural pivot; everything after follows the pattern set there.

---

## 10. Strong existing pieces preserved through refactor

1. **GNS via Rust** — gold-standard transport, untouched
2. **`define_packet!` macro** — keeps existing for handshake/spawn packets; new schema-driven codec is additive
3. **`SequenceRingBuffer`, `JitterBuffer`, `PacketSequence`** — Rust primitives reused as-is
4. **Logic/visual state machine dual-pointer** — preserved as `NetStateMachine`, replay-safe semantics intact
5. **Per-axis reconcile** — generalized to declarative correction channels, math unchanged
6. **Scene-tree organization** — minimally affected; NetPredictor adds one child node per networked entity
