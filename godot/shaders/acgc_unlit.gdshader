shader_type spatial;
render_mode unshaded, cull_disabled;

// --- Transforms & Projection ---
uniform mat4 u_projection;
uniform mat4 u_modelview;
uniform mat3 u_normal_mtx;
uniform vec4 u_texmtx_row0[2];
uniform vec4 u_texmtx_row1[2];
uniform int u_texmtx_enable[2];
uniform int u_texgen_src[2];

// --- Fog ---
uniform int u_fog_enable;
uniform vec4 u_fog_params;
uniform vec4 u_fog_color;

// --- TEV Registers ---
uniform vec4 u_tev_prev;
uniform vec4 u_tev_reg0;
uniform vec4 u_tev_reg1;
uniform vec4 u_tev_reg2;

// --- Per-Stage TEV Config ---
uniform int u_num_tev_stages;
uniform ivec4 u_tev_color_in[3];
uniform ivec4 u_tev_alpha_in[3];
uniform int u_tev_color_op[3];
uniform int u_tev_alpha_op[3];
uniform int u_tev_tc_src[3];
uniform ivec4 u_tev_bsc[3];
uniform ivec4 u_tev_out[3];
uniform ivec2 u_tev_swap[3];
uniform ivec4 u_tev_ind_cfg[3];
uniform ivec3 u_tev_ind_wrap[3];

// --- Textures ---
uniform sampler2D u_texture0 : filter_linear, repeat_enable;
uniform sampler2D u_texture1 : filter_linear, repeat_enable;
uniform sampler2D u_texture2 : filter_linear, repeat_enable;
uniform int u_use_texture[3];
uniform ivec2 u_tex_wrap[3];

// --- Lighting ---
uniform ivec4 u_lighting_cfg0;
uniform ivec4 u_lighting_cfg1;
uniform vec4 u_chan_color[2];
uniform vec3 u_light_pos[8];
uniform vec4 u_light_color[8];

// --- KONST Colors ---
uniform vec4 u_kcolor[4];
uniform ivec3 u_tev_ksel[3];

// --- Swap Tables ---
uniform ivec4 u_swap_table[4];

// --- Alpha Compare & Scissor ---
uniform ivec3 u_alpha_ctrl;
uniform ivec2 u_alpha_refs;
uniform ivec4 u_scissor;
uniform vec4 u_vp_transform;

// --- Indirect Textures ---
uniform int u_num_ind_stages;
uniform sampler2D u_ind_tex0 : filter_linear, repeat_enable;
uniform sampler2D u_ind_tex1 : filter_linear, repeat_enable;
uniform vec2 u_ind_scale[4];
uniform vec3 u_ind_mtx_r0[3];
uniform vec3 u_ind_mtx_r1[3];

// --- Instance Uniforms for Normal Matrix ---
instance uniform vec3 u_normal_r0 = vec3(1.0, 0.0, 0.0);
instance uniform vec3 u_normal_r1 = vec3(0.0, 1.0, 0.0);
instance uniform vec3 u_normal_r2 = vec3(0.0, 0.0, 1.0);

// --- Varyings ---
varying vec4 v_color;
varying vec2 v_texcoord0;
varying vec2 v_texcoord1;
varying vec3 v_normal;
varying float v_fog_z;

