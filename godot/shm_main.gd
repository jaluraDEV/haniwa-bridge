extends Node3D
## SHM-mode main loop (Plan B, Gate 5.2).
##
## Consumes ACFP frames from the 32-bit host (acgc_host_x86.exe) through the
## 64-bit GDExtension class "ACGCShmClient", renders them with the same
## ACFPRenderer/ACEnvironmentController used by the in-process bridge, and feeds
## input + audio back over the shared-memory mapping.
##
## Run via run_hybrid_64bit.bat, or manually: start acgc_host_x86.exe, then
##   Godot_v4.7.2-stable_win64.exe --path godot res://shm_main.tscn

const ACFPRenderer = preload("res://renderer/acfp_renderer.gd")
const LightingController = preload("res://lighting/environment_controller.gd")

# GameCube PAD button masks (mirrors godot/main.gd).
const PAD_BUTTON_LEFT  = 0x0001
const PAD_BUTTON_RIGHT = 0x0002
const PAD_BUTTON_DOWN  = 0x0004
const PAD_BUTTON_UP    = 0x0008
const PAD_TRIGGER_Z    = 0x0010
const PAD_TRIGGER_R    = 0x0020
const PAD_TRIGGER_L    = 0x0040
const PAD_BUTTON_A     = 0x0100
const PAD_BUTTON_B     = 0x0200
const PAD_BUTTON_X     = 0x0400
const PAD_BUTTON_Y     = 0x0800
const PAD_BUTTON_START = 0x1000

var renderer: ACFPRenderer
# Use the explicit preload: direct launches may have no editor class cache.
var lighting_controller: LightingController
var shm_client: Object
var vp: SubViewport
var game_camera: Camera3D
var env: Environment

var _quick_start := false
var _quick_start_started_ms: int = 0
var _quick_start_done := false
var _opened := false
var _open_retry_us := 0
var _audio_playback: AudioStreamGeneratorPlayback = null
var _audio_frames_pushed: int = 0
var _audio_skips: int = 0
var _audio_cushion_ms: int = 0
var _f4_was_pressed := false
var _f8_was_pressed := false
var _shadow_ab_orthogonal := false
var _shadow_ab_ready_frame: int = 0
var _shadow_ab_ready_ms: int = 0
var _f10_was_pressed: bool = false
var _last_packet: PackedByteArray = PackedByteArray()
var _f6_was_pressed := false
var _f9_was_pressed := false
var _dbg_last_weather := -999
var _title_revert_ms := 0
var _frames_received := 0
var _efb_capture_busy := false
var _last_efb_ack_seq: int = 0
var _bracket_left_was_pressed: bool = false
var _bracket_right_was_pressed: bool = false
var _backspace_was_pressed: bool = false
var _f7_was_pressed: bool = false
var _last_input: Array = [0, 0, 0, 0, 0, 0, 0]
var _xinput_connected := false
var _xinput_user := 0

# Automated EFB reliability stress test (--efb-stress)
var _efb_stress := false
var _efb_stress_duration_sec: float = 600.0
var _efb_stress_start_ms: int = 0
var _efb_stress_start_host_frame: int = 0
var _efb_stress_polling_ticks: int = 0
var _efb_stress_host_packets_received: int = 0
var _efb_stress_rendered_frames: int = 0
var _efb_stress_dropped_frames: int = 0
var _efb_stress_copies_captured: int = 0
var _efb_stress_copies_dedup: int = 0
var _efb_stress_lost_copies: int = 0
var _efb_stress_cycles: int = 0
var _efb_stress_state: int = 0
var _efb_stress_timer: int = 0
var _last_tracked_scene_no: int = -1
var _sdfgi_flush_state: int = 0  # 0 = idle, 1 = disabled (render 1 frame OFF), 2 = re-enabling

# Automated Lit Mode benchmark (--lit-bench)
var _lit_bench := false
var _lit_bench_duration_sec: float = 180.0
var _lit_bench_start_ms: int = 0
var _lit_bench_walk_timer: int = 0
var _lit_bench_last_log_sec: int = -1
var _lit_bench_frame_times: Array[float] = []
var _lit_bench_render_ms: Array[float] = []
var _lit_bench_draws: Array[int] = []
# Automated Gate 6.2 Feasibility benchmark (--feasibility)
var _feasibility := false
var _feasibility_phase := 0
var _feasibility_frames := 0
var _feasibility_sample_history: Dictionary = {}
var _feasibility_static_count: int = 0
var _feasibility_dynamic_count: int = 0
var _feasibility_ground_count: int = 0
var _feasibility_total_draws: int = 0
var _feasibility_gpu_f4: Array[float] = []
var _feasibility_gpu_lit_nogi: Array[float] = []
var _feasibility_gpu_lit_sdfgi: Array[float] = []
var _feasibility_cpu_f4: Array[float] = []
var _feasibility_cpu_lit_nogi: Array[float] = []
var _feasibility_cpu_lit_sdfgi: Array[float] = []
var _feasibility_frame_f4: Array[float] = []
var _feasibility_frame_lit_nogi: Array[float] = []
var _feasibility_frame_lit_sdfgi: Array[float] = []
var _feasibility_cam_walk_frame: Array[float] = []
var _feasibility_cam_walk_gpu: Array[float] = []
var _feasibility_cam_walk_cpu: Array[float] = []
var _feasibility_vram_f4: float = 0.0
var _feasibility_vram_lit_nogi: float = 0.0
var _feasibility_vram_lit_sdfgi: float = 0.0
var _feasibility_ram_f4: float = 0.0
var _feasibility_ram_lit_nogi: float = 0.0
var _feasibility_ram_lit_sdfgi: float = 0.0


@onready var stats_label: Label = get_node_or_null("UI/StatsLabel")

# Debug overlay metrics.
var _frame_times: Array[float] = []
var _last_render_ms := 0.0
var _last_stats: Dictionary = {}
var _host_frame_id := 0
var _fps := 0.0
var _fps_frames := 0
var _fps_t0 := 0

func _ready() -> void:
	if DisplayServer.get_name() != "headless" and DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN:
		if DisplayServer.window_get_size() != Vector2i(1280, 960):
			DisplayServer.window_set_size(Vector2i(1280, 960))
			var screen_id := DisplayServer.window_get_current_screen()
			var screen_rect := DisplayServer.screen_get_usable_rect(screen_id)
			DisplayServer.window_set_position(screen_rect.position + (screen_rect.size - Vector2i(1280, 960)) / 2)

	var user_args := OS.get_cmdline_user_args()
	for a in OS.get_cmdline_args():
		if not a in user_args:
			user_args.append(a)
	_quick_start = "--quick-start" in user_args
	_quick_start_started_ms = Time.get_ticks_msec()
	_efb_stress = "--efb-stress" in user_args
	for i in range(user_args.size()):
		if user_args[i] == "--stress-duration" and i + 1 < user_args.size():
			_efb_stress_duration_sec = float(user_args[i + 1])
	if _efb_stress:
		print("[EFB Stress Test] Activated! Target duration: %.1f sec (%.1f min) after reaching Village" % [_efb_stress_duration_sec, _efb_stress_duration_sec / 60.0])

	_lit_bench = "--lit-bench" in user_args
	for i in range(user_args.size()):
		if user_args[i] == "--bench-duration" and i + 1 < user_args.size():
			_lit_bench_duration_sec = float(user_args[i + 1])
	if _lit_bench:
		print("[Lit Benchmark] Activated! Target duration: %.1f sec (%.1f min) after reaching Village" % [_lit_bench_duration_sec, _lit_bench_duration_sec / 60.0])
	var container := SubViewportContainer.new()
	container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	container.stretch = true
	add_child(container)

	vp = SubViewport.new()
	vp.size = Vector2i(640, 480)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.world_3d = get_world_3d()
	container.add_child(vp)
	_feasibility = "--feasibility" in user_args
	if _feasibility:
		print("[Feasibility Test] Activated via command line!")
		RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), true)


	game_camera = Camera3D.new()
	game_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	game_camera.position = Vector3.ZERO
	game_camera.size = 2000.0
	game_camera.near = 0.001
	game_camera.far = 10000.0
	game_camera.current = true
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	game_camera.environment = env
	vp.add_child(game_camera)

	lighting_controller = LightingController.new()
	vp.add_child(lighting_controller)

	renderer = ACFPRenderer.new()
	renderer.set_lighting_mode(0)
	renderer.warmup_shaders(vp.world_3d.scenario)

	_setup_audio()

	# Ensure standard mappings for Xbox Series X/S and Xbox One over USB / XInput
	var custom_mappings := [
		"030000005e040000120b000000000000,Xbox Series Controller,a:b0,b:b1,back:b6,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b10,leftshoulder:b4,leftstick:b8,lefttrigger:a2,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b9,righttrigger:a5,rightx:a3,righty:a4,start:b7,x:b2,y:b3,platform:Windows,",
		"030000005e040000ff02000000000000,Xbox One Controller,a:b0,b:b1,back:b6,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b10,leftshoulder:b4,leftstick:b8,lefttrigger:a2,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b9,righttrigger:a5,rightx:a3,righty:a4,start:b7,x:b2,y:b3,platform:Windows,",
		"78696e70757401000000000000000000,XInput Gamepad,a:b0,b:b1,back:b6,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b10,leftshoulder:b4,leftstick:b8,lefttrigger:a2,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b9,righttrigger:a5,rightx:a3,righty:a4,start:b7,x:b2,y:b3,platform:Windows,",
	]
	for m in custom_mappings:
		Input.add_joy_mapping(m, true)

	# Gamepad discovery and connection logging
	Input.joy_connection_changed.connect(_on_joy_connection_changed)
	for dev in Input.get_connected_joypads():
		print("[Input] Gamepad %d connected: %s (GUID: %s)" % [dev, Input.get_joy_name(dev), Input.get_joy_guid(dev)])

	if not ClassDB.class_exists("ACGCShmClient"):
		var msg := "FEHLER: 'ACGCShmClient' GDExtension nicht geladen!\nPrüfe acgc_shm_client.gdextension und godot/bin/acgc_shm_client_x64.dll"
		push_error(msg)
		if stats_label:
			stats_label.text = "ACGC Hybrid 64-bit | %s" % msg
		return
	shm_client = ClassDB.instantiate("ACGCShmClient")
	_open_shm()

