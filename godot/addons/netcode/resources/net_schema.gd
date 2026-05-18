@tool
class_name NetSchema extends Resource

# Inspector-authored config for a NetPredictor (or NetReliable in later
# phases). Carries the state + command templates, the tick + snapshot rates,
# per-field codec metadata, and the reconcile channels.


# Phase 6.1: explicit lifecycle classifier. Replaces the previous implicit
# command_template-null gate. Three roles:
#   PREDICTED   — client-driven input + server reconcile. Players, vehicles.
#                 Requires command_template; runs _authority_tick / _server_tick
#                 / _proxy_tick branches; SMOOTHED_OFFSET corrections legal.
#   REPLICATED  — server-state-only. AI, grenades, doors, world props. No
#                 inputs; server calls host._capture_state each gated tick;
#                 clients only run _proxy_tick. SMOOTHED_OFFSET illegal.
#   LOCAL_ONLY  — cosmetic / pure-client. Particles, predicted UI. Framework
#                 skips network branches entirely; predictor exists for state
#                 lifecycle + host hook plumbing only.
enum Archetype { PREDICTED, REPLICATED, LOCAL_ONLY }


func _init() -> void:
	# Editor-time wiring. Two pieces:
	# 1) `changed` -> _editor_revalidate so any emit_changed (from per-property
	#    setters, from state_fields_editor_property._commit, from bubbled
	#    correction edits) drives the project-wide validation revalidate.
	# 2) Resubscribe to corrections' `changed` signals once Godot has finished
	#    deserializing the array. Defer to next frame because @export var
	#    assignment happens after _init.
	if Engine.is_editor_hint():
		if not changed.is_connected(_editor_revalidate):
			changed.connect(_editor_revalidate)
		_resubscribe_corrections.call_deferred()


# Inspector edits inside inline sub-resources (NetCorrection.fields, etc.)
# don't reach the parent inspector's property_edited signal. Each NetCorrection
# fires its own `changed` from its per-property setters; this method wires
# every correction's `changed` to our `emit_changed` so the schema sees inner
# edits and the usual revalidate/triangle-refresh listeners fire. Called from
# _init (deferred — array isn't populated until after _init) and from the
# `corrections` setter on every array mutation.
func _resubscribe_corrections() -> void:
	if not Engine.is_editor_hint():
		return
	for c in corrections:
		if c == null:
			continue
		if not c.changed.is_connected(emit_changed):
			c.changed.connect(emit_changed)


# Godot's engine writes @export vars directly to the script var — _set is only
# invoked for *dynamic* (unknown-to-the-class) properties, so we can't catch
# inspector writes via _set. Each @export var below has an explicit setter that
# calls _schedule_emit_changed. The schedule coalesces multiple setter fires in
# the same frame (e.g. .tres deserialization writes each property in sequence)
# into one emit_changed on the next idle frame — so listeners (validation
# revalidate, open-script button refresh, etc.) fire once per logical change.
# Note: Godot's node warning triangle (NetPredictor's red icon) only refreshes
# on save in Godot 4.6; we don't fight that — push_error to Output is the
# live feedback channel.
var _emit_scheduled: bool = false


func _schedule_emit_changed() -> void:
	if not Engine.is_editor_hint() or _emit_scheduled:
		return
	_emit_scheduled = true
	_do_deferred_emit_changed.call_deferred()


func _do_deferred_emit_changed() -> void:
	_emit_scheduled = false
	emit_changed()


func _editor_revalidate() -> void:
	if not Engine.is_editor_hint():
		return
	# Coalesce. emit_changed fires per-character during inspector text edits;
	# walking every .tres per keystroke is wasted CPU. Defer via a static flag
	# so all changes in the same frame collapse to one revalidate pass. Use an
	# instance method via Callable for the deferral — static-method Callables
	# don't reliably fire under call_deferred in Godot 4.x.
	if NetSchema._revalidate_scheduled:
		return
	NetSchema._revalidate_scheduled = true
	_do_deferred_revalidate.call_deferred()


func _do_deferred_revalidate() -> void:
	NetSchema._revalidate_scheduled = false
	NetSchema.refresh_id_cache()


