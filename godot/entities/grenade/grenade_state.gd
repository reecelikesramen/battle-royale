@tool
class_name GrenadeState extends NetState

@export var pos: Vector3 = Vector3.ZERO
@export var velocity: Vector3 = Vector3.ZERO
@export var rotation_quat: Quaternion = Quaternion.IDENTITY
@export var fuse_remaining: float = 3.0
@export var state: int = 0
@export var explosion_progress: float = 0.0