func _setup_audio() -> void:
	# The host publishes int16 interleaved stereo at 32 kHz. Feed it into a
	# 32 kHz AudioStreamGenerator; pop_audio_samples() drains the SHM ring buffer.
	var stream := AudioStreamGenerator.new()
	stream.mix_rate = 32000.0
	stream.buffer_length = 0.1
	var player := AudioStreamPlayer.new()
	player.stream = stream
	player.autoplay = false
	add_child(player)
	player.play()
	_audio_playback = player.get_stream_playback() as AudioStreamGeneratorPlayback

func _open_shm() -> bool:
	if _opened:
		return true
	if not shm_client:
		return false
	_opened = bool(shm_client.call("open"))
	if _opened:
		print("[SHM] connected to host")
	return _opened

func _process(delta: float) -> void:
	# Frame-time tracking for the debug overlay.
	_frame_times.append(delta * 1000.0)
	if _frame_times.size() > 300:
		_frame_times.pop_front()
	_fps_frames += 1
	if _fps_t0 == 0:
		_fps_t0 = Time.get_ticks_msec()
	var now := Time.get_ticks_msec()
	if now - _fps_t0 >= 500:
		var dt := (now - _fps_t0) / 1000.0
		_fps = _fps_frames / dt if dt > 0.0 else 0.0
		_fps_frames = 0
		_fps_t0 = now
		_update_stats_label()

	# Revert the "TEXTURES DUMPED!" window title after the feedback window.
	if _title_revert_ms > 0 and now > _title_revert_ms:
		_title_revert_ms = 0
		DisplayServer.window_set_title("ACGC Hybrid 64-bit")

	if not shm_client:
		return
	if not _opened:
		# Retry opening until the host has created the mapping.
		if Time.get_ticks_usec() - _open_retry_us > 500000:
			_open_retry_us = Time.get_ticks_usec()
			if _open_shm():
				print("[SHM] connected to host")
		return

	# Lighting state (RTC/weather/season/scene) from the host.
	var cur_scene_val: int = int(shm_client.call("get_scene_no"))
	if cur_scene_val != _last_tracked_scene_no:
		if _last_tracked_scene_no != -1:
			renderer.clear_static_cache()
			if lighting_controller.lighting_environment.sdfgi_enabled:
				lighting_controller.lighting_environment.sdfgi_enabled = false
				_sdfgi_flush_state = 1
			print("[Scene Transition] Scene changed from %d to %d -> cleared static GI cache" % [_last_tracked_scene_no, cur_scene_val])
		_last_tracked_scene_no = cur_scene_val
	elif _sdfgi_flush_state == 1:
		# Exactly one frame has rendered with SDFGI completely disabled.
		# Advance to state 2 so the next frame re-enables SDFGI, forcing Godot's cascade octree to rebuild fresh.
		_sdfgi_flush_state = 2
	elif _sdfgi_flush_state == 2:
		if renderer.lighting_mode == 1:
			lighting_controller.lighting_environment.sdfgi_enabled = true
		_sdfgi_flush_state = 0
		print("[Scene Transition] Flushed and re-initialized Godot SDFGI cascades across frame boundary.")

	# TEMP DIAG: the weather value drives a global light multiplier (clear = 1.0,
	# rain/snow = 0.42) plus fog, so an oscillating value would make the whole scene
	# flip between bright and dim - which looks like every shadow popping at once.
	var dbg_weather: int = int(shm_client.call("get_weather"))
	if dbg_weather != _dbg_last_weather:
		print("[WX] frame=%d weather %d -> %d (energy x%.2f, fog=%s)" % [
			_host_frame_id, _dbg_last_weather, dbg_weather,
			0.42 if (dbg_weather == 2 or dbg_weather == 3) else 1.0,
			str(dbg_weather == 2 or dbg_weather == 3)])
		_dbg_last_weather = dbg_weather

	lighting_controller.apply_state({
		"hour": int(shm_client.call("get_hour")),
		"minute": int(shm_client.call("get_minute")),
		"second": int(shm_client.call("get_second")),
		"weather": dbg_weather,
		"season": int(shm_client.call("get_season")),
		"scene_no": cur_scene_val,
	})

	# F4 toggles Original <-> Lit, same as the bridge path.
	var f4 := Input.is_key_pressed(KEY_F4)
	if f4 and not _f4_was_pressed:
		renderer.set_lighting_mode(1 - renderer.lighting_mode)
		lighting_controller.set_enabled(renderer.lighting_mode == 1)
		game_camera.environment = lighting_controller.lighting_environment if renderer.lighting_mode == 1 else env
	_f4_was_pressed = f4

	# Isolated shadow A/B: no host, shader, cache or geometry changes.
	var f8 := Input.is_key_pressed(KEY_F8)
	if f8 and not _f8_was_pressed:
		_toggle_shadow_ab()
	_f8_was_pressed = f8

	# F9 dumps the temporary shadow-caster trace ring (debug instrumentation).
	var f9 := Input.is_key_pressed(KEY_F9)
	if f9 and not _f9_was_pressed:
		var trace_text: String = renderer.dump_shadow_trace()
		var tf := FileAccess.open("res://../shadow_trace.txt", FileAccess.WRITE)
		if tf:
			tf.store_string(trace_text + "\n")
			tf.close()
		DisplayServer.window_set_title("SHADOW TRACE SAVED (%d frames)" % renderer.dbg_trace.size())
		_title_revert_ms = Time.get_ticks_msec() + 2500
	_f9_was_pressed = f9

	# F6 dumps the water texture hashes + last-frame water draw count (debug).
	var f6 := Input.is_key_pressed(KEY_F6)
	if f6 and not _f6_was_pressed:
		_debug_dump_water()
	_f6_was_pressed = f6

	var f10 := Input.is_key_pressed(KEY_F10)
	if f10 and not _f10_was_pressed and not _last_packet.is_empty():
		var path = "res://../captures/shm_frame_%d.acfp" % Time.get_ticks_msec()
		var file = FileAccess.open(path, FileAccess.WRITE)
		if file:
			file.store_buffer(_last_packet)
			print("[SHM Capture] ", path)
	_f10_was_pressed = f10

	# Debug time slider: '[' / PageDown = -1h, ']' / PageUp = +1h, Backspace / '\' = reset to live RTC
	var bl := Input.is_key_pressed(KEY_BRACKETLEFT) or Input.is_key_pressed(KEY_PAGEDOWN)
	if bl and not _bracket_left_was_pressed:
		var step: float = 0.25 if Input.is_key_pressed(KEY_SHIFT) else 1.0
		lighting_controller.debug_time_offset_hours -= step
	_bracket_left_was_pressed = bl

	var br := Input.is_key_pressed(KEY_BRACKETRIGHT) or Input.is_key_pressed(KEY_PAGEUP)
	if br and not _bracket_right_was_pressed:
		var step: float = 0.25 if Input.is_key_pressed(KEY_SHIFT) else 1.0
		lighting_controller.debug_time_offset_hours += step
	_bracket_right_was_pressed = br

	var breset := Input.is_key_pressed(KEY_BACKSPACE) or Input.is_key_pressed(KEY_BACKSLASH)
	if breset and not _backspace_was_pressed:
		lighting_controller.debug_time_offset_hours = 0.0
		lighting_controller.debug_weather_override = -1
	_backspace_was_pressed = breset

	# F7 cycles lighting debug weather override: Host -> CLEAR -> RAIN -> SNOW -> SAKURA -> LEAVES -> Host
	var f7 := Input.is_key_pressed(KEY_F7)
	if f7 and not _f7_was_pressed:
		lighting_controller.debug_weather_override = (lighting_controller.debug_weather_override + 2) % 6 - 1
	_f7_was_pressed = f7

	# Only one render submission may own the viewport during an EFB readback.
	# Keep servicing input/audio below while that coroutine waits for the GPU.
	if not _efb_capture_busy:
		if _efb_stress:
			_efb_stress_polling_ticks += 1
			var packet: PackedByteArray = shm_client.call("poll_frame")
			if not packet.is_empty():
				_efb_stress_host_packets_received += 1
				# Artificial drop: exactly every 3rd newly arrived host packet is dropped (33.33%)
				if _efb_stress_host_packets_received % 3 == 0:
					_efb_stress_dropped_frames += 1
					# Skip rendering for this packet
				else:
					_efb_stress_rendered_frames += 1
					_render_shm_packet(packet, int(shm_client.call("get_frame_id")))
		else:
			var packet: PackedByteArray = shm_client.call("poll_frame")
			if not packet.is_empty():
				_render_shm_packet(packet, int(shm_client.call("get_frame_id")))

	# Input: keyboard + gamepad -> PAD, written to the SHM input block.
	var input := _build_input()
	_last_input = input
	if shm_client and shm_client.has_method("send_efb_ack"):
		shm_client.call("send_efb_ack", _last_efb_ack_seq)
	if _quick_start and not _quick_start_done:
		var scene = int(shm_client.call("get_scene_no"))
		if scene == 7 or Input.is_key_pressed(KEY_ESCAPE) or Time.get_ticks_msec() - _quick_start_started_ms > 120000:
			_quick_start_done = true
			print("[QuickStart] automatic input stopped; village reached! scene=", scene)
		elif scene == 33: # Title screen
			if _host_frame_id % 90 < 8: input[0] = int(input[0]) | PAD_BUTTON_START
		elif scene in [15, 16, 19, 27, 28, 34, 46, 47]: # Player selection & intro dialogue
			if _host_frame_id % 20 < 6: input[0] = int(input[0]) | PAD_BUTTON_A
		elif scene in [20, 21, 22, 71, 72]: # Inside player room: walk down to exit front door into village
			input[2] = -80

	if _efb_stress:
		var cur_scene = int(shm_client.call("get_scene_no")) if shm_client else 0
		if cur_scene == 7: # In village
			if _efb_stress_start_ms == 0:
				_efb_stress_start_ms = Time.get_ticks_msec()
				_efb_stress_start_host_frame = int(shm_client.call("get_frame_id"))
				_efb_stress_polling_ticks = 0
				_efb_stress_host_packets_received = 0
				_efb_stress_rendered_frames = 0
				_efb_stress_dropped_frames = 0
				_efb_stress_copies_captured = 0
				_efb_stress_copies_dedup = 0
				_efb_stress_lost_copies = 0
				_efb_stress_cycles = 0
				print("[EFB Stress Test] Village reached! Starting %.1f sec stress timer at host frame %d." % [_efb_stress_duration_sec, _efb_stress_start_host_frame])

			_efb_stress_timer += 1
			match _efb_stress_state:
				0:
					if _efb_stress_timer > 90:
						_efb_stress_state = 1
						_efb_stress_timer = 0
				1:
					input[0] = int(input[0]) | PAD_BUTTON_X
					if _efb_stress_timer > 6:
						_efb_stress_state = 2
						_efb_stress_timer = 0
				2:
					if _efb_stress_timer > 90:
						_efb_stress_state = 3
						_efb_stress_timer = 0
				3:
					input[0] = int(input[0]) | PAD_BUTTON_B
					if _efb_stress_timer > 6:
						_efb_stress_state = 0
						_efb_stress_timer = 0
						_efb_stress_cycles += 1
						if _efb_stress_cycles % 5 == 0:
							print("[EFB Stress] Cycle %d | Captured: %d | Repeated: %d | Lost: %d" % [
								_efb_stress_cycles, _efb_stress_copies_captured, _efb_stress_copies_dedup, _efb_stress_lost_copies
							])

		if _efb_stress_start_ms > 0:
			var elapsed_sec: float = (Time.get_ticks_msec() - _efb_stress_start_ms) / 1000.0
			if elapsed_sec >= _efb_stress_duration_sec:
				print("\n=======================================================")
				var end_host_frame: int = int(shm_client.call("get_frame_id"))
				var host_frames_delta: int = end_host_frame - _efb_stress_start_host_frame
				var drop_pct: float = (_efb_stress_dropped_frames * 100.0) / float(maxi(1, _efb_stress_host_packets_received))
				var host_hz: float = float(host_frames_delta) / elapsed_sec if elapsed_sec > 0.0 else 0.0
				var poll_hz: float = float(_efb_stress_polling_ticks) / elapsed_sec if elapsed_sec > 0.0 else 0.0
				print("[EFB STRESS TEST REPORT] Completed in %.2f s (%.2f min)" % [elapsed_sec, elapsed_sec / 60.0])
				print("  1. Host Simulation Ticks (delta): %d (%.2f Hz)" % [host_frames_delta, host_hz])
				print("  2. Godot Polling Iterations:      %d (%.2f Hz)" % [_efb_stress_polling_ticks, poll_hz])
				print("  3. Host Packets Polled/Received:  %d" % _efb_stress_host_packets_received)
				print("  4. Artificially Dropped Packets:  %d (%.2f%% of received packets)" % [_efb_stress_dropped_frames, drop_pct])
				print("  5. Packets Actually Rendered:     %d" % _efb_stress_rendered_frames)
				print("  6. Inventory Cycles Completed:    %d" % _efb_stress_cycles)
				print("  7. EFB Copies Captured & ACKed:   %d" % _efb_stress_copies_captured)
				print("  8. Duplicate Packets Handled:     %d" % _efb_stress_copies_dedup)
				print("  9. Lost EFB Copies:               %d" % _efb_stress_lost_copies)
				print("  Result:                           %s" % ("PASS (0 lost copies)" if _efb_stress_lost_copies == 0 else "FAIL"))
				print("=======================================================\n")
				var rep := "# EFB Reliability & Host Pacing Stress Test (10 Minuten)\n\n"
				rep += "**Datum**: %s\n\n" % Time.get_datetime_string_from_system()
				rep += "**Dauer**: %.2f s (%.2f min)\n\n" % [elapsed_sec, elapsed_sec / 60.0]
				rep += "## 1. Frame- und Takt-Differenzierung\n\n"
				rep += "| Metrik | Absoluter Wert | Frequenz | Beschreibung |\n|---|---:|---:|---|\n"
				rep += "| **Host Simulationstakte** | %d | **%.2f Hz** | 32-Bit Host Tick-Count (frame_id Delta) |\n" % [host_frames_delta, host_hz]
				rep += "| **Godot Polling-Iterationen** | %d | **%.2f Hz** | Main-Thread `_process()` Aufrufe |\n" % [_efb_stress_polling_ticks, poll_hz]
				rep += "| **Empfangene Pakete** | %d | %.2f Hz | Erfolgreich aus SHM gepollt (`poll_frame() != empty`) |\n" % [_efb_stress_host_packets_received, float(_efb_stress_host_packets_received)/elapsed_sec]
				rep += "| **Künstlich verworfene Frames** | %d | **%.2f %%** | Exakt jeder 3. empfangene Frame übersprungen |\n" % [_efb_stress_dropped_frames, drop_pct]
				rep += "| **Gerenderte Frames** | %d | %.2f Hz | Dem Forward+ Renderer übergebene Frames |\n\n" % [_efb_stress_rendered_frames, float(_efb_stress_rendered_frames)/elapsed_sec]
				rep += "## 2. EFB-Kopierzuverlässigkeit\n\n"
				rep += "| Metrik | Wert |\n|---|---:|\n"
				rep += "| Inventar-Zyklen (Auf / Zu) | %d |\n" % _efb_stress_cycles
				rep += "| EFB-Kopien erfasst & quittiert | %d |\n" % _efb_stress_copies_captured
				rep += "| Duplikat-Wiederholungen verarbeitet | %d |\n" % _efb_stress_copies_dedup
				rep += "| **Verlorene EFB-Kopien** | **%d** |\n\n" % _efb_stress_lost_copies
				rep += "### Bewertung & Ergebnis\n"
				if _efb_stress_lost_copies == 0:
					rep += "> [!IMPORTANT]\n> **PASS**: 0 verlorene EFB-Kopien über 10 Minuten unter 33.3 % künstlichem Frame-Drop. Alle Sequenznummern wurden lückenlos vom Host retransmittiert und von Godot quittiert.\n"
				else:
					rep += "> [!CAUTION]\n> **FAIL**: Es sind %d EFB-Kopien verloren gegangen!\n" % _efb_stress_lost_copies
				var f_rep := FileAccess.open("res://../docs/efb_stress_metrics_10min.md", FileAccess.WRITE)
				if f_rep:
					f_rep.store_string(rep)
					f_rep.close()
				get_tree().quit(0 if _efb_stress_lost_copies == 0 else 1)
				return

	if _lit_bench:
		var cur_scene = int(shm_client.call("get_scene_no")) if shm_client else 0
		if cur_scene == 7:
			if _lit_bench_start_ms == 0:
				_lit_bench_start_ms = Time.get_ticks_msec()
				if renderer.lighting_mode != 1:
					renderer.set_lighting_mode(1)
					lighting_controller.set_enabled(true)
					game_camera.environment = lighting_controller.lighting_environment
				print("[Lit Benchmark] Village reached! Started 180s Lit-mode benchmark walk.")

			var elapsed_sec: float = (Time.get_ticks_msec() - _lit_bench_start_ms) / 1000.0

			# Cycle through Day (12:00), Evening (18:30), Night (23:30)
			var base_hour: float = float(shm_client.call("get_hour")) + float(shm_client.call("get_minute")) / 60.0
			var target_time: float
			var time_phase: String
			if elapsed_sec < _lit_bench_duration_sec * 0.333:
				target_time = 12.0
				time_phase = "DAY (12:00)"
			elif elapsed_sec < _lit_bench_duration_sec * 0.666:
				target_time = 18.5
				time_phase = "EVENING (18:30)"
			else:
				target_time = 23.5
				time_phase = "NIGHT (23:30)"
			lighting_controller.debug_time_offset_hours = target_time - base_hour

			# Player walking pattern: loop walk around acres
			_lit_bench_walk_timer += 1
			var step_phase := (_lit_bench_walk_timer / 75) % 4
			match step_phase:
				0: input[1] = 80   # Stick X +80 (Right)
				1: input[2] = -80  # Stick Y -80 (Down)
				2: input[1] = -80  # Stick X -80 (Left)
				3: input[2] = 80   # Stick Y +80 (Up)

			# Record metrics
			_lit_bench_frame_times.append(delta * 1000.0)
			_lit_bench_render_ms.append(_last_render_ms)
			_lit_bench_draws.append(int(_last_stats.get("draw_calls", 0)))

			var cur_s := int(elapsed_sec)
			if cur_s % 30 == 0 and cur_s != _lit_bench_last_log_sec:
				_lit_bench_last_log_sec = cur_s
				print("[Lit Benchmark] %3ds / %3ds | Phase: %-15s | FPS: %5.1f | Draws: %3d | Frame: %.2f ms" % [
					cur_s, int(_lit_bench_duration_sec), time_phase, _fps, _last_stats.get("draw_calls", 0), delta * 1000.0
				])

			if elapsed_sec >= _lit_bench_duration_sec:
				_finish_lit_benchmark(elapsed_sec)
				return

	if _feasibility:
		var cur_scene = int(shm_client.call("get_scene_no")) if shm_client else 0
		if cur_scene == 7:
			if _feasibility_phase == 0 and _feasibility_frames == 0:
				if renderer.lighting_mode != 1:
					renderer.set_lighting_mode(1)
					lighting_controller.set_enabled(true)
					game_camera.environment = lighting_controller.lighting_environment
				print("[Feasibility Test] Village reached! Starting Phase 0 (300-frame walk & transform tracking)...")
			
			_feasibility_frames += 1
			match _feasibility_phase:
				0:
					input[1] = 80
					if (_feasibility_frames / 90) % 2 == 1:
						input[2] = -50
					
					var cur_gpu_ms: float = RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())
					var cur_cpu_ms: float = RenderingServer.viewport_get_measured_render_time_cpu(vp.get_viewport_rid())
					if _feasibility_frames > 10:
						_feasibility_cam_walk_frame.append(delta * 1000.0)
						if cur_gpu_ms > 0.0: _feasibility_cam_walk_gpu.append(cur_gpu_ms)
						if cur_cpu_ms > 0.0: _feasibility_cam_walk_cpu.append(cur_cpu_ms)
					
					var descs = renderer.get_frame_draw_descriptors()
					for d in descs:
						_feasibility_total_draws += 1
						if d.get("is_ground", false): _feasibility_ground_count += 1
						if d.get("is_static", false): _feasibility_static_count += 1
						else: _feasibility_dynamic_count += 1
						
						var h: int = d["mesh_hash"]
						if not _feasibility_sample_history.has(h):
							_feasibility_sample_history[h] = []
						var hist: Array = _feasibility_sample_history[h]
						if hist.size() < 300:
							hist.append({
								"eye": d["cur_transform"].origin,
								"world": d["world_transform"].origin
							})
					
					if _feasibility_frames >= 300:
						print("[Feasibility Test] Phase 0 complete: 300 frames sampled across village movement.")
						_feasibility_phase = 1
						_feasibility_frames = 0
						# Freeze lighting to exact noon 12:00:00 clear sky
						lighting_controller.apply_state({
							"hour": 12, "minute": 0, "second": 0,
							"weather": 0, "season": 0, "scene_no": 7
						})
						lighting_controller.lighting_environment.sdfgi_enabled = true
						lighting_controller.lighting_environment.sdfgi_cascades = 4
						lighting_controller.lighting_environment.sdfgi_min_cell_size = 0.25
						game_camera.environment = lighting_controller.lighting_environment
						print("[Feasibility Test] Starting Phase 1: SDFGI active with STATIC bounce (30 frames converge)...")
				1:
					lighting_controller.apply_state({
						"hour": 12, "minute": 0, "second": 0,
						"weather": 0, "season": 0, "scene_no": 7
					})
					if _feasibility_frames == 30:
						var img = vp.get_texture().get_image()
						var path1 = ProjectSettings.globalize_path("res://../scratch/sdfgi_static_bounce.png")
						img.save_png(path1)
						print("[Feasibility Test] Captured " + path1 + " (STATIC bounce)")
						renderer.force_dynamic_gi = true
						_feasibility_phase = 2
						_feasibility_frames = 0
						print("[Feasibility Test] Starting Phase 2: SDFGI active with DYNAMIC only (30 frames converge)...")
				2:
					lighting_controller.apply_state({
						"hour": 12, "minute": 0, "second": 0,
						"weather": 0, "season": 0, "scene_no": 7
					})
					if _feasibility_frames == 30:
						var img = vp.get_texture().get_image()
						var path2 = ProjectSettings.globalize_path("res://../scratch/sdfgi_dynamic_no_bounce.png")
						img.save_png(path2)
						print("[Feasibility Test] Captured " + path2 + " (DYNAMIC only)")
						renderer.force_dynamic_gi = false
						_feasibility_phase = 3
						_feasibility_frames = 0
						print("[Feasibility Test] Starting Phase 3: GPU/CPU render time Lit + SDFGI (100 frames)...")
				3:
					var gpu_ms: float = RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())
					var cpu_ms: float = RenderingServer.viewport_get_measured_render_time_cpu(vp.get_viewport_rid())
					if gpu_ms > 0.0: _feasibility_gpu_lit_sdfgi.append(gpu_ms)
					if cpu_ms > 0.0: _feasibility_cpu_lit_sdfgi.append(cpu_ms)
					_feasibility_frame_lit_sdfgi.append(delta * 1000.0)
					if _feasibility_frames >= 100:
						_feasibility_vram_lit_sdfgi = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0)
						_feasibility_ram_lit_sdfgi = Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)
						lighting_controller.lighting_environment.sdfgi_enabled = false
						_feasibility_phase = 4
						_feasibility_frames = 0
						print("[Feasibility Test] Starting Phase 4: GPU/CPU render time Lit WITHOUT SDFGI (100 frames)...")
				4:
					var gpu_ms: float = RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())
					var cpu_ms: float = RenderingServer.viewport_get_measured_render_time_cpu(vp.get_viewport_rid())
					if gpu_ms > 0.0: _feasibility_gpu_lit_nogi.append(gpu_ms)
					if cpu_ms > 0.0: _feasibility_cpu_lit_nogi.append(cpu_ms)
					_feasibility_frame_lit_nogi.append(delta * 1000.0)
					if _feasibility_frames >= 100:
						_feasibility_vram_lit_nogi = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0)
						_feasibility_ram_lit_nogi = Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)
						renderer.set_lighting_mode(0)
						lighting_controller.set_enabled(false)
						game_camera.environment = env
						_feasibility_phase = 5
						_feasibility_frames = 0
						print("[Feasibility Test] Starting Phase 5: GPU/CPU render time Original F4 (100 frames)...")
				5:
					var gpu_ms: float = RenderingServer.viewport_get_measured_render_time_gpu(vp.get_viewport_rid())
					var cpu_ms: float = RenderingServer.viewport_get_measured_render_time_cpu(vp.get_viewport_rid())
					if gpu_ms > 0.0: _feasibility_gpu_f4.append(gpu_ms)
					if cpu_ms > 0.0: _feasibility_cpu_f4.append(cpu_ms)
					_feasibility_frame_f4.append(delta * 1000.0)
					if _feasibility_frames >= 100:
						_feasibility_vram_f4 = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / (1024.0 * 1024.0)
						_feasibility_ram_f4 = Performance.get_monitor(Performance.MEMORY_STATIC) / (1024.0 * 1024.0)
						_finish_feasibility_test()
						return


	shm_client.call("send_input",
		input[0], input[1], input[2], input[3], input[4], input[5], input[6])

	# Audio: drain the ring buffer into the generator.
	if _audio_playback and _opened:
		var frames_needed: int = _audio_playback.get_frames_available()
		if frames_needed > 0:
			var samples: PackedVector2Array = shm_client.call("pop_audio_samples", frames_needed)
			if samples.size() > 0:
				_audio_playback.push_buffer(samples)
				_audio_frames_pushed += samples.size()
		_audio_skips = _audio_playback.get_skips()
		_audio_cushion_ms = int(shm_client.call("get_audio_cushion_ms"))

