class_name State extends Node

## signal to transition to a new state
@warning_ignore("unused_signal")
signal transition(new_state_name: StringName)

## game logic callback on enter
func logic_enter() -> void: pass
## game logic callback on exit
func logic_exit() -> void: pass
## game logic callback per physics update
func logic_physics(_delta: float) -> void: pass
## game logic callback per frame
func logic_process(_delta: float) -> void: pass

## visual callback on enter
func visual_enter() -> void: pass
## visual callback on exit
func visual_exit() -> void: pass
## visual callback per physics update
func visual_physics(_delta: float) -> void: pass
## visual callback per frame
func visual_process(_delta: float) -> void: pass