# Godot's stock revert arrow on the property header would otherwise reset
# state_fields to {} (the @export default). Empty leaves the schema invalid
# until the user re-syncs. Override so revert resets each row to per-field
# NetStateField defaults instead — same outcome as the (now-retired) "Reset
# state_fields config to defaults" button, but driven by Godot's standard UX.
func _property_can_revert(property: StringName) -> bool:
	if property == &"state_fields":
		return state_template != null
	if property == &"command_fields":
		return command_template != null
	return false


func _property_get_revert(property: StringName) -> Variant:
	var defaults: Dictionary[StringName, NetStateField] = {}
	var tmpl: Resource = null
	if property == &"state_fields":
		tmpl = state_template
	elif property == &"command_fields":
		tmpl = command_template
	else:
		return null
	if tmpl == null:
		return defaults
	for fname in _user_field_names(tmpl):
		defaults[fname] = NetStateField.new()
	return defaults


static var _revalidate_scheduled: bool = false


## Globally unique id used on the wire. NetStatePacket carries schema_id +
## entity_id; receivers look up the NetSchema by id to decode payload bytes.
## Must match between server and client (and across all schemas a peer holds).
@export var id: int = 0:
	set(v):
		id = v
		_schedule_emit_changed()

## Default-valued instance of the NetState subclass for this entity. Framework
## clones via duplicate(true) when allocating shadow_state / render_state.
## Expand inline to see + edit per-schema starting values for the @export
## fields declared on the script (pos, velocity, etc.). Mismatches between
## this template's fields and state_fields[] fire a drift warning.
@export var state_template: NetState:
	set(v):
		state_template = v
		_schedule_emit_changed()
## Lifecycle role for this entity. PREDICTED (default) for player-style
## input-driven entities, REPLICATED for server-state-only entities (no inputs
## — host implements `_capture_state`), LOCAL_ONLY for pure-client cosmetic
## predictors. See Archetype enum docs above for the per-role behavior.
@export var archetype: Archetype = Archetype.PREDICTED:
	set(v):
		archetype = v
		_schedule_emit_changed()

## Default-valued instance of the NetCommand subclass (input packet). Cloned
## by NetPredictor on each tick; defaults seed unused fields. Leave unset
## for REPLICATED / LOCAL_ONLY schemas (server pushes state directly).
@export var command_template: NetCommand:
	set(v):
		command_template = v
		_schedule_emit_changed()

## Per-entity simulation + wire rate (Hz). Server-side hosts gate their
## _physics_process at (project_physics_hz / tick_hz) so high-frequency
## entities (players, vehicles) and low-frequency ones (props, projectiles,
## ambient world objects) can coexist without all paying the player rate.
## The wire rate equals this — each gated tick produces one snapshot.
@export var tick_hz: int = 120:
	set(v):
		tick_hz = v
		_schedule_emit_changed()
## Historical: explicit server broadcast rate. Now redundant — entities
## broadcast once per gated tick, so the on-wire rate equals tick_hz. Field
## kept (and still hashed) for pinned-hash backwards compatibility; remove on
## the next breaking-change pass. Don't read for behavior, use tick_hz.
@export var snapshot_hz: int = 30:
	set(v):
		snapshot_hz = v
		_schedule_emit_changed()

## Per-field proxy interpolation declarations (LERP / SLERP / DISCRETE /
## HERMITE / PREDICTED). When non-empty, NetPredictor pre-blends snapshots
## and the host's _proxy_apply receives a single blended state instead of
## raw (from, to, alpha). Leave empty to keep the host-driven signature
## (current behavior — used by the player which has bespoke proxy logic).
@export var field_interp: Dictionary[StringName, NetFieldInterp] = {}:
	set(v):
		field_interp = v
		_schedule_emit_changed()

## Multiplier on the proxy ring buffer's auto-tuned inter-sample delay.
## 1.0 = render one segment behind (default). 0.5 = tighter, more
## extrapolation. 2.0 = safer under jitter at the cost of perceived lag.
## Replaces the dead NetTimeline.interp_window_ratio.
@export var buffer_segments: float = 1.0:
	set(v):
		buffer_segments = maxf(v, 0.0)
		_schedule_emit_changed()

