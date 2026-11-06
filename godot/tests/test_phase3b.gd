extends Node3D

const ACFPRenderer = preload("res://renderer/acfp_renderer.gd")

func _ready():
	print("=== Running Phase 3b Test: RenderingServer Backend & Resource Caching ===")

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
	print("World3D scenario RID: ", scenario)

	var renderer = ACFPRenderer.new()

	# --- Frame 1 Render ---
	var packet1 = bridge.call("get_frame_packet")
	print("Retrieved Frame 1 packet (%d bytes)" % packet1.size())

	var res1 = renderer.render_packet(packet1, scenario)
	print("Frame 1 Render Result:")
	print("  Success:          ", res1.success)
	print("  Draw Calls:       ", res1.draw_calls)
	print("  Active Instances: ", res1.active_instances)
	print("  Mesh Cache Misses:", res1.mesh_cache_misses)
	print("  Mesh Cache Hits:  ", res1.mesh_cache_hits)
	print("  Tex Cache Misses: ", res1.tex_cache_misses)
	print("  Tex Cache Hits:   ", res1.tex_cache_hits)
	print("  Render Time:      %.2f ms" % res1.time_ms)

	if not res1.success:
		print("ERROR: Frame 1 render failed: ", res1.get("error", "unknown"))
		get_tree().quit(1)
		return

	if res1.draw_calls == 0 or res1.active_instances == 0:
		print("ERROR: Frame 1 had zero draw calls or active instances!")
		get_tree().quit(1)
		return

	if res1.mesh_cache_misses == 0 or res1.tex_cache_misses == 0:
		print("ERROR: Frame 1 expected cache misses for initial load!")
		get_tree().quit(1)
		return

	# --- Frame 2 Render (Tick 61) ---
	print("\nTicking Frame 61 to test caching across frames...")
	bridge.call("tick", 0, 0, 0, 0, 0, 0, 0)
	var packet2 = bridge.call("get_frame_packet")
	print("Retrieved Frame 2 packet (%d bytes)" % packet2.size())

	var res2 = renderer.render_packet(packet2, scenario)
	print("Frame 2 Render Result:")
	print("  Success:          ", res2.success)
	print("  Draw Calls:       ", res2.draw_calls)
	print("  Active Instances: ", res2.active_instances)
	print("  Mesh Cache Misses:", res2.mesh_cache_misses)
	print("  Mesh Cache Hits:  ", res2.mesh_cache_hits)
	print("  Tex Cache Misses: ", res2.tex_cache_misses)
	print("  Tex Cache Hits:   ", res2.tex_cache_hits)
	print("  Render Time:      %.2f ms" % res2.time_ms)

	if not res2.success:
		print("ERROR: Frame 2 render failed: ", res2.get("error", "unknown"))
		get_tree().quit(1)
		return

	if res2.mesh_cache_hits == 0:
		print("ERROR: Expected mesh cache hits on Frame 2!")
		get_tree().quit(1)
		return

	if res2.tex_cache_hits == 0:
		print("ERROR: Expected texture cache hits on Frame 2!")
		get_tree().quit(1)
		return

	# Verify instance pool state
	print("\nVerifying instance pool state...")
	for idx in range(min(5, res2.active_instances)):
		var inst = renderer.instance_pool[idx]
		print("  Instance[%d]: RID=%s is_valid=%s" % [idx, inst, inst.is_valid()])
		if not inst.is_valid():
			print("ERROR: Instance has invalid RID!")
			get_tree().quit(1)
			return

	print("\nCleaning up renderer resources...")
	renderer.cleanup()
	if renderer.mesh_cache.size() != 0 or renderer.tex_cache.size() != 0 or renderer.instance_pool.size() != 0:
		print("ERROR: Cleanup did not clear all caches!")
		get_tree().quit(1)
		return

	print("=================================================================")
	print("PHASE 3b SUCCESS: Godot RenderingServer Backend & Caching Verified!")
	print("Frame 1: %d draws, %.2f ms | Frame 2: %d draws, %d mesh hits, %d tex hits, %.2f ms" % [
		res1.draw_calls, res1.time_ms, res2.draw_calls, res2.mesh_cache_hits, res2.tex_cache_hits, res2.time_ms
	])
	print("=================================================================")
	get_tree().quit(0)
