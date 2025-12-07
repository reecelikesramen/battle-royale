extends ToggleUI


var _options_visible := false


func _ready() -> void:
	super._ready()
	$VBoxContainer/OptionsAreaHBox.visible = _options_visible


func _on_options_button_pressed() -> void:
	_options_visible = not _options_visible
	$VBoxContainer/OptionsAreaHBox.visible = _options_visible


func _on_exit_button_pressed() -> void:
	NetworkTransport.disconnect_client()
