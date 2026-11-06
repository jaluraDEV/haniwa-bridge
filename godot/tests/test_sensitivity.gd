extends Node

func to_u64_hex(val: int) -> String:
	var hi = (val >> 32) & 0xFFFFFFFF
	var lo = val & 0xFFFFFFFF
	return "0x%08x%08x" % [hi, lo]

func _ready():
	print("============================================================")
	print("SENSITIVITY & COVERAGE TEST (Gate 1 Item 1)")
	print("============================================================")

	load("res://acgc_bridge.gdextension")
	var bridge = ClassDB.instantiate("ACGCBridge")

	# Initialize game with fixed addresses
	var ok = bridge.call("init_game", 2002, 9, 15, 12, 0, 0, 1)
	if not ok:
		printerr("FATAL: bridge.init_game failed!")
		get_tree().quit(1)
		return

	# Advance 600 ticks into active train scene with fixed inputs
	print("[TEST] Ticking 600 frames into active train scene (START @ 120, A @ 300)...")
	for tick in range(1, 601):
		var buttons = 0
		if tick >= 120 and tick <= 130:
			buttons = 0x1000 # START
		elif tick >= 300 and tick <= 310:
			buttons = 0x0100 # A
		bridge.call("tick", buttons, 0, 0, 0, 0, 0, 0)

	var h_base = bridge.call("get_arena_hash")
	var orig_rng = bridge.call("get_rng_seed")
	var scene_no = bridge.call("get_scene_no")
	var scene_mode = bridge.call("get_scene_mode")
	var actor_cnt = bridge.call("get_actor_count")

	print("\n[BASELINE Tick 600]")
	print("  Hash       : %s" % to_u64_hex(h_base))
	print("  Scene No   : %d (SCENE_PLAYERSELECT = Train Ride)" % scene_no)
	print("  Scene Mode : %d (SCENE_MODE 3)" % scene_mode)
	print("  Actors     : %d active actors in scene" % actor_cnt)
	print("  RNG Seed   : 0x%08x" % orig_rng)

	var results = {
		"baseline_hash": to_u64_hex(h_base),
		"scene_no": scene_no,
		"scene_mode": scene_mode,
		"actor_count": actor_cnt,
		"rng_seed": "0x%08x" % orig_rng,
		"tests": []
	}

	# Test 1: Arena / MEM1 Heap modification
	print("\n--- Test 1: Arena / MEM1 Heap Sensitivity ---")
	var orig_arena_byte = bridge.call("peek_arena_byte", 0x4000)
	var poke_arena_val = (orig_arena_byte ^ 0x77)
	bridge.call("poke_arena_byte", 0x4000, poke_arena_val)
	var h_arena = bridge.call("get_arena_hash")
	var arena_changed = (h_arena != h_base)
	print("  Poked arena[0x4000]: 0x%02x -> 0x%02x | Hash: %s (Diff: %s)" % [
		orig_arena_byte, poke_arena_val, to_u64_hex(h_arena), "YES (PASSED)" if arena_changed else "NO (FAILED)"
	])
	assert(arena_changed, "Arena poke must change hash!")
	bridge.call("poke_arena_byte", 0x4000, orig_arena_byte) # Revert
	var h_arena_rev = bridge.call("get_arena_hash")
	print("  Reverted arena[0x4000] -> Hash: %s (Clean Revert: %s)" % [
		to_u64_hex(h_arena_rev), "YES (PASSED)" if h_arena_rev == h_base else "NO (FAILED)"
	])
	assert(h_arena_rev == h_base, "Arena revert must restore baseline hash!")
	results["tests"].append({
		"name": "Arena / MEM1 Heap (0x4000)",
		"orig_byte": "0x%02x" % orig_arena_byte,
		"poked_byte": "0x%02x" % poke_arena_val,
		"poked_hash": to_u64_hex(h_arena),
		"reverted_hash": to_u64_hex(h_arena_rev),
		"changed": arena_changed,
		"reverted_cleanly": (h_arena_rev == h_base)
	})

	# Test 2: Actor Area Sensitivity (zelda_arena)
	print("\n--- Test 2: Actor Area (zelda_arena) Sensitivity ---")
	var orig_actor_byte = bridge.call("peek_actor_byte", 0x10)
	var poke_actor_val = (orig_actor_byte ^ 0xBE)
	bridge.call("poke_actor_byte", 0x10, poke_actor_val)
	var h_actor = bridge.call("get_arena_hash")
	var actor_changed = (h_actor != h_base)
	print("  Poked actor[0x10]: 0x%02x -> 0x%02x | Hash: %s (Diff: %s)" % [
		orig_actor_byte, poke_actor_val, to_u64_hex(h_actor), "YES (PASSED)" if actor_changed else "NO (FAILED)"
	])
	assert(actor_changed, "Actor poke must change hash!")
	bridge.call("poke_actor_byte", 0x10, orig_actor_byte) # Revert
	var h_actor_rev = bridge.call("get_arena_hash")
	print("  Reverted actor[0x10] -> Hash: %s (Clean Revert: %s)" % [
		to_u64_hex(h_actor_rev), "YES (PASSED)" if h_actor_rev == h_base else "NO (FAILED)"
	])
	assert(h_actor_rev == h_base, "Actor revert must restore baseline hash!")
	results["tests"].append({
		"name": "Actor Area (zelda_arena payload)",
		"orig_byte": "0x%02x" % orig_actor_byte,
		"poked_byte": "0x%02x" % poke_actor_val,
		"poked_hash": to_u64_hex(h_actor),
		"reverted_hash": to_u64_hex(h_actor_rev),
		"changed": actor_changed,
		"reverted_cleanly": (h_actor_rev == h_base)
	})

	# Test 3: RNG State Sensitivity
	print("\n--- Test 3: RNG State Sensitivity ---")
	bridge.call("poke_rng_seed", 0xCAFEBABE)
	var h_rng = bridge.call("get_arena_hash")
	var rng_changed = (h_rng != h_base)
	print("  Poked RNG seed = 0xCAFEBABE -> Hash: %s (Diff: %s)" % [
		to_u64_hex(h_rng), "YES (PASSED)" if rng_changed else "NO (FAILED)"
	])
	assert(rng_changed, "RNG poke must change hash!")
	bridge.call("poke_rng_seed", orig_rng) # Revert
	var h_rng_rev = bridge.call("get_arena_hash")
	print("  Reverted RNG seed -> Hash: %s (Clean Revert: %s)" % [
		to_u64_hex(h_rng_rev), "YES (PASSED)" if h_rng_rev == h_base else "NO (FAILED)"
	])
	assert(h_rng_rev == h_base, "RNG revert must restore baseline hash!")
	results["tests"].append({
		"name": "RNG State Seed (__qrand_idum)",
		"poked_hash": to_u64_hex(h_rng),
		"reverted_hash": to_u64_hex(h_rng_rev),
		"changed": rng_changed,
		"reverted_cleanly": (h_rng_rev == h_base)
	})

	# Test 4: Normalized Stack Region (Must NOT change hash)
	print("\n--- Test 4: Normalized Region (Top 64KB Stack Cutoff) ---")
	# Offset 0x017FF000 is inside the top 64KB OS reserved thread stack area
	bridge.call("poke_arena_byte", 0x017FF000, 0xEE)
	var h_norm = bridge.call("get_arena_hash")
	var norm_ignored = (h_norm == h_base)
	print("  Poked reserved OS stack [0x017FF000] = 0xEE -> Hash: %s (Ignored: %s)" % [
		to_u64_hex(h_norm), "YES (PASSED)" if norm_ignored else "NO (FAILED)"
	])
	assert(norm_ignored, "Normalized stack region must not affect hash!")
	bridge.call("poke_arena_byte", 0x017FF000, 0x00) # Cleanup
	results["tests"].append({
		"name": "Normalized Region (Top 64KB Stack Cutoff)",
		"poked_hash": to_u64_hex(h_norm),
		"ignored_as_expected": norm_ignored
	})

	var out_f = FileAccess.open("res://tests/sensitivity_results.json", FileAccess.WRITE)
	if out_f:
		out_f.store_string(JSON.stringify(results, "\t"))
		out_f.close()
		print("\n[TEST] Written sensitivity results to res://tests/sensitivity_results.json")

	bridge.call("shutdown_game")
	print("[SUCCESS] Sensitivity test completed with 100% PASS!")
	get_tree().quit(0)