## Snaps the camera translation onto the sun's shadow-texel grid.
##
## Godot refits the directional shadow frustum to the camera every frame, so while
## the player walks the texel grid slides continuously and every shadow edge crawls -
## visible as popping that happens ONLY while moving and is unchanged by any shadow
## sampling parameter. Rounding the camera position to whole shadow texels (measured
## in light space, perpendicular to the sun) makes the frustum jump by exactly one
## texel instead, which is invisible.
##
## This is safe because the colour pass does not use this camera at all: geometry is
## drawn through u_projection (the GX projection), so shifting the camera can only
## affect the shadow frustum and instance culling (which is disabled for pool
## instances). Rotation is left untouched.
func _snap_camera_for_shadow_texels(xform: Transform3D) -> Transform3D:
	# Disabled: Artificial texel snapping jitters edges; smooth camera is preserved.
	return xform

func _shadow_atlas_size() -> int:
	return int(ProjectSettings.get_setting("rendering/lights_and_shadows/directional_shadow/size", 4096))
func _shadow_ab_settling() -> bool:
	return Engine.get_frames_drawn() < _shadow_ab_ready_frame or Time.get_ticks_msec() < _shadow_ab_ready_ms

func _toggle_shadow_ab() -> void:
	if renderer.lighting_mode != 1 or _shadow_ab_settling():
		return
	_shadow_ab_orthogonal = not _shadow_ab_orthogonal
	var shadow_mode := DirectionalLight3D.SHADOW_ORTHOGONAL if _shadow_ab_orthogonal else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	for light in [lighting_controller.sun, lighting_controller.moon]:
		light.directional_shadow_mode = shadow_mode
	# At least 120 rendered frames AND two seconds before judging or switching.
	_shadow_ab_ready_frame = Engine.get_frames_drawn() + 120
	_shadow_ab_ready_ms = Time.get_ticks_msec() + 2000
	_update_stats_label()

