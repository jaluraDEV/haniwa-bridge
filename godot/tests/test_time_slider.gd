extends SceneTree

const LightingController = preload("res://lighting/environment_controller.gd")

func _init():
	print("--- TEST TIME SLIDER & WEATHER OVERRIDE ---")
	var lc = LightingController.new()
	var test_state = {
		"hour": 10,
		"minute": 0,
		"second": 0,
		"weather": 0,
		"season": 0,
		"scene_no": 1
	}
	lc.apply_state(test_state)
	print("Base time: 10:00 -> current_time_hours: %.2f, Phase: %s, SunE: %.2f" % [lc.current_time_hours, lc.current_phase_name, lc.sun.light_energy])
	assert(lc.current_phase_name == "Day")
	
	# Offset +10h -> 20:00 (Night)
	lc.debug_time_offset_hours = 10.0
	lc.apply_state(test_state)
	print("Offset +10h: 20:00 -> current_time_hours: %.2f, Phase: %s, SunE: %.2f, MoonE: %.2f" % [lc.current_time_hours, lc.current_phase_name, lc.sun.light_energy, lc.moon.light_energy])
	assert(lc.current_phase_name == "Night")
	
	# Offset -3h -> 07:00 (Morning)
	lc.debug_time_offset_hours = -3.0
	lc.apply_state(test_state)
	print("Offset -3h: 07:00 -> current_time_hours: %.2f, Phase: %s, SunE: %.2f" % [lc.current_time_hours, lc.current_phase_name, lc.sun.light_energy])
	assert(lc.current_phase_name == "Morning")
	
	# Weather override to Rain (1)
	lc.debug_weather_override = 1
	lc.apply_state(test_state)
	print("Weather override RAIN -> fog_enabled: %s, ambient_light_energy: %.3f" % [lc.lighting_environment.fog_enabled, lc.lighting_environment.ambient_light_energy])
	assert(lc.lighting_environment.fog_enabled == true)
	
	# Reset offset
	lc.debug_time_offset_hours = 0.0
	lc.debug_weather_override = -1
	lc.apply_state(test_state)
	print("Reset offset -> current_time_hours: %.2f, fog_enabled: %s" % [lc.current_time_hours, lc.lighting_environment.fog_enabled])
	assert(lc.current_time_hours == 10.0)
	assert(lc.lighting_environment.fog_enabled == false)
	
	print("[TIME SLIDER TEST] PASS: All lighting shifts verified without modifying host state!")
	quit(0)
