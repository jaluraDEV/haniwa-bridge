extends Node3D

const LightingController = preload("res://lighting/environment_controller.gd")

const ACFPRenderer = preload("res://renderer/acfp_renderer.gd")

# GameCube PAD button bitmasks
const PAD_BUTTON_LEFT    = 0x0001
const PAD_BUTTON_RIGHT   = 0x0002
const PAD_BUTTON_DOWN    = 0x0004
const PAD_BUTTON_UP      = 0x0008
const PAD_TRIGGER_Z      = 0x0010
const PAD_TRIGGER_R      = 0x0020
const PAD_TRIGGER_L      = 0x0040
const PAD_BUTTON_A       = 0x0100
const PAD_BUTTON_B       = 0x0200
const PAD_BUTTON_X       = 0x0400
const PAD_BUTTON_Y       = 0x0800
const PAD_BUTTON_START   = 0x1000

var bridge: Object
var renderer: ACFPRenderer
var vp: SubViewport
var lighting_controller: LightingController
var game_camera: Camera3D
var thread_lighting_state: Dictionary = {}
var pending_lighting_state: Dictionary = {}
var f4_was_pressed: bool = false
var env: Environment

var frame_count: int = 0
var last_fps_time: int = 0
var fps: float = 60.0

var total_frames: int = 0
var last_frame_time_us: int = 0
var max_frame_ms: float = 0.0
var max_tick_ms: float = 0.0
var max_render_ms: float = 0.0
var history_frame_ms: Array[float] = []
var history_tick_ms: Array[float] = []
var history_render_ms: Array[float] = []

# Worker thread pipeline state
var tick_thread: Thread = Thread.new()
var tick_sem: Semaphore = Semaphore.new()
var done_sem: Semaphore = Semaphore.new()
var thread_exit: bool = false
var thread_input_params: Dictionary = {}
var thread_packet: PackedByteArray = PackedByteArray()
var thread_tick_us: int = 0
var thread_scene_no: int = -1
var pending_scene_no: int = -1
var benchmark_scenes: Dictionary = {}
var pending_packet: PackedByteArray = PackedByteArray()
var pending_tick_us: int = 0
var game_ready: bool = false
var benchmark_frames: int = 0
var benchmark_scene: int = -1
var cli_lighting_mode: int = -1
var benchmark_output: String = "res://../scratch/runtime_benchmark.json"
var benchmark_intervals: Array[float] = []
var benchmark_work: Array[float] = []
var benchmark_draws: Array[int] = []
var benchmark_started_us: int = 0
var last_present_us: int = 0
var benchmark_present: Array[float] = []
var benchmark_slow_frames: int = 0
var benchmark_fill_min: int = 65536
var benchmark_fill_max: int = 0

# VSync setting: 0=Disabled (Standard), 1=Enabled, 2=Adaptive
var vsync_mode: int = 0
const VSYNC_NAMES = ["Aus (Disabled) [Standard]", "An (Enabled)", "Adaptiv (Adaptive)"]
var toast_message: String = ""
var toast_expire_ms: int = 0
var warmup_stats: Dictionary = {}
var last_draw_count: int = 0
var last_logged_pad: Dictionary = {}

# Session recording & replay
var session_record_path: String = ""
var session_record_file: FileAccess = null
var session_recording: bool = false
var session_replay_path: String = ""
var session_replay_file: FileAccess = null
var session_replaying: bool = false
var session_replay_ticks_limit: int = 1000
var session_tick_index: int = 0
var test_change_scene_tick: int = -1
var test_change_scene_id: int = -1
var test_auto_start: bool = false
var physics_tick_counter: int = 0

func _start_session_record(path: String):
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	session_record_file = FileAccess.open(path, FileAccess.WRITE)
	if session_record_file:
		# Write 32-byte header
		session_record_file.store_32(0x53474341) # "ACGS"
		session_record_file.store_32(1)          # version
		session_record_file.store_32(2002)       # year
		session_record_file.store_32(9)          # month
		session_record_file.store_32(15)         # day
		session_record_file.store_32(12)         # hour
		session_record_file.store_32(0)          # min
		session_record_file.store_32(0)          # sec
		session_record_file.store_32(0)          # seed
		session_record_file.store_32(benchmark_scene if benchmark_scene >= 0 else 0)
		session_recording = true
		session_tick_index = 0
		print("[Session] Recording started to %s" % path)

