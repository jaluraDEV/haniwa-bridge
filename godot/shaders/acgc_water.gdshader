shader_type spatial;
render_mode cull_disabled, blend_mix, depth_draw_never, diffuse_burley, specular_schlick_ggx;

// ACGC x Godot — WATER ULTRA / Forward+
// Keeps the ACGC GX projection remap and the original uniform names.
// Screen-space reflections are approximate, not hardware ray tracing.

const float WATER_TAU = 6.28318530718;
const float WATER_EPS = 0.000001;

// ACGC custom perspective, provided by the bridge. Do not replace these
// with Godot's PROJECTION_MATRIX / INV_PROJECTION_MATRIX in the main pass.
uniform mat4 u_projection;
uniform mat4 u_inverse_projection;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear_mipmap;

// Base palette — kept compatible with existing materials.
uniform vec4 u_shallow_color : source_color = vec4(0.12, 0.64, 0.61, 1.0);
uniform vec4 u_deep_color : source_color = vec4(0.025, 0.24, 0.36, 1.0);
uniform vec4 u_reflection_color : source_color = vec4(0.40, 0.68, 0.85, 1.0);
uniform vec4 u_foam_color : source_color = vec4(0.82, 0.96, 0.93, 1.0);

// Captured GX UVs are large integer-like coordinates, NOT [0, 1].
uniform float u_wave_uv_scale = 0.0009765625; // 1 / 1024
uniform float u_wave_height : hint_range(0.0, 12.0) = 6.8;
uniform float u_wave_speed : hint_range(0.0, 2.0) = 0.85;
uniform float u_wave_strength : hint_range(0.0, 0.5) = 0.23;
uniform float u_ripple_detail : hint_range(0.0, 1.0) = 0.85;

// All depth and wave distances are in captured GAME UNITS, not metres.
uniform float u_foam_width : hint_range(0.0, 24.0) = 5.5;
uniform float u_depth_distance : hint_range(10.0, 240.0) = 90.0;
uniform float u_foam_strength : hint_range(0.0, 2.0) = 1.15;
uniform float u_crest_foam : hint_range(0.0, 1.0) = 0.30;
uniform float u_caustics_strength : hint_range(0.0, 1.0) = 0.32;

uniform float u_reflection_strength : hint_range(0.0, 2.0) = 0.92;
uniform float u_refraction : hint_range(0.0, 0.1) = 0.010;
uniform float u_dispersion : hint_range(0.0, 1.0) = 0.20;
uniform float u_sparkle_strength : hint_range(0.0, 1.0) = 0.22;

// SSR: reflection of visible opaque objects in the screen/depth buffer.
// Heavy: disable u_ssr_enabled or lower u_ssr_steps if necessary.
uniform bool u_ssr_enabled = true;
uniform int u_ssr_steps : hint_range(8, 48, 1) = 28;
uniform float u_ssr_max_distance : hint_range(20.0, 500.0) = 220.0;
uniform float u_ssr_thickness : hint_range(0.5, 30.0) = 6.0;
uniform float u_ssr_strength : hint_range(0.0, 1.0) = 0.90;
uniform float u_ssr_blur : hint_range(0.0, 4.0) = 0.75;

// Varyings are VIEW SPACE (the name is kept for bridge compatibility).
varying vec3 v_world_pos;
varying vec3 v_base_position;
varying vec2 v_wave_uv;
varying float v_view_depth;

float water_hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float water_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = water_hash(i);
    float b = water_hash(i + vec2(1.0, 0.0));
    float c = water_hash(i + vec2(0.0, 1.0));
    float d = water_hash(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// Slow, asymmetric swell: avoid marching sine lines and repeating grids.
float swell(vec2 p, float t) {
    vec2 q = p + vec2(
        sin(p.y * 0.46 - t * 0.24),
        cos(p.x * 0.39 + t * 0.19)
    ) * 0.30;
    return sin(dot(q, vec2(0.86, 0.51)) - t * 1.17) * 0.53
         + sin(dot(q, vec2(-0.49, 1.08)) - t * 0.79 + 1.7) * 0.29
         + sin(dot(q, vec2(1.47, -0.37)) - t * 1.46 + 3.1) * 0.18;
}

// Same low-frequency displacement basis drives geometry and normals.
float surface_height(vec2 p, float t) {
    float low = swell(p, t);
    float medium = sin(dot(p, vec2(2.6, -1.8)) - t * 2.1 + low * 1.3);
    float crosswave = sin(dot(p, vec2(-2.0, -2.9)) + t * 1.65 - low * 0.9);
    return low + (medium * 0.13 + crosswave * 0.09) * u_ripple_detail;
}

// IMPORTANT: the exact ACGC clip-space remap is preserved here.
void vertex() {
    bool is_shadow_pass = abs(PROJECTION_MATRIX[3][3] - 1.0) < 0.001;
    v_base_position = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;

    vec2 p = UV * (u_wave_uv_scale * WATER_TAU);
    v_wave_uv = p;
    float t = TIME * u_wave_speed;
    float displacement = swell(p, t) * 0.52 +
                         sin(dot(p, vec2(-1.65, 0.72)) - t * 1.34) * 0.11;

    VERTEX += normalize(NORMAL) * displacement * u_wave_height;
    vec4 eye_pos = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);

    if (is_shadow_pass) {
        POSITION = PROJECTION_MATRIX * eye_pos;
    } else {
        POSITION = u_projection * eye_pos;
        POSITION.y = -POSITION.y;
        POSITION.z = (POSITION.w - POSITION.z) * 0.5;
    }

    v_world_pos = eye_pos.xyz;
    v_view_depth = -eye_pos.z;
}