## Per-field codec config keyed by field name. One entry per @export var on
## state_template — the key explicitly binds config to a script field so
## drift is visible at a glance. Drives wire encoding (quant), reconcile
## (predict), and proxy interpolation (no_interp). Use the "Generate
## state_fields from state_template" button in the inspector to populate
## from the script.
@export var state_fields: Dictionary[StringName, NetStateField] = {}:
	set(v):
		state_fields = v
		_schedule_emit_changed()
## Per-field codec config for command_template fields. Mirrors state_fields.
## Quant.AUTO falls back to put_var on the wire (safe default for bool/int).
## Use QUANT8/QUANT16 on float-typed cmd fields when range is known.
@export var command_fields: Dictionary[StringName, NetStateField] = {}:
	set(v):
		command_fields = v
		_schedule_emit_changed()
## Reconcile channels — groups of state fields that share an error magnitude
## and smoothing behavior (e.g. "horizontal" snaps + smooths pos.xz together).
## Order doesn't affect the wire; the framework iterates them in declaration
## order each tick.
@export var corrections: Array[NetCorrection] = []:
	set(v):
		corrections = v
		# Array reassignment (add/remove element) — (re-)subscribe to each
		# correction's `changed` so future inner edits bubble back to us.
		_resubscribe_corrections.call_deferred()
		_schedule_emit_changed()

## Additional nodes whose @export-able properties replicate alongside the main
## state_fields. Encoded after the state_fields block on the wire. Useful for
## syncing animation tree parameters, collision shapes, etc. without inlining
## them into the NetState class.
@export var child_refs: Array[NetChildRef] = []:
	set(v):
		child_refs = v
		_schedule_emit_changed()


func find_correction(correction_name: StringName) -> NetCorrection:
	for c in corrections:
		if c.name == correction_name:
			return c
	return null


func find_state_field(field_name: StringName) -> NetStateField:
	return state_fields.get(field_name)


func find_command_field(field_name: StringName) -> NetStateField:
	return command_fields.get(field_name)


# Returns a list of structured issues with this schema (empty when valid).
# Hosts use this at two times:
#   - editor: NetPredictor._get_configuration_warnings() surfaces these as
#     the red triangle in the scene tree (filtered to WARNING+).
#   - startup: NetReplication.register_schema logs ERROR as push_error and
#     WARNING as push_warning.
# Sub-validators are split per concern so adding a rule is mechanical; each
# returns its own batch and validate() concatenates.
func validate() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	issues.append_array(_validate_id())
	issues.append_array(_validate_id_uniqueness())
	issues.append_array(_validate_template())
	if state_template == null:
		# Bail before the rest — every other validator dereferences state_template.
		return issues
	issues.append_array(_validate_state_fields_drift())
	issues.append_array(_validate_quant_compatibility())
	issues.append_array(_validate_quant_ranges())
	issues.append_array(_validate_correction_field_paths())
	issues.append_array(_validate_correction_contradictions())
	issues.append_array(_validate_correction_modes())
	issues.append_array(_validate_archetype())
	return issues


# Legacy adapter for callers that want flat strings (NetPredictor configuration
# warnings, NetReplication startup logs). Filters by minimum severity.
func validate_strings(min_severity: ValidationIssue.Severity = ValidationIssue.Severity.WARNING) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for issue in validate():
		if issue.severity <= min_severity:  # enum order: ERROR=0 < WARNING=1 < INFO=2
			out.append(issue.to_string_line())
	return out


func _validate_id() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if id == 0:
		issues.append(ValidationIssue.make(
				ValidationIssue.Severity.ERROR,
				&"id_unset",
				"id",
				"id is 0 — assign a unique nonzero int. NetStatePacket routes by schema_id; collisions corrupt state across schemas."))
	return issues


