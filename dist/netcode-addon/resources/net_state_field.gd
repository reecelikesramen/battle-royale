@tool
class_name NetStateField extends Resource

# Per-field metadata for a NetState. Drives quantization (wire codec, Phase 6),
# prediction flags, and interpolation behavior for proxies.
#
# Field NAME is the dictionary key in NetSchema.state_fields, not a property
# on this Resource — that way the binding can only exist in one place and
# renames are atomic via the inspector's key chip.

enum Quant { AUTO, QUANT8, QUANT16, FLOAT32, QUAT32 }
## Wire encoding. AUTO uses Godot's put_var/get_var (general-purpose, larger).
## QUANT8/QUANT16 pack scalars + vectors into 1/2 bytes per axis between
## min_value..max_value (lossy, must set range). FLOAT32 sends raw IEEE-754
## floats (4 bytes/axis, lossless). QUAT32 packs unit quaternions into 4 bytes
## (smallest-three encoding, ~1/512 rad error).
@export var quant: Quant = Quant.AUTO

## When false, field is replicated to proxies only — predicted entities skip
## it on replay. Used for cosmetics that derive from other fields.
@export var predict: bool = true

## When true, proxy interpolation uses the freshest value without easing
## between snapshots (useful for booleans, indices, state IDs).
@export var no_interp: bool = false

## Lower bound for QUANT8/QUANT16 range. Values below this clamp to min on
## encode. Ignored for AUTO/FLOAT32/QUAT32.
@export var min_value: float = 0.0
## Upper bound for QUANT8/QUANT16 range. Values above this clamp to max on
## encode. Ignored for AUTO/FLOAT32/QUAT32.
@export var max_value: float = 0.0
