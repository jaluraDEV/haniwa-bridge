class_name ACEnvironmentController
extends Node3D
## Phase 4.1 RTC Tag/Nacht- und Beleuchtungs-Sync in Godot.
## Consumes actual game state from the 32-bit host (hour, minute, second, weather, season, scene_no)
## and continuously interpolates celestial rotation (sun/moon), light colors, energies, and sky/ambient.

enum Weather { CLEAR, RAIN, SNOW, SAKURA, LEAVES }
enum Season { SPRING, SUMMER, AUTUMN, WINTER }

var sun := DirectionalLight3D.new()
var moon := DirectionalLight3D.new()
var world_environment := WorldEnvironment.new()
var lighting_environment := Environment.new()
var _sky_material := ProceduralSkyMaterial.new()

## Experimental SDFGI toggle
@export var enable_sdfgi: bool = false
var enabled: bool = false
var last_state: Dictionary = {}

## Debug overrides (lighting preview only, does NOT touch host game logic)
var debug_time_offset_hours: float = 0.0
var debug_weather_override: int = -1 # -1 = host weather, 0..4 = override

# Current calculated celestial state (accessible for debug / verification)
var current_time_hours: float = 12.0
var current_orbit: float = 0.0
var current_sun_altitude: float = 1.0
var current_moon_altitude: float = -1.0
var current_phase_name: String = "Day"

static func read_bridge_state(bridge: Object) -> Dictionary:
	return {
		"hour": int(bridge.call("get_hour")),
		"minute": int(bridge.call("get_minute")),
		"second": int(bridge.call("get_second")) if bridge.has_method("get_second") else 0,
		"weather": int(bridge.call("get_weather")),
		"season": int(bridge.call("get_season")),
		"scene_no": int(bridge.call("get_scene_no")),
	}

## Scene IDs with field_draw_type == INDOORS, from port/include/m_scene_table.h
## (scene_table enum). These render a black background and no outdoor sun.
const INTERIOR_SCENES: Array[int] = [
	6, 9, 12, 13, 14, 17, 18, 20, 21, 22, 23, 24, 25, 29, 31,
	35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 50, 51,
]

static func is_interior_scene(scene_no: int) -> bool:
	return INTERIOR_SCENES.has(scene_no)

func _ready() -> void:
	sun.name = "Sun"
	moon.name = "Moon"
	world_environment.name = "LightingEnvironment"
	add_child(sun)
	add_child(moon)
	add_child(world_environment)

	# Disabled until the lit renderer is explicitly selected (F4 key).
	sun.visible = false
	moon.visible = false
	sun.shadow_enabled = true
	moon.shadow_enabled = true

	# Soft-shadow filter quality: SOFT_MEDIUM balances PCF tap count against sample cost.
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
	for light in [sun, moon]:
		# Single cascade on purpose. With 4 splits the cascade boundaries (250/625/1250/
		# 2500 units) form concentric rings around the camera, i.e. they are present
		# EVERYWHERE in the map, and split blending plus the per-frame refit made
		# shadows pop globally. One orthographic cascade has no seams, no blending and
		# no split transitions. Combined with the 8192 atlas over a 1500-unit range the
		# texel density is better than the 4-split setup had.
		light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		# The earlier lone max_distance test (2500 -> 6000) could not work: Godot fits
		# the shadow frustum to the CAMERA frustum and then clamps it by max_distance,
		# while the Lit camera far was still 2500. The colour pass does not use the
		# camera far at all (it renders through u_projection, the GX projection), so
		# geometry beyond 2500 was visible but shadowless; walking pushed objects
		# across that boundary and their shadow popped. Far and max_distance are now
		# raised TOGETHER, with near-biased splits so close shadows stay sharp.
		light.directional_shadow_max_distance = 4000.0
		light.directional_shadow_split_1 = 0.10  # unused in SHADOW_ORTHOGONAL
		light.directional_shadow_split_2 = 0.25  # unused in SHADOW_ORTHOGONAL
		light.directional_shadow_split_3 = 0.50  # unused in SHADOW_ORTHOGONAL
		light.directional_shadow_blend_splits = false  # one cascade: nothing to blend
		# Keep the soft far edge. A hard cutoff (fade_start = 1.0) was tried and
		# felt worse to the user, so the 15% fade stays.
		light.directional_shadow_fade_start = 0.85
		light.shadow_blur = 1.5
		# Bias scales with texel size: after the atlas went 4096 -> 8192 the same
		# world-space bias spans twice as many texels, which pushed every shadow
		# lookup further off the surface and visibly weakened all shadows. Finer
		# texels need LESS bias, so both are back near Godot's defaults (2.0/0.1).
		light.shadow_normal_bias = 0.5
		light.shadow_bias = 0.1

	var sky := Sky.new()
	sky.sky_material = _sky_material
	lighting_environment.sky = sky
	lighting_environment.background_mode = Environment.BG_SKY
	lighting_environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	lighting_environment.ambient_light_sky_contribution = 0.0
	lighting_environment.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	lighting_environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	lighting_environment.sdfgi_enabled = enable_sdfgi
	lighting_environment.sdfgi_cascades = 4
	lighting_environment.sdfgi_min_cell_size = 64.0
	lighting_environment.sdfgi_use_occlusion = false
	lighting_environment.ssao_enabled = false  # TEST: screen-space AO flickers with camera motion and reads like shadow popping
	lighting_environment.ssao_radius = 2.0
	lighting_environment.ssao_intensity = 0.5
	lighting_environment.glow_enabled = true
	lighting_environment.glow_intensity = 0.05
	lighting_environment.glow_hdr_threshold = 1.2
	lighting_environment.volumetric_fog_enabled = false

	# Attached only to the lit camera/environment path when enabled.
	world_environment.environment = null
	if not last_state.is_empty():
		apply_state(last_state)

