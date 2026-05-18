# Per-peer adaptive lag-comp rewind cap

## Context

`NetLagCompensator.max_rewind_ticks` is a global anti-cheat clamp — currently
`DEFAULT_MAX_REWIND_TICKS = 60` ticks (500ms @ 120Hz). Sized for mobile-average's
worst-case legitimate `(server_tick - last_received_tick)` age. Trade-off: a
LAN/wifi-light client with ~80ms RTT gets the same 500ms rewind grace as a
mobile client — meaning the LAN player can "cheat the past" by 400ms more than
their network conditions justify, popping targets that crossed cover ~half a
second ago.

**Goal:** clamp each rewind to roughly the requester's measured RTT + a small
jitter margin, so the wider rewind grace is granted only to clients that
actually need it. CS:GO equivalent: per-client `sv_maxunlag` derived from
measured ping.

**What exists:**

- `rust/src/network_driver.rs:74` — `client_ping: i64` field is *client-side
  only*. Pulled via `client.get_connection_real_time_status(connection,
  0).status.ping()` in client poll path (`:455`).
- Server has no symmetric per-peer ping field. GNS exposes
  `get_connection_real_time_status(peer_connection, 0)` per peer — same API,
  just iterated over `connected_clients`.
- `NetLagCompensator.with_rewind(tick, callback)` is single-arg today; the
  caller (`shoot_handler.gd:154`) knows the shooter's `peer_id`
  (`shooter.owner_id`), so plumbing the peer id through is local.
- `HISTORY_TICK_CAPACITY = 128` (in `net_predictor.gd`) — memory ceiling on
  rewind, decoupled from the anti-cheat clamp. Any per-peer cap is bounded
  above by this. No history change required.

## Approach

Server samples each peer's GNS-measured ping once per server tick into an
EMA-smoothed cache. The lag compensator's rewind accepts an optional
`peer_id`; when provided, the legality window is computed as
`clamp(ceil((peer_rtt_ms + JITTER_MARGIN_MS) * tick_hz / 1000), MIN_CAP_TICKS,
HISTORY_TICK_CAPACITY)` instead of the static default. Fresh connections
(no ping sample yet) fall back to a generous floor; unknown peers fall back
to `DEFAULT_MAX_REWIND_TICKS` for back-compat.

Constants tentatively: `JITTER_MARGIN_MS = 80`, `MIN_CAP_TICKS = 30` (~250ms —
covers loopback / listen-server and 1-2s of fresh-connection settling).

## Phase A — Rust per-peer ping sampling

`rust/src/network_driver.rs`:

- Add `peer_pings: HashMap<u16, i32>` field on `NetworkDriver` (ms). Reset
  entries on peer disconnect.
- Inside `handle_server_events` (after Phase 0.2's `as_mut()` refactor) or in
  a dedicated `sample_peer_pings` helper called from `handle_events` once per
  server tick: iterate `server.connections()` (whichever API GNS exposes) or
  iterate the existing `connected_clients` set and call
  `server.get_connection_real_time_status(peer_conn, 0).status.ping()` for
  each. Store as i32 ms.
- `#[func] fn get_peer_ping(peer_id: i64) -> i64` — returns ms, or -1 if peer
  unknown.

Sample rate: once per server tick (120Hz). GNS's status call is cheap (in-mem
read). If profile shows it as hot, drop to every 8th tick (~15Hz) — ping
doesn't change fast.

## Phase B — GDScript NetServer ping cache + EMA

`godot/addons/netcode/core/net_server.gd`:

