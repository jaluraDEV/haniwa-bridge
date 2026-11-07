extends Control

const MANIFEST_REL_PATH       := "orig/GAFE01_00/manifest.json"
const DOL_REL_PATH            := "orig/GAFE01_00/sys/main.dol"
const REL_REL_PATH            := "orig/GAFE01_00/sys/foresta.rel"
const COPYDATE_REL_PATH       := "orig/GAFE01_00/files/COPYDATE"
const PROGRESS_REL_PATH       := "orig/GAFE01_00/extract_progress.txt"
const BUILD_PROGRESS_REL_PATH := "build_progress.txt"

var _root_dir: String = ""
var _is_extracted: bool = false
var _extract_pid: int = -1
var _build_pid: int = -1
var _launching: bool = false

# UI Nodes (constructed programmatically for zero .tscn corruption risk)
var _status_badge: Label
var _status_detail: Label
var _progress_bar: ProgressBar
var _progress_label: Label
var _btn_launch: Button
var _btn_extract: Button
var _chk_fast_start: CheckBox
var _chk_fullscreen: CheckBox
var _file_dialog: FileDialog

func _ready() -> void:
	_resolve_root_dir()

	# Forward immediately if automated test flags are passed
	var all_args := OS.get_cmdline_args() + OS.get_cmdline_user_args()
	for arg in all_args:
		if arg in ["--direct-play", "--efb-stress", "--lit-bench", "--quick-start"]:
			if DisplayServer.get_name() != "headless":
				DisplayServer.window_set_size(Vector2i(1280, 960))
			get_tree().change_scene_to_file("res://shm_main.tscn")
			return

	# Ensure launcher window opens at clean, comfortable dimensions and centered
	if DisplayServer.get_name() != "headless" and DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_size(Vector2i(880, 580))
		var screen_id := DisplayServer.window_get_current_screen()
		var screen_rect := DisplayServer.screen_get_usable_rect(screen_id)
		DisplayServer.window_set_position(screen_rect.position + (screen_rect.size - Vector2i(880, 580)) / 2)

	_build_ui()
	_load_launcher_settings()
	get_window().files_dropped.connect(_on_files_dropped)
	_verify_extracted_data()

func _resolve_root_dir() -> void:
	var exe_dir := OS.get_executable_path().get_base_dir().simplify_path()
	var proj_parent := ProjectSettings.globalize_path("res://..").simplify_path()
	var candidates: Array[String] = []
	if OS.has_feature("editor"):
		candidates.append(proj_parent)
		candidates.append(exe_dir)
		candidates.append(exe_dir.get_base_dir().simplify_path())
	else:
		candidates.append(exe_dir)
		candidates.append(proj_parent)
		candidates.append(exe_dir.get_base_dir().simplify_path())
	for cand in candidates:
		if FileAccess.file_exists(cand.path_join("HaniwaHost.exe")) or FileAccess.file_exists(cand.path_join("acgc_host_x86.exe")):
			_root_dir = cand
			return
	_root_dir = proj_parent if OS.has_feature("editor") else exe_dir

