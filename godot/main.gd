extends Node

func isServer() -> bool:
	return "--server" in OS.get_cmdline_user_args() or DisplayServer.get_name() == "headless" or OS.has_feature("dedicated_server")

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	print("I'm a server" if isServer() else "I'm a client")
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta: float) -> void:
	pass