# Project-wide id uniqueness. Editor-only — runtime register_schema does its
# own hash-pinning per id. The cache is populated by the netcode plugin's
# filesystem_changed hook (see netcode.gd); refresh_id_cache() walks every
# script_class=NetSchema .tres in the project and groups by id.
func _validate_id_uniqueness() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if not Engine.is_editor_hint():
		return issues
	if id == 0:
		# Already covered by _validate_id; skip to avoid grouping multiple
		# unset-id schemas as collisions with each other.
		return issues
	if _id_paths_cache.is_empty():
		refresh_id_cache()
	var paths: PackedStringArray = _id_paths_cache.get(id, PackedStringArray())
	if paths.size() <= 1:
		return issues
	# Filter our own path out so we don't accuse ourselves.
	var my_path: String = resource_path
	var others: PackedStringArray = PackedStringArray()
	for p in paths:
		if p != my_path:
			others.append(p)
	if others.is_empty():
		return issues
	issues.append(ValidationIssue.make(
			ValidationIssue.Severity.ERROR,
			&"id_collision",
			"id",
			"id %d is also claimed by: %s. Schema ids must be globally unique — receivers route NetStatePacket by schema_id."
					% [id, ", ".join(others)]))
	return issues


func _validate_template() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if state_template == null:
		issues.append(ValidationIssue.make(
				ValidationIssue.Severity.ERROR,
				&"template_unset",
				"state_template",
				"state_template is unset; predictor cannot allocate shadow_state."))
	return issues


func _validate_state_fields_drift() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	var script_fields: PackedStringArray = _user_field_names(state_template)
	# Fields declared on the script but missing from state_fields. Fall back
	# to Quant.AUTO on the wire — custom inspector auto-syncs on view.
	for f in script_fields:
		if not state_fields.has(f):
			issues.append(ValidationIssue.make(
					ValidationIssue.Severity.WARNING,
					&"missing_state_field",
					"state_fields[%s]" % f,
					"missing entry for '%s' — defaults to Quant.AUTO. Open schema in inspector to auto-sync, then save." % f))
	# Orphans: entries whose key doesn't exist on the script.
	for k in state_fields.keys():
		if not script_fields.has(k):
			issues.append(ValidationIssue.make(
					ValidationIssue.Severity.WARNING,
					&"orphan_state_field",
					"state_fields[%s]" % str(k),
					"entry '%s' has no matching @export var on state_template (orphan from rename or deletion)." % str(k)))
	return issues


func _validate_quant_compatibility() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	for fname in state_fields.keys():
		var cfg: NetStateField = state_fields[fname]
		if cfg == null:
			continue
		var probe_value = state_template.get(fname)
		if probe_value == null:
			# Field not on template — orphan, already flagged by drift validator.
			continue
		var t: int = typeof(probe_value)
		if not _quant_compatible(cfg.quant, t):
			issues.append(ValidationIssue.make(
					ValidationIssue.Severity.ERROR,
					&"quant_type_mismatch",
					"state_fields[%s].quant" % str(fname),
					"Quant.%s is not valid for field type %s. Encoding will fall back to put_var with a runtime push_warning."
							% [_quant_name(cfg.quant), _type_label(t)]))
	return issues


func _validate_quant_ranges() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	for fname in state_fields.keys():
		var cfg: NetStateField = state_fields[fname]
		if cfg == null:
			continue
		if cfg.quant != NetStateField.Quant.QUANT8 and cfg.quant != NetStateField.Quant.QUANT16:
			continue
		if cfg.min_value > cfg.max_value:
			issues.append(ValidationIssue.make(
					ValidationIssue.Severity.ERROR,
					&"quant_range_inverted",
					"state_fields[%s]" % str(fname),
					"min_value (%f) > max_value (%f); encoding will clamp all values to min." % [cfg.min_value, cfg.max_value]))
		elif cfg.min_value == cfg.max_value:
			issues.append(ValidationIssue.make(
					ValidationIssue.Severity.WARNING,
					&"quant_range_zero",
					"state_fields[%s]" % str(fname),
					"min_value == max_value (%f); QUANT8/QUANT16 codec emits the lo value for every input. Use FLOAT32 or AUTO if range is unknown." % cfg.min_value))
	return issues


