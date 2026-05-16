extends Node

const MAIN_MENU_SCENE_PATH := "res://ui/main_menu/main_menu.tscn"
const MAP_SCENE_PATH := "res://world/playtest_map/playtest_map.tscn"

# Hosted dedicated server (Sprint 5+). Override locally by typing into the
# IP field on the main menu, or via --autojoin CLI args.
const DEFAULT_SERVER_HOST := "playtest.server.pywire.dev"
const DEFAULT_SERVER_PORT := 45876

# Cloud Run Function URL for waking the dedicated server VM (Sprint 6).
# Real URL is only known after the first `terraform apply` — read it from
# `terraform output -raw wake_function_url` and paste here, or leave empty
# to hide the "Wake server" button in the main menu.
const WAKE_FUNCTION_URL := "https://wake-q6qjnjtfhq-uc.a.run.app"
const MAP_SPAWN := Vector3(482.0, 574.0, 517.0)
# Off-map staging position for dead players. Far enough that no live entity
# can collide; well below any reasonable playable terrain.
const GRAVEYARD := Vector3(0.0, -1000.0, 0.0)