- `var _peer_ping_ema_ms: Dictionary` (peer_id → float).
- In server's per-tick handler (or in an existing post-tick callback), pull
  raw ping from `NetSession.get_peer_ping(peer_id)` and EMA-smooth at
  `alpha = 0.1` (matches NetTimeline's existing EMA constant).
- `func peer_ping_ms(peer_id: int) -> int` — returns rounded EMA value;
  returns `-1` if peer never sampled (caller decides fallback).
- Clear entry on `peer_disconnected`.

Optional: emit `peer_ping_updated(peer_id, ms)` once per N ticks for any
HUD subscriber.

## Phase C — Compensator per-peer overload

`godot/addons/netcode/core/net_lag_compensator.gd`:

- New constants:
  ```gdscript
  const JITTER_MARGIN_MS: int = 80
  const MIN_CAP_TICKS: int = 30
  ```
- New signature:
  ```gdscript
  func with_rewind_for_peer(tick: int, peer_id: int, callback: Callable) -> Variant
  ```
  Computes `peer_cap_ticks = _peer_cap_for(peer_id)`, temporarily overrides
  `max_rewind_ticks`, delegates to `with_rewind`, restores.
- `_peer_cap_for(peer_id) -> int`:
  - `ping_ms = NetServer.peer_ping_ms(peer_id)`
  - if `ping_ms < 0`: return `DEFAULT_MAX_REWIND_TICKS` (fallback)
  - return `clamp(ceil((ping_ms + JITTER_MARGIN_MS) * NetTimeline.tick_hz / 1000), MIN_CAP_TICKS, NetPredictor.HISTORY_TICK_CAPACITY)`
- Single-arg `with_rewind` keeps `DEFAULT_MAX_REWIND_TICKS` (back-compat for
  tests + any non-shoot caller).

## Phase D — Shoot handler plumbing

`godot/controllers/player/shoot_handler.gd:154`:

```gdscript
var result: Variant = _comp.with_rewind_for_peer(
        last_received_tick, peer_id,
        _do_raycast.bind(ray_origin, dir, peer_id, wall_dist))
```

`peer_id` already in scope at this site (`= shooter.owner_id`).

## Phase E — Refused-rewind telemetry

`net_lag_compensator.gd`:

- Add an out-arg or signal distinguishing refusal reasons: "history miss"
  (tick older than `HISTORY_TICK_CAPACITY`) vs "peer cap exceeded" (tick
  older than computed peer cap but younger than history). Lets the shoot
  handler log:
  ```
  [SHOOT] peer=N rewind_refused tick=T reason=peer_cap age=AGE cap=CAP
  ```
  Useful both for tuning constants and for spotting cheaters (consistent
  cap-breaches from one peer).

## Files to modify

**Rust:** `rust/src/network_driver.rs` (~30 LOC).

**GDScript:**
- `godot/addons/netcode/core/net_server.gd` — EMA cache + getter (~30 LOC).
- `godot/addons/netcode/core/net_lag_compensator.gd` — overload + cap calc
  + refusal reason (~30 LOC).
- `godot/controllers/player/shoot_handler.gd` — call-site swap, add
  refusal-reason log (~5 LOC).

**Tests:**
- `godot/tests/test_lag_comp_per_peer.gd` (new, ~50 LOC):
  - Stub `NetServer.peer_ping_ms` to fixed values; verify
    `_peer_cap_for` scales linearly with ping, floors at MIN_CAP_TICKS,
    ceilings at HISTORY_TICK_CAPACITY.
  - Unknown peer → returns DEFAULT_MAX_REWIND_TICKS (back-compat path).
  - Rewind at peer_cap-1: succeeds. At peer_cap+1: refused with reason
    "peer_cap".

## Reuses

- `NetTimeline.tick_hz` for ticks↔ms conversion.
- Existing `connected_clients` iteration in `network_driver.rs`.
- Existing `peer_disconnected` signal for cache cleanup.
- Existing EMA alpha (0.1) from NetTimeline as the smoothing constant.

## Trade-offs

**Fresh-connection floor (`MIN_CAP_TICKS=30`, ~250ms).** Loopback /
listen-server peer pings will measure near 0; we clamp at 250ms so a same-
process or LAN client isn't given a degenerate 8ms rewind window. This means
any client during their first ~1 second of connection — before EMA stabilizes
— effectively gets DEFAULT_MAX_REWIND_TICKS (since `ping_ms < 0` fallback
fires). Acceptable: cheat exposure on fresh connections is unchanged from
today's behavior.

**EMA vs. percentile.** EMA lags real ping changes (cell handoff, etc.).
P99-over-window would react slower to network *improvement*, bounding cheat
from one-off bad samples. EMA is simpler and good enough for v1. Revisit if
telemetry shows abuse via "ping flooding" attacks.

**Ping-inflation attack.** Attacker stalls GNS probe replies to inflate
measured ping → bigger rewind cap. But GNS pings via dedicated probe
packets, not piggy-backed acks; replying late requires actually delaying
their own traffic, which delays their shots reaching the server too. Net
zero gain. Bounded.

**Where to compute the cap.** In NetLagCompensator (clean encapsulation —
anti-cheat policy lives in one place) vs. in shoot_handler (caller controls
policy). Encapsulate in compensator — future damage sources (grenade
lag-comp, melee) get the same protection automatically.

## Out of scope (deferred)

- Server-side ping in debug HUD. Trivial once getter exists, but UI is its
  own pass.
- Per-peer cap for grenade lag-comp. Grenades currently don't rewind; if
  they ever do, this scaffolding applies as-is.
- Adaptive `HISTORY_TICK_CAPACITY` based on lobby-wide max ping. Memory is
  cheap; static 128 is fine.
- Cheat-detection telemetry (rolling count of cap-refused shots per peer →
  flag). Worth doing later for ops visibility, but separate from the cap
  itself.

## Verification

**Unit (in-tree):**
- Tests above pass.
- Existing `test_lag_compensation.gd` still passes (single-arg
  `with_rewind` falls through to legacy default).

**Two-process smoke:**
- Start dedicated server + two clients. Apply `--net-preset=mobile-average`
  on one client, `--net-preset=wifi-light` on the other.
- Verify `[SHOOT] peer=X rewind_refused reason=peer_cap` fires on the
  wifi-light client when they quote artificially-old ticks (manual edit
  hack on local fork to test), but not in normal play.
- Verify the mobile-average client's shots still resolve (their cap >
  their typical age).

**Profile:**
- Per-tick GNS status query × N peers. Expected: < 50µs total at 100
  peers. Drop sample rate to every 8th tick if measured hotter.

## Open notes

- If `get_connection_real_time_status` returns 0/-1 during connection
  handshake, treat as "unknown" and use fallback. Add a one-time log on
  first valid ping per peer for telemetry sanity.
- Document on shoot-handler refusal print: `reason=peer_cap` vs
  `reason=history_miss` is the diagnostic ops will use to tell "this
  player has bad ping, increase MIN_CAP" from "ancient tick, drop the
  shot".
- If lobby-wide latency grows beyond what `HISTORY_TICK_CAPACITY=128`
  covers (1067ms), revisit history first — caps inheriting that ceiling
  is correct behavior.
