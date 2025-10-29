extends Control


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if LowLevelNetworkHandler.isServer():
		visible = false
	else:
		visible = true
		%Button.pressed.connect(connect_to_server)
	
func connect_to_server():
	if !LowLevelNetworkHandler.is_connected:
		LowLevelNetworkHandler.start_client_default()
		print("Client started")
		visible = false
