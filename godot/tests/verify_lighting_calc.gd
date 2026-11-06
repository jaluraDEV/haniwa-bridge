extends SceneTree

const LightingController = preload("res://lighting/environment_controller.gd")

func _init() -> void:
	var f = FileAccess.open("res://tests/lighting_results.txt", FileAccess.WRITE)
	if not f:
		f = FileAccess.open("user://lighting_results.txt", FileAccess.WRITE)

	var log_line = func(msg: String):
		print(msg)
		if f:
			f.store_line(msg)

	log_line.call("=== Running RTC Day/Night Lighting Verification Test ===")
	var controller = LightingController.new()
	var root_node = Node3D.new()
	root_node.add_child(controller)

	var test_times = [
		{"hour": 12, "minute": 0, "second": 0, "label": "12:00:00 (High Noon / Zenith)"},
		{"hour": 20, "minute": 0, "second": 0, "label": "20:00:00 (Night / Early Evening)"},
		{"hour": 2, "minute": 0, "second": 0, "label": "02:00:00 (Deep Night / Midnight Orbit)"},
		{"hour": 6, "minute": 45, "second": 0, "label": "06:45:00 (Morning Warm Light)"},
		{"hour": 18, "minute": 30, "second": 0, "label": "18:30:00 (Golden Hour / Sunset Dusk)"},
	]

	# First test: Lit Mode (enabled = true)
	controller.set_enabled(true)

	for entry in test_times:
		var state = {
			"hour": entry.hour,
			"minute": entry.minute,
			"second": entry.second,
			"weather": 0, # Clear
			"season": 0,  # Spring
			"scene_no": 1 # Village
		}
		controller.apply_state(state)

		var t: float = controller.current_time_hours
		var orb_rad: float = controller.current_orbit
		var orb_deg: float = rad_to_deg(orb_rad)
		var s_rot: Vector3 = controller.sun.rotation
		var m_rot: Vector3 = controller.moon.rotation
		var s_alt: float = controller.current_sun_altitude
		var m_alt: float = controller.current_moon_altitude

		log_line.call("\n-------------------------------------------------------------")
		log_line.call("Zeit: %s" % entry.label)
		log_line.call("  t (hours):           %.4f" % t)
		log_line.call("  Phase:               %s" % controller.current_phase_name)
		log_line.call("  Orbit:               %.4f rad (%.1f deg)" % [orb_rad, orb_deg])
		log_line.call("  Sun Altitude:        %.4f (sin(orbit))" % s_alt)
		log_line.call("  Sun Rotation:        Vector3(%.4f, %.4f, %.4f)" % [s_rot.x, s_rot.y, s_rot.z])
		log_line.call("  Sun Light Energy:    %.3f (Visible: %s)" % [controller.sun.light_energy, controller.sun.visible])
		log_line.call("  Sun Light Color:     Color(%.3f, %.3f, %.3f)" % [controller.sun.light_color.r, controller.sun.light_color.g, controller.sun.light_color.b])
		log_line.call("  Moon Altitude:       %.4f" % m_alt)
		log_line.call("  Moon Rotation:       Vector3(%.4f, %.4f, %.4f)" % [m_rot.x, m_rot.y, m_rot.z])
		log_line.call("  Moon Light Energy:   %.3f (Visible: %s)" % [controller.moon.light_energy, controller.moon.visible])
		log_line.call("  Moon Light Color:    Color(%.3f, %.3f, %.3f)" % [controller.moon.light_color.r, controller.moon.light_color.g, controller.moon.light_color.b])
		log_line.call("  Sky Top Color:       Color(%.3f, %.3f, %.3f)" % [controller._sky_material.sky_top_color.r, controller._sky_material.sky_top_color.g, controller._sky_material.sky_top_color.b])
		log_line.call("  Sky Horizon Color:   Color(%.3f, %.3f, %.3f)" % [controller._sky_material.sky_horizon_color.r, controller._sky_material.sky_horizon_color.g, controller._sky_material.sky_horizon_color.b])
		log_line.call("  Ambient Energy:      %.3f" % controller.lighting_environment.ambient_light_energy)
		log_line.call("  Ambient Color:       Color(%.3f, %.3f, %.3f)" % [controller.lighting_environment.ambient_light_color.r, controller.lighting_environment.ambient_light_color.g, controller.lighting_environment.ambient_light_color.b])

	# Assertions for the specific requirements
	# 1. 12:00:00 -> Zenith
	controller.apply_state({"hour": 12, "minute": 0, "second": 0, "weather": 0, "season": 0, "scene_no": 1})
	assert(abs(controller.current_sun_altitude - 1.0) < 0.001, "12:00 sun altitude must be ~1.0 (zenith)")
	assert(controller.sun.light_energy >= 1.2, "12:00 sun energy must be >= 1.2")
	assert(controller.sun.visible == true, "12:00 sun must be visible")
	assert(controller.moon.visible == false, "12:00 moon must not be visible")

	# 2. 20:00:00 -> Night / Sun below horizon
	controller.apply_state({"hour": 20, "minute": 0, "second": 0, "weather": 0, "season": 0, "scene_no": 1})
	assert(controller.current_sun_altitude < 0.0, "20:00 sun altitude must be negative")
	assert(controller.sun.light_energy == 0.0, "20:00 sun energy must be 0")
	assert(controller.sun.visible == false, "20:00 sun must not be visible")
	assert(controller.moon.visible == true, "20:00 moon must be visible")
	assert(controller.moon.light_energy > 0.05, "20:00 moon energy must be > 0.05")

	# 3. 02:00:00 -> Deep Night Moonlight
	controller.apply_state({"hour": 2, "minute": 0, "second": 0, "weather": 0, "season": 0, "scene_no": 1})
	assert(controller.current_sun_altitude < -0.8, "02:00 sun altitude must be deep below horizon")
	assert(controller.sun.light_energy == 0.0, "02:00 sun energy must be 0")
	assert(controller.sun.visible == false, "02:00 sun must not be visible")
	assert(controller.moon.visible == true, "02:00 moon must be visible")
	assert(controller.moon.light_energy >= 0.15, "02:00 moon energy must be >= 0.15")

	# 4. Retro / F4-Original unlit check:
	controller.set_enabled(false)
	controller.apply_state({"hour": 12, "minute": 0, "second": 0, "weather": 0, "season": 0, "scene_no": 1})
	assert(controller.sun.visible == false, "In unlit retro mode, sun must be invisible even at noon!")
	assert(controller.moon.visible == false, "In unlit retro mode, moon must be invisible!")
	assert(controller.world_environment.environment == null, "In unlit retro mode, world environment must be null!")
	log_line.call("\n[SUCCESS] All lighting verification assertions passed!")

	if f:
		f.flush()
		f.close()

	quit(0)
