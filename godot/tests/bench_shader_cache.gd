extends Node3D

const ACFPRenderer = preload("res://renderer/acfp_renderer.gd")

func _ready():
	var start_us = Time.get_ticks_usec()
	var packet_path = "captures/scene_village_day.acfp"
	if not FileAccess.file_exists(packet_path):
		packet_path = "../captures/scene_village_day.acfp"
		
	var f = FileAccess.open(packet_path, FileAccess.READ)
	if not f:
		print("FAILED to open packet")
		get_tree().quit(1)
		return
	var data = f.get_buffer(f.get_length())
	f.close()
	
	var vp = SubViewport.new()
	vp.size = Vector2i(640, 480)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.world_3d = get_world_3d()
	add_child(vp)
	
	var cam = Camera3D.new()
	cam.current = true
	vp.add_child(cam)
	
	var scenario = vp.world_3d.scenario
	var renderer = ACFPRenderer.new()
	
	var load_us = Time.get_ticks_usec()
	var warmup_stats = renderer.warmup_shaders(scenario)
	var warmup_done_us = Time.get_ticks_usec()
	
	var render_stats = renderer.render_packet(data, scenario)
	var first_render_us = Time.get_ticks_usec()
	
	print("[BENCH] Total startup to first frame: %.2f ms" % ((first_render_us - start_us) / 1000.0))
	print("[BENCH] Shader warmup time: %.2f ms (compiled %d variants)" % [
		(warmup_done_us - load_us) / 1000.0,
		warmup_stats.get("count", 0)
	])
	print("[BENCH] First frame render_packet time: %.2f ms (draws=%d)" % [
		(first_render_us - warmup_done_us) / 1000.0,
		render_stats.get("draw_calls", 0)
	])
	
	renderer.cleanup()
	get_tree().quit(0)