void vertex() {
	vec4 eyePos = MODEL_MATRIX * vec4(VERTEX, 1.0);
	POSITION = u_projection * eyePos;
	POSITION.y = -POSITION.y;
	POSITION.z = (POSITION.w - POSITION.z) * 0.5;

	if (u_vp_transform.x > 0.0 && (u_vp_transform.x != 1.0 || u_vp_transform.y != 1.0 || u_vp_transform.z != 0.0 || u_vp_transform.w != 0.0)) {
		POSITION.x = POSITION.x * u_vp_transform.x + POSITION.w * u_vp_transform.z;
		POSITION.y = POSITION.y * u_vp_transform.y + POSITION.w * u_vp_transform.w;
	}

	v_fog_z = -eyePos.z;
	v_color = COLOR;
	mat3 nrm_mtx = mat3(u_normal_r0, u_normal_r1, u_normal_r2);
	vec3 transformed_norm = nrm_mtx * NORMAL;
	v_normal = (dot(transformed_norm, transformed_norm) > 1e-6) ? normalize(transformed_norm) : vec3(0.0, 1.0, 0.0);

	vec4 tc0 = (u_texgen_src[0] == 1) ? vec4(v_normal, 1.0) : vec4(UV, 0.0, 1.0);
	if (u_texmtx_enable[0] != 0) {
		v_texcoord0 = vec2(dot(u_texmtx_row0[0], tc0), dot(u_texmtx_row1[0], tc0));
	} else {
		v_texcoord0 = tc0.xy;
	}

	vec4 tc1 = (u_texgen_src[1] == 1) ? vec4(v_normal, 1.0) : vec4(UV, 0.0, 1.0);
	if (u_texmtx_enable[1] != 0) {
		v_texcoord1 = vec2(dot(u_texmtx_row0[1], tc1), dot(u_texmtx_row1[1], tc1));
	} else {
		v_texcoord1 = tc1.xy;
	}
}

vec3 getKonstC(int sel) {
	if (sel <= 7) return vec3(float(8 - sel) / 8.0);
	if (sel <= 11) return vec3(0.0);
	if (sel <= 15) return u_kcolor[sel - 12].rgb;
	int ki = (sel - 16) & 3;
	int ch = (sel - 16) >> 2;
	switch (ch) {
		case 0: return vec3(u_kcolor[ki].r);
		case 1: return vec3(u_kcolor[ki].g);
		case 2: return vec3(u_kcolor[ki].b);
		default: return vec3(u_kcolor[ki].a);
	}
}

float getKonstA(int sel) {
	if (sel <= 7) return float(8 - sel) / 8.0;
	if (sel <= 15) return 0.0;
	int ki = (sel - 16) & 3;
	int ch = (sel - 16) >> 2;
	switch (ch) {
		case 0: return u_kcolor[ki].r;
		case 1: return u_kcolor[ki].g;
		case 2: return u_kcolor[ki].b;
		default: return u_kcolor[ki].a;
	}
}

vec3 getTevC(int id, vec4 prev, vec4 tex, vec4 ras,
			 vec4 r0, vec4 r1, vec4 r2, vec3 konst) {
	switch (id) {
		case 0: return prev.rgb;
		case 1: return vec3(prev.a);
		case 2: return r0.rgb;
		case 3: return vec3(r0.a);
		case 4: return r1.rgb;
		case 5: return vec3(r1.a);
		case 6: return r2.rgb;
		case 7: return vec3(r2.a);
		case 8: return tex.rgb;
		case 9: return vec3(tex.a);
		case 10: return ras.rgb;
		case 11: return vec3(ras.a);
		case 12: return vec3(1.0);
		case 13: return vec3(0.5);
		case 14: return konst;
		default: return vec3(0.0);
	}
}

float getTevA(int id, float prev, float tex, float ras,
			  float r0, float r1, float r2, float konst) {
	switch (id) {
		case 0: return prev;
		case 1: return r0;
		case 2: return r1;
		case 3: return r2;
		case 4: return tex;
		case 5: return ras;
		case 6: return konst;
		default: return 0.0;
	}
}

vec4 applySwap(vec4 v, ivec4 sw) {
	return vec4(v[sw.x], v[sw.y], v[sw.z], v[sw.w]);
}

