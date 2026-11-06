extends Node

# ACGC Button bitmasks (GameCube PAD)
const PAD_BUTTON_LEFT    = 0x0001
const PAD_BUTTON_RIGHT   = 0x0002
const PAD_BUTTON_DOWN    = 0x0004
const PAD_BUTTON_UP      = 0x0008
const PAD_TRIGGER_Z      = 0x0010
const PAD_TRIGGER_R      = 0x0020
const PAD_TRIGGER_L      = 0x0040
const PAD_BUTTON_A       = 0x0100
const PAD_BUTTON_B       = 0x0200
const PAD_BUTTON_X       = 0x0400
const PAD_BUTTON_Y       = 0x0800
const PAD_BUTTON_START   = 0x1000

var bridge: RefCounted = null
var current_tick: int = 0
var max_ticks: int = 120
var log_history: Array = []

func _ready():
	print("============================================================")
	print("PHASE 1 GATE VERIFICATION TEST")
	print("Testing acgc_init / acgc_tick / acgc_shutdown & 60Hz Pacing")
	print("============================================================")
	
	load("res://acgc_bridge.gdextension")
	if not ClassDB.class_exists("ACGCBridge"):
		printerr("FATAL: ACGCBridge not found in ClassDB!")
		get_tree().quit(1)
		return
		
	bridge = ClassDB.instantiate("ACGCBridge")
	print("[TEST] ACGCBridge instantiated successfully: ", bridge)
	
	# Test ping
	var p = bridge.call("ping")
	assert(p == 42, "ping() must return 42")
	print("[TEST] Bridge ping() returned: ", p)
	
	# Test init_game
	print("[TEST] Calling bridge.init_game()...")
	var ok = bridge.call("init_game")
	if not ok:
		printerr("FATAL: bridge.init_game() failed!")
		get_tree().quit(1)
		return
	print("[TEST] bridge.init_game() succeeded! Game is initialized.")
	
	var running = bridge.call("is_game_running")
	print("[TEST] is_game_running: ", running)
	if not running:
		printerr("FATAL: is_game_running reported false after init!")
		get_tree().quit(1)
		return

func _physics_process(delta: float):
	if bridge == null:
		return
	
	current_tick += 1
	if current_tick > max_ticks:
		finish_test()
		return
	
	# Determine input for this tick to test input bridge
	var buttons = 0
	var stick_x = 0
	var stick_y = 0
	var substick_x = 0
	var substick_y = 0
	var trigger_l = 0
	var trigger_r = 0
	
	# Feed different inputs across frames
	if current_tick >= 10 and current_tick <= 20:
		buttons = PAD_BUTTON_START
	elif current_tick >= 30 and current_tick <= 45:
		stick_x = 60
		stick_y = 40
	elif current_tick >= 55 and current_tick <= 70:
		buttons = PAD_BUTTON_A
		trigger_r = 180
	elif current_tick >= 80 and current_tick <= 95:
		substick_x = -50
		buttons = PAD_BUTTON_B
		
	# Execute fixed 60Hz tick
	var frame_result = bridge.call("tick", buttons, stick_x, stick_y, substick_x, substick_y, trigger_l, trigger_r)
	
	# Query state via API
	var fc = bridge.call("get_frame_count")
	var h  = bridge.call("get_hour")
	var m  = bridge.call("get_minute")
	var s  = bridge.call("get_second")
	var season = bridge.call("get_season")
	var weather = bridge.call("get_weather")
	var now_sec = bridge.call("get_now_sec")
	
	var snapshot = {
		"tick": current_tick,
		"delta": delta,
		"buttons": buttons,
		"stick_x": stick_x,
		"frame_count": fc,
		"hour": h,
		"min": m,
		"sec": s,
		"season": season,
		"weather": weather,
		"now_sec": now_sec
	}
	log_history.append(snapshot)
	
	if current_tick % 30 == 0 or current_tick == 1:
		print("[TICK %3d] dt=%.4f | PortFrames=%3d | RTC=%02d:%02d:%02d (sec=%d) | Season=%d Weather=%d | Input=0x%04x" % [
			current_tick, delta, fc, h, m, s, now_sec, season, weather, buttons
		])

func finish_test():
	set_physics_process(false)
	print("------------------------------------------------------------")
	print("[TEST] Completed %d physics ticks." % max_ticks)
	
	var final_frames = bridge.call("get_frame_count")
	print("[TEST] Final port frame count: ", final_frames)
	
	# Verification assertions
	if final_frames < max_ticks:
		printerr("ERROR: Frame counter (%d) did not advance to expected ticks (%d)!" % [final_frames, max_ticks])
		get_tree().quit(1)
		return
		
	print("[TEST] Calling bridge.shutdown_game()...")
	bridge.call("shutdown_game")
	print("[TEST] bridge.shutdown_game() completed.")
	
	var running_after = bridge.call("is_game_running")
	print("[TEST] is_game_running after shutdown: ", running_after)
	if running_after:
		printerr("ERROR: Game still reports running after shutdown!")
		get_tree().quit(1)
		return
	
	# Save run log for determinism comparison
	var json_str = JSON.stringify(log_history, "\t")
	var file = FileAccess.open("res://tests/phase1_run_log.json", FileAccess.WRITE)
	if file:
		file.store_string(json_str)
		file.close()
		print("[TEST] State history written to tests/phase1_run_log.json")
		
	print("============================================================")
	print("GATE 1 VERIFICATION SUCCESSFUL!")
	print("============================================================")
	get_tree().quit(0)