func _validate_correction_field_paths() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	var script_fields: PackedStringArray = _user_field_names(state_template)
	for c in corrections:
		if c == null:
			continue
		for fi in c.fields.size():
			var path: String = c.fields[fi]
			var loc: String = "corrections[%s].fields[%d]" % [str(c.name), fi]
			if path == "":
				issues.append(ValidationIssue.make(
						ValidationIssue.Severity.ERROR,
						&"correction_path_empty",
						loc,
						"Empty field path."))
				continue
			var parsed := _split_field_path(path)
			var fname: String = parsed.field
			var axes: String = parsed.axes
			if not script_fields.has(fname):
				issues.append(ValidationIssue.make(
						ValidationIssue.Severity.ERROR,
						&"correction_missing_field",
						loc,
						"References field '%s' which is not declared on state_template — correction is silently inert at runtime." % fname))
				continue
			if axes != "":
				var probe_value = state_template.get(fname)
				var valid_axes := _axes_for_type(typeof(probe_value))
				if valid_axes == "":
					issues.append(ValidationIssue.make(
							ValidationIssue.Severity.ERROR,
							&"correction_axis_on_scalar",
							loc,
							"Field '%s' is scalar type %s; axis suffix '.%s' is invalid (drop the suffix)."
									% [fname, _type_label(typeof(probe_value)), axes]))
				else:
					for ch in axes:
						# `not in` is a single GDScript operator — unambiguous
						# vs `not ch in valid_axes` (which the parser is fine
						# with but reads two ways to a human).
						if ch not in valid_axes:
							issues.append(ValidationIssue.make(
									ValidationIssue.Severity.ERROR,
									&"correction_invalid_axis",
									loc,
									"Axis '%s' is invalid for field '%s' (type %s; valid axes: '%s')."
											% [ch, fname, _type_label(typeof(probe_value)), valid_axes]))
							break
	return issues


func _validate_correction_contradictions() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	for c in corrections:
		if c == null:
			continue
		if c.always_snap and c.always_smooth:
			issues.append(ValidationIssue.make(
					ValidationIssue.Severity.ERROR,
					&"correction_contradiction",
					"corrections[%s]" % str(c.name),
					"always_snap and always_smooth are both true; pick one. Runtime will see always_snap win silently."))
	return issues


# Phase 4: SMOOTHED_OFFSET mode has strict structural requirements (only valid
# on predicted entities, only on the 'pos' field for now). RENDER_LERP is the
# default and has no extra rules. Flagged as ERROR because a misconfigured
# SMOOTHED_OFFSET channel silently bypasses the corrections pass at runtime.
func _validate_correction_modes() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	for c in corrections:
		if c == null or c.mode != NetCorrection.Mode.SMOOTHED_OFFSET:
			continue
		var loc: String = "corrections[%s]" % str(c.name)
		if archetype != Archetype.PREDICTED:
			issues.append(ValidationIssue.make(
					ValidationIssue.Severity.ERROR,
					&"correction_mode_requires_predicted",
					loc,
					"mode = SMOOTHED_OFFSET is only valid on PREDICTED schemas (input-driven entities with command_template). Set archetype = PREDICTED or switch the channel to RENDER_LERP."))
		for fi in c.fields.size():
			var path: String = c.fields[fi]
			if path == "":
				continue
			var parsed := _split_field_path(path)
			var fname: String = parsed.field
			# Phase 4 scope: only 'pos' is offset-able. Extend this set when
			# generalizing to velocity / rotation (see netcode-synchronizer.md §10).
			if fname != "pos":
				issues.append(ValidationIssue.make(
						ValidationIssue.Severity.ERROR,
						&"correction_mode_field_not_allowed",
						"%s.fields[%d]" % [loc, fi],
						"mode = SMOOTHED_OFFSET only supports field 'pos' (Phase 4 scope). Got '%s'. Split into a RENDER_LERP channel or wait for the generalization."
								% fname))
	return issues


