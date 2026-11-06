import math

def smoothstep(from_val, to_val, x):
    if from_val == to_val: return 0.0
    t = max(0.0, min(1.0, (x - from_val) / (to_val - from_val)))
    return t * t * (3.0 - 2.0 * t)

def lerp(a, b, t):
    return a + (b - a) * t

class Color:
    def __init__(self, r, g, b):
        self.r = float(r)
        self.g = float(g)
        self.b = float(b)
    def lerp(self, other, t):
        return Color(lerp(self.r, other.r, t), lerp(self.g, other.g, t), lerp(self.b, other.b, t))
    def __str__(self):
        return f"Color({self.r:.3f}, {self.g:.3f}, {self.b:.3f})"

def sample_lighting(hour, minute=0, second=0):
    t = (hour + minute / 60.0 + second / 3600.0) % 24.0
    tau = math.pi * 2.0
    orbit = (t - 6.0) * tau / 24.0
    sun_altitude = math.sin(orbit)
    moon_altitude = -sun_altitude

    sun_rot_x = -orbit
    sun_rot_y = math.radians(-35.0)
    sun_rot_z = 0.0

    moon_rot_x = -(orbit + math.pi)
    moon_rot_y = math.radians(-35.0)
    moon_rot_z = 0.0

    if 5.5 <= t < 8.0:
        phase = "Morning"
        progress = smoothstep(5.5, 8.0, t)
        sun_col = Color(1.0, 0.58, 0.28).lerp(Color(1.0, 0.94, 0.86), progress)
        sun_pwr = lerp(0.05, 1.05, progress)
        moon_pwr = lerp(0.08, 0.0, progress)
        sky_top = Color(0.04, 0.08, 0.18).lerp(Color(0.24, 0.50, 0.84), progress)
        sky_horiz = Color(0.95, 0.58, 0.35).lerp(Color(0.68, 0.78, 0.88), progress)
        amb_col = Color(0.25, 0.24, 0.35).lerp(Color(0.68, 0.75, 0.85), progress)
        amb_pwr = lerp(0.20, 0.45, progress)
    elif 8.0 <= t < 17.5:
        phase = "Day"
        if t <= 12.0:
            noon_prog = smoothstep(8.0, 12.0, t)
            sun_col = Color(1.0, 0.94, 0.86).lerp(Color(1.0, 0.98, 0.94), noon_prog)
            sun_pwr = lerp(1.05, 1.25, noon_prog)
            sky_top = Color(0.24, 0.50, 0.84).lerp(Color(0.25, 0.52, 0.86), noon_prog)
            sky_horiz = Color(0.68, 0.78, 0.88).lerp(Color(0.70, 0.82, 0.92), noon_prog)
            amb_col = Color(0.68, 0.75, 0.85).lerp(Color(0.72, 0.80, 0.90), noon_prog)
            amb_pwr = lerp(0.45, 0.50, noon_prog)
        else:
            aft_prog = smoothstep(12.0, 17.5, t)
            sun_col = Color(1.0, 0.98, 0.94).lerp(Color(1.0, 0.78, 0.45), aft_prog)
            sun_pwr = lerp(1.25, 0.95, aft_prog)
            sky_top = Color(0.25, 0.52, 0.86).lerp(Color(0.18, 0.32, 0.60), aft_prog)
            sky_horiz = Color(0.70, 0.82, 0.92).lerp(Color(0.92, 0.62, 0.32), aft_prog)
            amb_col = Color(0.72, 0.80, 0.90).lerp(Color(0.55, 0.45, 0.40), aft_prog)
            amb_pwr = lerp(0.50, 0.38, aft_prog)
        moon_pwr = 0.0
    elif 17.5 <= t < 19.5:
        phase = "Evening"
        if t <= 18.5:
            eve_prog = smoothstep(17.5, 18.5, t)
            sun_col = Color(1.0, 0.78, 0.45).lerp(Color(1.0, 0.42, 0.12), eve_prog)
            sun_pwr = lerp(0.95, 0.40, eve_prog)
            sky_top = Color(0.18, 0.32, 0.60).lerp(Color(0.08, 0.12, 0.30), eve_prog)
            sky_horiz = Color(0.92, 0.62, 0.32).lerp(Color(0.96, 0.35, 0.12), eve_prog)
            amb_col = Color(0.55, 0.45, 0.40).lerp(Color(0.40, 0.25, 0.28), eve_prog)
            amb_pwr = lerp(0.38, 0.28, eve_prog)
            moon_pwr = lerp(0.0, 0.04, eve_prog)
        else:
            dusk_prog = smoothstep(18.5, 19.5, t)
            sun_col = Color(1.0, 0.42, 0.12).lerp(Color(0.70, 0.20, 0.08), dusk_prog)
            sun_pwr = lerp(0.40, 0.0, dusk_prog)
            sky_top = Color(0.08, 0.12, 0.30).lerp(Color(0.025, 0.035, 0.090), dusk_prog)
            sky_horiz = Color(0.96, 0.35, 0.12).lerp(Color(0.08, 0.09, 0.18), dusk_prog)
            amb_col = Color(0.40, 0.25, 0.28).lerp(Color(0.18, 0.22, 0.38), dusk_prog)
            amb_pwr = lerp(0.28, 0.20, dusk_prog)
            moon_pwr = lerp(0.04, 0.10, dusk_prog)
    else:
        phase = "Night"
        sun_pwr = 0.0
        sun_col = Color(1.0, 0.60, 0.35)
        if t >= 19.5:
            night_norm = (t - 19.5) / 10.0
        else:
            night_norm = (t + 4.5) / 10.0
        deep_night = math.sin(night_norm * math.pi)
        moon_pwr = lerp(0.10, 0.22, deep_night)
        sky_top = Color(0.025, 0.035, 0.090).lerp(Color(0.012, 0.020, 0.050), deep_night)
        sky_horiz = Color(0.08, 0.09, 0.18).lerp(Color(0.035, 0.050, 0.100), deep_night)
        amb_col = Color(0.18, 0.22, 0.38).lerp(Color(0.14, 0.18, 0.35), deep_night)
        amb_pwr = lerp(0.20, 0.16, deep_night)

    # Physical horizon cutoff
    if sun_altitude <= 0.0:
        sun_pwr = 0.0
    if moon_altitude <= 0.0:
        moon_pwr = 0.0

    return {
        "time": f"{hour:02d}:{minute:02d}:{second:02d}",
        "t_hours": t,
        "phase": phase,
        "orbit_rad": orbit,
        "orbit_deg": math.degrees(orbit),
        "sun_altitude": sun_altitude,
        "sun_rotation": (sun_rot_x, sun_rot_y, sun_rot_z),
        "sun_energy": sun_pwr,
        "sun_color": str(sun_col),
        "sun_visible": sun_pwr > 0.001,
        "moon_altitude": moon_altitude,
        "moon_rotation": (moon_rot_x, moon_rot_y, moon_rot_z),
        "moon_energy": moon_pwr,
        "moon_color": "Color(0.550, 0.720, 1.000)",
        "moon_visible": moon_pwr > 0.001,
        "sky_top": str(sky_top),
        "sky_horiz": str(sky_horiz),
        "ambient_energy": amb_pwr,
        "ambient_color": str(amb_col)
    }

