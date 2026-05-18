# Network feel improvements

## Context

Bad-network test at mobile-average preset (200ms RTT + 60ms jitter + reorder) showed three concrete pains, validated against `bad-network-test.log` (5958 lines):

| Pain | Measured | Root cause |
|---|---|---|
| Shoot tracer needs full RTT to appear | First-shot delta 175–410ms (mean ~280ms) | Tracer renders only when `SHOT_FIRED` reliable arrives back from server; no client-side prediction |
| Grenade arc starts after full RTT | Not measured; same architecture as shoot | Throw is `THROW_GRENADE` reliable → server spawns → state syncs back |
| Rubber-band on counter-strafe + sprint; general jitter | 2704 RECON events, 60% of frames have a reconcile, magnitude distribution biased <0.4m (constant micro-jitter), with a long tail to 4m+ | Mobile-RTT inputs arrive stale → server simulates from stale snapshot → server state diverges from local prediction → reconcile snaps body each tick |

Anti-cheat clamp (`max_rewind_ticks=60`, 500ms) hit only 4 times in the session — the wider rewind window from the prior sprint is doing its job and not refusing legitimate shots.

User direction (verbatim): "*we need to optimize both maximum reaction time for good networked players and playability for bad network players (they will suffer no matter what) and still decrease trust vectors as much as possible to prevent exploits. [...] one thing i think we could leverage is add an option in gameplay to set interpolation window for users like cs2 exposes cl_interp.*"

This plan ships **client-side prediction of local-shooter visuals** (kills shoot/grenade RTT pain), **a user-controllable Network Quality preset** (lets bad-network users trade visual precision for input feel), and **reconcile-jitter tuning** (kills the constant micro-jitter). Anti-cheat surface is **not widened** — all server-authoritative paths (hit detection, damage, grenade explosion, lag-comp clamp) stay untouched.

## Goals

- Local shooter sees tracer ≤ 1 frame after trigger pull at any RTT.
- Local thrower sees grenade arc start ≤ 1 frame after throw input at any RTT.
- High-ping clients can opt in to smoother visuals with the understanding they'll trail their authoritative position by more meters.
- Reconcile event count drops 30%+ at mobile-average preset (HIGH quality) without changing single-player or low-ping behavior.
- No new trust vectors: server still owns hit detection, damage, grenade physics, and the lag-comp clamp.

## Non-goals

- Predicting remote players' shots/grenades (they remain server-authoritative).
- Predicting damage / hitmarkers on local shooter (server-authoritative; arrives separately via `HIT_CONFIRM`).
- Bot/AI prediction.
- Reworking the existing schema-driven correction pipeline. Multipliers hook in, structure unchanged.
- Adding the per-peer adaptive rewind cap (`lag-comp-per-peer-cap.md` — separate, deferred).

## Sprint overview

| # | Sprint | LOC | Days | Depends on |
|---|---|---|---|---|
| 0 | Diagnostic hardening (per-shot delta fix + grenade+throw timing logs) | ~40 | 0.5 | — |
| 1 | Client-side local tracer prediction | ~120 | 1.5 | 0 |
| 2 | Client-side local grenade prediction (ghost entity) | ~250 | 3 | 0 |
| 3 | Network Quality preset infrastructure (runtime multipliers + settings store) | ~300 | 2.5 | — |
| 4 | Network Quality auto-mode + escape-menu UI | ~200 | 2 | 3 |
| 5 | Reconcile-jitter tuning + log gate cleanup | ~80 | 1 | 3 |
| 6 | Counter-strafe specific velocity-priority reconcile (optional, gated on user testing) | ~150 | 2 | 5 |
| 7 | Verification pass + telemetry summary line | ~50 | 1 | all above |

Total: **~1190 LOC, ~13.5 dev-days.** Sprints 1, 2, 3 are independent — can be parallelized across a multi-dev split or interleaved.

---

## Sprint 0 — Diagnostic hardening

**Goal:** ensure the diagnostic logs added in the previous session report accurate per-shot/per-throw timing, plus the corresponding timing for grenade so the user can validate sprint 2.

### Deliverables

