extends SceneTree
const Renderer = preload("res://renderer/acfp_renderer.gd")
func _initialize() -> void:
	var renderer = Renderer.new()
	var failures = 0
	for frame in range(1, 31):
		renderer._current_frame_index = frame
		renderer._reset_frame_state()
		var actual = renderer._is_static_draw(123, Transform3D.IDENTITY, 456)
		if actual != (frame == 30): failures += 1
	# Missing producer frames must break the stability streak.
	renderer._current_frame_index = 32
	renderer._reset_frame_state()
	if renderer._is_static_draw(123, Transform3D.IDENTITY, 456): failures += 1
	# Pruning uses the newly decoded frame, not the previous submission.
	renderer._current_frame_index = 120
	renderer._reset_frame_state()
	if not renderer._static_draw_cache.is_empty(): failures += 1
	renderer.cleanup()
	print("[GI_FRAME_HISTORY_TEST] failures=", failures)
	quit(0 if failures == 0 else 1)