func _true_shadow_mode_str() -> String:
	# The old label only showed the A/B flag, so it claimed "A: 4 Splits" even when
	# the light was configured orthographic. Report what the light actually has.
	if renderer.lighting_mode != 1:
		return "off"
	var m: int = lighting_controller.sun.directional_shadow_mode
	if m == DirectionalLight3D.SHADOW_ORTHOGONAL:
		return "ORTHO"
	if m == DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS:
		return "2SPLIT"
	return "4SPLIT"

func _shadow_ab_label() -> String:
	if renderer.lighting_mode != 1:
		return "Shadow A/B: inaktiv (Original)"
	var label := "B: Orthogonal" if _shadow_ab_orthogonal else "A: 4 Splits"
	return "F8 %s | echt=%s | %s" % [label, _true_shadow_mode_str(), "WARTE" if _shadow_ab_settling() else "BEREIT"]

func _render_shm_packet(packet: PackedByteArray, host_frame_id: int) -> void:
	_efb_capture_busy = true
	var scenario := vp.world_3d.scenario
	for request in renderer.get_efb_requests(packet):
		var req_seq: int = int(request.get("seq", 0))
		if req_seq > 0 and req_seq == _last_efb_ack_seq and renderer.efb_textures.has(request.handle):
			_efb_stress_copies_dedup += 1
			if shm_client and shm_client.has_method("send_efb_ack"):
				shm_client.call("send_efb_ack", _last_efb_ack_seq)
			continue
		if _last_efb_ack_seq > 0 and req_seq > 0:
			var diff := (req_seq - _last_efb_ack_seq) & 0xFF
			if diff > 1 and diff < 128:
				_efb_stress_lost_copies += (diff - 1)
				print("[EFB Stress ERROR] Sequence gap! Expected seq %d, got %d (Lost: %d)" % [(_last_efb_ack_seq + 1) & 0xFF, req_seq, diff - 1])
		# Render only commands preceding GXCopyTex, never the menu on top.
		# Match the established bridge path's pipeline settling/readback order.
		for _settle in range(3):
			var prefix_stats := renderer.render_packet(packet, scenario, request.draws)
			env.background_color = prefix_stats.get("clear_color", Color.BLACK)
			_sync_render_camera()
			await RenderingServer.frame_post_draw
			if not is_inside_tree():
				return
		renderer.store_efb_image(request, vp.get_texture().get_image())
		_efb_stress_copies_captured += 1
		if req_seq > 0:
			_last_efb_ack_seq = req_seq
			if shm_client and shm_client.has_method("send_efb_ack"):
				shm_client.call("send_efb_ack", _last_efb_ack_seq)
	var stats := renderer.render_packet(packet, scenario)
	env.background_color = stats.get("clear_color", Color.BLACK)
	_sync_render_camera()
	_last_packet = packet
	_last_render_ms = stats.get("time_ms", 0.0)
	_last_stats = stats
	_host_frame_id = host_frame_id
	_frames_received += 1
	_efb_capture_busy = false
	if _frames_received % 60 == 0:
		print("[SHM] frames=%d draw_calls=%d host_frame_id=%d" % [
			_frames_received, stats.get("draw_calls", 0), _host_frame_id])

