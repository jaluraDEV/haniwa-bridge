extends Node

func _ready():
	print("=== Running Phase 3a Test: In-Memory Frame Packet Delivery ===")
	
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
	# Year 2002, Month 9, Day 15, Hour 12, Min 0, Sec 0, fixed_addresses=0, scene_override=-1
	var ok = bridge.call("init_game", 2002, 9, 15, 12, 0, 0, 0, -1)
	if not ok:
		print("ERROR: bridge.init_game failed!")
		get_tree().quit(1)
		return
	print("Game initialized successfully!")

	print("Ticking 60 frames to reach stable rendering state...")
	for i in range(60):
		bridge.call("tick", 0, 0, 0, 0, 0, 0, 0)

	var has_packet = bridge.call("has_frame_packet")
	print("has_frame_packet() = ", has_packet)
	if not has_packet:
		print("ERROR: Expected has_frame_packet() == true after 60 ticks!")
		get_tree().quit(1)
		return

	var packet_size = bridge.call("get_frame_packet_size")
	var packet_ptr = bridge.call("get_frame_packet_ptr")
	print("get_frame_packet_size() = ", packet_size, " bytes")
	print("get_frame_packet_ptr()  = 0x%08x" % packet_ptr)

	if packet_size < 64:
		print("ERROR: Packet size is too small: ", packet_size)
		get_tree().quit(1)
		return

	if packet_ptr == 0:
		print("ERROR: Zero pointer returned!")
		get_tree().quit(1)
		return

	var packet = bridge.call("get_frame_packet")
	if typeof(packet) != TYPE_PACKED_BYTE_ARRAY:
		print("ERROR: Expected PackedByteArray, got: ", typeof(packet))
		get_tree().quit(1)
		return

	print("Retrieved PackedByteArray of size: ", packet.size(), " bytes")
	if packet.size() != packet_size:
		print("ERROR: PackedByteArray size mismatch with get_frame_packet_size()!")
		get_tree().quit(1)
		return

	# Verify Header fields
	var magic = packet.decode_u32(0)
	var version = packet.decode_u32(4)
	var frame_idx = packet.decode_u32(8)
	var tick_count = packet.decode_u32(12)
	var width = packet.decode_u32(16)
	var height = packet.decode_u32(20)
	var clear_depth = packet.decode_float(40)
	var tex_offset = packet.decode_u32(44)
	var tex_count = packet.decode_u32(48)
	var vbo_offset = packet.decode_u32(52)
	var vbo_count = packet.decode_u32(56)
	var cmd_offset = packet.decode_u32(60)
	var cmd_size = packet.decode_u32(64)

	print("Header Analysis:")
	print("  Magic:        0x%08x (Expected 0x50464341 'ACFP')" % magic)
	print("  Version:      ", version, " (Expected 1)")
	print("  Frame Index:  ", frame_idx)
	print("  Tick Count:   ", tick_count)
	print("  Dimensions:   ", width, "x", height)
	print("  Clear Depth:  ", clear_depth)
	print("  Textures:     count=", tex_count, " @ offset=", tex_offset)
	print("  VBOs:         count=", vbo_count, " @ offset=", vbo_offset)
	print("  Cmd Stream:   size=", cmd_size, " bytes @ offset=", cmd_offset)

	if magic != 0x50464341:
		print("ERROR: Invalid magic 0x%08x!" % magic)
		get_tree().quit(1)
		return

	if version != 1:
		print("ERROR: Invalid version ", version)
		get_tree().quit(1)
		return

	if width != 640 or height != 480:
		print("ERROR: Unexpected resolution: ", width, "x", height)
		get_tree().quit(1)
		return

	if tex_count == 0 or vbo_count == 0 or cmd_size == 0:
		print("ERROR: Frame packet has empty resources or commands!")
		get_tree().quit(1)
		return

	# Save to captures/phase3a_test.acfp for external tools
	var file = FileAccess.open("res://../captures/phase3a_test.acfp", FileAccess.WRITE)
	if file:
		file.store_buffer(packet)
		file.close()
		print("Saved test packet to captures/phase3a_test.acfp")

	print("=================================================================")
	print("PHASE 3a SUCCESS: In-memory frame packet delivered to Godot!")
	print("Textures: %d, VBOs: %d, Commands: %d KB, Total: %d KB" % [
		tex_count, vbo_count, cmd_size / 1024, packet.size() / 1024
	])
	print("=================================================================")
	get_tree().quit(0)
