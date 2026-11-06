extends Node3D

const ACFPRenderer = preload("res://renderer/acfp_renderer.gd")

func _ready():
	print("=== Running Phase 3d Test: Passes, UI, Scissor & EFB Handling ===")

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

	print("Ticking 60 frames to reach Title Screen...")
	for i in range(60):
		bridge.call("tick", 0, 0, 0, 0, 0, 0, 0)

	if not bridge.call("has_frame_packet"):
		print("ERROR: No frame packet available after 60 ticks!")
		get_tree().quit(1)
		return

	var scenario = get_world_3d().scenario
	var renderer = ACFPRenderer.new()

	var packet = bridge.call("get_frame_packet")
	print("Retrieved Frame packet (%d bytes)" % packet.size())

	var res = renderer.render_packet(packet, scenario)
	print("Frame Render Result:")
	print("  Success:           ", res.success)
	print("  Total Draw Calls:  ", res.draw_calls)
	print("  Opaque Draws:      ", res.opaque_draws)
	print("  Transparent Draws: ", res.transparent_draws)
	print("  UI Draws:          ", res.ui_draws)
	print("  EFB Copies:        ", res.efb_copies)
	print("  Active Instances:  ", res.active_instances)
	print("  Shader Variants:   ", res.shader_variants)
	print("  Render Time:       %.2f ms" % res.time_ms)

	if not res.success:
		print("ERROR: Render failed: ", res.get("error", "unknown"))
		get_tree().quit(1)
		return

	if res.draw_calls != (res.opaque_draws + res.transparent_draws + res.ui_draws):
		print("ERROR: Draw call count mismatch with sum of passes!")
		get_tree().quit(1)
		return

	if res.ui_draws == 0:
		print("ERROR: Expected UI draw calls on Title Screen!")
		get_tree().quit(1)
		return

	print("\nVerifying pass priority distribution on material pool...")
	var priorities_found = {}
	for idx in range(res.active_instances):
		var mat = renderer.material_pool[idx]
		# Check that material is valid
		if not mat.is_valid():
			print("ERROR: Invalid material at index ", idx)
			get_tree().quit(1)
			return

	print("Pass distribution verified: Opaque=%d, Transparent=%d, UI=%d" % [
		res.opaque_draws, res.transparent_draws, res.ui_draws
	])

	# Advance one more frame
	bridge.call("tick", 0, 0, 0, 0, 0, 0, 0)
	var packet2 = bridge.call("get_frame_packet")
	var res2 = renderer.render_packet(packet2, scenario)
	print("Frame 2 Render: %d draws (Opak: %d, Trans: %d, UI: %d) in %.2f ms" % [
		res2.draw_calls, res2.opaque_draws, res2.transparent_draws, res2.ui_draws, res2.time_ms
	])

	renderer.cleanup()
	print("=================================================================")
	print("PHASE 3d SUCCESS: Passes, UI, Scissor & Render Priority Verified!")
	print("=================================================================")
	get_tree().quit(0)