func _stop_session_record():
	if session_record_file:
		session_record_file.close()
		session_record_file = null
	session_recording = false
	print("[Session] Recording finished: %d ticks" % session_tick_index)

func _start_session_replay(path: String):
	session_replay_file = FileAccess.open(path, FileAccess.READ)
	if session_replay_file:
		var magic = session_replay_file.get_32()
		var ver = session_replay_file.get_32()
		if magic != 0x53474341 or ver != 1:
			printerr("[Session Replay] ERROR: Invalid session magic or version!")
			session_replay_file.close()
			session_replay_file = null
			return
		var _yr = session_replay_file.get_32()
		var _mo = session_replay_file.get_32()
		var _dy = session_replay_file.get_32()
		var _hr = session_replay_file.get_32()
		var _mn = session_replay_file.get_32()
		var _sc = session_replay_file.get_32()
		var _sd = session_replay_file.get_32()
		var sc_no = session_replay_file.get_32()
		session_replaying = true
		session_tick_index = 0
		print("[Session Replay] Replaying session from %s (scene=%d, limit=%d)" % [path, sc_no, session_replay_ticks_limit])

func _load_vsync_setting():
	var cfg = ConfigFile.new()
	var err = cfg.load("res://settings.ini")
	if err == OK:
		var v = cfg.get_value("Graphics", "vsync", 0)
		set_vsync_mode(int(v), false)
	else:
		set_vsync_mode(0, false)

func set_vsync_mode(mode: int, save_to_file: bool = true):
	vsync_mode = clampi(mode, 0, 2)
	DisplayServer.window_set_vsync_mode(vsync_mode)
	print("[Settings] VSync mode set to %d: %s" % [vsync_mode, VSYNC_NAMES[vsync_mode]])
	if save_to_file:
		var cfg = ConfigFile.new()
		cfg.load("res://settings.ini")
		cfg.set_value("Graphics", "vsync", vsync_mode)
		cfg.save("res://settings.ini")

func _toggle_vsync():
	var next_mode = (vsync_mode + 1) % 3
	set_vsync_mode(next_mode, true)
	_show_toast("VSync: " + VSYNC_NAMES[vsync_mode])

func _show_toast(msg: String, duration_ms: int = 2500):
	toast_message = msg
	toast_expire_ms = Time.get_ticks_msec() + duration_ms

func _worker_tick_loop():
	while true:
		tick_sem.wait()
		if thread_exit:
			break
		var t0 = Time.get_ticks_usec()
		bridge.call("tick",
			thread_input_params.get("buttons", 0),
			thread_input_params.get("stick_x", 0),
			thread_input_params.get("stick_y", 0),
			thread_input_params.get("substick_x", 0),
			thread_input_params.get("substick_y", 0),
			thread_input_params.get("trigger_l", 0),
			thread_input_params.get("trigger_r", 0)
		)
		thread_tick_us = Time.get_ticks_usec() - t0
		thread_scene_no = bridge.call("get_scene_no")
		thread_lighting_state = LightingController.read_bridge_state(bridge)
		if bridge.call("has_frame_packet"):
			thread_packet = bridge.call("get_frame_packet")
		else:
			thread_packet = PackedByteArray()
		done_sem.post()

func _percentile(arr: Array, p: float) -> float:
	if arr.is_empty():
		return 0.0
	var sorted = arr.duplicate()
	sorted.sort()
	var idx = int(round(p * (sorted.size() - 1)))
	return sorted[clampi(idx, 0, sorted.size() - 1)]

@onready var stats_label: Label = get_node_or_null("UI/StatsLabel")

