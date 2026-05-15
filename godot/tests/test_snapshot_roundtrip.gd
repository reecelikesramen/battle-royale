extends TestBase

# Phase 6b: shadow_state -> NetStatePacket.payload -> back to fields must
# preserve every @export. NetPredictor.snapshot_payload() uses StreamPeerBuffer
# put_var over discovered field names; decode must read them in the same order.

func test_full_snapshot_roundtrip() -> void:
	var predictor: NetPredictor = _make_predictor()
	var src: PlayerState = predictor.shadow_state
	src.pos = Vector3(1.5, 2.5, -3.5)
	src.velocity = Vector3(10.0, 0.0, -5.5)
	src.look = Vector2(0.4, -1.2)
	src.movement_state = 3
	src.peek_state = 1
	src.crouch_progress = 0.75
	src.prone_progress = 0.0
	src.peek_progress = 0.42

	var payload: PackedByteArray = predictor.snapshot_payload()
	assert_true(payload.size() > 0, "payload empty")

	var decoded: PlayerState = _decode(payload, predictor.state_field_names)
	assert_vec3_approx(decoded.pos, src.pos)
	assert_vec3_approx(decoded.velocity, src.velocity)
	assert_eq(decoded.look, src.look)
	assert_eq(decoded.movement_state, src.movement_state)
	assert_eq(decoded.peek_state, src.peek_state)
	assert_approx(decoded.crouch_progress, src.crouch_progress)
	assert_approx(decoded.prone_progress, src.prone_progress)
	assert_approx(decoded.peek_progress, src.peek_progress)


func test_default_state_roundtrip() -> void:
	var predictor: NetPredictor = _make_predictor()
	# Defaults: zero everywhere. Round-trip should still preserve types.
	var payload: PackedByteArray = predictor.snapshot_payload()
	var decoded: PlayerState = _decode(payload, predictor.state_field_names)
	assert_vec3_approx(decoded.pos, Vector3.ZERO)
	assert_vec3_approx(decoded.velocity, Vector3.ZERO)
	assert_eq(decoded.look, Vector2.ZERO)
	assert_eq(decoded.movement_state, 0)


func test_decode_payload_into_mutates_in_place() -> void:
	# Phase 6b.2: handle_net_state_packet uses decode_payload_into to populate
	# the predictor's own shadow_state. Verify it overwrites in place rather
	# than allocating a new Resource.
	var src_predictor: NetPredictor = _make_predictor()
	var src: PlayerState = src_predictor.shadow_state
	src.pos = Vector3(7.0, 8.0, 9.0)
	src.velocity = Vector3(-1.0, 2.0, -3.0)
	src.movement_state = 5

	var dst_predictor: NetPredictor = _make_predictor()
	var dst_ref: PlayerState = dst_predictor.shadow_state
	var payload: PackedByteArray = src_predictor.snapshot_payload()
	dst_predictor.decode_payload_into(dst_ref, payload)

	# Same Resource instance, mutated.
	assert_true(dst_ref == dst_predictor.shadow_state, "expected in-place mutation")
	assert_vec3_approx(dst_ref.pos, src.pos)
	assert_vec3_approx(dst_ref.velocity, src.velocity)
	assert_eq(dst_ref.movement_state, src.movement_state)


