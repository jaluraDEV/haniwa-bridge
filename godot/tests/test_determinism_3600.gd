extends Node

# ACGC Button bitmasks (GameCube PAD)
const PAD_BUTTON_START = 0x1000
const PAD_BUTTON_A     = 0x0100

@export var mode: String = "fixed_input" # "fixed_input" or "no_input"
@export var max_ticks: int = 3600
var use_fixed_addr: int = 0
var output_override: String = ""
var dump_run: int = 0

var bridge: RefCounted = null
var current_tick: int = 0
var log_history: Array = []

func to_u64_hex(val: int) -> String:
	var hi = (val >> 32) & 0xFFFFFFFF
	var lo = val & 0xFFFFFFFF
	return "0x%08x%08x" % [hi, lo]

func _ready():
	# Check CLI arguments for mode override
	var args = OS.get_cmdline_args()
	for arg in args:
		if arg.begins_with("--test-mode="):
			mode = arg.substr(12)
		elif arg.begins_with("--test-ticks="):
			max_ticks = int(arg.substr(13))
		elif arg.begins_with("--use-fixed-addr="):
			use_fixed_addr = int(arg.substr(17))
		elif arg.begins_with("--output="):
			output_override = arg.substr(9)
		elif arg.begins_with("--dump-run="):
			dump_run = int(arg.substr(11))

	print("============================================================")
	print("DETERMINISM VERIFICATION (3600 TICKS)")
	print("Mode: %s | Max Ticks: %d | FixedAddr: %d" % [mode, max_ticks, use_fixed_addr])
	print("============================================================")

	load("res://acgc_bridge.gdextension")
	bridge = ClassDB.instantiate("ACGCBridge")

	# Initialize with fixed RTC starting time: 2002-09-15 12:00:00
	var ok = bridge.call("init_game", 2002, 9, 15, 12, 0, 0, use_fixed_addr)
	if not ok:
		printerr("FATAL: bridge.init_game failed!")
		get_tree().quit(1)
		return

	# Run all ticks in a fast synchronous loop
	var start_ms = Time.get_ticks_msec()
	for tick in range(1, max_ticks + 1):
		var buttons = 0
		var stick_x = 0
		var stick_y = 0

		if mode == "fixed_input" or mode.begins_with("run"):
			# At tick 120-130, press START to advance past the logo / title screen
			if tick >= 120 and tick <= 130:
				buttons = PAD_BUTTON_START
			# At tick 300-310, press A
			elif tick >= 300 and tick <= 310:
				buttons = PAD_BUTTON_A

		bridge.call("tick", buttons, stick_x, stick_y, 0, 0, 0, 0)

		# Every 60 ticks (or tick 1 and final tick), record state and arena hash
		if tick % 60 == 0 or tick == 1 or tick == max_ticks:
			var arena_hash = bridge.call("get_arena_hash")
			var fc = bridge.call("get_frame_count")
			var h  = bridge.call("get_hour")
			var m  = bridge.call("get_minute")
			var s  = bridge.call("get_second")
			var now_sec = bridge.call("get_now_sec")
			var season = bridge.call("get_season")
			var weather = bridge.call("get_weather")
			var scene_no = bridge.call("get_scene_no")
			var scene_mode = bridge.call("get_scene_mode")
			var rng_seed = bridge.call("get_rng_seed")
			var is_running = bridge.call("is_game_running")
			var actor_count = bridge.call("get_actor_count")

			var snapshot = {
				"tick": tick,
				"frame_count": fc,
				"scene_no": scene_no,
				"scene_mode": scene_mode,
				"rng_seed": rng_seed,
				"is_game_running": is_running,
				"actor_count": actor_count,
				"arena_hash": to_u64_hex(arena_hash),
				"arena_hash_raw": arena_hash,
				"time": "%02d:%02d:%02d" % [h, m, s],
				"now_sec": now_sec,
				"season": season,
				"weather": weather
			}
			log_history.append(snapshot)

			if tick % 300 == 0 or tick == 1 or tick == max_ticks:
				print("[TICK %4d / %4d] Frames=%4d | Scn=%2d | ScnMode=%2d | Actors=%2d | RNG=0x%08x | Hash=%s" % [
					tick, max_ticks, fc, scene_no, scene_mode, actor_count, rng_seed, to_u64_hex(arena_hash)
				])

	var elapsed_s = (Time.get_ticks_msec() - start_ms) / 1000.0
	print("------------------------------------------------------------")
	print("[TEST] Completed %d ticks in %.2f seconds (%.1f ticks/sec)." % [
		max_ticks, elapsed_s, float(max_ticks) / max(elapsed_s, 0.001)
	])

	if dump_run > 0:
		bridge.call("dump_arena", dump_run)
		print("[TEST] Dumped arena to arena_run%d.bin" % dump_run)

	var output_file = output_override if output_override != "" else ("res://tests/determinism_%s.json" % mode)
	var json_str = JSON.stringify(log_history, "\t")
	var file = FileAccess.open(output_file, FileAccess.WRITE)
	if file:
		file.store_string(json_str)
		file.close()
		print("[TEST] Written state log to %s" % output_file)

	bridge.call("shutdown_game")
	print("[TEST] Game shutdown cleanly.")
	get_tree().quit(0)

func _physics_process(_delta: float):
	pass
