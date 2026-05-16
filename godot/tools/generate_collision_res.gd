# res://tools/generate_collision_resources.gd
# Editor-time tool that converts EXR heightmaps into persistent HeightMapShape3D .res files.
#
# USAGE:
#   1. Save this file at res://tools/generate_collision_resources.gd
#   2. In Godot, create an empty scene with a single Node
#   3. Attach this script to the Node
#   4. Configure the @export vars in the Inspector
#   5. Check "Generate Now" → it runs once → uncheck
#   6. Output: cell_<r>_<c>.res files in your output directory
#
# These .res files can be loaded by the server at startup with ResourceLoader.load()
# and assigned to a CollisionShape3D's shape property.

@tool
extends Node

@export_group("Input")
## Directory containing your EXR heightmap files (e.g. res://terrain/heightmaps/)
@export_dir var exr_directory: String = "res://terrain/heightmaps/"

## File naming pattern. Use {r} and {c} for row and column. Example: cell_{r}_{c}.exr
@export var filename_pattern: String = "cell_{r}_{c}.exr"

## Grid dimensions (your map is 8x8 cells)
@export var grid_rows: int = 8
@export var grid_cols: int = 8

@export_group("Heightmap Parameters")
## Resolution of input EXR (must be consistent across cells)
@export var exr_resolution: int = 1024

## Collision sample resolution per cell. Lower = less memory, faster queries.
## 513 = 2m spacing (recommended for server), 1025 = 1m spacing
@export_enum("257 (4m)", "513 (2m)", "1025 (1m)") var collision_resolution: int = 1

## Cell size in world meters (your cells are 1km = 1000m)
@export var cell_size_meters: float = 1000.0

@export_group("Per-Cell Elevation")
## Default elevation range in meters. Override per-cell below if cells vary.
@export var default_height_offset: float = 0.0
@export var default_height_range: float = 100.0

## Override elevation for specific cells. Key format: "r,c" → [offset_m, range_m]
## Example: { "2,2": [430.0, 270.0], "0,2": [1000.0, 200.0] }
@export var cell_elevation_overrides: Dictionary = {
	"2,2": [430.0, 270.0],  # Kozari village
}

@export_group("Output")
## Directory where .res files will be written
@export_dir var output_directory: String = "res://terrain/collision/"

## Output filename pattern. Use {r} and {c} for row and column.
@export var output_pattern: String = "cell_{r}_{c}.res"

@export_group("Run")
## Check this box to generate. Will run once then auto-uncheck.
@export var generate_now: bool = false:
	set(value):
		if value and Engine.is_editor_hint():
			_generate_all()
			generate_now = false


const COLLISION_RESOLUTIONS: Array[int] = [257, 513, 1025]


func _generate_all() -> void:
	var res_size: int = COLLISION_RESOLUTIONS[collision_resolution]
	print("=== Generating collision resources ===")
	print("Grid: %dx%d cells" % [grid_rows, grid_cols])
	print("EXR input resolution: %dx%d" % [exr_resolution, exr_resolution])
	print("Collision resolution: %dx%d (%.1fm vertex spacing)" % [
		res_size, res_size, cell_size_meters / (res_size - 1)
	])

	# Ensure output directory exists
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_directory))

	var total: int = 0
	var skipped: int = 0
	var failed: int = 0

	for r in range(grid_rows):
		for c in range(grid_cols):
			var key: String = "%d,%d" % [r, c]
			var input_name: String = filename_pattern.replace("{r}", str(r)).replace("{c}", str(c))
			var input_path: String = exr_directory.path_join(input_name)

			if not FileAccess.file_exists(input_path):
				skipped += 1
				continue

			# Per-cell elevation
			var offset: float = default_height_offset
			var height_range: float = default_height_range
			if cell_elevation_overrides.has(key):
				var override = cell_elevation_overrides[key]
				offset = float(override[0])
				height_range = float(override[1])

			# Generate
			var shape: HeightMapShape3D = _build_shape(input_path, res_size, offset, height_range)
			if shape == null:
				push_error("Failed to build shape for cell %s" % key)
				failed += 1
				continue

			# Save
			var output_name: String = output_pattern.replace("{r}", str(r)).replace("{c}", str(c))
			var output_path: String = output_directory.path_join(output_name)
			var err: Error = ResourceSaver.save(shape, output_path, ResourceSaver.FLAG_COMPRESS)
			if err != OK:
				push_error("Failed to save %s: error %d" % [output_path, err])
				failed += 1
				continue

			print("✓ Cell [%d,%d] → %s  (offset=%.0fm range=%.0fm)" % [
				r, c, output_name, offset, height_range
			])
			total += 1

	print("=== Done ===")
	print("Generated: %d  Skipped (no EXR): %d  Failed: %d" % [total, skipped, failed])


func _build_shape(exr_path: String, res_size: int, offset_m: float, range_m: float) -> HeightMapShape3D:
	# Load the EXR image
	var img: Image = Image.load_from_file(exr_path)
	if img == null:
		push_error("Could not load %s" % exr_path)
		return null

	var src_w: int = img.get_width()
	var src_h: int = img.get_height()
	if src_w != src_h:
		push_warning("EXR is not square: %dx%d - using width" % [src_w, src_h])

	# Build height array — sample EXR at res_size resolution, denormalize to meters
	var heights: PackedFloat32Array = PackedFloat32Array()
	heights.resize(res_size * res_size)

	for y in range(res_size):
		# Source pixel Y — sample at vertex positions, not cell centers
		var src_y: int = int(round(float(y) / (res_size - 1) * (src_h - 1)))
		for x in range(res_size):
			var src_x: int = int(round(float(x) / (res_size - 1) * (src_w - 1)))
			# EXR red channel is the normalized 0-1 height
			var norm: float = img.get_pixel(src_x, src_y).r
			heights[y * res_size + x] = offset_m + norm * range_m

	# Build HeightMapShape3D
	var shape: HeightMapShape3D = HeightMapShape3D.new()
	shape.map_width = res_size
	shape.map_depth = res_size
	shape.map_data = heights
	return shape