func _ready():
	RenderingServer.frame_post_draw.connect(_on_frame_post_draw)
	var args = OS.get_cmdline_args()
	args.append_array(OS.get_cmdline_user_args())
	for i in range(args.size() - 1):
		if args[i] == "--benchmark-frames": benchmark_frames = int(args[i + 1])
		if args[i] == "--benchmark-scene": benchmark_scene = int(args[i + 1])
		if args[i] == "--lighting-mode": cli_lighting_mode = int(args[i + 1])
		if args[i] == "--benchmark-output": benchmark_output = args[i + 1]
		if args[i] == "--record-session": session_record_path = args[i + 1]
		if args[i] == "--replay-session": session_replay_path = args[i + 1]
		if args[i] == "--replay-ticks": session_replay_ticks_limit = int(args[i + 1])
		if args[i] == "--change-scene-tick": test_change_scene_tick = int(args[i + 1])
		if args[i] == "--change-scene-id": test_change_scene_id = int(args[i + 1])
	for arg in args:
		if arg == "--auto-start": test_auto_start = true
	if not session_record_path.is_empty():
		_start_session_record(session_record_path)
	if not session_replay_path.is_empty():
		_start_session_replay(session_replay_path)
	if benchmark_frames > 0: benchmark_frames = maxi(benchmark_frames, 301)
	print("=== Animal Crossing (ACGC) Godot Hybrid Main Scene ===")
	Input.joy_connection_changed.connect(func(device: int, connected: bool):
		print("[Input] Gamepad %d %s: %s" % [device, "connected" if connected else "disconnected", Input.get_joy_name(device)])
	)
	for dev in Input.get_connected_joypads():
		print("[Input] Gamepad %d connected: %s (GUID: %s)" % [dev, Input.get_joy_name(dev), Input.get_joy_guid(dev)])

	var container = SubViewportContainer.new()
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.stretch = true
	add_child(container)

	vp = SubViewport.new()
	vp.size = Vector2i(640, 480)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.world_3d = get_world_3d()
	container.add_child(vp)

	var camera = Camera3D.new()
	game_camera = camera
	camera.current = true
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.position = Vector3.ZERO
	camera.size = 2000.0
	camera.near = 0.001
	camera.far = 10000.0

	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	camera.environment = env
	vp.add_child(camera)

	lighting_controller = LightingController.new()
	vp.add_child(lighting_controller)
	renderer = ACFPRenderer.new()
	_load_vsync_setting()
	warmup_stats = renderer.warmup_shaders(vp.get_world_3d().scenario)
	print("[Cold-Start] Pipeline warm-up finished: %d shader variants in %.2f ms" % [warmup_stats.get("variants_compiled", 0), warmup_stats.get("warmup_ms", 0.0)])

	var ext = load("res://acgc_bridge.gdextension")
	if not ClassDB.class_exists("ACGCBridge"):
		printerr("ERROR: ACGCBridge GDExtension not found!")
		return

	bridge = ClassDB.instantiate("ACGCBridge")
	var ok = bridge.call("init_game", 2002, 9, 15, 12, 0, 0, 0, benchmark_scene)
	if not ok:
		printerr("ERROR: Failed to initialize ACGC Game Engine!")
		return

	print("ACGC Game Engine initialized successfully at fixed 60 Hz! Display Hz=", DisplayServer.screen_get_refresh_rate())

	game_ready = true
	if cli_lighting_mode >= 0:
		set_lighting_mode(cli_lighting_mode)
	benchmark_started_us = Time.get_ticks_usec()
	# Start worker thread pipeline
	tick_thread.start(_worker_tick_loop)
	thread_input_params = { "buttons": 0, "stick_x": 0, "stick_y": 0, "substick_x": 0, "substick_y": 0, "trigger_l": 0, "trigger_r": 0 }
	tick_sem.post()

