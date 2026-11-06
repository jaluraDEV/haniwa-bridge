extends Node

func _ready():
	var args = OS.get_cmdline_args()
	var run_id = 1
	var use_fixed = 0
	var ticks = 600
	for arg in args:
		if arg.begins_with("--run-id="):
			run_id = int(arg.substr(9))
		elif arg.begins_with("--use-fixed="):
			use_fixed = int(arg.substr(12))
		elif arg.begins_with("--ticks="):
			ticks = int(arg.substr(8))

	load("res://acgc_bridge.gdextension")
	var bridge = ClassDB.instantiate("ACGCBridge")
	bridge.call("init_game", 2002, 9, 15, 12, 0, 0, use_fixed)

	for tick in range(1, ticks + 1):
		var buttons = 0
		if tick >= 120 and tick <= 130:
			buttons = 0x1000 # START
		elif tick >= 300 and tick <= 310:
			buttons = 0x0100 # A
		bridge.call("tick", buttons, 0, 0, 0, 0, 0, 0)

	var h = bridge.call("get_arena_hash")
	var ok_dump = bridge.call("dump_state_breakdown", run_id)
	print("[BREAKDOWN] Run %d Tick %d Hash: 0x%016x | Dump OK: %s" % [run_id, ticks, h, str(ok_dump)])

	bridge.call("shutdown_game")
	get_tree().quit(0)