def print_checkpoint(h, m=0, s=0, label=""):
    res = sample_lighting(h, m, s)
    print(f"=== {res['time']} - {label} ===")
    print(f"  Phase:           {res['phase']}")
    print(f"  Orbit:           {res['orbit_rad']:.4f} rad ({res['orbit_deg']:.1f}°)")
    print(f"  Sun Altitude:    {res['sun_altitude']:+.4f} (sin(orbit))")
    print(f"  Sun Rotation:    Vector3({res['sun_rotation'][0]:.4f}, {res['sun_rotation'][1]:.4f}, {res['sun_rotation'][2]:.4f})")
    print(f"  Sun Energy:      {res['sun_energy']:.3f} (Visible: {res['sun_visible']})")
    print(f"  Sun Color:       {res['sun_color']}")
    print(f"  Moon Altitude:   {res['moon_altitude']:+.4f}")
    print(f"  Moon Rotation:   Vector3({res['moon_rotation'][0]:.4f}, {res['moon_rotation'][1]:.4f}, {res['moon_rotation'][2]:.4f})")
    print(f"  Moon Energy:     {res['moon_energy']:.3f} (Visible: {res['moon_visible']})")
    print(f"  Moon Color:      {res['moon_color']}")
    print(f"  Sky Top:         {res['sky_top']}")
    print(f"  Sky Horizon:     {res['sky_horiz']}")
    print(f"  Ambient Energy:  {res['ambient_energy']:.3f}")
    print(f"  Ambient Color:   {res['ambient_color']}\n")

if __name__ == "__main__":
    print_checkpoint(12, 0, 0, "High Noon / Zenith")
    print_checkpoint(20, 0, 0, "Night (Early Evening)")
    print_checkpoint(2, 0, 0, "Deep Night (Midnight Orbit)")
    print_checkpoint(6, 45, 0, "Morning Warm Light")
    print_checkpoint(18, 30, 0, "Evening / Sunset Golden Hour")
