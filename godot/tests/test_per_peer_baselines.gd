extends TestBase

# Sprint 6: server keeps a baseline + keyframe counter per peer instead of one
# shared baseline. Verifies the bookkeeping primitives + per-peer delta encode
# work without driving them through NetSession (no real server bind in tests).


func test_update_peer_baseline_creates_entry() -> void:
	var p := _make_predictor()
	(p.shadow_state as PlayerState).pos = Vector3(1.0, 2.0, 3.0)

	assert_eq(p._peer_baselines.size(), 0, "starts empty")
	p._update_peer_baseline(101, true)
	assert_eq(p._peer_baselines.size(), 1, "peer 101 should be tracked after first update")
	var rec: Dictionary = p._peer_baselines[101]
	assert_eq(int(rec["ticks_since_kf"]), 1, "keyframe send resets counter to 1")
	assert_vec3_approx((rec["state"] as PlayerState).pos, Vector3(1.0, 2.0, 3.0))


func test_update_peer_baseline_increments_on_delta() -> void:
	var p := _make_predictor()
	p._update_peer_baseline(1, true)
	p._update_peer_baseline(1, false)
	p._update_peer_baseline(1, false)
	assert_eq(int(p._peer_baselines[1]["ticks_since_kf"]), 3,
			"counter should increment on each delta send")


func test_forget_peer_baseline_removes_entry() -> void:
	var p := _make_predictor()
	p._update_peer_baseline(42, true)
	assert_true(p._peer_baselines.has(42))
	p.forget_peer_baseline(42)
	assert_false(p._peer_baselines.has(42))


func test_encode_payload_uses_peer_baseline_for_delta() -> void:
	# Two peers with different baselines should get different-sized payloads
	# when the shadow state changed relative to one but not the other.
	var p := _make_predictor()
	var state: PlayerState = p.shadow_state

	state.pos = Vector3(5.0, 0.0, 0.0)
	# Peer A: baseline matches current state. Their next delta should be tiny
	# (mask-only, no field bytes).
	p._update_peer_baseline(1, true)
	var peer_a_rec: Dictionary = p._peer_baselines[1]
	var peer_a_payload: PackedByteArray = p._encode_payload(
			false,
			peer_a_rec["state"],
			peer_a_rec["child_values"],
			peer_a_rec["ticks_since_kf"])

	# Peer B: baseline frozen at empty state — they'll see pos as dirty.
	var stale_baseline: PlayerState = PlayerState.new()
	stale_baseline.pos = Vector3.ZERO
	var peer_b_payload: PackedByteArray = p._encode_payload(
			false,
			stale_baseline,
			[],
			1)

	assert_true(peer_b_payload.size() > peer_a_payload.size(),
			"peer with stale baseline (%d bytes) should get bigger delta than fresh peer (%d bytes)" \
					% [peer_b_payload.size(), peer_a_payload.size()])


func test_encode_payload_forces_keyframe_when_baseline_null() -> void:
	# A new peer has no baseline yet. Encoder must promote to keyframe even if
	# the caller asked for a delta.
	var p := _make_predictor()
	(p.shadow_state as PlayerState).pos = Vector3(2.0, 2.0, 2.0)
	var payload: PackedByteArray = p._encode_payload(false, null, [], 1)
	assert_eq(payload[0], 1, "expected keyframe header byte (1) when baseline is null")


func test_keyframe_stagger_across_peers() -> void:
	# Two peers with different ticks_since_kf counters must keyframe on
	# different physics ticks. Encoder consults each peer's counter
	# independently — if peer A is at INTERVAL and peer B is at 1, only A
	# should get a keyframe this tick.
	var p := _make_predictor()
	var baseline: PlayerState = (p.shadow_state as PlayerState).duplicate()

	var a_payload: PackedByteArray = p._encode_payload(
			false, baseline, [], NetPredictor.KEYFRAME_INTERVAL)
	var b_payload: PackedByteArray = p._encode_payload(
			false, baseline, [], 1)
	assert_eq(a_payload[0], 1, "peer A at interval should get a keyframe")
	assert_eq(b_payload[0], 0, "peer B mid-cycle should get a delta")


func _make_predictor() -> NetPredictor:
	# Same scaffolding pattern as test_snapshot_roundtrip._make_predictor: skip
	# the SceneTree-dependent half of _ready and populate fields by hand.
	var p := NetPredictor.new()
	p.schema = PlayerSchema.build()
	p.shadow_state = p.state_template.duplicate(true) as NetState
	p.render_state = p.state_template.duplicate(true) as NetState
	p.state_field_names = NetPredictor._user_field_names(p.shadow_state)
	p._cache_state_field_cfgs()
	return p
