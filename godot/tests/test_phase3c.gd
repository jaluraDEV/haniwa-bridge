extends Node3D

const ACFPRenderer = preload("res://renderer/acfp_renderer.gd")

func _ready():
	print("=== Running Phase 3c Test: Material & Shader Pipeline ===")

	var ext = load("res://acgc_bridge.gdextension")
	if not ClassDB.class_exists("ACGCBridge"):
		print("ERROR: ACGCBridge not in ClassDB!")
		get_tree().quit(1)
		return

	var bridge = ClassDB.instantiate("ACGCBridge")
	if not bridge:
		print("ERROR: Failed to instantiate ACGCBridge!")
		get_tree().quit(1)
		return

	print("Initializing game via bridge...")
	var ok = bridge.call("init_game", 2002, 9, 15, 12, 0, 0, 0, -1)
	if not ok:
		print("ERROR: bridge.init_game failed!")
		get_tree().quit(1)
		return

	print("Ticking 60 frames to reach stable rendering state...")
	for i in range(60):
		bridge.call("tick", 0, 0, 0, 0, 0, 0, 0)

	if not bridge.call("has_frame_packet"):
		print("ERROR: No frame packet available after 60 ticks!")
		get_tree().quit(1)
		return

	var scenario = get_world_3d().scenario
	var renderer = ACFPRenderer.new()

	# --- Frame 1 Render ---
	var packet1 = bridge.call("get_frame_packet")
	print("Retrieved Frame 1 packet (%d bytes)" % packet1.size())

	var res1 = renderer.render_packet(packet1, scenario)
	print("Frame 1 Render Result:")
	print("  Success:          ", res1.success)
	print("  Draw Calls:       ", res1.draw_calls)
	print("  Material Updates: ", res1.material_updates)
	print("  Shader Variants:  ", res1.shader_variants)
	print("  Active Instances: ", res1.active_instances)
	print("  Mesh Cache Miss:  ", res1.mesh_cache_misses)
	print("  Mesh Cache Hits:  ", res1.mesh_cache_hits)
	print("  Tex Cache Miss:   ", res1.tex_cache_misses)
	print("  Tex Cache Hits:   ", res1.tex_cache_hits)
	print("  Render Time:      %.2f ms" % res1.time_ms)

	if not res1.success:
		print("ERROR: Frame 1 render failed: ", res1.get("error", "unknown"))
		get_tree().quit(1)
		return

	if res1.draw_calls == 0 or res1.material_updates == 0:
		print("ERROR: Frame 1 had zero draw calls or material updates!")
		get_tree().quit(1)
		return

	if res1.shader_variants == 0:
		print("ERROR: Expected compiled shader variants!")
		get_tree().quit(1)
		return

	# Verify material pool state
	print("\nVerifying material pool state...")
	for idx in range(min(5, res1.active_instances)):
		var mat = renderer.material_pool[idx]
		print("  Material[%d]: RID=%s is_valid=%s" % [idx, mat, mat.is_valid()])
		if not mat.is_valid():
			print("ERROR: Material RID is invalid!")
			get_tree().quit(1)
			return

	# --- Frame 2 Render (Tick 61) ---
	print("\nTicking Frame 61 to verify pipeline reuse...")
	bridge.call("tick", 0, 0, 0, 0, 0, 0, 0)
	var packet2 = bridge.call("get_frame_packet")

	var res2 = renderer.render_packet(packet2, scenario)
	print("Frame 2 Render Result:")
	print("  Success:          ", res2.success)
	print("  Draw Calls:       ", res2.draw_calls)
	print("  Material Updates: ", res2.material_updates)
	print("  Shader Variants:  ", res2.shader_variants)
	print("  Mesh Hits:        ", res2.mesh_cache_hits)
	print("  Tex Hits:         ", res2.tex_cache_hits)
	print("  Render Time:      %.2f ms" % res2.time_ms)

	if not res2.success:
		print("ERROR: Frame 2 render failed: ", res2.get("error", "unknown"))
		get_tree().quit(1)
		return

	if res2.shader_variants != res1.shader_variants:
		print("NOTE: New shader variants compiled in frame 2: %d -> %d" % [res1.shader_variants, res2.shader_variants])

	print("\nCleaning up renderer resources...")
	renderer.cleanup()
	if renderer.mesh_cache.size() != 0 or renderer.tex_cache.size() != 0 or renderer.material_pool.size() != 0 or renderer.shader_variants.size() != 0:
		print("ERROR: Cleanup did not free all resources!")
		get_tree().quit(1)
		return

	print("=================================================================")
	print("PHASE 3c SUCCESS: Material & Shader Pipeline Verified in Godot!")
	print("Frame 1: %d draws, %d mat updates, %d shader variants, %.2f ms" % [
		res1.draw_calls, res1.material_updates, res1.shader_variants, res1.time_ms
	])
	print("Frame 2: %d draws, %d mesh hits, %d tex hits, %.2f ms" % [
		res2.draw_calls, res2.mesh_cache_hits, res2.tex_cache_hits, res2.time_ms
	])
	print("=================================================================")
	get_tree().quit(0)
