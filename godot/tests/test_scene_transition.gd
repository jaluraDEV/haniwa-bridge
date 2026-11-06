extends Node

var bridge: RefCounted = null
var current_tick: int = 0
var max_ticks: int = 500
var transition_triggered: bool = false
var return_transition_triggered: bool = false

func _ready():
	print("============================================================")
	print("SCENE TRANSITION TEST: Village (7) -> Post Office (14)")
	print("============================================================")
	
	load("res://acgc_bridge.gdextension")
	if not ClassDB.class_exists("ACGCBridge"):
		printerr("FATAL: ACGCBridge not found in ClassDB!")
		get_tree().quit(1)
		return
		
	bridge = ClassDB.instantiate("ACGCBridge")
	# Initialize game into village scene (7)
	var ok = bridge.call("init_game", 2002, 9, 15, 12, 0, 0, 0, 7)
	if not ok:
		printerr("FATAL: bridge.init_game() failed!")
		get_tree().quit(1)
		return
	print("[TEST] Game initialized in Scene 7 (Village)!")

func _physics_process(_delta):
	current_tick += 1
	var input = {
		"buttons": 0, "stick_x": 0, "stick_y": 0,
		"substick_x": 0, "substick_y": 0, "trigger_l": 0, "trigger_r": 0
	}
	
	var active = bridge.call("tick", 0, 0, 0, 0, 0, 0, 0)
	var sc = bridge.call("get_scene_no")
	var has_frame = bridge.call("has_frame_packet")
	var pkt_size = 0
	var pkt: PackedByteArray = PackedByteArray()
	if has_frame:
		pkt = bridge.call("get_frame_packet")
		pkt_size = pkt.size()

	if current_tick == 300 and has_frame:
		var f = FileAccess.open("res://../captures/scene_post_office.acfp", FileAccess.WRITE)
		if f:
			f.store_buffer(pkt)
			f.close()
			print("[TEST] Saved captures/scene_post_office.acfp (%d bytes)!" % pkt.size())

	if current_tick % 30 == 0:
		print("[TEST TICK %d] Scene=%d active=%d pkt_size=%d" % [current_tick, sc, active, pkt_size])
		
	# Trigger transition to Post Office (14) at tick 60
	if current_tick == 60 and not transition_triggered:
		print("[TEST] ---> Triggering scene transition to SCENE_POST_OFFICE (14)!")
		bridge.call("change_scene", 14)
		transition_triggered = true
		
	# Trigger return transition back to Village (7) at tick 280
	if current_tick == 280 and not return_transition_triggered:
		print("[TEST] ---> Triggering scene transition back to SCENE_FG (7)!")
		bridge.call("change_scene", 7)
		return_transition_triggered = true
		
	if current_tick >= max_ticks:
		print("============================================================")
		print("[TEST] Completed %d ticks! Current Scene = %d" % [current_tick, sc])
		print("TRANSITION TEST PASSED WITHOUT CRASH!")
		print("============================================================")
		bridge.call("shutdown_game")
		get_tree().quit(0)
