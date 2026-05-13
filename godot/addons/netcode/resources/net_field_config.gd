class_name NetFieldConfig extends Resource

# Per-field metadata for a NetState. Drives quantization (wire codec, Phase 6),
# prediction flags, and interpolation behavior for proxies.

@export var name: StringName

enum Quant { AUTO, QUANT8, QUANT16, FLOAT32, QUAT32 }
@export var quant: Quant = Quant.AUTO

## When false, field is replicated to proxies only -- predicted entities skip
## it on replay. Used for cosmetics that derive from other fields.
@export var predict: bool = true

## When true, proxy interpolation uses the freshest value without easing
## between snapshots (useful for booleans, indices).
@export var no_interp: bool = false

## Optional min/max for clamping or quantization range. Ignored when 0.
@export var min_value: float = 0.0
@export var max_value: float = 0.0
