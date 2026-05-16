extends Node

const MAIN_MENU_SCENE_PATH := "res://ui/main_menu/main_menu.tscn"
const MAP_SCENE_PATH := "res://world/playtest_map/playtest_map.tscn"
const MAP_SPAWN := Vector3(482.0, 574.0, 517.0)
# Off-map staging position for dead players. Far enough that no live entity
# can collide; well below any reasonable playable terrain.
const GRAVEYARD := Vector3(0.0, -1000.0, 0.0)