func set_enabled(value: bool) -> void:
	enabled = value
	world_environment.environment = lighting_environment if enabled else null
	if not enabled:
		sun.visible = false
		moon.visible = false
	if not last_state.is_empty():
		apply_state(last_state)

## Mathematical sample of the 4 lighting phases:
## - Morgen (05:30 – 08:00): Warmes, flaches Licht.
## - Tag (08:00 – 17:30): Heller Zenit.
## - Abend/Dämmerung (17:30 – 19:30): Goldene Stunde & orangeroter Himmel.
## - Nacht (19:30 – 05:30): Mondlicht (kühles blau, reduzierte Energie), dunkler Nachthimmel.
static func sample_lighting_profile(t: float) -> Dictionary:
	# Normalize time into [0.0, 24.0)
	t = fposmod(t, 24.0)

	var phase: String = "Night"
	var sun_col: Color
	var sun_pwr: float = 0.0
	var moon_col: Color = Color(0.55, 0.72, 1.0)
	var moon_pwr: float = 0.0
	var sky_top: Color
	var sky_horiz: Color
	var amb_col: Color
	var amb_pwr: float

	if t >= 5.5 and t < 8.0:
		# --- Phase 1: Morgen (05:30 - 08:00) ---
		# Warm, low-angle light climbing into crisp morning.
		phase = "Morning"
		var progress := smoothstep(5.5, 8.0, t)

		# Sun color: starts at warm golden-apricot, rises to bright morning daylight
		sun_col = Color(1.0, 0.58, 0.28).lerp(Color(1.0, 0.94, 0.86), progress)
		sun_pwr = lerpf(0.05, 1.05, progress)

		# Moon fades out rapidly as dawn arrives
		moon_pwr = lerpf(0.08, 0.0, progress)

		# Sky: deep twilight navy to crisp morning blue with golden dawn horizon
		sky_top = Color(0.04, 0.08, 0.18).lerp(Color(0.24, 0.50, 0.84), progress)
		sky_horiz = Color(0.95, 0.58, 0.35).lerp(Color(0.68, 0.78, 0.88), progress)

		amb_col = Color(0.25, 0.24, 0.35).lerp(Color(0.68, 0.75, 0.85), progress)
		amb_pwr = lerpf(0.20, 0.45, progress)

	elif t >= 8.0 and t < 17.5:
		# --- Phase 2: Tag (08:00 - 17:30) ---
		# Bright daylight peaking at noon zenith.
		phase = "Day"
		if t <= 12.0:
			var noon_prog := smoothstep(8.0, 12.0, t)
			sun_col = Color(1.0, 0.94, 0.86).lerp(Color(1.0, 0.98, 0.94), noon_prog)
			sun_pwr = lerpf(1.05, 1.25, noon_prog)
			sky_top = Color(0.24, 0.50, 0.84).lerp(Color(0.25, 0.52, 0.86), noon_prog)
			sky_horiz = Color(0.68, 0.78, 0.88).lerp(Color(0.70, 0.82, 0.92), noon_prog)
			amb_col = Color(0.68, 0.75, 0.85).lerp(Color(0.72, 0.80, 0.90), noon_prog)
			amb_pwr = lerpf(0.45, 0.50, noon_prog)
		else:
			var aft_prog := smoothstep(12.0, 17.5, t)
			sun_col = Color(1.0, 0.98, 0.94).lerp(Color(1.0, 0.78, 0.45), aft_prog)
			sun_pwr = lerpf(1.25, 0.95, aft_prog)
			sky_top = Color(0.25, 0.52, 0.86).lerp(Color(0.18, 0.32, 0.60), aft_prog)
			sky_horiz = Color(0.70, 0.82, 0.92).lerp(Color(0.92, 0.62, 0.32), aft_prog)
			amb_col = Color(0.72, 0.80, 0.90).lerp(Color(0.55, 0.45, 0.40), aft_prog)
			amb_pwr = lerpf(0.50, 0.38, aft_prog)
		moon_pwr = 0.0

	elif t >= 17.5 and t < 19.5:
		# --- Phase 3: Abend/Dämmerung (17:30 - 19:30) ---
		# Golden hour to fiery sunset to dusk.
		phase = "Evening"
		if t <= 18.5:
			# Golden hour to sunset peak (17:30 - 18:30)
			var eve_prog := smoothstep(17.5, 18.5, t)
			sun_col = Color(1.0, 0.78, 0.45).lerp(Color(1.0, 0.42, 0.12), eve_prog)
			sun_pwr = lerpf(0.95, 0.40, eve_prog)
			sky_top = Color(0.18, 0.32, 0.60).lerp(Color(0.08, 0.12, 0.30), eve_prog)
			sky_horiz = Color(0.92, 0.62, 0.32).lerp(Color(0.96, 0.35, 0.12), eve_prog)
			amb_col = Color(0.55, 0.45, 0.40).lerp(Color(0.40, 0.25, 0.28), eve_prog)
			amb_pwr = lerpf(0.38, 0.28, eve_prog)
			moon_pwr = lerpf(0.0, 0.04, eve_prog)
		else:
			# Sunset peak to nightfall (18:30 - 19:30)
			var dusk_prog := smoothstep(18.5, 19.5, t)
			sun_col = Color(1.0, 0.42, 0.12).lerp(Color(0.70, 0.20, 0.08), dusk_prog)
			sun_pwr = lerpf(0.40, 0.0, dusk_prog)
			sky_top = Color(0.08, 0.12, 0.30).lerp(Color(0.025, 0.035, 0.090), dusk_prog)
			sky_horiz = Color(0.96, 0.35, 0.12).lerp(Color(0.08, 0.09, 0.18), dusk_prog)
			amb_col = Color(0.40, 0.25, 0.28).lerp(Color(0.18, 0.22, 0.38), dusk_prog)
			amb_pwr = lerpf(0.28, 0.20, dusk_prog)
			moon_pwr = lerpf(0.04, 0.10, dusk_prog)

	else:
		# --- Phase 4: Nacht (19:30 - 05:30) ---
		# Cool blue moonlight and dark nocturnal sky.
		phase = "Night"
		sun_pwr = 0.0
		sun_col = Color(1.0, 0.60, 0.35) # Dormant

		var night_norm: float
		if t >= 19.5:
			# 19.5 -> 24.0 (length 4.5h)
			night_norm = (t - 19.5) / 10.0 # [0.0 .. 0.45]
		else:
			# 0.0 -> 5.5 (length 5.5h)
			night_norm = (t + 4.5) / 10.0  # [0.45 .. 1.0]

		# Midnight is reached around night_norm = 0.45 (00:00) to 0.65 (02:00)
		var deep_night := sin(night_norm * PI) # peaks around 01:00-02:00
		moon_pwr = lerpf(0.10, 0.22, deep_night)
		sky_top = Color(0.025, 0.035, 0.090).lerp(Color(0.012, 0.020, 0.050), deep_night)
		sky_horiz = Color(0.08, 0.09, 0.18).lerp(Color(0.035, 0.050, 0.100), deep_night)
		amb_col = Color(0.18, 0.22, 0.38).lerp(Color(0.14, 0.18, 0.35), deep_night)
		amb_pwr = lerpf(0.20, 0.16, deep_night)

	return {
		"phase": phase,
		"sun_color": sun_col,
		"sun_energy": sun_pwr,
		"moon_color": moon_col,
		"moon_energy": moon_pwr,
		"sky_top_color": sky_top,
		"sky_horizon_color": sky_horiz,
		"ambient_color": amb_col,
		"ambient_energy": amb_pwr,
	}