# Phase 6.1: archetype ↔ template consistency. PREDICTED requires a
# command_template (codec + input fan-out need it); REPLICATED + LOCAL_ONLY
# must leave command_template null (stale template is dead config — the
# subscriber path skips it but the inspector hides what's actually used).
# Flagged as ERROR for PREDICTED-without-cmd (snapshot codec dies on entity
# spawn) and WARNING for REPLICATED-with-cmd (will be silently ignored).
func _validate_archetype() -> Array[ValidationIssue]:
	var issues: Array[ValidationIssue] = []
	if archetype == Archetype.PREDICTED and command_template == null:
		issues.append(ValidationIssue.make(
				ValidationIssue.Severity.ERROR,
				&"archetype_missing_command_template",
				"archetype",
				"archetype = PREDICTED requires a command_template. Either set one or change archetype to REPLICATED (server-state-only) / LOCAL_ONLY (no network)."))
	elif archetype != Archetype.PREDICTED and command_template != null:
		issues.append(ValidationIssue.make(
				ValidationIssue.Severity.WARNING,
				&"archetype_dead_command_template",
				"command_template",
				"command_template is set but archetype = %s ignores it. Clear command_template or change archetype to PREDICTED." % Archetype.keys()[archetype]))
	return issues


# ---- helpers ----

static func _split_field_path(path: String) -> Dictionary:
	var dot := path.find(".")
	if dot < 0:
		return {"field": path, "axes": ""}
	return {"field": path.substr(0, dot), "axes": path.substr(dot + 1)}


static func _axes_for_type(t: int) -> String:
	match t:
		TYPE_VECTOR2: return "xy"
		TYPE_VECTOR3: return "xyz"
		TYPE_VECTOR4, TYPE_QUATERNION: return "xyzw"
	return ""


static func _quant_compatible(q: NetStateField.Quant, t: int) -> bool:
	match q:
		NetStateField.Quant.AUTO:
			return true
		NetStateField.Quant.QUAT32:
			return t == TYPE_QUATERNION
		NetStateField.Quant.FLOAT32:
			return t in [TYPE_FLOAT, TYPE_INT, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4]
		NetStateField.Quant.QUANT8, NetStateField.Quant.QUANT16:
			return t in [TYPE_FLOAT, TYPE_INT, TYPE_VECTOR2, TYPE_VECTOR3, TYPE_VECTOR4]
	return true


static func _quant_name(q: NetStateField.Quant) -> String:
	match q:
		NetStateField.Quant.AUTO: return "AUTO"
		NetStateField.Quant.QUANT8: return "QUANT8"
		NetStateField.Quant.QUANT16: return "QUANT16"
		NetStateField.Quant.FLOAT32: return "FLOAT32"
		NetStateField.Quant.QUAT32: return "QUAT32"
	return "?"


static func _type_label(t: int) -> String:
	match t:
		TYPE_NIL: return "null"
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_VECTOR4: return "Vector4"
		TYPE_VECTOR4I: return "Vector4i"
		TYPE_QUATERNION: return "Quaternion"
		TYPE_COLOR: return "Color"
		TYPE_TRANSFORM2D: return "Transform2D"
		TYPE_TRANSFORM3D: return "Transform3D"
		TYPE_BASIS: return "Basis"
	return "type=%d" % t


# ---- Project-wide id collision scan (editor-only) ----
#
# Walks EditorFileSystem looking for every .tres file whose script_class is
# "NetSchema", loads each, and groups paths by their schema id. The result
# powers _validate_id_uniqueness so a duplicate id between two .tres files is
# flagged ahead of runtime — runtime can only see a collision if two schemas
# actually register, which is often too late.
#
# Refresh is triggered by netcode.gd on plugin enter_tree and on every
# EditorFileSystem.filesystem_changed signal; lazy-fills if the cache is empty
# when a validator asks for it.
static var _id_paths_cache: Dictionary = {}  # int -> PackedStringArray
# Per-path hash of the last set of validation issues we emitted to Output.
# Used by refresh_id_cache() to dedupe push_error/push_warning across the many
# filesystem_changed signals Godot fires that don't actually change a schema
# (focus changes, unrelated saves, etc).
static var _last_emitted_issue_hashes: Dictionary = {}  # String path -> int