func _build_ui() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(740, 510)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.10, 0.13, 0.19, 0.98)
	style.border_color = Color(0.20, 0.28, 0.40, 0.7)
	style.set_border_width_all(1)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(20)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	# Logo Header
	var logo_path := "res://launcher/assets/haniwa_logo.png"
	var logo_tex: Texture2D = null
	if ResourceLoader.exists(logo_path):
		logo_tex = load(logo_path)
	if not logo_tex:
		var global_img_path := ProjectSettings.globalize_path(logo_path)
		if FileAccess.file_exists(global_img_path):
			var img := Image.load_from_file(global_img_path)
			if img:
				logo_tex = ImageTexture.create_from_image(img)

	if logo_tex:
		var logo := TextureRect.new()
		logo.texture = logo_tex
		logo.custom_minimum_size = Vector2(0, 95)
		logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		vbox.add_child(logo)
	else:
		var title := Label.new()
		title.text = "HaniwaBridge"
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.add_theme_font_size_override("font_size", 18)
		title.add_theme_color_override("font_color", Color(0.96, 0.98, 1.0))
		vbox.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "Animal Crossing GameCube • 64-Bit Godot 4 Forward+ Hybrid"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_font_size_override("font_size", 11)
	subtitle.add_theme_color_override("font_color", Color(0.60, 0.70, 0.84))
	vbox.add_child(subtitle)

	var sep := HSeparator.new()
	var sep_style := StyleBoxLine.new()
	sep_style.color = Color(0.18, 0.24, 0.34, 0.6)
	sep.add_theme_stylebox_override("separator", sep_style)
	vbox.add_child(sep)

	# Extraction Status Box
	var status_panel := PanelContainer.new()
	var st_style := StyleBoxFlat.new()
	st_style.bg_color = Color(0.06, 0.08, 0.12, 1.0)
	st_style.border_color = Color(0.16, 0.22, 0.32, 0.6)
	st_style.set_border_width_all(1)
	st_style.set_corner_radius_all(8)
	st_style.set_content_margin_all(14)
	status_panel.add_theme_stylebox_override("panel", st_style)
	vbox.add_child(status_panel)

	var status_vbox := VBoxContainer.new()
	status_vbox.add_theme_constant_override("separation", 6)
	status_panel.add_child(status_vbox)

	_status_badge = Label.new()
	_status_badge.add_theme_font_size_override("font_size", 13)
	status_vbox.add_child(_status_badge)

	_status_detail = Label.new()
	_status_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_detail.add_theme_font_size_override("font_size", 11)
	_status_detail.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))
	status_vbox.add_child(_status_detail)

	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(0, 16)
	_progress_bar.show_percentage = false
	var pbar_bg := StyleBoxFlat.new()
	pbar_bg.bg_color = Color(0.12, 0.16, 0.22, 1.0)
	pbar_bg.set_corner_radius_all(4)
	var pbar_fill := StyleBoxFlat.new()
	pbar_fill.bg_color = Color(0.18, 0.65, 0.78, 1.0)
	pbar_fill.set_corner_radius_all(4)
	_progress_bar.add_theme_stylebox_override("background", pbar_bg)
	_progress_bar.add_theme_stylebox_override("fill", pbar_fill)
	_progress_bar.visible = false
	status_vbox.add_child(_progress_bar)

	_progress_label = Label.new()
	_progress_label.add_theme_font_size_override("font_size", 11)
	_progress_label.add_theme_color_override("font_color", Color(0.65, 0.75, 0.88))
	_progress_label.visible = false
	status_vbox.add_child(_progress_label)

	# Options Section
	var opts_hbox := HBoxContainer.new()
	opts_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	opts_hbox.add_theme_constant_override("separation", 32)
	vbox.add_child(opts_hbox)

	_chk_fast_start = CheckBox.new()
	_chk_fast_start.text = "Fast Start (Skip Intro Dialogue)"
	_chk_fast_start.add_theme_font_size_override("font_size", 12)
	_chk_fast_start.add_theme_color_override("font_color", Color(0.84, 0.89, 0.95))
	_chk_fast_start.button_pressed = true
	_chk_fast_start.toggled.connect(_on_fast_start_toggled)
	opts_hbox.add_child(_chk_fast_start)

	_chk_fullscreen = CheckBox.new()
	_chk_fullscreen.text = "Start in Fullscreen"
	_chk_fullscreen.add_theme_font_size_override("font_size", 12)
	_chk_fullscreen.add_theme_color_override("font_color", Color(0.84, 0.89, 0.95))
	_chk_fullscreen.button_pressed = false
	_chk_fullscreen.toggled.connect(_on_fullscreen_toggled)
	opts_hbox.add_child(_chk_fullscreen)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 4)
	vbox.add_child(spacer)

	# Action Buttons
	var btn_hbox := HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 12)
	vbox.add_child(btn_hbox)

	_btn_extract = Button.new()
	_btn_extract.text = "Select USA ROM & Extract..."
	_btn_extract.custom_minimum_size = Vector2(250, 40)
	_btn_extract.add_theme_font_size_override("font_size", 12)
	var extract_style := StyleBoxFlat.new()
	extract_style.bg_color = Color(0.15, 0.20, 0.27, 1.0)
	extract_style.border_color = Color(0.26, 0.36, 0.48, 1.0)
	extract_style.set_border_width_all(1)
	extract_style.set_corner_radius_all(8)
	var extract_hover := StyleBoxFlat.new()
	extract_hover.bg_color = Color(0.20, 0.27, 0.36, 1.0)
	extract_hover.border_color = Color(0.35, 0.48, 0.62, 1.0)
	extract_hover.set_border_width_all(1)
	extract_hover.set_corner_radius_all(8)
	_btn_extract.add_theme_stylebox_override("normal", extract_style)
	_btn_extract.add_theme_stylebox_override("hover", extract_hover)
	_btn_extract.add_theme_color_override("font_color", Color(0.90, 0.94, 0.98))
	_btn_extract.pressed.connect(_on_extract_pressed)
	btn_hbox.add_child(_btn_extract)

	_btn_launch = Button.new()
	_btn_launch.text = "▶  Launch Game"
	_btn_launch.custom_minimum_size = Vector2(250, 40)
	_btn_launch.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn_launch.add_theme_font_size_override("font_size", 13)
	var launch_normal := StyleBoxFlat.new()
	launch_normal.bg_color = Color(0.14, 0.52, 0.62, 1.0)
	launch_normal.border_color = Color(0.25, 0.75, 0.88, 1.0)
	launch_normal.set_border_width_all(1)
	launch_normal.set_corner_radius_all(8)
	var launch_hover := StyleBoxFlat.new()
	launch_hover.bg_color = Color(0.18, 0.62, 0.74, 1.0)
	launch_hover.border_color = Color(0.35, 0.88, 1.0, 1.0)
	launch_hover.set_border_width_all(1)
	launch_hover.set_corner_radius_all(8)
	var launch_disabled := StyleBoxFlat.new()
	launch_disabled.bg_color = Color(0.12, 0.15, 0.19, 1.0)
	launch_disabled.border_color = Color(0.18, 0.22, 0.28, 1.0)
	launch_disabled.set_border_width_all(1)
	launch_disabled.set_corner_radius_all(8)
	_btn_launch.add_theme_stylebox_override("normal", launch_normal)
	_btn_launch.add_theme_stylebox_override("hover", launch_hover)
	_btn_launch.add_theme_stylebox_override("disabled", launch_disabled)
	_btn_launch.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0))
	_btn_launch.add_theme_color_override("font_disabled_color", Color(0.40, 0.46, 0.52))
	_btn_launch.pressed.connect(_on_launch_pressed)
	btn_hbox.add_child(_btn_launch)

	# Footer
	var footer := Label.new()
	footer.text = "Open Source Hybrid Engine • BYO-ROM (No assets included) • Requires USA Rev 0 (GAFE01_00) ROM"
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.add_theme_font_size_override("font_size", 10)
	footer.add_theme_color_override("font_color", Color(0.42, 0.48, 0.56))
	vbox.add_child(footer)

	# Native File Dialog for ROM selection
	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.use_native_dialog = true
	_file_dialog.title = "Select Animal Crossing USA (GAFE01_00) ROM"
	_file_dialog.filters = PackedStringArray([
		"*.iso, *.ciso, *.gcm ; GameCube Disc Images (*.iso, *.ciso, *.gcm)"
	])
	_file_dialog.file_selected.connect(_on_rom_file_selected)
	add_child(_file_dialog)

