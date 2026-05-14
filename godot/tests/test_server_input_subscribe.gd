extends TestBase

# NetPredictor auto-subscribes to NetServer.handle_player_input when it has a
# command_template set, on the server only. Each predictor filters incoming
# packets by peer_id == owner_id and enqueues them. Replaces per-entity
# boilerplate that previously lived in each controller's _enter_tree.


class _IpkSim:
	# Stand-in for PlayerInputPacket. Carries the three fields the predictor
	# reads to enqueue into server_input_queue.
	var sequence_id: int = 0
	var timestamp_us: int = 0


func _make_predictor(owner_id: int) -> NetPredictor:
	var schema := NetSchema.new()
	schema.id = 9100
	schema.state_template = NetState.new()
	schema.command_template = NetCommand.new()
	var p := NetPredictor.new()
	p.schema = schema
	p.owner_id = owner_id
	p.shadow_state = schema.state_template.duplicate(true) as NetState
	p.render_state = schema.state_template.duplicate(true) as NetState
	p.state_field_names = PackedStringArray()
	return p


func test_input_for_owner_enqueues() -> void:
	var p := _make_predictor(42)
	var pkt := _IpkSim.new()
	pkt.sequence_id = 7
	pkt.timestamp_us = 12345
	p._on_server_player_input(42, pkt)
	# JitterBuffer doesn't expose a per-packet getter without advancing the
	# sequence; size() is the cheap reachable signal that an enqueue landed.
	assert_eq(p.server_input_queue.size(), 1, "owner's packet should land in the queue")


func test_input_for_other_peer_is_dropped() -> void:
	# Predictor owned by peer 42 receives a packet from peer 99 — it must
	# drop the packet rather than enqueue another peer's inputs against this
	# entity's input ring.
	var p := _make_predictor(42)
	var pkt := _IpkSim.new()
	pkt.sequence_id = 3
	p._on_server_player_input(99, pkt)
	assert_eq(p.server_input_queue.size(), 0, "non-owner packet must be dropped")


func test_owner_id_minus_one_drops_unowned_packets() -> void:
	# Default owner_id = -1 (e.g. an entity that hasn't been claimed yet)
	# should reject everything so an unclaimed entity doesn't pick up stray
	# inputs from real peers.
	var p := _make_predictor(-1)
	var pkt := _IpkSim.new()
	p._on_server_player_input(0, pkt)
	p._on_server_player_input(7, pkt)
	assert_eq(p.server_input_queue.size(), 0)
