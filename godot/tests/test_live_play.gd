extends Node3D

const ACFPRenderer = preload("res://renderer/acfp_renderer.gd")

var bridge: Object
var renderer: ACFPRenderer
var vp: SubViewport
var env: Environment

const PAD_BUTTON_A     = 0x0100
const PAD_BUTTON_B     = 0x0200
const PAD_BUTTON_START = 0x1000

var target_ticks = 1200
var current_tick = 0
var frame_times = []
var peak_memory_mb = 0.0

func _ready():
	print("=== Phase 3e Verification: Live Playback & Performance ===")

	vp = SubViewport.new()
	vp.size = Vector2i(640, 480)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.world_3d = get_world_3d()
	add_child(vp)

	var camera = Camera3D.new()
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

	renderer = ACFPRenderer.new()

	var ext = load("res://acgc_bridge.gdextension")
	if not ClassDB.class_exists("ACGCBridge"):
		print("ERROR: ACGCBridge not registered in ClassDB!")
		get_tree().quit(1)
		return

	bridge = ClassDB.instantiate("ACGCBridge")
	var ok = bridge.call("init_game", 2002, 9, 15, 12, 0, 0, 0, -1)
	if not ok:
		print("ERROR: bridge.init_game failed!")
		get_tree().quit(1)
		return
	print("Game initialized successfully! Running 600 ticks...")

func _physics_process(delta):
	if current_tick >= target_ticks:
		_finish_test()
		return

	# Input: advance title screen and start game
	var buttons = 0
	if (current_tick >= 120 and current_tick <= 125) or (current_tick >= 240 and current_tick <= 245):
		buttons |= PAD_BUTTON_START
	if (current_tick >= 360 and current_tick <= 365) or (current_tick >= 480 and current_tick <= 485) or (current_tick >= 600 and current_tick <= 605) or (current_tick >= 720 and current_tick <= 725):
		buttons |= PAD_BUTTON_A

	var t0 = Time.get_ticks_usec()
	bridge.call("tick", buttons, 0, 0, 0, 0, 0, 0)
	var tick_time_ms = (Time.get_ticks_usec() - t0) / 1000.0

	if bridge.call("has_frame_packet"):
		var packet = bridge.call("get_frame_packet")
		var scenario = vp.get_world_3d().scenario

		var r0 = Time.get_ticks_usec()
		var stats = renderer.render_packet(packet, scenario)
		var render_time_ms = (Time.get_ticks_usec() - r0) / 1000.0

		var total_frame_ms = tick_time_ms + render_time_ms
		frame_times.append(total_frame_ms)

		env.background_color = stats.get("clear_color", Color.BLACK)

		if current_tick in [60, 150, 300, 450, 600, 800, 1000, 1200]:
			var img = vp.get_texture().get_image()
			if img:
				var out_path = "res://../captures/live_tick_%d.png" % current_tick
				img.save_png(out_path)
				print("Tick %d: SceneMode=%d Draws=%d MeshesInCache=%d TotalTime=%.2f ms (Tick=%.2f, Render=%.2f) -> Saved %s" % [
					current_tick,
					bridge.call("get_scene_mode"),
					stats.get("draw_calls", 0),
					renderer.mesh_cache.size(),
					total_frame_ms,
					tick_time_ms,
					render_time_ms,
					out_path
				])

	current_tick += 1

func _finish_test():
	set_physics_process(false)
	var avg_ms = 0.0
	var max_ms = 0.0
	for t in frame_times:
		avg_ms += t
		if t > max_ms: max_ms = t
	if frame_times.size() > 0:
		avg_ms /= frame_times.size()

	var mem_bytes = OS.get_static_memory_usage()
	var mem_mb = mem_bytes / (1024.0 * 1024.0)

	print("=== Live Playback Summary ===")
	print("  Total Frames Processed: ", frame_times.size())
	print("  Average Frame Time:     %.2f ms (Budget: 16.67 ms, FPS: %.1f)" % [avg_ms, 1000.0 / max(avg_ms, 0.001)])
	print("  Worst Frame Time:       %.2f ms" % max_ms)
	print("  Godot Static Memory:    %.2f MB" % mem_mb)
	print("  Active Shader Variants: ", renderer.shader_variants.size())
	print("  Mesh Cache Size:        ", renderer.mesh_cache.size())
	print("  Texture Cache Size:     ", renderer.tex_cache.size())

	renderer.cleanup()
	print("=== Test Complete. Quitting... ===")
	get_tree().quit(0)