vec2 applyWrap(vec2 coord, ivec2 wrap, vec2 tex_sz) {
	vec2 half_t = 0.5 / max(tex_sz, vec2(1.0));
	if (wrap.x == 0) {
		coord.x = clamp(coord.x, half_t.x, 1.0 - half_t.x);
	} else if (wrap.x == 2) {
		float m = mod(coord.x, 2.0);
		coord.x = clamp((m > 1.0) ? (2.0 - m) : m, half_t.x, 1.0 - half_t.x);
	}
	if (wrap.y == 0) {
		coord.y = clamp(coord.y, half_t.y, 1.0 - half_t.y);
	} else if (wrap.y == 2) {
		float m = mod(coord.y, 2.0);
		coord.y = clamp((m > 1.0) ? (2.0 - m) : m, half_t.y, 1.0 - half_t.y);
	}
	return coord;
}

vec4 tevStage(ivec4 cin, int cop, ivec4 ain, int aop,
			  vec4 prev, vec4 tex, vec4 ras,
			  vec4 r0, vec4 r1, vec4 r2,
			  vec3 konstC, float konstA) {
	vec3 ca = getTevC(cin.x, prev, tex, ras, r0, r1, r2, konstC);
	vec3 cb = getTevC(cin.y, prev, tex, ras, r0, r1, r2, konstC);
	vec3 cc = getTevC(cin.z, prev, tex, ras, r0, r1, r2, konstC);
	vec3 cd = getTevC(cin.w, prev, tex, ras, r0, r1, r2, konstC);
	vec3 blend = mix(ca, cb, cc);
	vec3 cResult = (cop == 1) ? (cd - blend) : (cd + blend);

	float aa = getTevA(ain.x, prev.a, tex.a, ras.a, r0.a, r1.a, r2.a, konstA);
	float ab = getTevA(ain.y, prev.a, tex.a, ras.a, r0.a, r1.a, r2.a, konstA);
	float ac = getTevA(ain.z, prev.a, tex.a, ras.a, r0.a, r1.a, r2.a, konstA);
	float ad = getTevA(ain.w, prev.a, tex.a, ras.a, r0.a, r1.a, r2.a, konstA);
	float aBlend = mix(aa, ab, ac);
	float aResult = (aop == 1) ? (ad - aBlend) : (ad + aBlend);

	return vec4(cResult, aResult);
}

vec4 applyBSC(vec4 v, ivec4 bsc) {
	switch (bsc.x) {
		case 1: v.rgb += 0.5; break;
		case 2: v.rgb -= 0.5; break;
	}
	switch (bsc.y) {
		case 1: v.rgb *= 2.0; break;
		case 2: v.rgb *= 4.0; break;
		case 3: v.rgb *= 0.5; break;
	}
	switch (bsc.z) {
		case 1: v.a += 0.5; break;
		case 2: v.a -= 0.5; break;
	}
	switch (bsc.w) {
		case 1: v.a *= 2.0; break;
		case 2: v.a *= 4.0; break;
		case 3: v.a *= 0.5; break;
	}
	return v;
}

void writeToReg(vec4 val, ivec4 out_cfg,
				inout vec4 prev, inout vec4 r0, inout vec4 r1, inout vec4 r2) {
	vec3 rgb = clamp(val.rgb, 0.0, 1.0);
	float a = clamp(val.a, 0.0, 1.0);
	switch (out_cfg.z) {
		case 0: prev.rgb = rgb; break;
		case 1: r0.rgb = rgb; break;
		case 2: r1.rgb = rgb; break;
		default: r2.rgb = rgb; break;
	}
	switch (out_cfg.w) {
		case 0: prev.a = a; break;
		case 1: r0.a = a; break;
		case 2: r1.a = a; break;
		default: r2.a = a; break;
	}
}

vec3 sampleIndTex(int ind_stage, vec2 tc0, vec2 tc1) {
	vec2 tc = (ind_stage == 0) ? tc0 : tc1;
	vec4 s = (ind_stage == 0) ? texture(u_ind_tex0, tc) : texture(u_ind_tex1, tc);
	return s.rgb;
}

