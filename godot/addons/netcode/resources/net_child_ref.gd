@tool
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

## Reference name (for debug + lookup). Unique within the schema. Pure label;
## not on the wire.
@export var name: StringName
## NodePath to the child relative to the NetPredictor's parent (entity root).
## E.g. "AnimationTree" or "Body/CollisionShape". Resolved at _ready.
@export var path: NodePath
## Property paths on the resolved child read via Node.get()/set() each tick.
## E.g. "parameters/blend_position" for AnimationTree, "shape" for a
## CollisionShape3D, "visible" for a MeshInstance3D.
@export var fields: PackedStringArray

## Sprint 2: when true, the snapshot decoder writes this child's fields only
## on proxy clients (not local authority, not server). Lets a controller use
## NetChildRef to ship cosmetic state (animation blend, peek lerp) to remote
## viewers without clobbering the locally-driven values on the owner.
@export var proxy_only: bool = false
