extends TestBase

# Sprint 2: NetChildRef.proxy_only gates the decoder's child-node writes. On
# the local authority (and on the server) the bytes are still consumed from
# the stream so the wire layout stays consistent, but the node.set() is
# suppressed — the host's locally-driven values aren't clobbered. On a remote
# proxy the writes happen normally.


func test_proxy_only_skips_writes_on_server() -> void:
	# NetSession.is_server is the only thing that flips the suppression path
	# in tests (NetClient.id is unset, so is_local_authority is false). Force
	# is_server = true to simulate the server peer.
	var was_server: bool = NetSession.is_server
	NetSession.is_server = true

	var src_probe := Node3D.new()
	src_probe.position = Vector3(1.0, 2.0, 3.0)
	var sender: NetPredictor = _make_predictor()
	# Sender doesn't suppress on encode; this works regardless of role.
	sender._resolved_children.append([src_probe, PackedStringArray(["position"]), _make_proxy_only_ref()])
	var payload: PackedByteArray = sender.snapshot_payload()

	# Receiver is on the same server peer; should NOT write to the node.
	var dst_probe := Node3D.new()
	dst_probe.position = Vector3(7.0, 8.0, 9.0)
	var receiver: NetPredictor = _make_predictor()
	receiver._resolved_children.append([dst_probe, PackedStringArray(["position"]), _make_proxy_only_ref()])
	receiver.decode_payload_into(receiver.shadow_state, payload)

	assert_vec3_approx(dst_probe.position, Vector3(7.0, 8.0, 9.0), 0.0001,
			"server peer should not have written the child field")

	NetSession.is_server = was_server
	src_probe.free()
	dst_probe.free()


func test_proxy_only_writes_on_proxy() -> void:
	# Same fixture, but the receiver is a proxy (NetSession.is_server = false,
	# is_local_authority = false). proxy_only should NOT suppress the write.
	var was_server: bool = NetSession.is_server
	NetSession.is_server = false

	var src_probe := Node3D.new()
	src_probe.position = Vector3(5.5, -2.0, 1.25)
	var sender: NetPredictor = _make_predictor()
	sender._resolved_children.append([src_probe, PackedStringArray(["position"]), _make_proxy_only_ref()])
	var payload: PackedByteArray = sender.snapshot_payload()

	var dst_probe := Node3D.new()
	dst_probe.position = Vector3.ZERO
	var receiver: NetPredictor = _make_predictor()
	# owner_id must differ from NetClient.id (default -1) so is_local_authority
	# stays false. Pick a value that no real peer would have.
	receiver.owner_id = 999
	receiver._resolved_children.append([dst_probe, PackedStringArray(["position"]), _make_proxy_only_ref()])
	receiver.decode_payload_into(receiver.shadow_state, payload)

	assert_vec3_approx(dst_probe.position, Vector3(5.5, -2.0, 1.25), 0.0001,
			"proxy peer should write the child field as normal")

	NetSession.is_server = was_server
	src_probe.free()
	dst_probe.free()


func test_proxy_only_false_writes_everywhere() -> void:
	# Legacy default: proxy_only = false means writes happen regardless of role.
	var was_server: bool = NetSession.is_server
	NetSession.is_server = true

	var src_probe := Node3D.new()
	src_probe.position = Vector3(11.0, 22.0, 33.0)
	var sender: NetPredictor = _make_predictor()
	var cref := NetChildRef.new()
	cref.proxy_only = false
	sender._resolved_children.append([src_probe, PackedStringArray(["position"]), cref])
	var payload: PackedByteArray = sender.snapshot_payload()

	var dst_probe := Node3D.new()
	var receiver: NetPredictor = _make_predictor()
	receiver._resolved_children.append([dst_probe, PackedStringArray(["position"]), cref])
	receiver.decode_payload_into(receiver.shadow_state, payload)
	assert_vec3_approx(dst_probe.position, Vector3(11.0, 22.0, 33.0), 0.0001,
			"proxy_only=false should still write on the server")

	NetSession.is_server = was_server
	src_probe.free()
	dst_probe.free()


func _make_predictor() -> NetPredictor:
	var p := NetPredictor.new()
	p.schema = PlayerSchema.build()
	p.shadow_state = p.state_class.new()
	p.render_state = p.state_class.new()
	p.state_field_names = NetPredictor._user_field_names(p.shadow_state)
	return p


func _make_proxy_only_ref() -> NetChildRef:
	var cref := NetChildRef.new()
	cref.name = &"probe"
	cref.proxy_only = true
	return cref