vec2 applyIndirect(ivec4 ind_cfg, ivec3 ind_wrap, vec2 coord,
				   vec2 prev_offset, vec2 tc0, vec2 tc1) {
	int ind_mtx_id = ind_cfg.y;
	if (ind_mtx_id == 0) return coord;

	vec3 indSample = sampleIndTex(ind_cfg.x, tc0, tc1);
	int bias = ind_cfg.z;
	vec3 biased = indSample;
	if ((bias & 1) != 0) biased.x -= 0.5;
	if ((bias & 2) != 0) biased.y -= 0.5;
	if ((bias & 4) != 0) biased.z -= 0.5;

	vec2 offset = vec2(0.0);
	int idx;
	if (ind_mtx_id >= 1 && ind_mtx_id <= 3) {
		idx = ind_mtx_id - 1;
		offset.x = dot(u_ind_mtx_r0[idx], biased);
		offset.y = dot(u_ind_mtx_r1[idx], biased);
	} else if (ind_mtx_id >= 5 && ind_mtx_id <= 7) {
		idx = ind_mtx_id - 5;
		offset.x = dot(u_ind_mtx_r0[idx], biased);
		offset.y = 0.0;
	} else if (ind_mtx_id >= 9 && ind_mtx_id <= 11) {
		idx = ind_mtx_id - 9;
		offset.x = 0.0;
		offset.y = dot(u_ind_mtx_r1[idx], biased);
	}

	if (ind_wrap.z != 0) offset += prev_offset;

	vec2 wrappedCoord = coord;
	if (ind_wrap.x == 6) wrappedCoord.x = 0.0;
	else if (ind_wrap.x >= 1 && ind_wrap.x <= 5) {
		float wrapSize = float(1 << (9 - ind_wrap.x));
		float w = coord.x * 256.0;
		wrappedCoord.x = (w - wrapSize * floor(w / wrapSize)) / 256.0;
	}
	if (ind_wrap.y == 6) wrappedCoord.y = 0.0;
	else if (ind_wrap.y >= 1 && ind_wrap.y <= 5) {
		float wrapSize = float(1 << (9 - ind_wrap.y));
		float w = coord.y * 256.0;
		wrappedCoord.y = (w - wrapSize * floor(w / wrapSize)) / 256.0;
	}

	return wrappedCoord + offset;
}

bool alphaTest(int comp, float val, float ref) {
	const float EPS = 0.5 / 255.0;
	switch (comp) {
		case 0: return false;
		case 1: return val < ref;
		case 2: return abs(val - ref) < EPS;
		case 3: return val <= ref;
		case 4: return val > ref;
		case 5: return abs(val - ref) >= EPS;
		case 6: return val >= ref;
		default: return true;
	}
}


vec3 srgbToLinear(vec3 c) {
	return mix(c / 12.92, pow((c + vec3(0.055)) / 1.055, vec3(2.4)), greaterThan(c, vec3(0.04045)));
}

