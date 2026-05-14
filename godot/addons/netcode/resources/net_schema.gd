class_name NetSchema extends Resource

# Inspector-authored config for a NetPredictor (or NetReplicator/NetReliable
# in later phases). Carries the state + command class refs, the tick + snapshot
# rates, per-field codec metadata, and the reconcile channels.

# Globally unique id used on the wire. NetStatePacket carries schema_id +
# entity_id; the receiver looks up the NetSchema by id to know how to decode
# payload bytes.
@export var id: int = 0

@export var state_class: Script
@export var command_class: Script

@export var tick_hz: int = 120
@export var snapshot_hz: int = 30

@export var state_fields: Array[NetFieldConfig] = []
@export var corrections: Array[NetCorrection] = []

# Phase 8: additional nodes whose @export-able properties replicate alongside
# state_fields. Encoded after the state_fields block on the wire; not yet in
# the dirty mask (Phase 8c).
@export var child_refs: Array[NetChildRef] = []


func find_correction(correction_name: StringName) -> NetCorrection:
	for c in corrections:
		if c.name == correction_name:
			return c
	return null


func find_state_field(field_name: StringName) -> NetFieldConfig:
	for f in state_fields:
		if f.name == field_name:
			return f
	return null


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
	parts.append("state_class=%s" % (state_class.resource_path if state_class else ""))
	parts.append("command_class=%s" % (command_class.resource_path if command_class else ""))
	parts.append("tick_hz=%d" % tick_hz)
	parts.append("snapshot_hz=%d" % snapshot_hz)
	for f in state_fields:
		parts.append("field|%s|%d|%d|%d|%f|%f" % [
				str(f.name),
				int(f.quant),
				int(f.predict),
				int(f.no_interp),
				f.min_value,
				f.max_value])
	for c in corrections:
		parts.append("corr|%s|%s|%f|%f|%f|%d" % [
				str(c.name),
				"|".join(c.fields),
				c.snap_threshold,
				c.smooth_rate,
				c.deadband,
				int(c.always_snap)])
	for cr in child_refs:
		parts.append("child|%s|%s|%s|%d" % [
				str(cr.name),
				str(cr.path),
				"|".join(cr.fields),
				int(cr.proxy_only)])
	return "\n".join(parts).hash()
