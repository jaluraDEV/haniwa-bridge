extends Node

func _ready():
	print("=== Testing ACGC GDExtension Bridge ===")
	# Ensure the extension resource is loaded
	var ext = load("res://acgc_bridge.gdextension")
	print("Loaded GDExtension: ", ext)
	
	if not ClassDB.class_exists("ACGCBridge"):
		print("ERROR: ACGCBridge still not in ClassDB!")
		get_tree().quit(1)
		return
	
	print("Found class ACGCBridge in ClassDB!")
	
	var bridge = ClassDB.instantiate("ACGCBridge")
	print("Instantiated bridge object: ", bridge)
	
	var res = bridge.call("ping")
	print("bridge.call('ping') returned: ", res)
	
	if res == 42:
		print("SUCCESS: 32-bit GDExtension ping() = 42!")
	else:
		print("ERROR: Expected 42, got: ", res)
		get_tree().quit(1)
		return

	print("=== Running Game Port Inside Godot (60 ticks) ===")
	var ticks_executed = bridge.call("run_ticks", 60)
	print("bridge.call('run_ticks', 60) returned: ", ticks_executed)
	
	if ticks_executed >= 60:
		print("============================================================")
		print("GATE 0 SUCCESS: Port initialized and ticked inside Godot x86_32!")
		print("Ticks executed: ", ticks_executed)
		print("============================================================")
		get_tree().quit(0)
	else:
		print("ERROR: Expected >= 60 ticks, got: ", ticks_executed)
		get_tree().quit(1)