func apply_state(state: Dictionary) -> void:
	for key in ["hour", "minute"]:
		if not state.has(key):
			return
	var hour := int(state.get("hour", 0))
	var minute := int(state.get("minute", 0))
	var second := int(state.get("second", 0))
	var raw_weather := int(state.get("weather", Weather.CLEAR))
	var weather := debug_weather_override if debug_weather_override >= 0 else raw_weather
	var season := int(state.get("season", Season.SPRING))

	if hour < 0 or hour > 23 or minute < 0 or minute > 59 or second < 0 or second > 59:
		return
	if weather < Weather.CLEAR or weather > Weather.LEAVES:
		return
	if season < Season.SPRING or season > Season.WINTER:
		return

	last_state = state.duplicate()
	var scene_no := int(state.get("scene_no", -1))
	var is_interior := is_interior_scene(scene_no)

	var time_hours := fposmod(float(hour) + float(minute) / 60.0 + float(second) / 3600.0 + debug_time_offset_hours, 24.0)
	current_time_hours = time_hours

	# Visual orbit: 06:00 is sunrise (orbit 0), 12:00 is noon (PI/2), 18:00 is sunset (PI), 24:00 is midnight (3PI/2)
	var orbit := (time_hours - 6.0) * TAU / 24.0
	var sun_altitude := sin(orbit)
	var moon_altitude := -sun_altitude

	current_orbit = orbit
	current_sun_altitude = sun_altitude
	current_moon_altitude = moon_altitude

	# Rotate sun and moon
	sun.rotation = Vector3(-orbit, deg_to_rad(-35.0), 0.0)
	moon.rotation = Vector3(-(orbit + PI), deg_to_rad(-35.0), 0.0)

	# Sample the 4-phase day/night lighting profile
	var p := sample_lighting_profile(time_hours)
	current_phase_name = p.phase

	var wet := weather == Weather.RAIN or weather == Weather.SNOW
	var cloud_factor := 0.42 if wet else 1.0

	var sun_pwr: float = float(p.sun_energy) * cloud_factor
	# Sun is only physically above the horizon when sun_altitude > 0
	if sun_altitude <= 0.0:
		sun_pwr = 0.0

	var moon_pwr: float = float(p.moon_energy) * cloud_factor
	if moon_altitude <= 0.0:
		moon_pwr = 0.0

	sun.light_energy = sun_pwr
	sun.light_color = p.sun_color
	moon.light_energy = moon_pwr
	moon.light_color = p.moon_color

	# Interior rooms: pure black background and lights off (matches GameCube original interior)
	if is_interior:
		sun.visible = false
		moon.visible = false
		lighting_environment.background_mode = Environment.BG_COLOR
		lighting_environment.background_color = Color.BLACK
	else:
		lighting_environment.background_mode = Environment.BG_SKY
		# Retro protection: ONLY visible when enabled (Lit mode) AND light has positive energy
		sun.visible = enabled and (sun.light_energy > 0.001)
		moon.visible = enabled and (moon.light_energy > 0.001)

	# Sky & Ambient
	var sky_top: Color = p.sky_top_color
	var sky_horiz: Color = p.sky_horizon_color
	var amb_col: Color = p.ambient_color
	var amb_pwr: float = float(p.ambient_energy)

	if season == Season.WINTER:
		sky_top = sky_top.lerp(Color(0.38, 0.52, 0.70), 0.20)

	if wet:
		var overcast := Color(0.35, 0.38, 0.42)
		sky_top = sky_top.lerp(overcast, 0.70)
		sky_horiz = sky_horiz.lerp(overcast, 0.75)
		amb_col = amb_col.lerp(overcast, 0.60)
		amb_pwr *= 0.85

	_sky_material.sky_top_color = sky_top
	_sky_material.sky_horizon_color = sky_horiz
	_sky_material.ground_bottom_color = sky_top.darkened(0.65)
	_sky_material.ground_horizon_color = sky_horiz

	lighting_environment.ambient_light_color = amb_col
	lighting_environment.ambient_light_energy = amb_pwr
	lighting_environment.fog_enabled = wet
	lighting_environment.fog_light_color = sky_horiz
	lighting_environment.fog_density = 0.00012 if wet else 0.0
