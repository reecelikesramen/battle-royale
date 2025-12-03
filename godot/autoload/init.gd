extends Node

const SEMVER_PATTERN = "^v(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)(?:-((?:0|[1-9]\\d*|\\d*[a-zA-Z-][a-zA-Z0-9-]*)(?:\\.(?:0|[1-9]\\d*|\\d*[a-zA-Z-][a-zA-Z0-9-]*))*))?(?:\\+([a-zA-Z0-9-]+(?:\\.[a-zA-Z0-9-]+)*))?\\.pck$"
const GCS_BUCKET = "erudite-cycle-480104-game-builds"
const GCS_BASE_URL = "https://storage.googleapis.com/" + GCS_BUCKET

var _r = RegEx.new()
var _game_dir: DirAccess
var _http: HTTPRequest
var _pending_downloads: Array[String] = []
var _download_index := 0
var _build_version: String = ""
var _os_prefix: String = ""
var _downloading_manifest := true

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	process_patches_and_updates()


# Patch-safe initialization. All init code that can be patched should go here.
# This runs after all patches (existing + auto-updated) are loaded and applied.
func initialize() -> void:
	# Transition to main menu
	get_tree().call_deferred(&"change_scene_to_file", Constants.MAIN_MENU_SCENE_PATH)


# Handles patching and auto-update flow. Separated from initialize() so patches can modify init logic.
func process_patches_and_updates() -> void:
	# Final state: all patches loaded, proceed to initialization
	if Engine.has_meta(&"patches_loaded"):
		print("All patches loaded, initializing...")
		initialize()
		return
	
	# Phase 2: Auto-update check (after Phase 1 reload)
	if Engine.has_meta(&"patches_applied_phase1") and not Engine.has_meta(&"auto_update_complete"):
		print("Phase 1 complete, starting auto-update...")
		start_auto_update()
		return
	
	# Phase 1: Apply existing patches first
	if not Engine.has_meta(&"patches_applied_phase1"):
		print("Phase 1: Applying existing patches...")
		apply_existing_patches()
		return

func apply_existing_patches() -> void:
	_r.compile(SEMVER_PATTERN)
	_game_dir = DirAccess.open(OS.get_executable_path().get_base_dir())
	if not _game_dir:
		push_error("Failed to load game executable dir")
		# Mark phase 1 complete anyway, continue to auto-update
		Engine.set_meta(&"patches_applied_phase1", true)
		get_tree().call_deferred(&"reload_current_scene")
		return
	
	load_patches()
	Engine.set_meta(&"patches_applied_phase1", true)
	print("Phase 1 complete: Existing patches applied, reloading...")
	get_tree().call_deferred(&"reload_current_scene")

func start_auto_update() -> void:
	_r.compile(SEMVER_PATTERN)
	_os_prefix = get_os_prefix()
	
	# Get build version from VERSION.txt file
	var version_file = FileAccess.open("res://VERSION.txt", FileAccess.READ)
	if version_file == null:
		push_error("VERSION.txt file not found at res://VERSION.txt")
		complete_patching_flow()
		return
	
	_build_version = version_file.get_as_text().strip_edges()
	version_file.close()
	if _build_version.is_empty():
		push_error("VERSION.txt file is empty")
		complete_patching_flow()
		return
	
	print("Build version: ", _build_version)
	print("OS prefix: ", _os_prefix)
	print("Executable dir: ", OS.get_executable_path().get_base_dir())
	
	# Setup HTTP client for downloads
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_http_request_completed)
	
	# Check for updates
	check_for_updates()

func complete_patching_flow() -> void:
	Engine.set_meta(&"auto_update_complete", true)
	Engine.set_meta(&"patches_loaded", true)
	print("Patching flow complete, reloading...")
	get_tree().call_deferred(&"reload_current_scene")


func get_os_prefix() -> String:
	match OS.get_name():
		"Windows":
			return "windows"
		"Linux":
			return "linux"
		"macOS":
			return "mac"
		_:
			return "linux"

func check_for_updates() -> void:
	print("Checking for updates...")
	var url = GCS_BASE_URL + "/versions.json?t=" + str(Time.get_unix_time_from_system())
	var error = _http.request(url)
	if error != OK:
		push_error("Failed to request versions.json: " + str(error))
		complete_patching_flow()

