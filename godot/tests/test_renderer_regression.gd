extends Node

# Pass --baseline <absolute path to the previous renderer script>.
# Uses only local captures; no images or game assets are written to the repo.
const CurrentRenderer = preload("res://renderer/acfp_renderer.gd")
const SCENES = ["frame_60", "frame_150", "scene_train", "scene_village_day",
	"scene_village_night", "scene_interior", "scene_house", "scene_fog",
	"scene_train_door", "scene_path", "scene_keyboard", "scene_station", "scene_tom_nook"]

func _ready():
	var args = OS.get_cmdline_user_args()
	var baseline_path = ""
	for i in range(args.size() - 1):
		if args[i] == "--baseline": baseline_path = args[i + 1]
	var baseline = load(baseline_path)
	if baseline == null:
		get_tree().quit(1)
		return
	var renderers = [baseline.new(), CurrentRenderer.new()]
	var views: Array[SubViewport] = []
	var environments: Array[Environment] = []
	for renderer in renderers:
		var vp = SubViewport.new()
		vp.size = Vector2i(640, 480)
		vp.world_3d = World3D.new()
		vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(vp)
		var camera = Camera3D.new()
		camera.projection = Camera3D.PROJECTION_ORTHOGONAL
		camera.size = 2000.0
		camera.near = 0.001
		camera.far = 10000.0
		camera.current = true
		var env = Environment.new()
		env.background_mode = Environment.BG_COLOR
		env.ambient_light_source = Environment.AMBIENT_SOURCE_DISABLED
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		camera.environment = env
		vp.add_child(camera)
		views.append(vp)
		environments.append(env)
	var failures = 0
	var evictions = 0
	# Revisit scenes after cache pressure, including transitions to fewer draws.
	for cycle in range(3):
		for scene in SCENES:
			var packet = FileAccess.get_file_as_bytes("res://../captures/%s.acfp" % scene)
			if packet.is_empty():
				failures += 1
				continue
			# Distinct resource IDs with identical geometry force real eviction.
			var vbo_table = packet.decode_u32(52)
			for vbo in range(packet.decode_u32(56)):
				var hash_offset = vbo_table + vbo * 28 + 4
				packet.encode_u64(hash_offset, packet.decode_u64(hash_offset) ^ (cycle << 40))
			# Keep frame IDs unique too: stale-frame eviction uses this stamp.
			packet.encode_u32(8, cycle * SCENES.size() + SCENES.find(scene) + 1)
			for i in range(2):
				var stats = renderers[i].render_packet(packet, views[i].world_3d.scenario)
				environments[i].background_color = stats.get("clear_color", Color.BLACK)
				if i == 1: evictions += stats.get("mesh_cache_evictions", 0)
			await RenderingServer.frame_post_draw
			var before = views[0].get_texture().get_image().get_data()
			var after = views[1].get_texture().get_image().get_data()
			var identical = before == after
			if not identical: failures += 1
			print("[RENDER_REGRESSION] cycle=%d scene=%s identical=%s" % [cycle, scene, identical])
	for renderer in renderers: renderer.cleanup()
	print("[RENDER_REGRESSION] failures=%d mesh_evictions=%d" % [failures, evictions])
	get_tree().quit(0 if failures == 0 and evictions > 0 else 1)
