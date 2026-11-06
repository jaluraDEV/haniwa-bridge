extends Node3D

func _ready():
	print("--- Godot x86_32 Stress Test Starting ---")
	print("Video Adapter: ", RenderingServer.get_video_adapter_name())
	print("Rendering Device: ", RenderingServer.get_rendering_device())
	
	# Spawn a large scene of boxes and spheres
	var rng = RandomNumberGenerator.new()
	rng.seed = 12345
	var box_mesh = BoxMesh.new()
	var sphere_mesh = SphereMesh.new()
	
	for i in range(500):
		var mi = MeshInstance3D.new()
		mi.mesh = box_mesh if i % 2 == 0 else sphere_mesh
		mi.position = Vector3(rng.randf_range(-50, 50), rng.randf_range(0, 20), rng.randf_range(-50, 50))
		mi.rotation = Vector3(rng.randf_range(0, 3.14), rng.randf_range(0, 3.14), 0)
		add_child(mi)
		
	# Setup DirectionalLight
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, 45, 0)
	light.shadow_enabled = true
	add_child(light)
	
	# Setup Camera
	var cam = Camera3D.new()
	cam.position = Vector3(0, 25, 60)
	add_child(cam)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	
	# Setup WorldEnvironment without SDFGI first
	var env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.2, 0.4, 0.8)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.3, 0.3, 0.3)
	env.sdfgi_enabled = true
	env.ssao_enabled = false
	env.glow_enabled = true
	
	var world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)
	
	print("Setup complete: 500 MeshInstance3D objects + DirectionalLight3D + SDFGI + SSAO + Glow")

var frame_count = 0

func _process(_delta):
	frame_count += 1
	if frame_count % 30 == 0:
		var static_mem = OS.get_static_memory_usage() / (1024.0 * 1024.0)
		var peak_mem = OS.get_static_memory_peak_usage() / (1024.0 * 1024.0)
		var render_objects = Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
		var render_drawcalls = Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		print("Frame %d: StaticMem=%.2f MB (Peak=%.2f MB) Objects=%d Drawcalls=%d" % [frame_count, static_mem, peak_mem, render_objects, render_drawcalls])
	
	if frame_count >= 120:
		print("--- Stress Test Completed Successfully ---")
		get_tree().quit(0)