func test_delta_only_carries_changed_fields() -> void:
	# Phase 6b.3: first snapshot is a keyframe; second is a delta against the
	# baseline. The delta must omit unchanged fields (smaller payload) and
	# decoding into a fresh state mutates only the dirty ones.
	var sender: NetPredictor = _make_predictor()
	var src: PlayerState = sender.shadow_state
	src.pos = Vector3(1.0, 2.0, 3.0)
	src.velocity = Vector3(4.0, 5.0, 6.0)
	src.movement_state = 2

	# Keyframe.
	var keyframe_payload: PackedByteArray = sender.snapshot_payload()
	sender._last_broadcasted_state = src.duplicate()
	sender._ticks_since_keyframe = 1

	# Only change movement_state. velocity / pos / etc. should be omitted.
	src.movement_state = 4
	var delta_payload: PackedByteArray = sender.snapshot_payload()

	# Delta should be strictly smaller than the full keyframe.
	assert_true(delta_payload.size() < keyframe_payload.size(),
			"delta (%d) not smaller than keyframe (%d)" % [delta_payload.size(), keyframe_payload.size()])

	# Apply keyframe then delta to a fresh receiver and confirm result.
	var receiver: NetPredictor = _make_predictor()
	receiver.decode_payload_into(receiver.shadow_state, keyframe_payload)
	receiver.decode_payload_into(receiver.shadow_state, delta_payload)
	var dst: PlayerState = receiver.shadow_state
	assert_eq(dst.movement_state, 4, "movement_state delta not applied")
	assert_vec3_approx(dst.pos, Vector3(1.0, 2.0, 3.0), 0.0001, "pos clobbered")
	assert_vec3_approx(dst.velocity, Vector3(4.0, 5.0, 6.0), 0.0001, "velocity clobbered")


func test_keyframe_interval_forces_full_snapshot() -> void:
	# After KEYFRAME_INTERVAL ticks the encoder must emit a keyframe again so
	# clients that missed a delta can resync.
	var sender: NetPredictor = _make_predictor()
	sender.shadow_state.pos = Vector3(10.0, 0.0, 0.0)
	var first: PackedByteArray = sender.snapshot_payload()
	assert_eq(first[0], 1, "first packet should be keyframe")

	# Simulate broadcasting: stash baseline + advance tick counter.
	sender._last_broadcasted_state = sender.shadow_state.duplicate()
	sender._ticks_since_keyframe = NetPredictor.KEYFRAME_INTERVAL

	# Even with shadow_state unchanged, the interval should trigger a keyframe.
	var forced: PackedByteArray = sender.snapshot_payload()
	assert_eq(forced[0], 1, "expected keyframe at interval boundary")


func test_handle_net_state_packet_updates_predictor_state() -> void:
	# End-to-end: build a NetStatePacket from a source predictor's snapshot
	# and hand it to a destination predictor. shadow_state, last_received_tick,
	# and last_input_seq must all reflect the packet.
	var src_predictor: NetPredictor = _make_predictor()
	var src: PlayerState = src_predictor.shadow_state
	src.pos = Vector3(1.0, 2.0, 3.0)
	src.look = Vector2(0.1, 0.2)
	src.movement_state = 2

	var packet := NetStatePacket.new()
	packet.schema_id = src_predictor.schema.id
	packet.entity_id = 42
	packet.last_input_seq = 1337
	packet.baseline_tick = 0
	packet.new_tick = 9999
	packet.payload = src_predictor.snapshot_payload()

	var dst_predictor: NetPredictor = _make_predictor()
	dst_predictor.handle_net_state_packet(packet)

	assert_eq(dst_predictor.last_received_tick, 9999)
	assert_eq(dst_predictor.last_input_seq, 1337)
	assert_vec3_approx((dst_predictor.shadow_state as PlayerState).pos, src.pos)
	assert_eq((dst_predictor.shadow_state as PlayerState).movement_state, 2)


# Helper: build a NetPredictor without registering against the NetReplication
# autoload (we don't want test side-effects). Allocates shadow_state via the
# schema's state_template and populates state_field_names.
func test_child_ref_round_trip() -> void:
	# Phase 8a: schema.child_refs lets the predictor sync arbitrary properties
	# on sibling nodes alongside shadow_state. Bypass _resolve_children() by
	# poking _resolved_children directly so the test doesn't need a SceneTree.
	var src_probe := Node3D.new()
	src_probe.position = Vector3(7.0, 8.0, 9.0)

	var sender: NetPredictor = _make_predictor()
	var payload_without_child: PackedByteArray = sender.snapshot_payload()
	sender._resolved_children.append([src_probe, PackedStringArray(["position"])])
	var payload_with_child: PackedByteArray = sender.snapshot_payload()
	assert_true(payload_with_child.size() > payload_without_child.size(),
			"child field should add bytes; without=%d with=%d" % [payload_without_child.size(), payload_with_child.size()])

	var dst_probe := Node3D.new()
	var receiver: NetPredictor = _make_predictor()
	receiver._resolved_children.append([dst_probe, PackedStringArray(["position"])])

	receiver.decode_payload_into(receiver.shadow_state, payload_with_child)

	assert_vec3_approx(dst_probe.position, Vector3(7.0, 8.0, 9.0))

	src_probe.free()
	dst_probe.free()