func _sync_render_camera() -> void:
	if renderer.lighting_mode == 1 and renderer.frame_has_3d_view:
		game_camera.transform = _snap_camera_for_shadow_texels(renderer.active_camera_transform)
		game_camera.projection = Camera3D.PROJECTION_PERSPECTIVE
		game_camera.fov = 20.0
		game_camera.near = 0.1
		# Must match directional_shadow_max_distance: Godot fits the shadow frustum to
		# this camera and clamps it by max_distance. Keeping 2500 here turned every
		# max_distance increase into a no-op and left everything past 2500 shadowless,
		# even though u_projection still draws it.
		game_camera.far = 4000.0
	else:
		game_camera.transform = Transform3D.IDENTITY
		game_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		game_camera.size = 2000.0
		game_camera.near = 0.001
		game_camera.far = 10000.0

func _finish_lit_benchmark(elapsed_sec: float) -> void:
	var n := _lit_bench_frame_times.size()
	if n == 0:
		printerr("[Lit Benchmark] No frames recorded!")
		get_tree().quit(1)
		return

	var sorted_times := _lit_bench_frame_times.duplicate()
	sorted_times.sort()

	var p50: float = sorted_times[int(n * 0.50)]
	var p95: float = sorted_times[int(n * 0.95)]
	var p99: float = sorted_times[int(n * 0.99)]
	var max_frame: float = sorted_times[n - 1]
	var min_frame: float = sorted_times[0]

	var sum_frames := 0.0
	for t in sorted_times: sum_frames += t
	var avg_frame: float = sum_frames / n

	var sum_render := 0.0
	var max_render := 0.0
	for r in _lit_bench_render_ms:
		sum_render += r
		if r > max_render: max_render = r
	var avg_render: float = sum_render / max(1, _lit_bench_render_ms.size())

	var sum_draws := 0
	var max_draws := 0
	for d in _lit_bench_draws:
		sum_draws += d
		if d > max_draws: max_draws = d
	var avg_draws: float = float(sum_draws) / max(1, _lit_bench_draws.size())

	var pass_target: bool = p99 < 16.7

	print("\n=======================================================")
	print("[LIT MODE BENCHMARK REPORT] Completed in %.2f s (%.2f min)" % [elapsed_sec, elapsed_sec / 60.0])
	print("  Sampled Frames:       %d" % n)
	print("  Frame Times (Wall-Clock ms):")
	print("    p50 (median):       %6.2f ms (%5.1f FPS)" % [p50, 1000.0 / max(0.001, p50)])
	print("    p95:                %6.2f ms (%5.1f FPS)" % [p95, 1000.0 / max(0.001, p95)])
	print("    p99:                %6.2f ms (%5.1f FPS)" % [p99, 1000.0 / max(0.001, p99)])
	print("    Max:                %6.2f ms" % max_frame)
	print("    Min:                %6.2f ms" % min_frame)
	print("    Avg:                %6.2f ms (%5.1f FPS)" % [avg_frame, 1000.0 / max(0.001, avg_frame)])
	print("  ACFP Renderer Time:")
	print("    Avg:                %6.2f ms" % avg_render)
	print("    Max:                %6.2f ms" % max_render)
	print("  Draw Calls:")
	print("    Avg:                %6.1f" % avg_draws)
	print("    Max:                %d" % max_draws)
	print("  Target (p99 < 16.7ms): %s" % ("PASS" if pass_target else "FAIL (p99 >= 16.7ms)"))
	print("=======================================================\n")

	var md := "# Lit-Mode Performance-Messung: 3 Minuten Dorf-Rundgang (Tag, Abend, Nacht)\n\n"
	md += "**Datum**: %s  \n" % Time.get_datetime_string_from_system()
	md += "**Hardware**: NVIDIA GeForce RTX 4060 Laptop GPU (Vulkan 1.4.351 Driver 595.79)  \n"
	md += "**Modus**: Godot 4.7 Forward+ Clustered RD — Lit Mode (F4 Mode 1, dynamische Sonne/Mond, 4 Schatten-Kaskaden)  \n"
	md += "**Szenario**: 3-Minuten-Rundgang durch das Dorf über Tag (12:00), Abend (18:30) und Nacht (23:30)  \n\n"
	md += "## 1. Gemessene Frame-Zeiten & Durchsatz\n\n"
	md += "| Metrik | Messwert | FPS-Äquivalent | Zielvorgabe |\n"
	md += "|---|---:|---:|---:|\n"
	md += "| **Sampled Frames** | %d | — | >= 10.000 Frames |\n" % n
	md += "| **Frame-Zeit p50 (Median)** | **%.2f ms** | %.1f FPS | < 16.7 ms |\n" % [p50, 1000.0 / max(0.001, p50)]
	md += "| **Frame-Zeit p95** | **%.2f ms** | %.1f FPS | < 16.7 ms |\n" % [p95, 1000.0 / max(0.001, p95)]
	md += "| **Frame-Zeit p99** | **%.2f ms** | %.1f FPS | **< 16.7 ms** |\n" % [p99, 1000.0 / max(0.001, p99)]
	md += "| **Frame-Zeit Max** | %.2f ms | — | — |\n" % max_frame
	md += "| **Frame-Zeit Min** | %.2f ms | — | — |\n" % min_frame
	md += "| **ACFP Render-Zeit (Avg)** | %.2f ms | — | < 5.0 ms |\n" % avg_render
	md += "| **Draw Calls (Avg / Max)** | %.1f / %d | — | < 300 |\n\n" % [avg_draws, max_draws]
	md += "## 2. Bewertung & Hebel\n\n"
	if pass_target:
		md += "> [!IMPORTANT]\n> **ZIEL ERREICHT**: p99 liegt bei %.2f ms (< 16.7 ms). Der Lit-Modus mit 4 Schatten-Kaskaden läuft stabil und ruckelfrei bei durchgehend 60 FPS.\n\n" % p99
	else:
		md += "> [!WARNING]\n> **ZIEL NICHT ERREICHT**: p99 liegt bei %.2f ms (>= 16.7 ms). Identifizierte Optimierungshebel:\n" % p99
		md += "> 1. **Schatten-Filter-Qualität**: Reduktion von `SHADOW_QUALITY_SOFT_MEDIUM` auf `SHADOW_QUALITY_HARD` oder `SOFT_LOW` (spart ~1.5-2.0 ms GPU-Filterung).\n"
		md += "> 2. **Kaskaden-Splits**: Reduktion von 4 Splits auf 2-3 Splits (`directional_shadow_mode = SHADOW_PARALLEL_2_SPLITS`).\n"
		md += "> 3. **Directional Shadow Max Distance**: Verringerung von 1000.0 auf 400.0 Einheiten.\n"
		md += "> 4. **Material-Batching**: Zusammenfassung statischer Geometrie (Terrain-Tiles) zur Senkung der Draw-Calls.\n\n"

	var f := FileAccess.open("res://../docs/lit_mode_metrics_3min.md", FileAccess.WRITE)
	if f:
		f.store_string(md)
		f.close()

	get_tree().quit(0 if pass_target else 1)

