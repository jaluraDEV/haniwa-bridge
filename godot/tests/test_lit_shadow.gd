extends Node

# Throwaway validation: compile the lit shader and exercise the directional
# shadow pass with the real (non-headless) renderer. Not part of the game.

const ACFPRenderer = preload("res://renderer/acfp_renderer.gd")

func _ready():
	var vp := SubViewport.new()
	vp.size = Vector2i(640, 480)
	vp.world_3d = World3D.new()
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(vp)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.position = Vector3.ZERO
	camera.size = 2000.0
	camera.near = 0.001
	camera.far = 10000.0
	camera.current = true
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	camera.environment = env
	vp.add_child(camera)

	# Directional light with shadows to force the shadow pass to compile.
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.rotation = Vector3(deg_to_rad(-45.0), deg_to_rad(-35.0), 0.0)
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.directional_shadow_max_distance = 1000.0
	vp.add_child(sun)

	var renderer = ACFPRenderer.new()
	renderer.set_lighting_mode(1)

	var packet = FileAccess.get_file_as_bytes("res://../captures/scene_village_day.acfp")
	if packet.is_empty():
		printerr("[LIT_SHADOW] capture missing")
		get_tree().quit(2)
		return

	var scenario = vp.world_3d.scenario
	var frames := 12
	var stats: Dictionary = {}
	for i in range(frames):
		stats = renderer.render_packet(packet, scenario)
		env.background_color = stats.get("clear_color", Color.BLACK)
		await RenderingServer.frame_post_draw
	renderer.cleanup()
	print("[LIT_SHADOW] rendered %d frames, draw_calls=%d, shader_variants=%d" % [frames, stats.get("draw_calls", 0), stats.get("shader_variants", 0)])
	get_tree().quit(0)
