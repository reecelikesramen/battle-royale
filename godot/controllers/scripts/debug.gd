extends PanelContainer

@onready var property_container = %VBoxContainer
var props = {}

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	visible = false
	if LowLevelNetworkHandler.is_dedicated_server:
		%ExitToMenuButton.visible = false
	
func _process(_delta) -> void:
	set_debug_property("FPS", Engine.get_frames_per_second())

func _input(event):
	if event.is_action_pressed("debug"):
		visible = !visible

func set_debug_property(title: String, value):
	if title not in props:
		props[title] = Label.new()
		property_container.add_child(props[title])
	var property = props[title]
	property.name = title
	property.text = "%s: %s" % [title, value]


func _on_exit_to_menu_button_pressed() -> void:
	get_tree().change_scene_to_file("res://main_menu.tscn")


func _on_quit_button_pressed() -> void:
	get_tree().quit()
