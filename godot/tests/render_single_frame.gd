extends Node3D

const ACFPRenderer = preload("res://renderer/acfp_renderer.gd")

func _ready():
	var args = OS.get_cmdline_user_args()
	var packet_path = ""
	var output_path = ""
	var max_draws = -1
	var debug_color = false

	var i = 0
	while i < args.size():
		var arg = args[i]
		if arg == "--packet" and i + 1 < args.size():
			packet_path = args[i + 1]
			i += 2
		elif arg == "--output" and i + 1 < args.size():
			output_path = args[i + 1]
			i += 2
		elif arg == "--max-draws" and i + 1 < args.size():
			max_draws = int(args[i + 1])
			i += 2
		elif arg == "--debug-color":
			debug_color = true
			i += 1
		else:
			i += 1

	if packet_path.is_empty():
		printerr("ERROR: --packet argument required")
		get_tree().quit(1)
		return

	if not FileAccess.file_exists(packet_path):
		printerr("ERROR: Packet file does not exist: ", packet_path)
		get_tree().quit(1)
		return

	var f = FileAccess.open(packet_path, FileAccess.READ)
	var packet_data = f.get_buffer(f.get_length())
	f.close()

	var vp = SubViewport.new()
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

	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.glow_enabled = false
	env.ssr_enabled = false
	env.ssao_enabled = false
	env.sdfgi_enabled = false
	camera.environment = env
	vp.add_child(camera)

	var scenario = vp.get_world_3d().scenario
	var renderer = ACFPRenderer.new()
	var stats = renderer.render_packet(packet_data, scenario, max_draws, debug_color)
	env.background_color = stats.get("clear_color", Color.BLACK)

	# Resubmit like the live loop while shader pipelines settle; this is a
	# correctness snapshot, not a runtime performance benchmark.
	for _frame in range(16):
		renderer.render_packet(packet_data, scenario, max_draws, debug_color)
		await RenderingServer.frame_post_draw

	var img = vp.get_texture().get_image()
	if img and not output_path.is_empty():
		print("[Godot] Image format: %d (FORMAT_RGBA8=%d)" % [img.get_format(), Image.FORMAT_RGBA8])
		img.save_png(output_path)
		print("[Godot] Saved image to: %s (Draws: %d, Time: %.2f ms)" % [output_path, stats.get("draw_calls", 0), stats.get("time_ms", 0.0)])
	elif not img:
		printerr("[Godot] ERROR: Viewport returned null image")

	renderer.cleanup()
	get_tree().quit(0)
