# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

"Battle Royale" — Godot 4.6 (Forward+) multiplayer game. Authoritative server with client-side prediction & reconciliation. Networking + math + packet codecs implemented in Rust via [godot-rust](https://github.com/godot-rust/gdext) (`godot = "0.4.3"`), backed by Valve's GameNetworkingSockets (`game-networking-sockets` crate). Godot project lives in `godot/`, Rust gdextension in `rust/`.

## Build / run

Rust gdextension (must build before opening editor, debug profile is what editor loads):

```
cd rust
cargo build              # debug -> rust/target/debug/, picked up by editor
cargo build --release    # release -> manually copy to godot/addons/rust/bin/ for exports
```

Linker target paths in `godot/addons/rust/rust.gdextension`:
- Editor/debug reads `rust/target/debug/librust.{so,dylib,dll}`
- Exports/release reads `godot/addons/rust/bin/librust.*`

Godot: open `godot/project.godot` in Godot 4.6 editor. No CLI test harness; no lint config. Linux cross-compile from macOS uses `x86_64-w64-mingw32-gcc` (see `rust/config.toml`).

CI: `.github/workflows/godot-google-ci.yml` builds Rust on 3 OS runners, uploads libs to GCS, then triggers `cloudbuild.yaml` to do Godot exports + PCK patch diffs. Env vars `GODOT_VERSION`, `EXPORT_NAME=battle-royale`, `PROJECT_PATH=godot`.

## Architecture

### Networking — client/server split

Autoloads registered in `project.godot` from `addons/netcode/core/`:
- `NetSession` (`net_session.tscn`) — extends the Rust `NetworkDriver` class. Exposes fake lag/loss/jitter/dup/reorder knobs that proxy into GNS. Emits `on_client_packet` / `on_server_packet` / `on_disconnect_from_server`. Renamed from `NetworkTransport` in Sprint 3.
- `NetClient` — receives packets, manages local + remote player IDs, emits per-packet-type signals (`handle_net_state`, `handle_net_reliable`, `handle_server_tick`, etc.). Renamed from `NetworkClient`.
- `NetServer` — server-side counterpart. Renamed from `NetworkServer`.
- `NetTimeline` — server tick clock + interp window helpers (`tick_delta`, `server_now_us`, `render_time_us`).
- `NetReplication` — entity registry + snapshot dispatch (registers schemas/predictors, routes `NetStatePacket`s).
- `NetReliableHub` — reliable RPC routing with topic-based subscription + dedup ring.

`NetSession.is_server` distinguishes roles at runtime — same binary, same scripts. All autoload always.

Packets defined in Rust (`rust/src/packet/`): `PlayerInputPacket`, `NetStatePacket`, `NetReliablePacket`, `IdAssignmentPacket`, `PlayerDisconnectedPacket`, `ServerTickPacket`. Serialized with `postcard` + serde. Macros in `packet/macros.rs` bridge to GDScript classes.

### Player controller — dual logic/visual state machine

`godot/controllers/player/player.gd` (`PlayerController extends CharacterBody3D`) is authoritative-input-replay capable.

Two state machines as children (`MovementStateMachine`, `PeekStateMachine`) using base classes in `godot/core/state_machine/`:
- `StateMachine.gd` runs **two parallel state pointers**: `_logic_state` (deterministic game step, advanced via `run_logic`) and `_visual_state` (cosmetic, synced via `sync_visual` after logic settles). They diverge during input replay so visuals don't flicker.
- `State.gd` has paired callbacks: `logic_enter/exit/physics/process/transitions` for deterministic side; `visual_enter/exit/physics/process` for cosmetics.
- Transitions: states emit `transition(name)` signal; SM queues into `_pending_transition` and resolves in a loop per physics step (with same-frame cycle detection).
- `INITIAL_STATE` and `DEBUG_NAME` exported per SM. State IDs derived from child index — order of state child nodes matters for network sync (`state_to_id`).

Movement states: `idle / walk / sprint / crouch / prone / jump / fall` (under `movement_states/`). Peek states: `not_peek / peek / peeking` (under `peek_states/`).

`Enums.IntegrationContext { VISUAL, GAME }` — `player.context` flips this; states branch behavior accordingly. `is_authority` true only when local client owns this player. `is_replaying_inputs` true while reconciling.

Reconciliation tunables on `PlayerController`: snap thresholds, correction rates, deadbands for horizontal/vertical position + velocity. Server sends `PlayerStatePacket`; client compares against unacked `SequenceRingBuffer` of inputs, snaps or smooths.

Input: `PlayerInput` (RefCounted) wraps current + previous `PlayerInputPacket` and exposes `is_*_just_pressed()` edge helpers.

### Rust crate layout

`rust/src/lib.rs` registers `MyExtension` via `#[gdextension]`. Modules:
- `network_driver` — `NetworkDriver` Godot Node class wrapping GNS sockets (client + server), polls messages/events with time budget (`POLL_TIME_BUDGET_MS = 2`).
- `packet/` — all wire types + conversions to/from Godot variants.
- `data_structures/` — `JitterBuffer`, `SequenceRingBuffer` (exposed to GDScript).
- `math/sequence.rs` — sequence number comparison (wraparound-safe).

Default port 45876. `PLAYER_COUNT = 100`.

### World / UI

- `world/test_map`, `world/island_map` — playable scenes. Main scene set via `run/main_scene` uid in `project.godot`.
- `ui/` — `main_menu`, `escape_menu`, `init` (boot), `debug` (in-game overlay), shared `themes`.
- `core/toggle_ui.gd` — generic UI toggle helper.
- Debug overlay only shown when client (not server) and `NetworkClient.debug` set; state machines push current state name via `NetworkClient.debug.set_debug_property(DEBUG_NAME, ...)`.

## Conventions

- Input action names live in `project.godot` `[input]` (move_*, jump, crouch, prone, peek_left/right, sprint, toggle_camera, debug). Use `Input.is_action_*` with these exact names.
- `Constants` and `Enums` autoloads — put shared consts/enums there, don't re-declare.
- `.uid` files are Godot resource UIDs; don't hand-edit, don't delete (they pin cross-scene references).
- Toggle vs hold for crouch/peek controlled by exported `TOGGLE_CROUCH` / `TOGGLE_PEEK` bools on `PlayerController`.
- When adding a new packet: define Rust struct in `rust/src/packet/`, register in `packet/mod.rs`, add conversion, wire dispatch in `network_client.gd` / `network_server.gd`.
- When adding a state: add child node under the SM, implement logic_* + visual_* on a `State` subclass, emit `transition(&"name")` to switch. State child order determines network ID — appending is safe, reordering breaks replay across versions.

## Asset dimensions (from blender-notes.md)

Walls 4m × 2.4m × 0.25m. Door 0.826m × 2.04m. Medium window 1.2m × 1.35m @ 0.9m sill. Clerestory 1.2m × 0.4m @ 1.7m sill. Baseboard 10cm tall × 1cm deep. House foundation 12m × 8m.
