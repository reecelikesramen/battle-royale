extends NetworkHandler

var is_dedicated_server: bool:
	get: return "--server" in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server")

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	print("I'm a server" if is_dedicated_server else "I'm a client")
	if is_dedicated_server:
		start_server_default()
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