func _physics_process(_delta):
	if not game_ready:
		return
	physics_tick_counter += 1

	# Input Bridge
	var buttons = 0
	var stick_x = 0
	var stick_y = 0
	var substick_x = 0
	var substick_y = 0
	var trigger_l = 0
	var trigger_r = 0

	if session_replaying:
		if session_replay_file and not session_replay_file.eof_reached() and session_tick_index < session_replay_ticks_limit:
			buttons = session_replay_file.get_16()
			stick_x = session_replay_file.get_8()
			if stick_x > 127: stick_x -= 256
			stick_y = session_replay_file.get_8()
			if stick_y > 127: stick_y -= 256
			substick_x = session_replay_file.get_8()
			if substick_x > 127: substick_x -= 256
			substick_y = session_replay_file.get_8()
			if substick_y > 127: substick_y -= 256
			trigger_l = session_replay_file.get_8()
			trigger_r = session_replay_file.get_8()
			var exp_scene = session_replay_file.get_16()
			var exp_draws = session_replay_file.get_16()
			session_tick_index += 1
			if session_tick_index % 60 == 0:
				var desync = 0
				if pending_scene_no >= 0 and pending_scene_no != exp_scene:
					desync += 1
				if abs(last_draw_count - exp_draws) > 0:
					desync += 1
				print("[Session Replay] Tick %d: scene=%d (exp=%d), draws=%d (exp=%d), desync=%d" % [session_tick_index, pending_scene_no, exp_scene, last_draw_count, exp_draws, desync])
		else:
			print("[Session Replay] Completed %d ticks replay successfully!" % session_tick_index)
			session_replaying = false
			if DisplayServer.get_name() == "headless" or benchmark_frames > 0:
				get_tree().quit()
	else:
		# 1. Main Analog Stick (Keyboard: WASD, Gamepad: Left Stick)
		# 1. Keyboard Main analog stick (WASD)
		if Input.is_key_pressed(KEY_D): stick_x += 80
		if Input.is_key_pressed(KEY_A): stick_x -= 80
		if Input.is_key_pressed(KEY_W): stick_y += 80  # GameCube +Y is UP
		if Input.is_key_pressed(KEY_S): stick_y -= 80  # GameCube -Y is DOWN

		# Keyboard D-Pad
		if Input.is_key_pressed(KEY_UP):    buttons |= PAD_BUTTON_UP
		if Input.is_key_pressed(KEY_DOWN):  buttons |= PAD_BUTTON_DOWN
		if Input.is_key_pressed(KEY_LEFT):  buttons |= PAD_BUTTON_LEFT
		if Input.is_key_pressed(KEY_RIGHT): buttons |= PAD_BUTTON_RIGHT

		# Keyboard Action buttons
		if Input.is_key_pressed(KEY_SPACE) or Input.is_key_pressed(KEY_ENTER):
			buttons |= PAD_BUTTON_A
		if Input.is_key_pressed(KEY_SHIFT) or Input.is_key_pressed(KEY_BACKSPACE) or Input.is_key_pressed(KEY_X):
			buttons |= PAD_BUTTON_B
		if Input.is_key_pressed(KEY_C) or Input.is_key_pressed(KEY_M):
			buttons |= PAD_BUTTON_X
		if Input.is_key_pressed(KEY_Y) or Input.is_key_pressed(KEY_V) or Input.is_key_pressed(KEY_I):
			buttons |= PAD_BUTTON_Y
		if Input.is_key_pressed(KEY_ESCAPE) or Input.is_key_pressed(KEY_TAB):
			buttons |= PAD_BUTTON_START

		# Keyboard Triggers & Z
		if Input.is_key_pressed(KEY_Q) or Input.is_key_pressed(KEY_1):
			trigger_l = 255
			buttons |= PAD_TRIGGER_L
		if Input.is_key_pressed(KEY_E) or Input.is_key_pressed(KEY_3):
			trigger_r = 255
			buttons |= PAD_TRIGGER_R
		if Input.is_key_pressed(KEY_Z) or Input.is_key_pressed(KEY_2):
			buttons |= PAD_TRIGGER_Z

		# Keyboard C-Stick (IJKL)
		if Input.is_key_pressed(KEY_L): substick_x += 80
		if Input.is_key_pressed(KEY_J): substick_x -= 80
		if Input.is_key_pressed(KEY_I): substick_y += 80
		if Input.is_key_pressed(KEY_K): substick_y -= 80

		# 2. Gamepads (Xbox, PlayStation, Switch, Generic - all connected devices)
		var joypads = Input.get_connected_joypads()
		for dev in joypads:
			var joy_lx = Input.get_joy_axis(dev, JOY_AXIS_LEFT_X)
			var joy_ly = Input.get_joy_axis(dev, JOY_AXIS_LEFT_Y)
			if abs(joy_lx) > 0.15:
				stick_x = int(clamp(stick_x + joy_lx * 80.0, -80.0, 80.0))
			if abs(joy_ly) > 0.15:
				stick_y = int(clamp(stick_y - joy_ly * 80.0, -80.0, 80.0))

			# D-Pad
			if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_UP):    buttons |= PAD_BUTTON_UP
			if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_DOWN):  buttons |= PAD_BUTTON_DOWN
			if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_LEFT):  buttons |= PAD_BUTTON_LEFT
			if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_RIGHT): buttons |= PAD_BUTTON_RIGHT

			# Action Buttons (Xbox A/B/X/Y, PS Cross/Circle/Square/Triangle)
			if Input.is_joy_button_pressed(dev, JOY_BUTTON_A):
				buttons |= PAD_BUTTON_A
			if Input.is_joy_button_pressed(dev, JOY_BUTTON_B):
				buttons |= PAD_BUTTON_B
			if Input.is_joy_button_pressed(dev, JOY_BUTTON_X):
				buttons |= PAD_BUTTON_X
			if Input.is_joy_button_pressed(dev, JOY_BUTTON_Y):
				buttons |= PAD_BUTTON_Y

			# Start / Pause (Xbox Menu/Start, View/Back; PS Options/Share)
			if Input.is_joy_button_pressed(dev, JOY_BUTTON_START) or Input.is_joy_button_pressed(dev, JOY_BUTTON_BACK):
				buttons |= PAD_BUTTON_START

			# Triggers & Shoulder buttons
			if Input.is_joy_button_pressed(dev, JOY_BUTTON_LEFT_SHOULDER):
				trigger_l = 255
				buttons |= PAD_TRIGGER_L
			var joy_tl = Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_LEFT)
			if joy_tl > 0.15:
				trigger_l = maxi(trigger_l, int(joy_tl * 255.0))
				buttons |= PAD_TRIGGER_L

			var joy_tr = Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_RIGHT)
			if joy_tr > 0.15:
				trigger_r = maxi(trigger_r, int(joy_tr * 255.0))
				buttons |= PAD_TRIGGER_R

			if Input.is_joy_button_pressed(dev, JOY_BUTTON_RIGHT_SHOULDER):
				buttons |= PAD_TRIGGER_Z

			# Right Analog Stick (C-Stick)
			var joy_rx = Input.get_joy_axis(dev, JOY_AXIS_RIGHT_X)
			var joy_ry = Input.get_joy_axis(dev, JOY_AXIS_RIGHT_Y)
			if abs(joy_rx) > 0.15:
				substick_x = int(clamp(substick_x + joy_rx * 80.0, -80.0, 80.0))
			if abs(joy_ry) > 0.15:
				substick_y = int(clamp(substick_y - joy_ry * 80.0, -80.0, 80.0))

		stick_x = clampi(stick_x, -80, 80)
		stick_y = clampi(stick_y, -80, 80)
		substick_x = clampi(substick_x, -80, 80)
		substick_y = clampi(substick_y, -80, 80)

		if test_auto_start:
			# Press Start at title screen, then A repeatedly to select player and load
			if physics_tick_counter >= 120 and physics_tick_counter <= 130:
				buttons |= PAD_BUTTON_START
			elif physics_tick_counter > 150 and (physics_tick_counter % 20 < 10):
				buttons |= PAD_BUTTON_A

		# Log raw PADStatus when state changes
		var pad_changed = (buttons != last_logged_pad.get("buttons", -1) or
						   abs(stick_x - last_logged_pad.get("stick_x", 0)) > 20 or
						   abs(stick_y - last_logged_pad.get("stick_y", 0)) > 20 or
						   abs(substick_x - last_logged_pad.get("substick_x", 0)) > 20 or
						   abs(substick_y - last_logged_pad.get("substick_y", 0)) > 20 or
						   abs(trigger_l - last_logged_pad.get("trigger_l", 0)) > 30 or
						   abs(trigger_r - last_logged_pad.get("trigger_r", 0)) > 30)
		if pad_changed and (buttons != 0 or stick_x != 0 or stick_y != 0 or substick_x != 0 or substick_y != 0):
			print("[PADStatus] btn=0x%04X stick=(%d, %d) cstick=(%d, %d) trig=(%d, %d)" % [buttons, stick_x, stick_y, substick_x, substick_y, trigger_l, trigger_r])
			last_logged_pad = {
				"buttons": buttons,
				"stick_x": stick_x,
				"stick_y": stick_y,
				"substick_x": substick_x,
				"substick_y": substick_y,
				"trigger_l": trigger_l,
				"trigger_r": trigger_r
			}

		if session_recording and session_record_file:
			session_record_file.store_16(buttons)
			session_record_file.store_8(stick_x & 0xFF)
			session_record_file.store_8(stick_y & 0xFF)
			session_record_file.store_8(substick_x & 0xFF)
			session_record_file.store_8(substick_y & 0xFF)
			session_record_file.store_8(trigger_l)
			session_record_file.store_8(trigger_r)
			session_record_file.store_16(clampi(pending_scene_no, 0, 65535))
			session_record_file.store_16(clampi(last_draw_count, 0, 65535))
			session_tick_index += 1

	# 1. Wait for previous tick to produce packet
	done_sem.wait()
	pending_packet = thread_packet
	pending_tick_us = thread_tick_us
	pending_scene_no = thread_scene_no
	pending_lighting_state = thread_lighting_state

	if test_auto_start and pending_scene_no == 7 and test_change_scene_id == 14 and test_change_scene_tick < 0:
		test_change_scene_tick = physics_tick_counter + 60
		print("[Main] Reached Village (Scene 7)! Will transition to Post Office (14) at tick %d" % test_change_scene_tick)

	if test_change_scene_tick > 0 and physics_tick_counter == test_change_scene_tick:
		print("[Main] Triggering test scene change to %d!" % test_change_scene_id)
		bridge.call("change_scene", test_change_scene_id)

	# 2. Setup next tick inputs and trigger worker thread concurrently
	thread_input_params = {
		"buttons": buttons,
		"stick_x": stick_x,
		"stick_y": stick_y,
		"substick_x": substick_x,
		"substick_y": substick_y,
		"trigger_l": trigger_l,
		"trigger_r": trigger_r
	}
	tick_sem.post()