static func refresh_id_cache() -> void:
	_id_paths_cache = {}
	if not Engine.is_editor_hint():
		return
	# Resolve EditorInterface dynamically: a bare reference fails to PARSE
	# in exported builds (the symbol doesn't exist outside the editor), even
	# though the runtime guard above prevents the line from ever executing.
	# Without this, exporting the dedicated server bricks the netcode addon.
	var fs = Engine.get_singleton("EditorInterface").get_resource_filesystem()
	if fs == null:
		return
	_scan_dir_for_schemas(fs.get_filesystem(), _id_paths_cache)
	# Push every schema's validation issues to Output, so a saved .tres with
	# (say) a bad correction axis surfaces in the Errors / Warnings panel
	# without needing to play the scene or hover the NetPredictor red triangle.
	# Dedupe via _last_emitted_issue_hashes so a no-op filesystem signal
	# doesn't re-emit the same lines.
	_emit_editor_validation()


static func _emit_editor_validation() -> void:
	var seen: Dictionary = {}
	for paths in _id_paths_cache.values():
		for path in paths:
			if seen.has(path):
				continue
			seen[path] = true
			var res = ResourceLoader.load(path, "Resource", ResourceLoader.CACHE_MODE_REUSE)
			if not res is NetSchema:
				continue
			var schema: NetSchema = res
			var issues: Array[ValidationIssue] = schema.validate()
			var content_hash: int = _hash_issue_list(issues)
			if _last_emitted_issue_hashes.get(path, -1) == content_hash:
				continue
			_last_emitted_issue_hashes[path] = content_hash
			for issue in issues:
				var line: String = "NetSchema %s [%s] %s: %s" % [
						path, issue.severity_name(), issue.location, issue.message]
				match issue.severity:
					ValidationIssue.Severity.ERROR:
						push_error(line)
					ValidationIssue.Severity.WARNING:
						push_warning(line)
					_:
						pass
	# Prune entries for paths that are no longer present (file deleted/renamed)
	# so a future re-add fires a fresh emit instead of a phantom dedupe hit.
	for path in _last_emitted_issue_hashes.keys():
		if not seen.has(path):
			_last_emitted_issue_hashes.erase(path)


static func _hash_issue_list(issues: Array[ValidationIssue]) -> int:
	var parts: PackedStringArray = PackedStringArray()
	for i in issues:
		parts.append("%d|%s|%s|%s" % [int(i.severity), str(i.category), i.location, i.message])
	return "\n".join(parts).hash()


static func _scan_dir_for_schemas(dir, out: Dictionary) -> void:
	if dir == null:
		return
	for i in dir.get_subdir_count():
		_scan_dir_for_schemas(dir.get_subdir(i), out)
	for i in dir.get_file_count():
		# Filter to .tres only — EditorFileSystem's get_file_script_class_name
		# is unreliable for typed Resource subclasses (returns "" for many
		# .tres files even when the binding is correct), so we can't pre-filter
		# by class name. Load + `is NetSchema` is robust; CACHE_MODE_REUSE
		# means already-loaded resources return the in-memory instance for
		# near-zero cost, and the per-file cost for fresh loads is bounded by
		# the project's typical .tres count.
		var path: String = dir.get_file_path(i)
		if not path.ends_with(".tres"):
			continue
		var res = ResourceLoader.load(path, "Resource", ResourceLoader.CACHE_MODE_REUSE)
		if not res is NetSchema:
			continue
		var schema: NetSchema = res
		var paths: PackedStringArray = out.get(schema.id, PackedStringArray())
		paths.append(path)
		out[schema.id] = paths


# Local copy of NetPredictor._user_field_names so NetSchema validation doesn't
# depend on the component. Walks @export properties on a NetState/NetCommand
# instance, excluding Resource base props.
const _RESOURCE_BASE_PROPS := [
	&"resource_local_to_scene",
	&"resource_path",
	&"resource_name",
	&"resource_scene_unique_id",
	&"script",
]