1. Per-shot `SHOOT-RENDER delta_ms` fix: clear `_shoot_local_edge_us` after first render — auto-fire's subsequent SHOT_FIREDs don't print stale-growing deltas. **(already in flight in current session, commit before sprint 1).**
2. New `[GRENADE-LOCAL t=US look=V]` log on grenade throw input edge (player.gd:209 area).
3. New `[GRENADE-SPAWN-CONFIRM local delta_ms=N]` log fired when the first NetState packet for a server-spawned grenade attributed to the local thrower arrives.
4. Memory note about how to flip all SHOOT/GRENADE/RECON logs off at once (single grep over `_LOG: bool = true` / `_DEBUG := true` constants).

### Files

- `godot/controllers/player/shoot_handler.gd` (already touched this session)
- `godot/controllers/player/player.gd` — grenade throw edge log
- `godot/entities/grenade/grenade.gd` — spawn-confirm log on first proxy state

### Verification

Run mobile-average bad-network test, grep:

```bash
grep -E "\[(SHOOT|GRENADE)-(LOCAL|RENDER|SPAWN-CONFIRM)" log
```

Expect per-shot delta ≈ first-RTT (~200ms) before sprint 1; expect grenade spawn-confirm ≈ first-RTT (~200ms) before sprint 2. These become the baseline numbers we beat.

---

## Sprint 1 — Client-side local tracer prediction

**Goal:** local shooter sees tracer same frame as trigger pull. No anti-cheat impact (hit detection unchanged, server-authoritative).

### Approach

On the rising edge of `shoot=true` in `_gather_command`, if the **client-side fire-rate gate** allows it, immediately call `_spawn_tracer` using the live camera position and look direction, **and** record the predicted shot in a small ring so the inbound server `SHOT_FIRED` can be matched and suppressed.

The server's `FIRE_INTERVAL_US = 120000` is mirrored as a client constant. Client gates its prediction at the same cadence. Mismatch (server denies a shot the client predicted — e.g. dead-state race) leaves a ghost tracer on screen that fades in 80ms via the existing tracer lifetime; acceptable.

### Implementation phases

**Phase 1.1** — extract tracer rendering into a publicly callable path. Today `_spawn_tracer(o, e)` is already a private method on `ShootHandler`. Promote it to `spawn_local_tracer(origin, look_dir)` that converts dir → endpoint via a fixed visual length (use the same 50m render cap the server uses for misses) and calls the existing `_spawn_tracer`.

**Phase 1.2** — predicted-shot ring on `ShootHandler`:
- Small fixed-size dict `_predicted_shots: Array[int]` of monotonic counter IDs, capped at e.g. 32.
- `_last_predicted_shot_us: int` for client-side rate-limiting.

**Phase 1.3** — wire prediction in `player.gd._gather_command`:
- On `shoot=true` rising edge AND `Time.get_ticks_usec() - shoot_handler._last_predicted_shot_us >= FIRE_INTERVAL_US`:
  - Get camera `global_position` and forward basis
  - Call `shoot_handler.spawn_local_tracer(cam_pos, -cam_forward)`
  - Push a predicted-shot marker
  - Bump `_last_predicted_shot_us`
- Also handle auto-fire: while `shoot=true` held, the same gate fires the next tracer when cadence elapses. Match server cadence exactly so suppression below works.

**Phase 1.4** — suppress server loopback for local shooter:
- In `_on_shot_fired`, when `shooter_id == NetClient.id`:
  - If `_predicted_shots` non-empty: pop oldest, return (predicted tracer already on screen)
  - Else: render normally (was an unpredicted shot — first shot after spawn before predictor seeded, or anti-cheat race)
- Remote shooters: unchanged.

**Phase 1.5** — fall-through safety: if 10+ predicted shots haven't been confirmed (e.g. high jitter caused server to denial-spam), wipe the ring and force-render the next server tracer. Prevents desync where predictions out-pace actuals indefinitely.

### Files

- `godot/controllers/player/shoot_handler.gd` — `spawn_local_tracer` public, `_predicted_shots` ring, modified `_on_shot_fired`.
- `godot/controllers/player/player.gd` — `_gather_command` rising-edge call into shoot handler.