func _verify_extracted_data() -> void:
	var host_exe := _get_host_exe_path()
	if host_exe.is_empty():
		_is_extracted = false
		_status_badge.text = "● STATUS: ENGINE BUILD REQUIRED"
		_status_badge.add_theme_color_override("font_color", Color(1.0, 0.72, 0.28))
		_status_detail.text = "HaniwaHost.exe has not been built yet. Click '1-Click Build: Compile Engine' below to compile the 32-bit headless host locally on your machine."
		_btn_launch.disabled = true
		_btn_extract.text = "⚙️  1-Click Build: Compile Engine"
		return

	var manifest_path := _root_dir.path_join(MANIFEST_REL_PATH)
	var dol_path := _root_dir.path_join(DOL_REL_PATH)
	var rel_path := _root_dir.path_join(REL_REL_PATH)
	var copydate_path := _root_dir.path_join(COPYDATE_REL_PATH)

	_is_extracted = false
	if FileAccess.file_exists(manifest_path) and FileAccess.file_exists(dol_path) and FileAccess.file_exists(rel_path) and FileAccess.file_exists(copydate_path):
		var txt := FileAccess.get_file_as_string(manifest_path)
		var parsed = JSON.parse_string(txt)
		if typeof(parsed) == TYPE_DICTIONARY and parsed.get("game_id", "") == "GAFE01" and int(parsed.get("revision", -1)) == 0:
			_is_extracted = true
			var dol_mb := float(parsed.get("dol_size", 0)) / 1048576.0
			var rel_mb := float(parsed.get("rel_size", 0)) / 1048576.0
			var f_cnt := int(parsed.get("fst_file_count", 0))
			_status_badge.text = "● STATUS: EXTRACTED & READY (USA Rev 0 • GAFE01_00)"
			_status_badge.add_theme_color_override("font_color", Color(0.30, 0.92, 0.52))
			_status_detail.text = "Verified extracted game data in orig/GAFE01_00/ (DOL: %.2f MB | REL: %.2f MB | %d FST files).\nYou can launch the game directly — the ROM file is no longer required." % [dol_mb, rel_mb, f_cnt]
			_btn_launch.disabled = false
			_btn_extract.text = "Re-Extract / Change ROM..."
			return

	_status_badge.text = "● STATUS: NOT EXTRACTED — USA ROM (GAFE01_00) Required"
	_status_badge.add_theme_color_override("font_color", Color(1.0, 0.72, 0.28))
	_status_detail.text = "No extracted game data found. Click 'Select USA ROM & Extract' (or drag and drop your .iso here) to perform the one-time extraction from your Animal Crossing (USA Rev 0, GAFE01_00) disc image."
	_btn_launch.disabled = true
	_btn_extract.text = "Select USA ROM (.iso/.ciso/.gcm) & Extract"