static func _user_field_names(probe: Resource) -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray()
	if probe == null:
		return names
	for prop in probe.get_property_list():
		if (prop.usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		if (prop.usage & PROPERTY_USAGE_CATEGORY) != 0:
			continue
		if (prop.usage & PROPERTY_USAGE_GROUP) != 0:
			continue
		if prop.name in _RESOURCE_BASE_PROPS:
			continue
		# Godot stores resource metadata under `metadata/<key>` props on every
		# Resource (e.g. `metadata/_custom_script_type` on a default-init NetState).
		# These are storage, not user fields — never participate in state_fields.
		if (prop.name as String).begins_with("metadata/"):
			continue
		names.append(prop.name)
	return names


# Sprint 7: deterministic content hash of the schema's wire-affecting bits.
# Two peers that agree on the hash agree on field order, quantization, and
# correction channels — so the wire codec produces identical bytes for
# identical inputs. Used by NetReplication.register_schema to detect drift
# between server + client builds (server with QUANT8 on pos.xz vs client
# still on AUTO is silent corruption otherwise).
#
# Layout: tag-prefixed lines flattened into a String, hashed via String.hash()
# which is stable across runs in Godot 4.x. Returns an int (32-bit). Add new
# tag prefixes when extending the schema instead of inserting into existing
# tags so previously-pinned hashes stay valid for unrelated changes.
func compute_hash() -> int:
	var parts: PackedStringArray = PackedStringArray()
	parts.append("id=%d" % id)
	# Hash on the *script* path of the template instance so two schemas pointing
	# at the same NetState subclass produce identical hashes even if their
	# inspector-edited default values differ. Defaults aren't wire-visible —
	# they only seed shadow_state, which is overwritten by snapshot data — so
	# they intentionally don't participate in the hash. Tag prefixes
	# "state_class=" / "command_class=" are kept (not renamed to "*_template=")
	# so pinned hashes from before the template refactor stay valid for
	# unrelated changes (see comment above re: tag stability).
	var state_script: Script = state_template.get_script() if state_template != null else null
	var command_script: Script = command_template.get_script() if command_template != null else null
	parts.append("state_class=%s" % (state_script.resource_path if state_script else ""))
	parts.append("command_class=%s" % (command_script.resource_path if command_script else ""))
	parts.append("tick_hz=%d" % tick_hz)
	parts.append("snapshot_hz=%d" % snapshot_hz)
	# Phase 6.1: archetype affects framework dispatch (server tick body,
	# proxy buffer behavior, input subscription). Hash mismatch surfaces
	# mis-tagged schemas across builds before they cause silent divergence.
	parts.append("archetype=%d" % int(archetype))
	# Walk fields in sorted key order so the hash is independent of dictionary
	# insertion order. The wire codec walks state_field_names (script
	# declaration order, also deterministic) but for hashing we just need
	# *some* deterministic order — sorted keys are simpler and don't depend
	# on having a live state_template to introspect.
	var sorted_field_names: Array = state_fields.keys()
	sorted_field_names.sort()
	for fname in sorted_field_names:
		var f: NetStateField = state_fields[fname]
		parts.append("field|%s|%d|%d|%d|%f|%f" % [
				str(fname),
				int(f.quant),
				int(f.predict),
				int(f.no_interp),
				f.min_value,
				f.max_value])
	# Command fields participate too: a server with QUANT8 vs client with AUTO
	# on the same cmd field decodes wrong bytes silently otherwise.
	var sorted_cmd_field_names: Array = command_fields.keys()
	sorted_cmd_field_names.sort()
	for fname in sorted_cmd_field_names:
		var f: NetStateField = command_fields[fname]
		parts.append("cmd_field|%s|%d|%f|%f" % [
				str(fname),
				int(f.quant),
				f.min_value,
				f.max_value])
	for c in corrections:
		parts.append("corr|%s|%s|%f|%f|%f|%d|%d" % [
				str(c.name),
				"|".join(c.fields),
				c.snap_threshold,
				c.smooth_rate,
				c.deadband,
				int(c.always_snap),
				int(c.always_smooth)])
	for cr in child_refs:
		parts.append("child|%s|%s|%s|%d" % [
				str(cr.name),
				str(cr.path),
				"|".join(cr.fields),
				int(cr.proxy_only)])
	return "\n".join(parts).hash()
