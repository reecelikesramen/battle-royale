@tool
extends Node

@export var exr_path: String = "res://world/playtest_map/resources/kozari_heightmap_512x512_range284m_base439m.exr"
@export var height_min_m: float = 439.0
@export var height_range_m: float = 284.0
@export var output_resolution: int = 513  # 513 = 2m vertex spacing, 1025 = 1m
@export var save_path: String = "res://world/playtest_map/resources/kozari_shape.tres"
@export var run_now: bool = false:
	set(value):
		if value and Engine.is_editor_hint():
			_build_and_save()
			run_now = false

func _build_and_save() -> void:
	var img: Image = Image.load_from_file(exr_path)
	if img == null:
		push_error("Could not load EXR: %s" % exr_path)
		return

	print("Loaded EXR: %dx%d" % [img.get_width(), img.get_height()])

	var src_w: int = img.get_width()
	var src_h: int = img.get_height()
	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize(output_resolution * output_resolution)

	for y in range(output_resolution):
		var sy: int = int(round(float(y) / (output_resolution - 1) * (src_h - 1)))
		for x in range(output_resolution):
			var sx: int = int(round(float(x) / (output_resolution - 1) * (src_w - 1)))
			var norm: float = img.get_pixel(sx, sy).r
			heights[y * output_resolution + x] = height_min_m + norm * height_range_m

	var shape: HeightMapShape3D = HeightMapShape3D.new()
	shape.map_width = output_resolution
	shape.map_depth = output_resolution
	shape.map_data = heights

	var out_dir: String = ProjectSettings.globalize_path(save_path.get_base_dir())
	if not DirAccess.dir_exists_absolute(out_dir):
		DirAccess.make_dir_recursive_absolute(out_dir)

	var err: int = ResourceSaver.save(shape, save_path)
	if err != OK:
		push_error("ResourceSaver failed (%d): %s" % [err, save_path])
		return

	print("Saved: %s" % save_path)
	EditorInterface.get_resource_filesystem().scan()