// Invert the captured GX projection, not the Godot helper camera's projection.
float scene_eye_depth(vec2 uv, float raw_depth) {
    vec2 xy = uv * 2.0 - 1.0;
    vec4 v = u_inverse_projection * vec4(xy.x, -xy.y,
                                         1.0 - 2.0 * raw_depth, 1.0);
    return -v.z / (max(abs(v.w), WATER_EPS) * (v.w < 0.0 ? -1.0 : 1.0));
}

// Project view-space points through the SAME GX mapping as vertex().
vec2 eye_to_screen(vec3 eye_point) {
    vec4 clip = u_projection * vec4(eye_point, 1.0);
    return vec2(clip.x, -clip.y) / max(clip.w, WATER_EPS) * 0.5 + 0.5;
}

float screen_edge_mask(vec2 uv) {
    vec2 edge_dist = min(uv, vec2(1.0) - uv);
    return smoothstep(0.005, 0.09, min(edge_dist.x, edge_dist.y));
}

// Manual, limited SSR. The engine's automatic SSR does not work for
// screen-texture transparent materials. Return RGB + hit confidence.
vec4 trace_water_reflection(vec3 origin, vec3 direction) {
    int steps = max(u_ssr_steps, 1);
    float step_size = u_ssr_max_distance / float(steps);

    for (int i = 0; i < 48; i++) {
        if (i >= steps) {
            break;
        }
        float distance_along_ray = (float(i) + 1.0) * step_size;
        vec3 sample_pos = origin + direction * distance_along_ray;
        if (sample_pos.z >= -0.01) {
            break;
        }

        vec4 clip = u_projection * vec4(sample_pos, 1.0);
        if (clip.w <= WATER_EPS) {
            break;
        }
        vec2 uv = vec2(clip.x, -clip.y) / clip.w * 0.5 + 0.5;
        if (uv.x <= 0.003 || uv.x >= 0.997 || uv.y <= 0.003 || uv.y >= 0.997) {
            break;
        }

        float raw_depth = texture(depth_texture, uv).r;
        if (raw_depth <= WATER_EPS) {
            continue;
        }
        float scene_depth = scene_eye_depth(uv, raw_depth);
        float ray_depth = -sample_pos.z;
        float penetration = ray_depth - scene_depth;
        float thickness = u_ssr_thickness + step_size * 0.30;

        if (scene_depth > 0.0 && penetration >= 0.0 && penetration < thickness) {
            // Three bisection steps reduce shimmering along object silhouettes.
            float lo = max(distance_along_ray - step_size, 0.0);
            float hi = distance_along_ray;
            for (int j = 0; j < 3; j++) {
                float mid = (lo + hi) * 0.5;
                vec3 mid_pos = origin + direction * mid;
                vec2 mid_uv = eye_to_screen(mid_pos);
                if (mid_uv.x <= 0.0 || mid_uv.x >= 1.0 ||
                    mid_uv.y <= 0.0 || mid_uv.y >= 1.0) {
                    lo = mid;
                    continue;
                }
                float mid_raw = texture(depth_texture, mid_uv).r;
                float mid_depth = mid_raw > WATER_EPS
                    ? scene_eye_depth(mid_uv, mid_raw) : 1000000.0;
                if (-mid_pos.z > mid_depth) {
                    hi = mid;
                } else {
                    lo = mid;
                }
            }
            vec2 hit_uv = eye_to_screen(origin + direction * hi);
            float fade = screen_edge_mask(hit_uv) *
                         (1.0 - distance_along_ray / u_ssr_max_distance);
            // Limit very shallow / tangential depth coincidences.
            fade *= 1.0 - smoothstep(thickness * 0.55, thickness, penetration);
            vec3 reflected_rgb = textureLod(screen_texture,
                clamp(hit_uv, vec2(0.001), vec2(0.999)), u_ssr_blur).rgb;
            return vec4(reflected_rgb, clamp(fade, 0.0, 1.0));
        }
    }
    return vec4(0.0);
}