### Risks

- **Predicted tracer angle mismatch.** Local prediction uses camera forward at trigger pull. Server uses the captured `look_yaw/look_pitch` from the buffered NetCommand (one tick stale at minimum). At 120Hz that's ~8ms of camera motion, which during sprint+turn is ~0.5° angular delta. Tracers fade at 80ms — likely invisible. If users report visible offset, snap the predicted tracer's endpoint to match the server's when SHOT_FIRED arrives (replace ghost, not just suppress).
- **Anti-fire cheat surface unchanged.** Client predicts visuals only; the server's fire-rate enforcement is the only authority on whether a shot is "real." A client mod that predicts at 100ms cadence just shows the user fake tracers; no extra damage is dealt.

### Verification

- `[SHOOT-RENDER local delta_ms=N]` post-sprint: median <16ms (single frame). Sprint 0 baseline was ~280ms.
- Single-shot mode: zero double-tracer visible.
- Auto-fire: tracers appear at smooth 120ms cadence (8.3/sec) locally; server arrivals get suppressed.
- Two-process test: remote shooter's tracer appears normally (unaffected).

---

## Sprint 2 — Client-side local grenade prediction (ghost entity)

**Goal:** local thrower sees the grenade leave their hand and arc through space same frame as throw input. Server-spawned grenade replaces ghost when its first state packet arrives.

### Approach

Pre-instantiated **ghost-grenade** scene (visually identical to real grenade, no NetPredictor, no networking, local-physics-only). On `throw_grenade` input edge, the ghost is parented under a local "predicted-grenades" root, given the same initial velocity the reliable packet carries, and simulated by Godot's physics engine locally. When the first NetState for a server-spawned grenade with matching `thrower_id` arrives, the ghost is hidden (not freed yet — kept until explosion). When the real grenade explodes, the ghost is freed.

Why **ghost rather than NetPredictor-based prediction:** today's throw flow uses a separate `THROW_GRENADE` reliable packet (player.gd:209, grenade_spawner.gd:28-55), **not** the per-tick PlayerInput stream. Predicting via NetPredictor would require routing throws through PlayerInput, adding a `pending_throws` field to PlayerState, and threading replay logic — substantially more work for a feature where ghost-and-replace looks identical to the user.

### Implementation phases

**Phase 2.1** — `entities/grenade/ghost_grenade.gd` + `.tscn`. Strip the real grenade scene of NetPredictor + damage logic. RigidBody3D with same shape, mass, drag. Disabled physics layer for non-local-player collisions (still bounces off world geometry; passes through other players).

**Phase 2.2** — local-prediction store on `GrenadeSpawner`:
- `_local_ghosts: Dictionary[int, GhostGrenade]` — keyed by a local-incrementing ghost ID
- `_pending_ghost_match: Array[Dictionary]` — `[{ghost_id, origin, velocity, throw_time_us }]`

**Phase 2.3** — wire local prediction in `player.gd._send_grenade_throw`:
- Before sending the reliable: spawn a ghost via `GrenadeSpawner.spawn_local_ghost(origin, velocity)`
- Spawn returns the ghost; player records nothing further

**Phase 2.4** — match server-spawned grenade to ghost on first state:
- In `grenade.gd._proxy_apply` (or `_on_entity_registered` if data available there), check if `thrower_id == NetClient.id`
- If so, ask `GrenadeSpawner` to find the matching ghost by closest `throw_time_us` (within ±500ms window) and matching `velocity` (within 0.1 m/s — should be exact if our local capture matches what we sent)
- On match: hide the ghost (alpha=0 or visible=false); mark as matched
- Once the real grenade reaches STATE_EXPLODING, free the matched ghost

**Phase 2.5** — explosion handling:
- Ghost fuse runs locally. If real explosion arrives first: ghost is invisible already, no extra work.
- If ghost detonates before real explosion: play visual-only explosion on ghost (purely cosmetic), then wait for real grenade's explosion before freeing. Damage is **never** applied client-side from a ghost — that's the server's exclusive job.
- If real grenade rejected by server (thrower died mid-throw, server cooldown miss): ghost flies and lands and visual-detonates with no damage. User sees a grenade that did nothing. Better than nothing visible at all.

