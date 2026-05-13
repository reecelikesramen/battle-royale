class_name NetChildRef extends Resource

# Phase 8 declarative entry: tells NetPredictor to also replicate fields on a
# specific child node of the entity. The path resolves relative to the
# predictor's parent (the entity root), so a schema pointing at
# "AnimationTree" finds it as a sibling of the NetPredictor. fields is a flat
# list of property paths read via Node.get(name) / Node.set(name, value) on
# encode / decode respectively — e.g. "parameters/blend_position".
#
# Phase 8a wires the encode/decode loop with full inclusion (every field is
# written every snapshot, even deltas). Phase 8b extends NetStateMachine to
# replicate (current_state_id, active_state.progress) instead of plain
# property reads; 8c folds child fields into the dirty mask.

@export var name: StringName
@export var path: NodePath
@export var fields: PackedStringArray
