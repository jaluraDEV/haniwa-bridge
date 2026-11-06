extends SceneTree
## Integration regression: start the real 32-bit host first, then run with
## Godot --path godot --script res://tests/verify_shm_startup.gd
## Uses the real SHM main loop, not a replacement client or synthetic packet.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var scene = load("res://shm_main.tscn").instantiate()
	root.add_child(scene)
	var deadline = Time.get_ticks_msec() + 20000
	while scene._frames_received < 120 and Time.get_ticks_msec() < deadline:
		await process_frame
	var state: Dictionary = scene.lighting_controller.last_state
	var passed: bool = scene._opened and scene._frames_received >= 120 \
		and state.has("second") and scene._audio_frames_pushed > 0
	print("[SHM_STARTUP_TEST] passed=%s frames=%d audio_frames=%d rtc=%s" % [
		passed, scene._frames_received, scene._audio_frames_pushed, state])
	# Normal main-scene cleanup signals the test host to exit.
	quit(0 if passed else 1)