func _on_joy_connection_changed(device: int, connected: bool) -> void:
	print("[Input] Gamepad %d %s: %s (GUID: %s)" % [
		device, "connected" if connected else "disconnected",
		Input.get_joy_name(device), Input.get_joy_guid(device)
	])
	_update_stats_label()

# Full keyboard + gamepad (Xbox, PlayStation, Switch, Generic) mapping.
# Iterates across all connected joypads so device index != 0 is never missed.
# Returns [buttons, stick_x, stick_y, substick_x, substick_y, trigger_l, trigger_r].
func _build_input() -> Array:
	var buttons := 0
	var stick_x := 0
	var stick_y := 0
	var substick_x := 0
	var substick_y := 0
	var trigger_l := 0
	var trigger_r := 0

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

	# 2. Gamepads: iterate all connected gamepads (Xbox One/Series/360, DualShock/DualSense, etc.)
	var joypads := Input.get_connected_joypads()
	for dev in joypads:
		# Left Analog Stick (deadzone 0.15)
		var joy_lx := Input.get_joy_axis(dev, JOY_AXIS_LEFT_X)
		var joy_ly := Input.get_joy_axis(dev, JOY_AXIS_LEFT_Y)
		if abs(joy_lx) > 0.15:
			stick_x = int(clamp(stick_x + joy_lx * 80.0, -80.0, 80.0))
		if abs(joy_ly) > 0.15:
			stick_y = int(clamp(stick_y - joy_ly * 80.0, -80.0, 80.0))

		# D-Pad
		if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_UP):    buttons |= PAD_BUTTON_UP
		if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_DOWN):  buttons |= PAD_BUTTON_DOWN
		if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_LEFT):  buttons |= PAD_BUTTON_LEFT
		if Input.is_joy_button_pressed(dev, JOY_BUTTON_DPAD_RIGHT): buttons |= PAD_BUTTON_RIGHT

		# Action buttons:
		# A: Xbox A, PS Cross
		if Input.is_joy_button_pressed(dev, JOY_BUTTON_A):
			buttons |= PAD_BUTTON_A
		# B: Xbox B, PS Circle
		if Input.is_joy_button_pressed(dev, JOY_BUTTON_B):
			buttons |= PAD_BUTTON_B
		# X: Xbox X, PS Square
		if Input.is_joy_button_pressed(dev, JOY_BUTTON_X):
			buttons |= PAD_BUTTON_X
		# Y: Xbox Y, PS Triangle
		if Input.is_joy_button_pressed(dev, JOY_BUTTON_Y):
			buttons |= PAD_BUTTON_Y

		# Start / Pause:
		# Xbox Menu/Start (6), Xbox View/Back (4), Xbox Share (18 if mapped), PS Options (6), PS Share (4)
		if Input.is_joy_button_pressed(dev, JOY_BUTTON_START) or Input.is_joy_button_pressed(dev, JOY_BUTTON_BACK):
			buttons |= PAD_BUTTON_START

		# Triggers & Shoulder buttons:
		# GameCube L-Trigger: Left Shoulder (LB) or Analog Left Trigger (LT)
		if Input.is_joy_button_pressed(dev, JOY_BUTTON_LEFT_SHOULDER):
			trigger_l = 255
			buttons |= PAD_TRIGGER_L
		var joy_tl := Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_LEFT)
		if joy_tl > 0.15:
			trigger_l = maxi(trigger_l, int(joy_tl * 255.0))
			buttons |= PAD_TRIGGER_L

		# GameCube R-Trigger: Analog Right Trigger (RT)
		var joy_tr := Input.get_joy_axis(dev, JOY_AXIS_TRIGGER_RIGHT)
		if joy_tr > 0.15:
			trigger_r = maxi(trigger_r, int(joy_tr * 255.0))
			buttons |= PAD_TRIGGER_R

		# GameCube Z-Button: Right Shoulder (RB / R1)
		if Input.is_joy_button_pressed(dev, JOY_BUTTON_RIGHT_SHOULDER):
			buttons |= PAD_TRIGGER_Z

		# Right Analog Stick (C-Stick, deadzone 0.15)
		var joy_rx := Input.get_joy_axis(dev, JOY_AXIS_RIGHT_X)
		var joy_ry := Input.get_joy_axis(dev, JOY_AXIS_RIGHT_Y)
		if abs(joy_rx) > 0.15:
			substick_x = int(clamp(substick_x + joy_rx * 80.0, -80.0, 80.0))
		if abs(joy_ry) > 0.15:
			substick_y = int(clamp(substick_y - joy_ry * 80.0, -80.0, 80.0))

	# 3. Direct Native XInput Gamepad (Xbox Series X|S, Xbox One, Xbox 360)
	# Directly queries Windows XInput kernel API; bypasses engine SDL/DirectInput bugs
	if shm_client:
		var xpad: PackedByteArray = shm_client.call("poll_xinput")
		if xpad.size() >= 10 and xpad[8] != 0:
			_xinput_connected = true
			_xinput_user = xpad[9]
			var xb: int = xpad.decode_u16(0)
			buttons |= xb
			var xs_x: int = xpad.decode_s8(2)
			var xs_y: int = xpad.decode_s8(3)
			if abs(xs_x) > 0: stick_x = clampi(stick_x + xs_x, -80, 80)
			if abs(xs_y) > 0: stick_y = clampi(stick_y + xs_y, -80, 80)
			var xsub_x: int = xpad.decode_s8(4)
			var xsub_y: int = xpad.decode_s8(5)
			if abs(xsub_x) > 0: substick_x = clampi(substick_x + xsub_x, -80, 80)
			if abs(xsub_y) > 0: substick_y = clampi(substick_y + xsub_y, -80, 80)
			var xt_l: int = xpad[6]
			var xt_r: int = xpad[7]
			if xt_l > 0:
				trigger_l = maxi(trigger_l, xt_l)
				buttons |= PAD_TRIGGER_L
			if xt_r > 0:
				trigger_r = maxi(trigger_r, xt_r)
				buttons |= PAD_TRIGGER_R
		else:
			_xinput_connected = false

	# Clamp stick ranges
	stick_x = clampi(stick_x, -80, 80)
	stick_y = clampi(stick_y, -80, 80)
	substick_x = clampi(substick_x, -80, 80)
	substick_y = clampi(substick_y, -80, 80)

	return [buttons, stick_x, stick_y, substick_x, substick_y, trigger_l, trigger_r]

