class_name State extends Node

## signal to transition to a new state
@warning_ignore("unused_signal")
signal transition(new_state_name: StringName)

## The state we transitioned from
var previous_state: State

## Sprint 7: stable wire id for this state. Defaults to -1, which makes the
## StateMachine fall back to child index (legacy behavior). Set this to a
## positive int once a state is wire-visible so reordering the child nodes
## doesn't re-number it under reconciliation / replay. Each State in a
## StateMachine must have a unique stable_id (duplicates emit a warning at
## _ready and the second-registrant wins).
@export var stable_id: int = -1

## game logic callback on enter
func logic_enter() -> void: pass
## game logic callback on exit
func logic_exit() -> void: pass
## game logic callback per physics update
func logic_physics(_delta: float) -> void: pass
## game logic callback per frame
func logic_process(_delta: float) -> void: pass
## game logic transitions callback at least per physics update
func logic_transitions() -> void: pass

## visual callback on enter
func visual_enter() -> void: pass
## visual callback on exit
func visual_exit() -> void: pass
## visual callback per physics update
func visual_physics(_delta: float) -> void: pass
## visual callback per frame
func visual_process(_delta: float) -> void: pass
