extends PanelContainer

@onready var property_container = %VBoxContainer
var props = {}

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	visible = false
	
func _process(delta: float) -> void:
	set_debug_property("FPS", Engine.get_frames_per_second())

func _input(event):
	if event.is_action_pressed("debug"):
		visible = !visible

func set_debug_property(title: String, value):
	var property
	if title not in props:
		props[title] = Label.new()
	property = props[title]
	property.name = title
	property.text = "%s: %s" % [title, value]
	property_container.add_child(property)