func _on_extract_pressed() -> void:
	if _extract_pid != -1 or _build_pid != -1 or _launching:
		return
	var host_exe := _get_host_exe_path()
	if host_exe.is_empty():
		_start_build_host()
		return
	_file_dialog.popup_centered(Vector2i(800, 560))

func _start_build_host() -> void:
	if _build_pid != -1 or _extract_pid != -1 or _launching:
		return

	var old_prog := _root_dir.path_join(BUILD_PROGRESS_REL_PATH)
	if FileAccess.file_exists(old_prog):
		DirAccess.remove_absolute(old_prog)

	_btn_launch.disabled = true
	_btn_extract.disabled = true
	_progress_bar.visible = true
	_progress_bar.max_value = 100.0
	_progress_bar.value = 0.0
	_progress_label.visible = true
	_progress_label.text = "Initializing build environment..."
	_status_badge.text = "● STATUS: COMPILING HOST ENGINE..."
	_status_badge.add_theme_color_override("font_color", Color(0.45, 0.80, 1.0))
	_status_detail.text = "Building 32-bit headless C host locally on your machine. This compiles the game logic privately on your PC for 100% legal BYO-ROM compliance."

	var script_path := _root_dir.path_join("tools/build_host.ps1")
	var args := PackedStringArray(["-ExecutionPolicy", "Bypass", "-File", script_path])
	_build_pid = OS.create_process("powershell.exe", args, false)
	if _build_pid <= 0:
		_build_pid = -1
		_btn_extract.disabled = false
		_progress_bar.visible = false
		_progress_label.visible = false
		_status_badge.text = "● ERROR: Failed to start PowerShell build script."
		_status_badge.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
		_status_detail.text = "Could not launch 'powershell.exe -File %s'. You can run 'tools\\build_host.bat' manually." % script_path

