extends PanelContainer

@onready var property_container = %VBoxContainer
var props = {}

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	visible = false
	if LowLevelNetworkHandler.isServer():
		%Button.visible = false
		%LineEdit.visible = false
	
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


func _on_connect_pressed() -> void:
	print("Connect pressed")
	if LowLevelNetworkHandler.isServer():
		return
	if !LowLevelNetworkHandler.is_connected:
		LowLevelNetworkHandler.start_client_default()
		print("Client started")


#func _on_lin1Handler.test_submit_user_input(new_text)
