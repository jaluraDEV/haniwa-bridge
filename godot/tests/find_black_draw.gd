extends Node3D

const ACFPRenderer = preload("res://renderer/acfp_renderer.gd")

func _ready():
	print("Finding black draw...")
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
	vp.add_child(camera)

	var renderer = ACFPRenderer.new()
	var acfp_path = "res://../captures/scene_train.acfp"
	var f = FileAccess.open(acfp_path, FileAccess.READ)
	var packet = f.get_buffer(f.get_length())
	f.close()

	for d in [1, 2, 5, 10, 20, 30, 35, 36, 37, 38]:
		renderer.render_packet(packet, vp.get_world_3d().scenario, d)
		await get_tree().process_frame
		await get_tree().process_frame
		var img = vp.get_texture().get_image()
		if img:
			img.save_png("res://../captures/draw_test_%d.png" % d)
			print("Saved draw_test_%d.png" % d)

	renderer.cleanup()
	get_tree().quit(0)
