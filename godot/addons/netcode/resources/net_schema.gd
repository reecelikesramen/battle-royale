class_name NetSchema extends Resource

# Inspector-authored config for a NetPredictor (or NetReplicator/NetReliable
# in later phases). Carries the state + command class refs, the tick + snapshot
# rates, per-field codec metadata, and the reconcile channels.

@export var state_class: Script
@export var command_class: Script

@export var tick_hz: int = 120
@export var snapshot_hz: int = 30

@export var state_fields: Array[NetFieldConfig] = []
@export var corrections: Array[NetCorrection] = []


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
