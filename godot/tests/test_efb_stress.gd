extends SceneTree

const LightingController = preload("res://lighting/environment_controller.gd")
const ACFPRenderer = preload("res://renderer/acfp_renderer.gd")

const PAD_BUTTON_A     = 0x0100
const PAD_BUTTON_B     = 0x0200
const PAD_BUTTON_X     = 0x0400
const PAD_BUTTON_START = 0x1000

var shm_client: Object = null
var renderer: ACFPRenderer = null
var vp: SubViewport = null
var camera: Camera3D = null
var env: Environment = null

var _last_efb_ack_seq: int = 0
var _frames_received: int = 0
var _frames_dropped_artificially: int = 0
var _efb_copies_captured: int = 0
var _efb_copies_deduplicated: int = 0
var _lost_copies: int = 0
var _test_duration_sec: float = 600.0 # 10 minutes default
var _start_ms: int = 0

var _inventory_state: int = 0 # 0=closed, 1=opening, 2=open_inspecting, 3=closing
var _inventory_timer: int = 0
var _inventory_cycles: int = 0

func _init():
	var args = OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--duration" and i + 1 < args.size():
			_test_duration_sec = float(args[i + 1])
			
	print("[EFB Stress Test] Starting with target duration: %.1f seconds (%.1f minutes)" % [_test_duration_sec, _test_duration_sec / 60.0])
	
	if not ClassDB.class_exists("ACGCShmClient"):
		print("[EFB Stress Test] FAILED: ACGCShmClient not registered!")
		quit(1)
		return
		
	shm_client = ClassDB.instantiate("ACGCShmClient")
	if not shm_client.call("open"):
		print("[EFB Stress Test] FAILED: Could not open ACGC_SHM_V1 mapping")
		quit(1)
		return
		
	renderer = ACFPRenderer.new()
	vp = SubViewport.new()
	vp.size = Vector2i(640, 480)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	
	camera = Camera3D.new()
	camera.current = true
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 2000.0
	camera.near = 0.001
	camera.far = 10000.0
	
	env = Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color.BLACK
	camera.environment = env
	vp.add_child(camera)
	
	renderer.warmup_shaders(vp.world_3d.scenario)
	_start_ms = Time.get_ticks_msec()

func _process(_delta: float) -> bool:
	var now = Time.get_ticks_msec()
	var elapsed_sec = (now - _start_ms) / 1000.0
	if elapsed_sec >= _test_duration_sec:
		_finish_test()
		return false
		
	# 1. Manage artificial inventory cycling (X to open, inspect 60 frames, B to close, wait 60 frames)
	var btn := 0
	_inventory_timer += 1
	match _inventory_state:
		0: # Closed, waiting
			if _inventory_timer > 90:
				_inventory_state = 1
				_inventory_timer = 0
		1: # Pressing X to open
			btn = PAD_BUTTON_X
			if _inventory_timer > 6:
				_inventory_state = 2
				_inventory_timer = 0
		2: # Open, inspecting inventory & portrait
			if _inventory_timer > 120:
				_inventory_state = 3
				_inventory_timer = 0
		3: # Pressing B to close
			btn = PAD_BUTTON_B
			if _inventory_timer > 6:
				_inventory_state = 0
				_inventory_timer = 0
				_inventory_cycles += 1
				if _inventory_cycles % 5 == 0:
					print("[EFB Stress Test] Progress: %.1f/%.1f sec | Cycles: %d | Frames: %d (Dropped: %d) | Captured: %d | Repeated: %d | Lost: %d" % [
						elapsed_sec, _test_duration_sec, _inventory_cycles, _frames_received,
						_frames_dropped_artificially, _efb_copies_captured, _efb_copies_deduplicated, _lost_copies
					])

	# Send input and ACK to host
	shm_client.call("send_input", btn, 0, 0, 0, 0, 0, 0)
	shm_client.call("send_efb_ack", _last_efb_ack_seq)
	
	# 2. Artificial Frame-Drop: skip every 3rd frame to simulate extreme Godot stutter
	var raw_packet: PackedByteArray = shm_client.call("poll_frame")
	if raw_packet.is_empty():
		return true
		
	_frames_received += 1
	if _frames_received % 3 == 0:
		_frames_dropped_artificially += 1
		# Frame is artificially dropped by Godot!
		return true

	# 3. Process packet
	var scenario = vp.world_3d.scenario
	for req in renderer.get_efb_requests(raw_packet):
		var req_seq: int = int(req.get("seq", 0))
		if req_seq > 0 and req_seq == _last_efb_ack_seq and renderer.efb_textures.has(req.handle):
			_efb_copies_deduplicated += 1
			shm_client.call("send_efb_ack", _last_efb_ack_seq)
			continue
			
		# Execute capture
		renderer.render_packet(raw_packet, scenario, req.draws)
		var img = vp.get_texture().get_image()
		if img and not img.is_empty():
			# Check that the image is not dummy white
			var c = img.get_pixel(320, 240)
			if c == Color.WHITE and _inventory_state == 2:
				_lost_copies += 1
			renderer.store_efb_image(req, img)
			_efb_copies_captured += 1
			if req_seq > 0:
				_last_efb_ack_seq = req_seq
				shm_client.call("send_efb_ack", _last_efb_ack_seq)
		else:
			_lost_copies += 1
			
	renderer.render_packet(raw_packet, scenario)
	return true

func _finish_test():
	var elapsed_sec = (Time.get_ticks_msec() - _start_ms) / 1000.0
	print("\n=======================================================")
	print("[EFB Stress Test] COMPLETED in %.2f seconds (%.2f min)" % [elapsed_sec, elapsed_sec / 60.0])
	print("  Total Frames Received:       %d" % _frames_received)
	print("  Artificially Dropped Frames: %d (%.1f%%)" % [_frames_dropped_artificially, (_frames_dropped_artificially * 100.0) / max(1, _frames_received)])
	print("  Inventory Cycles Completed:  %d" % _inventory_cycles)
	print("  EFB Copies Captured & ACKed: %d" % _efb_copies_captured)
	print("  Duplicate Packets Handled:   %d" % _efb_copies_deduplicated)
	print("  Lost EFB Copies:             %d" % _lost_copies)
	print("  Result:                      %s" % ("PASS (0 lost copies)" if _lost_copies == 0 else "FAIL"))
	print("=======================================================\n")
	
	if renderer: renderer.cleanup()
	if shm_client: shm_client.call("send_exit_signal")
	quit(0 if _lost_copies == 0 else 1)