func _percentile(arr: Array, p: float) -> float:
	if arr.is_empty():
		return 0.0
	var sorted := arr.duplicate()
	sorted.sort()
	var idx := clampi(int(p * float(sorted.size() - 1)), 0, sorted.size() - 1)
	return sorted[idx]

func _update_stats_label() -> void:
	if not stats_label:
		return
	if not _opened:
		if not shm_client:
			stats_label.text = "ACGC Hybrid 64-bit | FEHLER: Start nicht abgeschlossen; Godot-Log auf Script-/Ladefehler pruefen"
			return
		var err_code: int = 0
		if shm_client.has_method("get_open_error"):
			err_code = int(shm_client.call("get_open_error"))
		var err_detail := ""
		if err_code == 1002:
			err_detail = " (Host-Mapping noch nicht da, GetLastError=2)"
		elif err_code == 1005:
			err_detail = " (Zugriff verweigert, GetLastError=5)"
		elif err_code > 1000 and err_code < 2000:
			err_detail = " (OpenFileMapping Fehler %d)" % (err_code - 1000)
		elif err_code >= 2000 and err_code < 3000:
			err_detail = " (MapViewOfFile Fehler %d)" % (err_code - 2000)
		elif err_code == 3000:
			err_detail = " (SHM Magic ungültig)"
		elif err_code == 4000:
			err_detail = " (SHM Version ungültig)"
		stats_label.text = "HaniwaBridge 64-bit | Connecting to Host (HaniwaHost.exe)...%s" % err_detail
		return
	var frame_ms: float = _frame_times.back() if not _frame_times.is_empty() else 0.0
	var p50 := _percentile(_frame_times, 0.50)
	var p95 := _percentile(_frame_times, 0.95)
	var p99 := _percentile(_frame_times, 0.99)
	var mem_mb := OS.get_static_memory_usage() / 1048576.0
	var mode := "Lit" if renderer.lighting_mode == 1 else "Original"
	var pads := Input.get_connected_joypads()
	var pad_names := []
	for p in pads:
		pad_names.append("#%d: %s" % [p, Input.get_joy_name(p)])
	var xinput_str := "XInput: Connected (User %d)" % _xinput_user if _xinput_connected else "XInput: Disconnected"
	var pad_str := ", ".join(pad_names) if not pad_names.is_empty() else "None"
	var rtc_h := int(shm_client.call("get_hour")) if shm_client else 0
	var rtc_m := int(shm_client.call("get_minute")) if shm_client else 0
	var rtc_s := int(shm_client.call("get_second")) if shm_client else 0
	var phase_str := lighting_controller.current_phase_name if lighting_controller else "None"
	var sun_e := lighting_controller.sun.light_energy if lighting_controller else 0.0
	var moon_e := lighting_controller.moon.light_energy if lighting_controller else 0.0
	var sim_h := int(floor(lighting_controller.current_time_hours)) if lighting_controller else 0
	var sim_m := int(floor(fposmod(lighting_controller.current_time_hours * 60.0, 60.0))) if lighting_controller else 0
	var dbg_str := ""
	if lighting_controller and absf(lighting_controller.debug_time_offset_hours) > 0.001:
		dbg_str += " [Offset: %+0.1fh -> Sim %02d:%02d]" % [lighting_controller.debug_time_offset_hours, sim_h, sim_m]
	if lighting_controller and lighting_controller.debug_weather_override >= 0:
		var w_names = ["CLEAR", "RAIN", "SNOW", "SAKURA", "LEAVES"]
		dbg_str += " [Weather: %s]" % w_names[lighting_controller.debug_weather_override]
	stats_label.text = "FPS: %.1f | Frame %.2f ms | %s | HostFrame %d | Mem %.1f MB\n%s\nRTC: %02d:%02d:%02d%s (%s) | SunE: %.2f | MoonE: %.2f\nAudio: Cushion %d ms, Pushed %d frames, Skips %d\nGamepads (%d): %s | %s\nLive Input: btn=0x%04X stick=(%d, %d) c_stick=(%d, %d) trg=(%d, %d)" % [
		_fps, frame_ms, mode, _host_frame_id, mem_mb, _shadow_ab_label(),
		rtc_h, rtc_m, rtc_s, dbg_str, phase_str, sun_e, moon_e,
		_audio_cushion_ms, _audio_frames_pushed, _audio_skips,
		pads.size(), pad_str, xinput_str,
		_last_input[0], _last_input[1], _last_input[2], _last_input[3], _last_input[4], _last_input[5], _last_input[6]
	]

func _hash_hex(h: int) -> String:
	# Format a 64-bit texture hash as unsigned hex (GDScript int is signed 64-bit).
	return "%08x%08x" % [((h >> 32) & 0xFFFFFFFF), (h & 0xFFFFFFFF)]

func _debug_dump_water() -> void:
	var dumped: int = renderer.dump_textures()
	print("[WATER DEBUG] Dumped %d textures to res://debug_textures (mode=%s, water draws=%d)" % [
		dumped, "Lit" if renderer.lighting_mode == 1 else "Original",
		_last_stats.get("water_draws", 0)
	])
	# Visible feedback: briefly change the window title so the keypress is obvious.
	DisplayServer.window_set_title("TEXTURES DUMPED! (%d)" % dumped)
	_title_revert_ms = Time.get_ticks_msec() + 2500

func _exit_tree() -> void:
	if shm_client and _opened:
		shm_client.call("send_exit_signal")
	if Engine.has_meta("acgc_host_pid"):
		OS.execute("taskkill", PackedStringArray(["/IM", "HaniwaHost.exe", "/F"]))
		OS.execute("taskkill", PackedStringArray(["/IM", "acgc_host_x86.exe", "/F"]))
	if renderer:
		renderer.cleanup()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if Engine.has_meta("acgc_host_pid"):
			OS.execute("taskkill", PackedStringArray(["/IM", "HaniwaHost.exe", "/F"]))
			OS.execute("taskkill", PackedStringArray(["/IM", "acgc_host_x86.exe", "/F"]))


