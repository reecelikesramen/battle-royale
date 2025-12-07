class_name ToggleUI
extends Control

signal opened()

@export var ACTION_NAME: StringName
@export var SHOW_MOUSE: bool = true


var open: bool:
	get: return open
	set(value):
		if _can_open() and value:
			open = true
			visible = true
			if SHOW_MOUSE:
				mouse_filter = Control.MOUSE_FILTER_STOP
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
			opened.emit()
		else:
			open = false
			visible = false
			if SHOW_MOUSE:
				mouse_filter = Control.MOUSE_FILTER_PASS
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	opened.connect(_on_open)
	visible = false


func _input(event):
	if event.is_action_pressed(ACTION_NAME):
		open = !open


## callback on open
func _on_open() -> void: pass


## callback to see if can open
func _can_open() -> bool: return true