func set_lighting_mode(mode: int):
	renderer.set_lighting_mode(mode)
	lighting_controller.set_enabled(renderer.lighting_mode == 1)
	game_camera.environment = lighting_controller.lighting_environment if renderer.lighting_mode == 1 else env
	var message = "Modus: Godot-Licht" if renderer.lighting_mode == 1 else "Modus: Original"
	_show_toast(message)
	print("[Lighting] ", message, " state=", pending_lighting_state)

var efb_capture_busy: bool = false

func _process(_delta):
	if efb_capture_busy: return
	if not game_ready or pending_packet.is_empty():
		return
	lighting_controller.apply_state(pending_lighting_state)
	var f4_pressed = Input.is_key_pressed(KEY_F4)
	if f4_pressed and not f4_was_pressed:
		set_lighting_mode(1 - renderer.lighting_mode)
	f4_was_pressed = f4_pressed
	var packet = pending_packet
	var tick_us = pending_tick_us
	pending_packet = PackedByteArray()
	var work_start_us = Time.get_ticks_usec()
	var efb_requests = renderer.get_efb_requests(packet)
	if not efb_requests.is_empty():
		efb_capture_busy = true
		for request in efb_requests:
			for _settle in range(3):
				renderer.render_packet(packet, vp.get_world_3d().scenario, request.draws)
				await RenderingServer.frame_post_draw
			renderer.store_efb_image(request, vp.get_texture().get_image())
		efb_capture_busy = false

	if packet.size() > 0:

		# F3 VSync Toggle Hotkey
		if Input.is_key_pressed(KEY_F3):
			if Time.get_ticks_msec() > toast_expire_ms - 2000:
				_toggle_vsync()

		# F9 Session Record Hotkey
		if Input.is_key_pressed(KEY_F9):
			if Time.get_ticks_msec() > toast_expire_ms - 2000:
				if session_recording:
					_stop_session_record()
					_show_toast("Session Recording Gestoppt: %d Ticks" % session_tick_index)
				else:
					var stamp = Time.get_ticks_msec()
					DirAccess.make_dir_absolute("res://../captures/sessions")
					_start_session_record("res://../captures/sessions/session_%d.session" % stamp)
					_show_toast("Session Recording Gestartet...")

		# F10 Capture Hotkey
		if Input.is_key_pressed(KEY_F10):
			var stamp = Time.get_ticks_msec()
			var cap_file = FileAccess.open("res://../captures/f10_capture_%d.acfp" % stamp, FileAccess.WRITE)
			if cap_file:
				cap_file.store_buffer(packet)
				cap_file.close()
				print("[Capture] Frame saved to captures/f10_capture_%d.acfp (%d bytes)" % [stamp, packet.size()])

		var scenario = vp.get_world_3d().scenario

		var r0 = Time.get_ticks_usec()
		var stats = renderer.render_packet(packet, scenario)
		var render_us = Time.get_ticks_usec() - r0
		last_draw_count = stats.get("draw_calls", 0)

		env.background_color = stats.get("clear_color", Color.BLACK)

		total_frames += 1
		var now_us = work_start_us
		var frame_delta_ms = 0.0
		if last_frame_time_us > 0:
			frame_delta_ms = (now_us - last_frame_time_us) / 1000.0
		last_frame_time_us = now_us

		var tick_ms = tick_us / 1000.0
		var render_ms = render_us / 1000.0
		var total_ms = frame_delta_ms
		var work_ms = (Time.get_ticks_usec() - work_start_us) / 1000.0

		# Hitch Detection (Frames > 20 ms)
		if work_ms > 20.0 or frame_delta_ms > 25.0:
			var cause = ""
			if tick_ms > 12.0:
				cause = "Tick logic hitch (%.2f ms)" % tick_ms
			elif render_ms > 12.0:
				var misses = stats.get("mesh_cache_misses", 0)
				var draws = stats.get("draw_calls", 0)
				if misses > 5:
					cause = "Mesh cache building (%d misses, %.2f ms)" % [misses, render_ms]
				elif draws > 300:
					cause = "Draw call dispatch (%d draws, %.2f ms)" % [draws, render_ms]
				else:
					cause = "RenderingServer dispatch (%.2f ms)" % render_ms
			else:
				cause = "Engine/OS scheduling delay (delta: %.2f ms, work: %.2f ms)" % [frame_delta_ms, work_ms]
			print("[HITCH] Frame %d: Total=%.2f ms (Tick=%.2f, Render=%.2f, Delta=%.2f) -> Cause: %s" % [
				total_frames, total_ms, tick_ms, render_ms, frame_delta_ms, cause
			])

		# Track history
		history_frame_ms.append(total_ms)
		history_tick_ms.append(tick_ms)
		history_render_ms.append(render_ms)
		if history_frame_ms.size() > 300:
			history_frame_ms.pop_front()
			history_tick_ms.pop_front()
			history_render_ms.pop_front()

		if total_ms > max_frame_ms: max_frame_ms = total_ms
		if tick_ms > max_tick_ms: max_tick_ms = tick_ms
		if render_ms > max_render_ms: max_render_ms = render_ms

		frame_count += 1
		var now = Time.get_ticks_msec()
		if now - last_fps_time >= 500:
			var dt = (now - last_fps_time) / 1000.0
			fps = frame_count / dt
			frame_count = 0
			last_fps_time = now

			if stats_label:
				var mem_mb = OS.get_static_memory_usage() / (1024.0 * 1024.0)
				var p50 = _percentile(history_frame_ms, 0.50)
				var p95 = _percentile(history_frame_ms, 0.95)
				var p99 = _percentile(history_frame_ms, 0.99)
				var underruns = 0
				var audio_fill = 0
				if bridge.has_method("get_audio_underruns"):
					underruns = bridge.call("get_audio_underruns")
				if bridge.has_method("get_audio_fill"):
					audio_fill = bridge.call("get_audio_fill")

				var toast_suffix = ""
				if Time.get_ticks_msec() < toast_expire_ms:
					toast_suffix = "  >>> %s <<<" % toast_message
				stats_label.text = "FPS: %.1f | Frame: %.2f ms (p50: %.2f, p95: %.2f, p99: %.2f, max: %.2f) | VSync: %s%s\nTick: %.2f ms | Render: %.2f ms | Draws: %d (Op: %d, Tr: %d, UI: %d)\nMeshCache: %d (hit: %d, miss: %d, evict: %d) | Audio: fill=%d, underruns=%d | Mem: %.1f MB" % [
					fps, total_ms, p50, p95, p99, max_frame_ms, VSYNC_NAMES[vsync_mode], toast_suffix,
					tick_ms, render_ms,
					stats.get("draw_calls", 0), stats.get("opaque_draws", 0), stats.get("transparent_draws", 0), stats.get("ui_draws", 0),
					renderer.mesh_cache.size(), stats.get("mesh_cache_hits", 0), stats.get("mesh_cache_misses", 0), stats.get("mesh_cache_evictions", 0),
					audio_fill, underruns, mem_mb
				]

		if benchmark_frames > 0:
			# Exclude the first 300 displayed frames (boot / shader warm-up).
			if total_frames > 300:
				benchmark_intervals.append(frame_delta_ms)
				if frame_delta_ms > 20.0: benchmark_slow_frames += 1
				benchmark_work.append(work_ms)
				benchmark_draws.append(stats.get("draw_calls", 0))
				benchmark_scenes[pending_scene_no] = benchmark_scenes.get(pending_scene_no, 0) + 1
				var fill = int(bridge.call("get_audio_fill"))
				benchmark_fill_min = mini(benchmark_fill_min, fill)
				benchmark_fill_max = maxi(benchmark_fill_max, fill)
			if total_frames >= benchmark_frames:
				_finish_benchmark()

