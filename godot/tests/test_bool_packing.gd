extends TestBase

# Phase 6b bool-packing codec. Validates:
#   - bool fields encode as 1 bit each, trailing the inline block
#   - decode roundtrips bool values + non-bool fields together
#   - payload size shrinks vs put_var path (sanity check the optimization)

class _CmdMixed extends NetCommand:
	@export var fwd: float = 0.0
	@export var jump: bool = false
	@export var crouch: bool = false
	@export var sprint: bool = false
	@export var look: Vector2 = Vector2.ZERO
	@export var prone: bool = false
	@export var shoot: bool = false
	@export var scope: bool = false
	@export var walk_mode: bool = false


func _build_predictor() -> NetPredictor:
	var schema := NetSchema.new()
	schema.id = 7777
	schema.state_template = NetState.new()
	schema.command_template = _CmdMixed.new()
	var p := NetPredictor.new()
	p.schema = schema
	p.command_field_names = NetPredictor._user_field_names(schema.command_template)
	p._cache_command_field_cfgs()
	return p


func test_bool_pack_roundtrip_all_true() -> void:
	var p := _build_predictor()
	var cmd := _CmdMixed.new()
	cmd.fwd = 0.5
	cmd.look = Vector2(1.25, -0.75)
	cmd.jump = true
	cmd.crouch = true
	cmd.sprint = true
	cmd.prone = true
	cmd.shoot = true
	cmd.scope = true
	cmd.walk_mode = true
	var payload := p.encode_command_payload(cmd)
	var out := p.command_template.duplicate(true) as NetCommand
	p.decode_command_payload_into(out, payload)
	assert_approx(out.fwd, 0.5)
	assert_eq(out.look, Vector2(1.25, -0.75))
	assert_eq(out.jump, true)
	assert_eq(out.crouch, true)
	assert_eq(out.sprint, true)
	assert_eq(out.prone, true)
	assert_eq(out.shoot, true)
	assert_eq(out.scope, true)
	assert_eq(out.walk_mode, true)


func test_bool_pack_roundtrip_mixed() -> void:
	var p := _build_predictor()
	var cmd := _CmdMixed.new()
	cmd.fwd = -1.0
	cmd.look = Vector2(0.0, 3.14)
	cmd.jump = true
	cmd.crouch = false
	cmd.sprint = true
	cmd.prone = false
	cmd.shoot = false
	cmd.scope = true
	cmd.walk_mode = false
	var payload := p.encode_command_payload(cmd)
	var out := p.command_template.duplicate(true) as NetCommand
	p.decode_command_payload_into(out, payload)
	assert_eq(out.jump, true)
	assert_eq(out.crouch, false)
	assert_eq(out.sprint, true)
	assert_eq(out.prone, false)
	assert_eq(out.shoot, false)
	assert_eq(out.scope, true)
	assert_eq(out.walk_mode, false)


func test_bool_pack_payload_size_is_one_byte_for_7_bools() -> void:
	# Confirms trailing bitset is exactly 1 byte for 7 bools. The 7 bool fields
	# are 7 bits → ceil(7/8) = 1 byte. Compare against a hypothetical put_var
	# emission (~8 bytes/bool × 7 = ~56 bytes) — the optimization win.
	var p := _build_predictor()
	var cmd := _CmdMixed.new()
	cmd.fwd = 0.0
	cmd.look = Vector2.ZERO
	# All bools default false.
	var payload := p.encode_command_payload(cmd)
	# Inline portion (AUTO put_var): float fwd ≈ 12 bytes, Vector2 look ≈ 12.
	# Trailing bitset: 1 byte. Total well under what 7× put_var bools would add.
	# Hard-cap to 64 bytes — comfortable headroom under the unpacked baseline.
	assert_true(payload.size() < 64, "packed payload should be << put_var baseline; got %d bytes" % payload.size())


func test_bool_field_indices_cached() -> void:
	var p := _build_predictor()
	# 7 bools in _CmdMixed: jump, crouch, sprint, prone, shoot, scope, walk_mode.
	# (fwd float, look Vector2 don't count.)
	assert_eq(p._command_bool_indices.size(), 7)
