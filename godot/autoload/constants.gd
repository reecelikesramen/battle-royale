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

# ─── Build identity ────────────────────────────────────────────────────────
# `build-sha.txt` (12-char git short SHA) is written next to the game binary
# by cloudbuild on every release. Server + client exchange this during the
# connect handshake; mismatch → server kicks with DisconnectReason.APP_BUILD_MISMATCH.
#
# Editor / local dev runs ship no build-sha.txt — we return DEV_BUILD_SHA, a
# sentinel that's stable across all dev runs so client+server launched from
# the same checkout always match. Exported builds *without* the file return
# MISSING_BUILD_SHA so the handshake fails loudly (catches half-baked zips).
const BUILD_SHA_FILE := "build-sha.txt"
const DEV_BUILD_SHA := "dev"
const MISSING_BUILD_SHA := "missing"
var _build_sha_cache := ""

func get_build_sha() -> String:
	if not _build_sha_cache.is_empty():
		return _build_sha_cache
	var dir := OS.get_executable_path().get_base_dir()
	var path := dir.path_join(BUILD_SHA_FILE)
	if FileAccess.file_exists(path):
		var s := FileAccess.get_file_as_string(path).strip_edges()
		if not s.is_empty():
			_build_sha_cache = s
			return s
	# No file on disk: editor runs are dev; exported-without-file is broken.
	_build_sha_cache = DEV_BUILD_SHA if OS.has_feature("editor") else MISSING_BUILD_SHA
	return _build_sha_cache


# Version tag (e.g. "v0.1.13") written by cloudbuild's set-version step into
# res://VERSION.txt. Exchanged alongside build_sha in the connect handshake
# so a mismatch message can read "Server v0.1.12 vs you v0.1.11" instead of
# just bare shas. Falls back to "dev" in editor / when the file is missing.
const VERSION_FILE := "res://VERSION.txt"
var _version_cache := ""

func get_version() -> String:
	if not _version_cache.is_empty():
		return _version_cache
	if FileAccess.file_exists(VERSION_FILE):
		var s := FileAccess.get_file_as_string(VERSION_FILE).strip_edges()
		if not s.is_empty():
			_version_cache = s
			return s
	_version_cache = "dev"
	return _version_cache