func _on_files_dropped(files: PackedStringArray) -> void:
	if files.is_empty() or _extract_pid != -1 or _build_pid != -1 or _launching:
		return
	for file_path in files:
		var ext := file_path.get_extension().to_lower()
		if ext in ["iso", "ciso", "gcm"]:
			var host_exe := _get_host_exe_path()
			if host_exe.is_empty():
				_status_detail.text = "Please build HaniwaHost.exe first by clicking the build button."
				return
			_on_rom_file_selected(file_path)
			return

func _get_host_exe_path() -> String:
	var haniwa := _root_dir.path_join("HaniwaHost.exe")
	if FileAccess.file_exists(haniwa):
		return haniwa
	var legacy := _root_dir.path_join("acgc_host_x86.exe")
	if FileAccess.file_exists(legacy):
		return legacy
	return ""

func _on_rom_file_selected(rom_path: String) -> void:
	var host_exe := _get_host_exe_path()
	if host_exe.is_empty():
		_status_badge.text = "● ERROR: HaniwaHost.exe not found!"
		_status_badge.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
		_status_detail.text = "Expected host binary at: " + _root_dir.path_join("HaniwaHost.exe")
		return

	var out_dir := _root_dir.path_join("orig/GAFE01_00")
	var prog_file := _root_dir.path_join(PROGRESS_REL_PATH)
	if FileAccess.file_exists(prog_file):
		DirAccess.remove_absolute(prog_file)

	_btn_launch.disabled = true
	_btn_extract.disabled = true
	_progress_bar.visible = true
	_progress_bar.value = 0.0
	_progress_label.visible = true
	_progress_label.text = "Starting extraction from: " + rom_path.get_file()
	_status_badge.text = "● STATUS: EXTRACTING USA ROM..."
	_status_badge.add_theme_color_override("font_color", Color(0.45, 0.80, 1.0))

	var args := PackedStringArray(["--extract-rom", rom_path, "--out-dir", out_dir])
	_extract_pid = OS.create_process(host_exe, args, false)
	if _extract_pid <= 0:
		_extract_pid = -1
		_btn_extract.disabled = false
		_status_badge.text = "● ERROR: Failed to start extractor process."
		_status_badge.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))

func _process(_delta: float) -> void:
	if _build_pid != -1:
		var prog_file := _root_dir.path_join(BUILD_PROGRESS_REL_PATH)
		if FileAccess.file_exists(prog_file):
			var raw := FileAccess.get_file_as_string(prog_file).strip_edges()
			var lines := raw.split("\n", false)
			if lines.size() >= 1:
				var target_val := float(lines[0])
				_progress_bar.value = move_toward(_progress_bar.value, target_val, _delta * 65.0)
				if lines.size() >= 2:
					_progress_label.text = lines[1].strip_edges()

		if not OS.is_process_running(_build_pid):
			_build_pid = -1
			_progress_bar.visible = false
			_progress_label.visible = false
			_btn_extract.disabled = false
			var host_exe := _get_host_exe_path()
			if not host_exe.is_empty():
				_status_badge.text = "● SUCCESS: Engine Built Successfully!"
				_status_badge.add_theme_color_override("font_color", Color(0.30, 0.92, 0.52))
				_status_detail.text = "HaniwaHost.exe has been compiled and is ready."
			else:
				_status_badge.text = "● BUILD FAILED: Check tools/build_host.bat"
				_status_badge.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
				_status_detail.text = "Compilation finished without creating HaniwaHost.exe. Please verify MSYS2 / MinGW32 or run 'tools/build_host.bat' for error details."
			_verify_extracted_data()

	if _extract_pid != -1:
		var prog_file := _root_dir.path_join(PROGRESS_REL_PATH)
		if FileAccess.file_exists(prog_file):
			var lines := FileAccess.get_file_as_string(prog_file).split("\n", false)
			if lines.size() >= 1:
				var parts := lines[0].split("/")
				if parts.size() == 2 and int(parts[1]) > 0:
					var cur := float(parts[0])
					var tot := float(parts[1])
					_progress_bar.max_value = tot
					_progress_bar.value = cur
					var fname := lines[1] if lines.size() >= 2 else ""
					_progress_label.text = "Extracting (%d/%d): %s" % [int(cur), int(tot), fname]

		if not OS.is_process_running(_extract_pid):
			_extract_pid = -1
			_btn_extract.disabled = false
			_progress_bar.visible = false
			_progress_label.visible = false
			_verify_extracted_data()
			if not _is_extracted:
				_status_badge.text = "● EXTRACTION FAILED — Invalid or Unsupported ROM"
				_status_badge.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
				_status_detail.text = "Please verify that your disc image is an unmodified USA Rev 0 (GAFE01_00) copy of Animal Crossing (.iso, .ciso, or .gcm)."