func test_delta_omits_unchanged_child_fields() -> void:
	# Phase 8c: child-ref fields share the dirty mask with state_fields. When a
	# child property matches the prior broadcast, it should cost only a mask bit
	# (no put_var write).
	var probe := Node3D.new()
	probe.position = Vector3(1.0, 2.0, 3.0)

	var sender: NetPredictor = _make_predictor()
	sender._resolved_children.append([probe, PackedStringArray(["position"])])
	sender._last_child_values.append({})

	# First call: keyframe, sets up baselines for both state + child.
	var keyframe_payload: PackedByteArray = sender.snapshot_payload()
	sender._last_broadcasted_state = sender.shadow_state.duplicate()
	sender._ticks_since_keyframe = 1
	sender._last_child_values[0]["position"] = probe.position

	# Unchanged state + unchanged child: delta is mask-only.
	var unchanged_delta: PackedByteArray = sender.snapshot_payload()

	# Now mutate the child only. Delta should grow vs unchanged but stay under
	# the keyframe size.
	probe.position = Vector3(7.0, 8.0, 9.0)
	var changed_child_delta: PackedByteArray = sender.snapshot_payload()
	assert_true(changed_child_delta.size() > unchanged_delta.size(),
			"child change should grow delta (unchanged=%d changed=%d)" % [unchanged_delta.size(), changed_child_delta.size()])
	assert_true(changed_child_delta.size() < keyframe_payload.size(),
			"child-only delta should still be smaller than keyframe (delta=%d kf=%d)" % [changed_child_delta.size(), keyframe_payload.size()])

	# End-to-end apply: keyframe -> unchanged delta -> changed delta.
	var receiver_probe := Node3D.new()
	var receiver: NetPredictor = _make_predictor()
	receiver._resolved_children.append([receiver_probe, PackedStringArray(["position"])])
	receiver._last_child_values.append({})
	receiver.decode_payload_into(receiver.shadow_state, keyframe_payload)
	receiver.decode_payload_into(receiver.shadow_state, unchanged_delta)
	assert_vec3_approx(receiver_probe.position, Vector3(1.0, 2.0, 3.0), 0.0001, "unchanged delta clobbered child")
	receiver.decode_payload_into(receiver.shadow_state, changed_child_delta)
	assert_vec3_approx(receiver_probe.position, Vector3(7.0, 8.0, 9.0), 0.0001, "child delta failed to apply")

	probe.free()
	receiver_probe.free()


func _make_predictor() -> NetPredictor:
	var p := NetPredictor.new()
	p.schema = load("res://entities/player/player_schema.tres") as NetSchema
	# Trigger the part of _ready that allocates shadow_state + names. Calling
	# add_child would register with NetReplication, which we want to avoid.
	p.shadow_state = p.state_template.duplicate(true) as NetState
	p.render_state = p.state_template.duplicate(true) as NetState
	p.state_field_names = NetPredictor._user_field_names(p.shadow_state)
	return p


func _decode(payload: PackedByteArray, field_names: PackedStringArray) -> PlayerState:
	# First byte is the keyframe flag; we only invoke this helper on payloads
	# we know are keyframes (no baseline established), so always-1 is asserted
	# implicitly. After the byte, fields follow in order as Variants.
	var sp := StreamPeerBuffer.new()
	sp.data_array = payload
	var _is_keyframe := sp.get_u8()
	var out := PlayerState.new()
	for fname in field_names:
		out.set(fname, sp.get_var())
	return out
