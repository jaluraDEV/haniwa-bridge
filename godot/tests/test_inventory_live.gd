extends Node

var bridge: RefCounted = null
var renderer: ACFPRenderer = null
var current_tick: int = 0
var max_ticks: int = 500
var inventory_opened: bool = false
var hand_draw_found: bool = false
var subviewport: SubViewport = null
var scenario: RID

func _ready():
	print("============================================================")
	print("INVENTORY LIVE TEST: Village (7) -> Open Inventory -> Cursor")
	print("============================================================")
	
	load("res://acgc_bridge.gdextension")
	if not ClassDB.class_exists("ACGCBridge"):
		printerr("FATAL: ACGCBridge not found in ClassDB!")
		get_tree().quit(1)
		return
		
	bridge = ClassDB.instantiate("ACGCBridge")
	var ok = bridge.call("init_game", 2002, 9, 15, 12, 0, 0, 0, 7)
	if not ok:
		printerr("FATAL: bridge.init_game() failed!")
		get_tree().quit(1)
		return
	print("[TEST] Game initialized in Scene 7 (Village)!")
	
	renderer = ACFPRenderer.new()
	scenario = RenderingServer.scenario_create()

func _physics_process(_delta):
	current_tick += 1
	var buttons = 0
	var stick_x = 0
	var stick_y = 0
	
	# Press Y periodically after player exit animation finishes (> 200 ticks)
	if current_tick >= 220 and current_tick <= 360:
		if (current_tick % 20) < 5:
			buttons |= 0x0800 # PAD_BUTTON_Y
			
	# Move stick right when inventory opens
	if current_tick >= 380 and current_tick <= 450:
		stick_x = 80

	var active = bridge.call("tick", buttons, stick_x, stick_y, 0, 0, 0, 0)
	var sc = bridge.call("get_scene_no")
	var has_frame = bridge.call("has_frame_packet")
	
	if has_frame:
		var pkt: PackedByteArray = bridge.call("get_frame_packet")
		if pkt.size() > 64:
			var res = renderer.render_packet(pkt, scenario, 640, 480)
			var draws = res.get("draw_calls", 0)
			
			if current_tick % 30 == 0:
				print("[TEST Tick %d] Scene=%d, Draws=%d, ActiveInst=%d, PktSize=%d" % [
					current_tick, sc, draws, res.get("active_instances", 0), pkt.size()
				])
				
			# Capture inventory packet once fully open (around tick 300)
			if current_tick == 300:
				var f = FileAccess.open("res://../captures/inventory_live.acfp", FileAccess.WRITE)
				if f:
					f.store_buffer(pkt)
					f.close()
					print("[TEST] Saved captures/inventory_live.acfp (%d bytes, %d draws)!" % [pkt.size(), draws])

	if current_tick >= max_ticks:
		print("============================================================")
		print("[TEST] Completed %d ticks! Inventory test PASSED!" % current_tick)
		print("============================================================")
		renderer.cleanup()
		RenderingServer.free_rid(scenario)
		bridge.call("shutdown_game")
		get_tree().quit(0)