**Phase 2.6** — divergence handling: ghost trajectory and real trajectory will diverge slightly over the fuse window (3 seconds) due to floating-point drift between server's RigidBody3D and client's. Acceptable for v1. If users notice, sprint 2.5 swaps ghost rendering off the moment the real grenade NetState arrives (~1 RTT after throw) — ghost still sims but isn't visible, real grenade is what they see thereafter.

### Files

- `godot/entities/grenade/ghost_grenade.gd` + `.tscn` (new)
- `godot/entities/grenade/grenade_spawner.gd` — `spawn_local_ghost`, match-and-hide logic
- `godot/entities/grenade/grenade.gd` — `_proxy_apply` notifies spawner on first apply
- `godot/controllers/player/player.gd` — `_send_grenade_throw` spawns ghost before sending reliable

### Risks

- **Ghost+real both visible window.** Roughly the first RTT. Test at mobile-average: 200ms of "two grenades next to each other" looks bad. Mitigation: hide ghost the instant first NetState arrives (sprint 2.6's deferred work) — typical case becomes "see ghost for 200ms, then real grenade replaces it seamlessly because they're at the same place."
- **Match failure → orphan ghost.** If server never spawns (denied), ghost flies forever, eventually self-cleans on fuse-zero. Worst case: user threw a grenade they "saw" do nothing. Rare.
- **Performance.** Ghost is a RigidBody3D. Throwing N grenades creates N ghosts until matched. Cap at e.g. 4 active ghosts (drop oldest).

### Verification

- `[GRENADE-LOCAL]` → ghost visible same frame. `[GRENADE-SPAWN-CONFIRM]` from sprint 0 fires ~RTT later but ghost is already there.
- Visually: throw at mobile-average, watch first 500ms — single grenade arc, no jump, no doubling.
- Throw, then die before grenade lands — ghost completes arc + visual detonation; no damage applied.

---

## Sprint 3 — Network Quality preset infrastructure

**Goal:** runtime multipliers on reconcile smoothing/snap/deadband and interp window, plus a settings persistence path. No UI yet — programmatic only with a default preset of `BALANCED`.

### Approach

Three multipliers stored on a new `NetClient.quality_preset: Dictionary` populated at boot:

```
{
  smooth_rate_mul: float    # 1.0 = current; higher = faster correction
  snap_mul: float           # 1.0 = current; higher = more tolerant
  deadband_mul: float       # 1.0 = current; higher = ignore more tiny errors
  buffer_segments_mul: float # 1.0 = current; higher = more interp lag, smoother proxies
}
```

`net_predictor.gd` reads these multipliers at six existing read sites (lines 1785, 1798, 1801, 1834, 1836, 1839 per the explore report) — multiply `c.smooth_rate`, `c.snap_threshold`, `c.deadband` in place. One write site for `buffer_segments`: line 305 multiplies the schema value before passing to ring buffer.

Settings persistence via new `SettingsStore` autoload backing `user://settings.cfg`, a single ConfigFile. Top-level section `[network]`, key `quality_preset` (enum LOW/BALANCED/HIGH/AUTO).

### Preset values (initial, tuned in sprint 5)

| Preset | smooth_rate_mul | snap_mul | deadband_mul | buffer_segments_mul |
|---|---|---|---|---|
| LOW (<40ms RTT)       | 1.5  | 0.5  | 0.7 | 0.6 |
| BALANCED (40-100ms)   | 1.0  | 1.0  | 1.0 | 1.0 |
| HIGH (>100ms RTT)     | 0.6  | 1.5  | 1.5 | 1.4 |
| AUTO                  | (sampled, see sprint 4) | | | |

**Interpretation:**
- LOW shrinks the smoothing constant (corrects faster — feels tighter), shrinks snap threshold (snap sooner because errors should be smaller), shrinks deadband (correct even small errors).
- HIGH does the opposite: corrects slower (more visual lag, less jitter), tolerates bigger errors before snapping (huge mispredicts are normal here), ignores small errors entirely (kills micro-jitter), buffers proxies longer (smoother remote players at the cost of seeing-them-late).

### Implementation phases

**Phase 3.1** — `SettingsStore` autoload:
- `var quality_preset: int` (enum)
- `load()` from `user://settings.cfg` on `_ready`, fallback to BALANCED
- `set_quality_preset(v: int)` writes through to disk
- Signal `quality_preset_changed(new_preset: int)`

**Phase 3.2** — `NetClient.quality_multipliers: Dictionary` computed from SettingsStore. Update on signal. Recompute on AUTO mode every N seconds (sprint 4).

**Phase 3.3** — apply multipliers in `net_predictor.gd`. Six existing reads — multiply in-place. Single `buffer_segments` read — multiply at line 305 before `set_buffer_delay_multiplier`.

**Phase 3.4** — never apply multipliers on the server / dedicated-server. Quality preset is a client-only concept. Gate read sites on `NetSession.has_client_role && not is_authoritative_instance` (correction reads only fire on non-auth NetPredictors anyway, so this is mostly a no-op; double-check in implementation).

**Phase 3.5** — tests under `godot/tests/`:
- `test_quality_preset_persistence.gd` — set, restart-load, verify
- `test_reconcile_with_quality_preset.gd` — fake a NetPredictor reconcile under each preset, verify the chosen alpha/snap path differs as expected

### Files

- `godot/core/settings_store.gd` + autoload entry in `project.godot`
- `godot/addons/netcode/core/net_client.gd` — `quality_multipliers` derived prop
- `godot/addons/netcode/components/net_predictor.gd` — six read sites + buffer_segments
- New tests above

### Risks

- **Multipliers compose surprisingly.** A 0.6× smooth_rate at HIGH means a smoothing time constant of ~1.67× longer; at the same time deadband ×1.5 means many small errors are skipped entirely. Net effect needs measurement — could be too sluggish. Sprint 5 tunes against real test logs.
- **Server thinks it's a client too on listen-server (future).** When the listen-server work lands (see `snuggly-cooking-boole.md` plan), the host's own NetPredictor will be authoritative on one instance and proxy on another. Multipliers must apply only to proxy. Sprint 3.4 covers this.

### Verification

- Programmatic test: `SettingsStore.set_quality_preset(HIGH)` → relevant NetPredictor's next reconcile uses scaled values.
- Default boot: BALANCED preset → byte-for-byte identical reconcile behavior to pre-sprint.

---

## Sprint 4 — Network Quality auto-mode + UI

**Goal:** AUTO mode samples current RTT and picks LOW/BALANCED/HIGH on a 5-second hysteresis. Escape menu exposes the four-way picker.

### Implementation phases

**Phase 4.1** — AUTO mode sampling:
- New `var _ping_ema_ms: float = 80.0` on `NetClient` (assumed-decent fallback)
- Tick handler EMA-smooths `NetSession.client_ping` (Rust-exposed already)
- Every 5 seconds (or on connection establishment + 2-second settle), if AUTO is selected:
  - `<40ms` → LOW (with -10ms hysteresis: stay HIGH until <30ms)
  - `40-100ms` → BALANCED (-10/+10 hysteresis around bucket edges)
  - `>100ms` → HIGH (+10ms hysteresis: stay BALANCED until >110ms)
- Apply via SettingsStore signal — same path as manual selection.

**Phase 4.2** — escape-menu submenu:
- Replace "Gameplay" stub button (`escape_menu.gd:103-117`'s area) with a working handler that populates `ContentVBox` with a four-way OptionButton: AUTO / LOW / BALANCED / HIGH
- Below the picker, a live readout: "Current RTT: 187ms — applying HIGH preset"
- Below that, a one-sentence description of the trade-off: "HIGH: smoother visuals on bad networks. Your avatar may appear slightly behind where you actually are."
- Persist on change via SettingsStore.

**Phase 4.3** — main-menu version of the same submenu under existing "Settings" path so users can pre-pick before joining.

**Phase 4.4** — keep CLI override: `--quality-preset=high` flag for headless test runs, parsed in `main_menu.gd._maybe_autoconnect`.

### Files

- `godot/addons/netcode/core/net_client.gd` — AUTO sampling
- `godot/ui/escape_menu/escape_menu.gd` — gameplay submenu
- `godot/ui/main_menu/main_menu.gd` — settings submenu (or split into its own scene)
- `godot/core/settings_store.gd` — no change

### Risks

- **Hysteresis thrash on jittery connections.** 5-second sample with ±10ms hysteresis should be plenty. If users report flapping, widen hysteresis or require N consecutive samples.
- **First-connection settling.** AUTO starts at BALANCED (default `_ping_ema_ms = 80`). Real ping replaces it within 1-2 seconds. Acceptable.

### Verification

- Manual: spin up two-process test with `--net-preset=mobile-average`. AUTO should pick HIGH within 5 seconds; flip to wifi-light preset mid-play, AUTO should pick BALANCED then LOW within ~10 seconds.
- Manual: pick LOW manually at mobile-average. Verify rubber-band is **worse** (proves multipliers actually changed behavior) and that the picker preview reads correctly.

---

## Sprint 5 — Reconcile-jitter tuning + log gate cleanup

**Goal:** with multipliers wired up, run the bad-network log capture under HIGH preset and tune the multiplier values so that:

- Reconcile event count drops 30%+
- Sub-0.4m offset count (the "constant jitter" bucket) drops 50%+
- No new hard-snaps introduced
- Counter-strafe peaks (>1.5m offsets) don't get worse

### Approach

1. Capture two log sessions: BALANCED and HIGH presets at mobile-average. Same gameplay script (walk → sprint → counter-strafe → sprint → stand).
2. Compute distribution stats per preset (re-use the grep+awk pipeline from chat).
3. If HIGH's <0.4m bucket isn't 50% lower than BALANCED's: bump `deadband_mul` to 2.0.
4. If HIGH's snap count rises: bump `snap_mul` to 2.0.
5. If HIGH feels noticeably more sluggish to the player: drop `smooth_rate_mul` floor to 0.8 (less aggressive lengthening).
6. Repeat 2-5 until stats hit.

Capture the final-tuned values in code (`SettingsStore` constants).

### Log gate cleanup

After tuning lands, flip diagnostic logs default-off:

- `SHOOT_DEBUG = false` in `player.gd`
- `SHOOT_LOG = false` in `shoot_handler.gd`
- `RECONCILE_LOG = false` in `net_predictor.gd`
- (Sprint 0's grenade equivalents follow the same pattern)

Add a single `NetClient.diagnostics_enabled` autoload-level toggle so dev can flip them all on at once when debugging future regressions, instead of editing six files.

### Files

- `godot/core/settings_store.gd` — tuned constants
- All log-gate constants in the four files above
- New `godot/addons/netcode/core/net_client.gd` `diagnostics_enabled` property

### Risks

- **Tuning is data-driven; values in sprint 3 are guesses.** Sprint 5 is the empirical pass. Some iteration expected.

### Verification

- New baseline log capture passes the targets above.
- All log-gate constants default false in the next commit. CI/release builds aren't dumping log lines per shot.

---

## Sprint 6 — Counter-strafe specific velocity-priority reconcile (gated)

**Goal:** investigate whether counter-strafe rubber-band can be cut further by skipping position reconcile during input-direction-flip transients and reconciling velocity-only for those few ticks.

### Why this is optional

The user's pain on counter-strafe might be sufficiently addressed by HIGH preset's looser smoothing alone. Capture sprint 5 logs first; if counter-strafe peaks still exceed 1m at HIGH preset, run sprint 6. If they're <0.7m, skip — the cost/risk of adding a new reconcile mode isn't worth it.

### Approach (if pursued)

- Detect "input flip" tick on the client: previous-tick move vector dot current-tick move vector < -0.3 (~110° direction change)
- For N=4 ticks after a flip: suppress horizontal `pos` reconcile entirely, still reconcile `velocity` and `pos.y`
- Why this works: during counter-strafe the server's position will catch up over a few ticks anyway as the same input it now receives matches what we predicted. Skipping the brief disagreement window prevents one snap per direction change.

### Risk

- **Hides real desync during flips.** If a wall-hack tries to use this window, server still owns hit detection and damage — but the visual position might drift further than today. Mitigate with a max-drift safety: if accumulated suppressed error exceeds 2m, force a reconcile anyway.

### Files (if pursued)

- `godot/addons/netcode/components/net_predictor.gd` — flip detection in correction pass, conditional skip of horizontal channel
- New test: `test_input_flip_velocity_only_reconcile.gd`

---

## Sprint 7 — Verification + telemetry summary

**Goal:** end-to-end demo of the improvements + a one-line per-session summary log so future regressions are obvious.

### Deliverables

1. Single playtest session at mobile-average with all features enabled (LOW/BALANCED/HIGH manual cycling). Recorded video. Pass criteria:
   - Local shooter sees tracer within 1 frame of trigger (visible in slow-mo replay)
   - Local thrower sees grenade arc start within 1 frame of throw input
   - HIGH preset visibly smoother than BALANCED to the user; LOW preset feels tightest (and rubber-bands the most — that's expected)
   - Picker UI works, persists across restart

2. `[NET-SUMMARY n_reconciles=N peak_offset=Xm snap_count=N preset=HIGH session_s=N]` printed once when player disconnects or scene unloads. Single grep target for ops/dev to see post-session stats.

3. Update `CLAUDE.md` "Architecture" section: brief mention of Network Quality preset under client/server split section.

### Files

- `godot/addons/netcode/components/net_predictor.gd` — summary emitter on shutdown
- `CLAUDE.md` — doc update

---

## Anti-cheat impact summary

For each new client-side capability, the trust vector:

| Capability | Client can fake | Server defense |
|---|---|---|
| Predict local tracer | Visual line on user's screen | Hit detection on server uses authoritative raycast against authoritative shadow_state. Faked tracer = faked visual = no damage dealt. |
| Predict local grenade arc | Visual grenade on user's screen | Real grenade spawned only via `THROW_GRENADE` reliable → server validates cooldown + thrower-alive. Ghost dealing damage is impossible (ghost has no damage code). |
| Network Quality HIGH multipliers | Looser reconcile = client visually trails authoritative position by more meters | Server still simulates the authoritative position. Client visual lag doesn't affect server's hit detection (lag-comp rewinds to client-quoted tick) or movement validation (server runs the same player physics regardless of client smoothing). |
| Network Quality LOW multipliers | Tighter reconcile = client visually matches authority more strictly | No new surface; just less visual lag for the user. |
| AUTO ping sampling | Client could lie about its ping to pick a higher tier preset | Preset is client-local — no server policy depends on it. Lying about ping has no in-game effect because the server-side anti-cheat rewind clamp (`max_rewind_ticks=60`) is independent and not influenced by client-reported ping. |

**Net trust delta: zero.** All new client-side state is presentation-layer; all gameplay-affecting decisions stay server-authoritative. The per-peer adaptive rewind cap (`lag-comp-per-peer-cap.md`) is the place where ping starts to affect server policy — that's a separate, future plan.

---

## Out of scope

- Per-peer adaptive rewind cap. See `lag-comp-per-peer-cap.md`.
- Predicting damage / hitmarkers on local shooter.
- AI/bot prediction.
- Tracer/grenade prediction for *remote* players.
- Reworking the schema-driven correction pipeline structurally. Multipliers hook in.
- Reworking listen-server / client-hosted mode. See `snuggly-cooking-boole.md`.

## Open notes

- Sprint 5's tuning values are guesses. Real numbers come from log capture.
- If sprint 6 is pursued and lands, document the input-flip suppression carefully — it's the kind of subtle behavior that confuses the next person to debug a reconcile bug.
- Sprint 2's ghost-grenade approach assumes existing grenade visual logic is cleanly extractable. If `grenade.gd` mixes visuals with networking too tightly, the ghost scene becomes more work — re-estimate after sprint 0 lands.
- The `--quality-preset=high` CLI flag in sprint 4 is also useful for CI: future automated playability tests can pin the preset to remove a variable.