func _load_launcher_settings() -> void:
	var cfg_path := _root_dir.path_join("settings.ini")
	if not FileAccess.file_exists(cfg_path):
		return
	var txt := FileAccess.get_file_as_string(cfg_path)
	if "fast_start = 0" in txt or "fast_start=0" in txt:
		_chk_fast_start.set_pressed_no_signal(false)
	else:
		_chk_fast_start.set_pressed_no_signal(true)

func _on_fast_start_toggled(enabled: bool) -> void:
	var p := _root_dir.path_join("settings.ini")
	var content := "[Graphics]\nresolution_width = 1280\nresolution_height = 960\nfullscreen = 0\nvsync = 1\nmsaa = 0\ntexture_cache = 0\n\n[Gameplay]\nfast_start = %d\n" % [1 if enabled else 0]
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f:
		f.store_string(content)

func _on_fullscreen_toggled(enabled: bool) -> void:
	if enabled:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)

func _on_launch_pressed() -> void:
	if not _is_extracted or _launching:
		return
	var host_exe := _get_host_exe_path()
	if host_exe.is_empty():
		_status_badge.text = "● ERROR: HaniwaHost.exe not found!"
		_status_badge.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
		_status_detail.text = "Expected host binary at: " + _root_dir.path_join("HaniwaHost.exe")
		return

	_launching = true
	_btn_launch.disabled = true
	_btn_extract.disabled = true
	_status_badge.text = "● STARTING 32-BIT HOST & SHM BRIDGE..."

	# Ensure settings.ini is written before host boots
	_on_fast_start_toggled(_chk_fast_start.button_pressed)

	# Terminate any stale host instances
	OS.execute("taskkill", PackedStringArray(["/IM", "HaniwaHost.exe", "/F"]))
	OS.execute("taskkill", PackedStringArray(["/IM", "acgc_host_x86.exe", "/F"]))

	var log_path := _root_dir.path_join("host.log")
	var host_args := PackedStringArray(["--log-file", log_path])
	var pid := OS.create_process(host_exe, host_args, false)
	if pid <= 0:
		_launching = false
		_btn_launch.disabled = false
		_btn_extract.disabled = false
		_status_badge.text = "● ERROR: Failed to launch HaniwaHost.exe"
		_status_badge.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35))
		return

	Engine.set_meta("acgc_host_pid", pid)

	# Transition window size to 1280x960 4:3 GameCube aspect ratio (or fullscreen)
	if DisplayServer.get_name() != "headless":
		if _chk_fullscreen.button_pressed:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		else:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_size(Vector2i(1280, 960))
			var screen_id := DisplayServer.window_get_current_screen()
			var screen_rect := DisplayServer.screen_get_usable_rect(screen_id)
			DisplayServer.window_set_position(screen_rect.position + (screen_rect.size - Vector2i(1280, 960)) / 2)

	await get_tree().create_timer(0.6).timeout
	get_tree().change_scene_to_file("res://shm_main.tscn")