func _on_http_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _downloading_manifest:
		# Handle manifest download
		if response_code != 200:
			push_error("Failed to fetch versions.json: HTTP " + str(response_code))
			complete_patching_flow()
			return
		
		var json = JSON.new()
		var parse_error = json.parse(body.get_string_from_utf8())
		if parse_error != OK:
			push_error("Failed to parse versions.json: " + str(parse_error))
			complete_patching_flow()
			return
		
		var data = json.data
		if not data.has("versions") or not data.versions is Array:
			push_error("Invalid versions.json format")
			complete_patching_flow()
			return
		
		var available_versions: Array = data.versions
		print("Available versions: ", available_versions)
		
		# Find local patches (after Phase 1, patches are already loaded)
		_game_dir = DirAccess.open(OS.get_executable_path().get_base_dir())
		if not _game_dir:
			push_error("Failed to open game directory")
			complete_patching_flow()
			return
		
		var local_files = Array(_game_dir.get_files())
		var local_patches = filter_semver(local_files)
		local_patches.sort_custom(compare_semver)
		print("Local patches: ", local_patches)
		
		# Find latest local version
		var latest_local = _build_version
		if local_patches.size() > 0:
			# Extract version from patch filename (remove OS prefix and .pck)
			var latest_file = local_patches[local_patches.size() - 1]
			var version_match = _r.search(latest_file)
			if version_match:
				latest_local = version_match.get_string(0).trim_suffix(".pck")
		
		print("Latest local version: ", latest_local)
		
		# Find versions to download (newer than latest_local)
		_pending_downloads.clear()
		for version in available_versions:
			if compare_semver(latest_local + ".pck", version + ".pck"):
				_pending_downloads.append(version)
		
		if _pending_downloads.size() == 0:
			print("No updates available")
			complete_patching_flow()
			return
		
		print("Found ", _pending_downloads.size(), " updates to download: ", _pending_downloads)
		_download_index = 0
		_downloading_manifest = false
		download_next_patch()
	else:
		# Handle patch download
		if response_code != 200:
			push_error("Failed to download patch: HTTP " + str(response_code))
			_download_index += 1
			download_next_patch()
			return
		
		# Save patch file (remove OS prefix from filename)
		var version = _pending_downloads[_download_index]
		var save_filename = version + ".pck"
		var save_path = OS.get_executable_path().get_base_dir().path_join(save_filename)
		
		var file = FileAccess.open(save_path, FileAccess.WRITE)
		if file == null:
			push_error("Failed to open file for writing: " + save_path)
			_download_index += 1
			download_next_patch()
			return
		
		file.store_buffer(body)
		file.close()
		print("Saved patch: ", save_path)
		
		_download_index += 1
		download_next_patch()

func download_next_patch() -> void:
	if _download_index >= _pending_downloads.size():
		print("All patches downloaded, applying new patches...")
		apply_new_patches()
		return
	
	var version = _pending_downloads[_download_index]
	var filename = _os_prefix + "-" + version + ".pck"
	var url = GCS_BASE_URL + "/releases/" + version + "/" + filename
	print("Downloading patch ", _download_index + 1, "/", _pending_downloads.size(), ": ", filename)
	
	var error = _http.request(url)
	if error != OK:
		push_error("Failed to request patch: " + str(error))
		_download_index += 1
		download_next_patch()

func apply_new_patches() -> void:
	# Apply newly downloaded patches
	_game_dir = DirAccess.open(OS.get_executable_path().get_base_dir())
	if not _game_dir:
		push_error("Failed to open game directory for applying new patches")
		complete_patching_flow()
		return
	
	# Load all patches (existing + new)
	load_patches()
	
	# Complete patching flow and reload to apply patches
	complete_patching_flow()

func load_patches():
	var files := Array(_game_dir.get_files())
	print("Found files: ", files)
	files = filter_semver(files)
	files.sort_custom(compare_semver)
	print("Sorted files: ", files)
	if files.size() == 0:
		print("No patches found")
		return
	
	var base_dir := OS.get_executable_path().get_base_dir()
	for file_name in files:
		print("Loading patch: ", base_dir.path_join(file_name))
		var success := ProjectSettings.load_resource_pack(base_dir.path_join(file_name))
		print("Success: ", success)


func filter_semver(arr: Array) -> Array[String]:
	var out: Array[String] = []
	for v in arr:
		if _r.search(v): out.append(v)
	return out


func compare_semver(a: String, b: String) -> bool:
	var ma = _r.search(a)
	var mb = _r.search(b)
	if !ma or !mb: return a < b
	
	for i in range(1, 4):
		var na = int(ma.get_string(i))
		var nb = int(mb.get_string(i))
		if na != nb: return na < nb
		
	var pa = ma.get_string(4)
	var pb = mb.get_string(4)
	if pa == pb: return false
	if pa == "": return false
	if pb == "": return true
	
	var sa = pa.split(".")
	var sb = pb.split(".")
	for i in range(min(sa.size(), sb.size())):
		var va = sa[i]
		var vb = sb[i]
		if va == vb: continue
		var ia = va.is_valid_int()
		var ib = vb.is_valid_int()
		if ia and ib:
			if int(va) != int(vb): return int(va) < int(vb)
		elif ia: return true
		elif ib: return false
		else: return va < vb
		
	return sa.size() < sb.size()