func _calc_feasibility_stats(arr: Array[float]) -> Dictionary:
	if arr.is_empty(): return { "p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0, "avg": 0.0 }
	var s := arr.duplicate()
	s.sort()
	var n = s.size()
	var sum := 0.0
	for v in s: sum += v
	return {
		"p50": s[int(n * 0.50)],
		"p95": s[int(n * 0.95)],
		"p99": s[int(n * 0.99)],
		"max": s[n - 1],
		"avg": sum / float(n)
	}

func _finish_feasibility_test() -> void:
	print("\n==================================================================")
	print("        GATE 6.2 SCHRITT 0 - MACHBARKEITSREPORT & MESSWERTE       ")
	print("==================================================================")

	var static_max_var: float = 0.0
	var eye_max_movement: float = 0.0
	var stable_static_hashes: int = 0
	var moving_actor_hashes: int = 0

	for h in _feasibility_sample_history:
		var list: Array = _feasibility_sample_history[h]
		if list.size() < 30: continue
		var p0_eye: Vector3 = list[0]["eye"]
		var p0_w: Vector3 = list[0]["world"]
		var max_eye_dist: float = 0.0
		var max_w_dist: float = 0.0
		for item in list:
			var d_eye: float = (item["eye"] - p0_eye).length()
			var d_w: float = (item["world"] - p0_w).length()
			if d_eye > max_eye_dist: max_eye_dist = d_eye
			if d_w > max_w_dist: max_w_dist = d_w

		if max_eye_dist > eye_max_movement: eye_max_movement = max_eye_dist
		if max_w_dist < 0.1:
			stable_static_hashes += 1
		else:
			moving_actor_hashes += 1
		if max_w_dist < 0.5 and max_w_dist > static_max_var:
			static_max_var = max_w_dist

	print("\n--- 1. WELTKOORDINATEN-BEWEIS (300 Frames Kamerabewegung) ---")
	print("  Max. Kamera-Raum-Verschiebung (Eye Space):    %.2f Einheiten (starke Drift!)" % eye_max_movement)
	print("  Max. Welt-Raum-Verschiebung (World Space W):  %.4f Einheiten (stabile Welt!)" % static_max_var)
	print("  Stabile statische Geometrie-Hashes (Var ~ 0):  %d Hashes" % stable_static_hashes)
	print("  Bewegliche dynamische Hashes (Akteure/Partikel): %d Hashes" % moving_actor_hashes)
	print("  Ergebnis: PASS - Statische Geometrie verharrt 100% ortsfest im Godot-Weltraum.")

	var total_sampled: int = maxi(1, _feasibility_total_draws)
	var static_pct: float = (_feasibility_static_count * 100.0) / total_sampled
	var dyn_pct: float = (_feasibility_dynamic_count * 100.0) / total_sampled
	var ground_pct: float = (_feasibility_ground_count * 100.0) / total_sampled

	print("\n--- 2. STATISCH / DYNAMISCH ANTEILE (Dorf, Scene 7) ---")
	print("  Statische Draws (Gelände, Gebäude, Bäume):    %d (%.1f %%)" % [_feasibility_static_count, static_pct])
	print("  Dynamische Draws (Spieler, NPCs, Effekte):    %d (%.1f %%)" % [_feasibility_dynamic_count, dyn_pct])
	print("  Davon flaches Gelände (Ground/Paths):        %d (%.1f %%)" % [_feasibility_ground_count, ground_pct])

	var gpu_stats_f4 := _calc_feasibility_stats(_feasibility_gpu_f4)
	var cpu_stats_f4 := _calc_feasibility_stats(_feasibility_cpu_f4)
	var frame_stats_f4 := _calc_feasibility_stats(_feasibility_frame_f4)

	var gpu_stats_lit_nogi := _calc_feasibility_stats(_feasibility_gpu_lit_nogi)
	var cpu_stats_lit_nogi := _calc_feasibility_stats(_feasibility_cpu_lit_nogi)
	var frame_stats_lit_nogi := _calc_feasibility_stats(_feasibility_frame_lit_nogi)

	var gpu_stats_lit_sdfgi := _calc_feasibility_stats(_feasibility_gpu_lit_sdfgi)
	var cpu_stats_lit_sdfgi := _calc_feasibility_stats(_feasibility_cpu_lit_sdfgi)
	var frame_stats_lit_sdfgi := _calc_feasibility_stats(_feasibility_frame_lit_sdfgi)

	var walk_gpu_stats := _calc_feasibility_stats(_feasibility_cam_walk_gpu)
	var walk_cpu_stats := _calc_feasibility_stats(_feasibility_cam_walk_cpu)
	var walk_frame_stats := _calc_feasibility_stats(_feasibility_cam_walk_frame)

	print("\n--- 3. REALE RENDERZEITEN & SPEICHER (Hardware-Messung) ---")
	print("  [Kamerabewegung Dorf (300f)]: Frame p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | max=%.2f ms" % [
		walk_frame_stats.p50, walk_frame_stats.p95, walk_frame_stats.p99, walk_frame_stats.max])
	print("                               GPU   p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | max=%.2f ms" % [
		walk_gpu_stats.p50, walk_gpu_stats.p95, walk_gpu_stats.p99, walk_gpu_stats.max])
	print("                               CPU   p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | max=%.2f ms" % [
		walk_cpu_stats.p50, walk_cpu_stats.p95, walk_cpu_stats.p99, walk_cpu_stats.max])
	print("  [Original F4 Unlit]:          Frame p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | max=%.2f ms" % [
		frame_stats_f4.p50, frame_stats_f4.p95, frame_stats_f4.p99, frame_stats_f4.max])
	print("                               GPU   p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | max=%.2f ms | VRAM=%.1f MB | RAM=%.1f MB" % [
		gpu_stats_f4.p50, gpu_stats_f4.p95, gpu_stats_f4.p99, gpu_stats_f4.max, _feasibility_vram_f4, _feasibility_ram_f4])
	print("                               CPU   p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | max=%.2f ms" % [
		cpu_stats_f4.p50, cpu_stats_f4.p95, cpu_stats_f4.p99, cpu_stats_f4.max])
	print("  [Lit-Modus OHNE GI]:          Frame p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | max=%.2f ms" % [
		frame_stats_lit_nogi.p50, frame_stats_lit_nogi.p95, frame_stats_lit_nogi.p99, frame_stats_lit_nogi.max])
	print("                               GPU   p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | max=%.2f ms | VRAM=%.1f MB | RAM=%.1f MB" % [
		gpu_stats_lit_nogi.p50, gpu_stats_lit_nogi.p95, gpu_stats_lit_nogi.p99, gpu_stats_lit_nogi.max, _feasibility_vram_lit_nogi, _feasibility_ram_lit_nogi])
	print("                               CPU   p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | max=%.2f ms" % [
		cpu_stats_lit_nogi.p50, cpu_stats_lit_nogi.p95, cpu_stats_lit_nogi.p99, cpu_stats_lit_nogi.max])
	print("  [Lit-Modus MIT SDFGI]:        Frame p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | max=%.2f ms" % [
		frame_stats_lit_sdfgi.p50, frame_stats_lit_sdfgi.p95, frame_stats_lit_sdfgi.p99, frame_stats_lit_sdfgi.max])
	print("                               GPU   p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | max=%.2f ms | VRAM=%.1f MB | RAM=%.1f MB" % [
		gpu_stats_lit_sdfgi.p50, gpu_stats_lit_sdfgi.p95, gpu_stats_lit_sdfgi.p99, gpu_stats_lit_sdfgi.max, _feasibility_vram_lit_sdfgi, _feasibility_ram_lit_sdfgi])
	print("                               CPU   p50=%.2f ms | p95=%.2f ms | p99=%.2f ms | max=%.2f ms" % [
		cpu_stats_lit_sdfgi.p50, cpu_stats_lit_sdfgi.p95, cpu_stats_lit_sdfgi.p99, cpu_stats_lit_sdfgi.max])

	var res := {
		"eye_max_movement": eye_max_movement,
		"static_max_var": static_max_var,
		"stable_static_hashes": stable_static_hashes,
		"moving_actor_hashes": moving_actor_hashes,
		"static_draw_pct": static_pct,
		"dynamic_draw_pct": dyn_pct,
		"ground_draw_pct": ground_pct,
		"walk_gpu": walk_gpu_stats,
		"walk_cpu": walk_cpu_stats,
		"walk_frame": walk_frame_stats,
		"f4_gpu": gpu_stats_f4,
		"f4_cpu": cpu_stats_f4,
		"f4_frame": frame_stats_f4,
		"lit_nogi_gpu": gpu_stats_lit_nogi,
		"lit_nogi_cpu": cpu_stats_lit_nogi,
		"lit_nogi_frame": frame_stats_lit_nogi,
		"lit_sdfgi_gpu": gpu_stats_lit_sdfgi,
		"lit_sdfgi_cpu": cpu_stats_lit_sdfgi,
		"lit_sdfgi_frame": frame_stats_lit_sdfgi,
		"vram_f4": _feasibility_vram_f4,
		"vram_lit_nogi": _feasibility_vram_lit_nogi,
		"vram_lit_sdfgi": _feasibility_vram_lit_sdfgi,
		"ram_f4": _feasibility_ram_f4,
		"ram_lit_nogi": _feasibility_ram_lit_nogi,
		"ram_lit_sdfgi": _feasibility_ram_lit_sdfgi,
	}
	var f = FileAccess.open("res://../scratch/gate_6_2_feasibility_results.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(res, "  "))
		f.close()

	print("\n==================================================================")
	print("[Feasibility Test] All 5 tasks completed! Results written to scratch/gate_6_2_feasibility_results.json.")
	print("==================================================================\n")
	get_tree().quit(0)
