@tool
extends VBoxContainer

@onready var _generate_button: Button = $GenerateButton
@onready var _download_button: Button = $DownloadButton
@onready var _status: Label = $Status

func _ready() -> void:
	_generate_button.pressed.connect(_on_generate_pressed)
	_download_button.pressed.connect(_on_download_pressed)

func _on_generate_pressed() -> void:
	var dlg := FileDialog.new()
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dlg.title = "Pick a folder containing your platform builds"
	dlg.access = FileDialog.ACCESS_FILESYSTEM
	get_tree().root.add_child(dlg)
	dlg.dir_selected.connect(_generate_manifest)
	dlg.popup_centered_ratio(0.7)

func _on_download_pressed() -> void:
	_status.text = "Stub: configure your launcher release URL in addons/launcher_publish/config.gd."

func _generate_manifest(dir_path: String) -> void:
	# Scaffolded: walk `dir_path`, compute sha256 of files matching expected
	# component names, write a v2 manifest. Real implementation is a
	# follow-up — Sprint 8 ships the scaffold so the addon installs cleanly
	# from Asset Library and tells the user what to plug in.
	_status.text = "Manifest generation not yet implemented. Pointed at: %s" % dir_path
