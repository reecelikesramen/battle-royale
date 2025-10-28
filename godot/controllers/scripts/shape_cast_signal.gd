extends ShapeCast3D

signal collision_state_changed(is_colliding: bool)

var _was_colliding: bool = false

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.

func _physics_process(delta: float) -> void:
	# Ensure we update the cast
	force_shapecast_update()
	var is_colliding_now = is_colliding()
	if is_colliding_now != _was_colliding:
		_was_colliding = is_colliding_now
		emit_signal("collision_state_changed", is_colliding_now)