void fragment() {
	if (u_scissor.z > 0 && u_scissor.w > 0) {
		if (FRAGCOORD.x < float(u_scissor.x) || FRAGCOORD.x > float(u_scissor.x + u_scissor.z) ||
			FRAGCOORD.y < float(u_scissor.y) || FRAGCOORD.y > float(u_scissor.y + u_scissor.w)) {
			discard;
		}
	}

	vec2 tc[2];
	tc[0] = v_texcoord0;
	tc[1] = v_texcoord1;

	vec2 stc[3];
	{
		vec2 ind_prev_offset = vec2(0.0);
		for (int s = 0; s < u_num_tev_stages; s++) {
			vec2 base = tc[u_tev_tc_src[s]];
			stc[s] = base;
			if (u_num_ind_stages > 0 && u_tev_ind_cfg[s].y != 0) {
				stc[s] = applyIndirect(u_tev_ind_cfg[s], u_tev_ind_wrap[s],
									   stc[s], ind_prev_offset, tc[0], tc[1]);
				ind_prev_offset = stc[s] - base;
			}
		}
	}

	vec4 texColor[3];
	texColor[0] = (u_use_texture[0] != 0) ? texture(u_texture0, applyWrap(stc[0], u_tex_wrap[0], vec2(textureSize(u_texture0, 0)))) : vec4(1.0);
	texColor[1] = (u_use_texture[1] != 0) ? texture(u_texture1, applyWrap(stc[1], u_tex_wrap[1], vec2(textureSize(u_texture1, 0)))) : vec4(1.0);
	texColor[2] = (u_use_texture[2] != 0) ? texture(u_texture2, applyWrap(stc[2], u_tex_wrap[2], vec2(textureSize(u_texture2, 0)))) : vec4(1.0);

	vec4 rasColor;
	if (u_lighting_cfg0.w == 0) {
		rasColor = vec4(1.0);
	} else {
		vec3 matC = (u_lighting_cfg0.y != 0) ? v_color.rgb : u_chan_color[0].rgb;
		vec3 ambC = (u_lighting_cfg0.z != 0) ? v_color.rgb : u_chan_color[1].rgb;
		if (u_lighting_cfg0.x != 0) {
			vec3 lightAccum = ambC;
			for (int i = 0; i < 8; i++) {
				if ((u_lighting_cfg1.z & (1 << i)) != 0) {
					vec3 L = normalize(u_light_pos[i]);
					float diff = clamp(dot(v_normal, L), 0.0, 1.0);
					lightAccum += diff * u_light_color[i].rgb;
				}
			}
			rasColor.rgb = matC * clamp(lightAccum, 0.0, 1.0);
		} else {
			rasColor.rgb = matC;
		}
		float matA = (u_lighting_cfg1.y != 0) ? v_color.a : u_chan_color[0].a;
		rasColor.a = (u_lighting_cfg1.x != 0) ? matA * u_chan_color[1].a : matA;
	}
	rasColor = clamp(rasColor, 0.0, 1.0);

	vec4 prev = u_tev_prev;
	vec4 r0 = u_tev_reg0;
	vec4 r1 = u_tev_reg1;
	vec4 r2 = u_tev_reg2;

	for (int s = 0; s < u_num_tev_stages; s++) {
		ivec2 swap = u_tev_swap[s];
		vec4 sTex = applySwap(texColor[s], u_swap_table[swap.y]);
		vec4 sRas = applySwap(rasColor, u_swap_table[swap.x]);
		vec3 kc = getKonstC(u_tev_ksel[s].x);
		float ka = getKonstA(u_tev_ksel[s].y);
		vec4 result = tevStage(u_tev_color_in[s], u_tev_color_op[s],
							   u_tev_alpha_in[s], u_tev_alpha_op[s],
							   prev, sTex, sRas, r0, r1, r2, kc, ka);
		result = applyBSC(result, u_tev_bsc[s]);
		writeToReg(result, u_tev_out[s], prev, r0, r1, r2);
	}

	if (u_alpha_ctrl.x != 7 || u_alpha_ctrl.z != 7) {
		float ref0 = float(u_alpha_refs.x) / 255.0;
		float ref1 = float(u_alpha_refs.y) / 255.0;
		bool pass0 = alphaTest(u_alpha_ctrl.x, prev.a, ref0);
		bool pass1 = alphaTest(u_alpha_ctrl.z, prev.a, ref1);
		bool pass;
		switch (u_alpha_ctrl.y) {
			case 0: pass = pass0 && pass1; break;
			case 1: pass = pass0 || pass1; break;
			case 2: pass = pass0 != pass1; break;
			default: pass = pass0 == pass1; break;
		}
		if (!pass) discard;
	}

	vec4 outCol = prev;

	if (u_fog_enable != 0) {
		float fog_denom = max(u_fog_params.z - u_fog_params.y, 1e-6);
		float fog_factor = clamp((v_fog_z - u_fog_params.y) / fog_denom, 0.0, 1.0);
		outCol.rgb = mix(outCol.rgb, u_fog_color.rgb, fog_factor);
	}

		ALBEDO = srgbToLinear(clamp(outCol.rgb, 0.0, 1.0));
// ##ALPHA_OUTPUT##
}