func _on_frame_post_draw():
	var now = Time.get_ticks_usec()
	if benchmark_frames > 0 and total_frames > 300 and last_present_us > 0:
		benchmark_present.append((now - last_present_us) / 1000.0)
	last_present_us = now

func _finish_benchmark():
	var report = {
		"scene_override": benchmark_scene,
		"measured_scene_frames": benchmark_scenes,
		"display_hz": DisplayServer.screen_get_refresh_rate(),
		"max_fps": Engine.max_fps,
		"vsync_mode": DisplayServer.window_get_vsync_mode(),
		"frames_over_20ms": benchmark_slow_frames,
		"displayed_frames": total_frames,
		"measured_frames": benchmark_intervals.size(),
		"elapsed_seconds": (Time.get_ticks_usec() - benchmark_started_us) / 1000000.0,
		"interval_p50_ms": _percentile(benchmark_intervals, 0.50),
		"interval_p95_ms": _percentile(benchmark_intervals, 0.95),
		"interval_p99_ms": _percentile(benchmark_intervals, 0.99),
		"interval_max_ms": benchmark_intervals.max(),
		"post_draw_p50_ms": _percentile(benchmark_present, 0.50),
		"post_draw_p95_ms": _percentile(benchmark_present, 0.95),
		"post_draw_p99_ms": _percentile(benchmark_present, 0.99),
		"render_work_p50_ms": _percentile(benchmark_work, 0.50),
		"render_work_p99_ms": _percentile(benchmark_work, 0.99),
		"draws_min": benchmark_draws.min(),
		"draws_max": benchmark_draws.max(),
		"audio_underruns": bridge.call("get_audio_underruns"),
		"audio_dropped_samples": bridge.call("get_audio_dropped_samples") if bridge.has_method("get_audio_dropped_samples") else -1,
		"audio_fill_min": benchmark_fill_min,
		"audio_fill_max": benchmark_fill_max,
		"static_memory_mb": OS.get_static_memory_usage() / 1048576.0,
	}
	var output = FileAccess.open(benchmark_output, FileAccess.WRITE)
	if output:
		output.store_string(JSON.stringify(report, "\t"))
	print("[RUNTIME_BENCHMARK] ", JSON.stringify(report))
	get_tree().quit(1 if report.audio_underruns > 0 or report.audio_dropped_samples != 0 else 0)

func _exit_tree():
	game_ready = false
	if session_recording:
		_stop_session_record()
	if session_replay_file:
		session_replay_file.close()
		session_replay_file = null
	if tick_thread.is_started():
		# Consume the outstanding job before publishing the stop flag.
		done_sem.wait()
		thread_exit = true
		tick_sem.post()
		tick_thread.wait_to_finish()
	if renderer:
		renderer.cleanup()
	if bridge:
		bridge.call("shutdown_game")
		bridge = null
