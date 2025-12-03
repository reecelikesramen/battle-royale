extends Node

const SEMVER_PATTERN = "^v(0|[1-9]\\d*)\\.(0|[1-9]\\d*)\\.(0|[1-9]\\d*)(?:-((?:0|[1-9]\\d*|\\d*[a-zA-Z-][a-zA-Z0-9-]*)(?:\\.(?:0|[1-9]\\d*|\\d*[a-zA-Z-][a-zA-Z0-9-]*))*))?(?:\\+([a-zA-Z0-9-]+(?:\\.[a-zA-Z0-9-]+)*))?\\.pck$"
var _r = RegEx.new()

var _game_dir: DirAccess

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	if Engine.has_meta(&"patches_loaded"):
		print("Patches loaded, changing to main menu")
		get_tree().call_deferred(&"change_scene_to_file", Constants.MAIN_MENU_SCENE_PATH)
		return
	
	print(ProjectSettings.globalize_path("res://"))
	print(ProjectSettings.localize_path(OS.get_executable_path().get_base_dir()))
	print("Loading patches...")
	
	_r.compile(SEMVER_PATTERN)
	_game_dir = DirAccess.open(OS.get_executable_path().get_base_dir())
	print(OS.get_executable_path().get_base_dir())
	if _game_dir:
		load_patches()
	else:
		push_error("Failed to load game executable dir and patch game")
	
	Engine.set_meta(&"patches_loaded", true)
	print("Loaded patches, reloading...")
	get_tree().call_deferred(&"reload_current_scene")


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