// Bright, moving thin lines (an artistic approximation, not bottom geometry).
float water_caustics(vec2 p, float t) {
    vec2 q = p * 2.1;
    q += vec2(sin(q.y * 1.11 + t * 0.87),
              cos(q.x * 1.27 - t * 0.76)) * 0.26;
    float a = sin(q.x * 2.83 + sin(q.y * 1.96 + t * 0.8));
    float b = sin(q.y * 2.55 - sin(q.x * 2.24 - t * 0.7));
    float line = 1.0 - abs(a * b);
    return pow(clamp(line, 0.0, 1.0), 11.0);
}

void fragment() {
    vec2 p = v_wave_uv;
    float t = TIME * u_wave_speed;
    vec3 eye_view = normalize(-v_world_pos);

    // Smooth water normals from un-displaced plane + captured UV axes.
    // Keeps the highlight orientation stable on rotated/mirrored GX tiles.
    vec3 dx = dFdx(v_base_position);
    vec3 dy = dFdy(v_base_position);
    vec3 base_normal = normalize(cross(dx, dy));
    if (dot(base_normal, eye_view) < 0.0) {
        base_normal = -base_normal;
    }

    vec2 du = dFdx(p);
    vec2 dv = dFdy(p);
    float uv_det = du.x * dv.y - du.y * dv.x;
    vec3 tangent = dx * dv.y - dy * du.y;
    vec3 bitangent = dy * du.x - dx * dv.x;

    // Distance/derivative filtering prevents far-away sparkling noise.
    float uv_footprint = max(length(du), length(dv));
    float medium_filter = 1.0 - smoothstep(0.28, 1.25, uv_footprint);
    float fine_filter = 1.0 - smoothstep(0.06, 0.35, uv_footprint);

    float h = surface_height(p, t);
    float h_x = surface_height(p + vec2(0.035, 0.0), t);
    float h_y = surface_height(p + vec2(0.0, 0.035), t);
    vec2 slope = vec2(h_x - h, h_y - h) / 0.035 * medium_filter;

    // Two travelling capillary layers: fine glints without a texture asset.
    float micro_a = dot(p, vec2(8.1, -4.3)) - t * 3.5 + h * 0.8;
    float micro_b = dot(p, vec2(-5.2, -9.7)) + t * 3.1 - h * 0.6;
    vec2 micro_slope = vec2(8.1, -4.3) * cos(micro_a) * 0.055 +
                       vec2(-5.2, -9.7) * cos(micro_b) * 0.043;
    slope += micro_slope * (u_ripple_detail * fine_filter);

    vec3 n = base_normal;
    if (abs(uv_det) > WATER_EPS &&
        dot(tangent, tangent) > WATER_EPS && dot(bitangent, bitangent) > WATER_EPS) {
        float handedness = uv_det < 0.0 ? -1.0 : 1.0;
        tangent = normalize(tangent) * handedness;
        bitangent = normalize(bitangent) * handedness;
        n = normalize(base_normal -
            (tangent * slope.x + bitangent * slope.y) * u_wave_strength * 2.5);
    }
    if (dot(n, eye_view) < 0.08) {
        n = normalize(mix(n, base_normal, 0.40));
    }
    NORMAL = n;

    // Optical water depth through the captured ACGC projection.
    float raw_depth = texture(depth_texture, SCREEN_UV).r;
    float water_depth = raw_depth > WATER_EPS
        ? max(scene_eye_depth(SCREEN_UV, raw_depth) - v_view_depth, 0.0)
        : u_depth_distance * 3.0;
    float depth_factor = 1.0 - exp(-water_depth / max(u_depth_distance, 0.001));

    // Refraction: only sample behind the water; reject foreground silhouettes.
    float refraction_visibility = smoothstep(0.0, 7.0, water_depth);
    vec2 offset = (n.xy - base_normal.xy) * u_refraction * refraction_visibility;
    // Small extra drifting distortion varies independently from swell.
    offset += vec2(sin(p.x * 3.2 + t * 2.2),
                   cos(p.y * 3.6 - t * 1.9)) * 0.00065 *
                   u_ripple_detail * fine_filter * refraction_visibility;
    vec2 refract_uv = clamp(SCREEN_UV + offset, vec2(0.001), vec2(0.999));
    float refract_raw = texture(depth_texture, refract_uv).r;
    if (refract_raw > WATER_EPS &&
        scene_eye_depth(refract_uv, refract_raw) < v_view_depth + 0.5) {
        refract_uv = SCREEN_UV;
        offset = vec2(0.0);
    }

    vec3 bottom_color = texture(screen_texture, refract_uv).rgb;
    if (u_dispersion > 0.001) {
        vec2 channel_offset = offset * u_dispersion * 0.35;
        bottom_color.r = texture(screen_texture,
            clamp(refract_uv + channel_offset, vec2(0.001), vec2(0.999))).r;
        bottom_color.b = texture(screen_texture,
            clamp(refract_uv - channel_offset, vec2(0.001), vec2(0.999))).b;
    }

    vec3 depth_tint = mix(u_shallow_color.rgb, u_deep_color.rgb, depth_factor);
    vec3 color = mix(bottom_color, depth_tint,
                     clamp(0.30 + depth_factor * 0.65, 0.0, 0.97));

    // Underwater light ribbons, strongest near the bank / visible bottom.
    float caustic_filter = 1.0 - smoothstep(0.20, 0.78, uv_footprint);
    float caustic = water_caustics(p, t) *
                    (1.0 - depth_factor) * caustic_filter *
                    u_caustics_strength;
    color += u_shallow_color.rgb * caustic * 0.50;

    // Broken shore foam, advancing and retreating over the depth edge.
    float bank_noise = water_noise(p * 2.3 + vec2(t * 0.15, -t * 0.12));
    float fine_noise = water_noise(p * 6.4 + vec2(-t * 0.35, t * 0.22));
    float wave_runup = sin(t * 1.40 + dot(p, vec2(1.1, 0.75))) * 0.48;
    float foam_band = max(u_foam_width, 0.001);
    float shore_depth = water_depth + wave_runup * foam_band * 0.32;
    float shore = 1.0 - smoothstep(0.0, foam_band, shore_depth);
    float breakup = smoothstep(0.29, 0.67,
                              bank_noise * 0.76 + fine_noise * 0.24);
    float shore_foam = shore * (0.30 + 0.70 * breakup);
    float crest_foam = smoothstep(0.55, 0.94, h + 0.12 * fine_noise) *
                       fine_filter * u_crest_foam;
    float foam = clamp((shore_foam + crest_foam) * u_foam_strength, 0.0, 1.0);

    // Schlick Fresnel (water F0 ~ 0.02) plus optional scene reflections.
    float n_dot_v = clamp(dot(n, eye_view), 0.0, 1.0);
    float fresnel = 0.02 + 0.98 * pow(1.0 - n_dot_v, 5.0);
    float glancing_reflection = clamp(0.10 + fresnel * 2.85, 0.0, 0.95);
    vec3 reflection_rgb = u_reflection_color.rgb;

    if (u_ssr_enabled && u_ssr_strength > 0.001 &&
        fresnel > 0.024 && foam < 0.92) {
        vec3 ray_dir = normalize(reflect(-eye_view, n));
        vec4 ssr = trace_water_reflection(v_world_pos + n * 1.2, ray_dir);
        reflection_rgb = mix(reflection_rgb, ssr.rgb,
                             ssr.a * u_ssr_strength);
    }
    color = mix(color, reflection_rgb,
                clamp(glancing_reflection * u_reflection_strength *
                      (1.0 - foam * 0.80), 0.0, 0.96));

    // Tiny, anti-aliased wind glints. They are lit by the scene (no EMISSION).
    float glint_phase = dot(p, vec2(3.7, 5.1)) - t * 2.65 + h * 2.3;
    float glint_aa = max(fwidth(glint_phase), 0.015);
    float glint = smoothstep(0.91 - glint_aa, 0.995 + glint_aa,
                             sin(glint_phase));
    float glint_mask = smoothstep(0.54, 0.86, bank_noise) * fine_filter;
    color += u_reflection_color.rgb * glint * glint_mask *
             u_sparkle_strength * (0.3 + fresnel) * (1.0 - foam);

    // Foam is rough, opaque-looking, and much less reflective than open water.
    vec3 foam_tint = u_foam_color.rgb * (0.88 + 0.12 * fine_noise);
    color = mix(color, foam_tint, foam * 0.87);

    ALBEDO = clamp(color, vec3(0.0), vec3(1.5));
    ALPHA = 1.0; // Still runs in the transparent pass due to screen sampling.
    METALLIC = 0.0;
    SPECULAR = 0.65;
    ROUGHNESS = mix(0.085 + bank_noise * 0.075, 0.73, foam);
    CLEARCOAT = (1.0 - foam) * 0.65;
    CLEARCOAT_ROUGHNESS = 0.11;
}
