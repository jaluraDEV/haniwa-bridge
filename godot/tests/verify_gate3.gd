extends Node3D

const ACFPRenderer = preload("res://renderer/acfp_renderer.gd")

var scenes = [
	"frame_60",
	"frame_150",
	"scene_train",
	"scene_village_day",
	"scene_village_night",
	"scene_interior",
	"scene_house",
	"scene_fog"
]

func _ready():
	print("=== Running Gate 3 Verification on all 8 Scenes ===")

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
	env.adjustment_enabled = false
	camera.environment = env
	vp.add_child(camera)

	var scenario = vp.get_world_3d().scenario
	var renderer = ACFPRenderer.new()

	var results = {}

	for sc_name in scenes:
		var acfp_path = "res://../captures/%s.acfp" % sc_name
		if not FileAccess.file_exists(acfp_path):
			print("WARNING: Packet not found: ", acfp_path)
			continue

		var f = FileAccess.open(acfp_path, FileAccess.READ)
		var packet = f.get_buffer(f.get_length())
		f.close()

		var render_stats = renderer.render_packet(packet, scenario)
		env.background_color = render_stats.get("clear_color", Color.BLACK)
		print("[%s] Rendered in %.2f ms | Draws: %d | Meshes: %d" % [
			sc_name,
			render_stats.get("time_ms", 0.0),
			render_stats.get("draw_calls", 0),
			render_stats.get("active_instances", 0)
		])

		# Wait 2 frames for GPU draw
		await get_tree().process_frame
		await get_tree().process_frame

		var img = vp.get_texture().get_image()
		if img:
			var out_png = "res://../captures/godot_%s.png" % sc_name
			img.save_png(out_png)
			print("  Saved ", out_png)
		else:
			print("  ERROR: Viewport returned null image for ", sc_name)

		results[sc_name] = render_stats

	renderer.cleanup()
	print("=== Gate 3 Verification Render Finished ===")
	get_tree().quit(0)
