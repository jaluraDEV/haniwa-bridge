# acfp_renderer.gd - Godot RenderingServer backend for ACGC Frame Packets (ACFP)
class_name ACFPRenderer
extends RefCounted

const ACFP_MAGIC = 0x50464341
const ACFP_VERSION = 1

# Opcodes
const CMD_SET_VIEWPORT_SCISSOR = 0x0001
const CMD_SET_PROJECTION       = 0x0002
const CMD_SET_TRANSFORMS       = 0x0003
const CMD_SET_DEPTH_BLEND      = 0x0004
const CMD_SET_ALPHA_TEST       = 0x0005
const CMD_SET_CULL             = 0x0006
const CMD_SET_FOG              = 0x0007
const CMD_SET_LIGHTING         = 0x0008
const CMD_SET_TEV_STAGE        = 0x0009
const CMD_SET_TEV_REGISTERS    = 0x000A
const CMD_BIND_TEXTURE         = 0x000B
const CMD_SET_INDIRECT         = 0x000C
const CMD_DRAW                 = 0x000D
const CMD_EFB_COPY             = 0x000E
const CMD_SET_TEXGEN           = 0x000F
const CMD_SET_VIEW_MATRIX      = 0x0010
const CMD_END_FRAME            = 0xFFFF

# Pass Types
const PASS_OPAQUE      = 0
const PASS_TRANSPARENT = 1
const PASS_UI          = 2

# Resource Caches
const MAX_CACHED_MESHES = 1024
const MAX_CACHED_TEXTURES = 4096
const MAX_CACHED_MATERIALS = 2048

# A mesh whose average object-space vertex normal points this strongly upward
# (+Y) is treated as flat ground/path: it receives shadows but does not cast
# them. Upright objects (actors, trees, buildings, signs) have sideways or
# mixed normals and keep casting. cos(45 deg) ~= 0.707.
const GROUND_NORMAL_THRESHOLD := 0.7

# Godot culls an instance from the directional shadow pass as well once its AABB
# leaves the camera frustum, so an upright caster that is just off-screen (e.g. a
# tree whose canopy slipped over the top edge) instantly loses its whole ground
# shadow. Expanding the visibility margin keeps such casters resident in the
# shadow pass. Units are GameCube capture units (camera far is 2500), so the margin
# is generous on purpose; it only widens culling tests, it moves no geometry.
const SHADOW_CASTER_CULL_MARGIN := 600.0

var mesh_cache: Dictionary = {}        # hash (int) -> RID (Mesh)
var mesh_is_ground: Dictionary = {}    # hash (int) -> bool (flat ground/path)
var mesh_radius: Dictionary = {}       # TEMP DEBUG: hash -> bounding radius
var mesh_avg_color: Dictionary = {}    # hash (int) -> Color (average vertex RGB)
var mesh_vertex_count: Dictionary = {} # hash (int) -> int (vertex count)
var mesh_free_pool: Array[RID] = []
var mesh_last_frame: Dictionary = {}   # hash (int) -> frame_index (int)
var tex_cache: Dictionary = {}         # hash (int) -> RID (Texture2D)
var tex_color_cache: Dictionary = {}    # hash (int) -> Color (average RGB, for water debug)
var tex_last_frame: Dictionary = {}    # hash (int) -> frame_index (int)
var tex_to_materials: Dictionary = {}  # RID (Texture2D) -> Array[int] (mat_hashes)
var mat_cache: Dictionary = {}         # state_hash (int) -> RID (Material)
var mat_last_frame: Dictionary = {}    # state_hash (int) -> frame_index (int)
var shader_variants: Dictionary = {}   # variant_key (int) -> RID (Shader)
var shader_base_body: String = ""
var lit_shader_body: String = ""
var water_shader_body: String = ""
var water_shader_rid: RID = RID()
var water_texture_hashes: Dictionary = {}  # 64-bit texture hash -> true (water surfaces)
var transparent_tex_hashes: Dictionary = {}  # textures bound to transparent draws (debug)
var transparent_mesh_colors: Dictionary = {}  # avg vertex RGB (Vector3i) -> count (debug)
var all_mesh_colors: Dictionary = {}          # avg vertex RGB of ALL draws -> count (debug)
var lighting_mode: int = 0
var force_dynamic_gi: bool = false

func set_lighting_mode(mode: int):
	lighting_mode = clampi(mode, 0, 1)

func add_water_texture_hash(hash_val: int) -> void:
	water_texture_hashes[hash_val] = true

func is_water_texture(hash_val: int) -> bool:
	return water_texture_hashes.has(hash_val)

func get_frame_texture_hashes() -> Array:
	# Unique content hashes of all textures referenced by the most recent frame.
	var unique: Dictionary = {}
	for h in frame_texture_hashes:
		if h != 0:
			unique[h] = true
	return unique.keys()

func get_transparent_tex_hashes() -> Array:
	return transparent_tex_hashes.keys()

func get_transparent_mesh_colors() -> Dictionary:
	return transparent_mesh_colors

func get_all_mesh_colors() -> Dictionary:
	return all_mesh_colors

func get_frame_texture_colors() -> Dictionary:
	# hash (int) -> Color, average RGB of each texture in the last frame.
	var out: Dictionary = {}
	for i in range(frame_texture_hashes.size()):
		var h = int(frame_texture_hashes[i])
		if h != 0:
			out[h] = frame_texture_colors[i] if i < frame_texture_colors.size() else Color.BLACK
	return out

func _avg_tex_color(data: PackedByteArray) -> Color:
	if data.size() < 4:
		return Color.BLACK
	var stride := maxi(4, (data.size() / 16384) * 4)  # cap ~4096 samples
	var r := 0
	var g := 0
	var b := 0
	var n := 0
	var i := 0
	while i + 3 < data.size():
		r += data[i]
		g += data[i + 1]
		b += data[i + 2]
		n += 1
		i += stride
	if n == 0:
		return Color.BLACK
	return Color(r / 255.0 / n, g / 255.0 / n, b / 255.0 / n)

func _hash_hex64(h: int) -> String:
	return "%08x%08x" % [((h >> 32) & 0xFFFFFFFF), (h & 0xFFFFFFFF)]

func dump_textures() -> int:
	# Save every unique texture bound in the last frame as a PNG into
	# res://debug_textures/ (the project folder), named <texture_hash>.png.
	var dir := "res://debug_textures"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var seen := {}
	var dumped := 0
	for i in range(frame_texture_hashes.size()):
		var h = int(frame_texture_hashes[i])
		if h == 0 or seen.has(h):
			continue
		seen[h] = true
		var rid: RID = frame_textures[i] if i < frame_textures.size() else RID()
		if not rid.is_valid():
			continue
		var img: Image = RenderingServer.texture_2d_get(rid)
		if img and not img.is_empty():
			img.save_png(dir + "/" + _hash_hex64(h) + ".png")
			dumped += 1
	return dumped

# Instance Pool
var instance_pool: Array[RID] = []
var instance_materials: Array[RID] = []
var instance_meshes: Array[RID] = []
var active_instance_count: int = 0
var dummy_white_tex: RID = RID()

# --- TEMPORARY DEBUG INSTRUMENTATION (shadow popping) - remove after diagnosis ---
# Ring buffer over consecutive frames. For the largest shadow casters it records the
# ACFP draw -> pool index -> instance RID -> mesh -> world origin -> visibility ->
# cast_shadows mapping, so a pool reassignment or a casting change becomes visible
# across frame boundaries. Bounded and debug-only.
const DBG_TRACE_ENABLED := false  # set true only while diagnosing; costs one array per caster per frame
const DBG_TRACE_FRAMES := 120  # ring depth when enabled
const DBG_TRACE_CASTERS := 24
var dbg_trace: Array = []
var dbg_frame_casters: Array = []

# Current Frame Resources (local IDs)
var frame_textures: Array[RID] = []
var frame_texture_hashes: Array = []  # parallel to frame_textures (64-bit content hash)
var frame_texture_colors: Array = []  # parallel to frame_textures (average RGB Color)
var frame_vbos: Array[Dictionary] = [] # Array of { "hash": int, "vbo_offset": int, "vertex_count": int, "stride": int }

# Current GX State
var cur_transform: Transform3D = Transform3D.IDENTITY
var cur_world_transform: Transform3D = Transform3D.IDENTITY
var cur_view_transform: Transform3D = Transform3D.IDENTITY
var cur_view_inverse: Transform3D = Transform3D.IDENTITY
var has_3d_view: bool = false
var frame_has_3d_view: bool = false
var active_camera_transform: Transform3D = Transform3D.IDENTITY
var frame_draw_descriptors: Array[Dictionary] = []
var cur_proj_matrix: Projection = Projection.IDENTITY
var cur_mv_matrix: Projection = Projection.IDENTITY
var cur_nrm_matrix: Basis = Basis.IDENTITY
var cur_vp_transform: Vector4 = Vector4(1.0, 1.0, 0.0, 0.0)
var cur_pass_type: int = PASS_OPAQUE

var cur_cull_mode: int = 0   # 0=none, 1=front, 2=back, 3=all
var cur_z_test: int = 1
var cur_z_write: int = 1
var cur_blend_mode: int = 0  # 0=none, 1=blend, 2=logic, 3=subtract

var cur_texmtx_row0: Array = [Vector4.ZERO, Vector4.ZERO]
var cur_texmtx_row1: Array = [Vector4.ZERO, Vector4.ZERO]
var cur_texmtx_enable: Array = [0, 0]
var cur_texgen_src: Array = [4, 5]

var cur_fog_enable: int = 0
var cur_fog_params: Vector4 = Vector4.ZERO
var cur_fog_color: Vector4 = Vector4.ZERO

var cur_tev_prev: Vector4 = Vector4.ZERO
var cur_tev_reg0: Vector4 = Vector4.ZERO
var cur_tev_reg1: Vector4 = Vector4.ZERO
var cur_tev_reg2: Vector4 = Vector4.ZERO

var cur_num_tev_stages: int = 1
var cur_tev_color_in: Array = [Vector4i.ZERO, Vector4i.ZERO, Vector4i.ZERO]
var cur_tev_alpha_in: Array = [Vector4i.ZERO, Vector4i.ZERO, Vector4i.ZERO]
var cur_tev_color_op: Array = [0, 0, 0]
var cur_tev_alpha_op: Array = [0, 0, 0]
var cur_tev_tc_src: Array = [0, 0, 0]
var cur_tev_bsc: Array = [Vector4i.ZERO, Vector4i.ZERO, Vector4i.ZERO]
var cur_tev_out: Array = [Vector4i.ZERO, Vector4i.ZERO, Vector4i.ZERO]
var cur_tev_swap: Array = [Vector2i.ZERO, Vector2i.ZERO, Vector2i.ZERO]

var cur_bound_textures: Array = [RID(), RID(), RID()]
var cur_bound_texture_hash: Array = [0, 0, 0]
var cur_use_texture: Array = [0, 0, 0]
var cur_tex_wrap: Array = [Vector2i.ZERO, Vector2i.ZERO, Vector2i.ZERO]

var cur_lighting_cfg0: Vector4i = Vector4i.ZERO
var cur_lighting_cfg1: Vector4i = Vector4i.ZERO
var cur_chan_color: Array = [Vector4.ONE, Vector4.ONE]
var cur_light_pos: Array = []
var cur_light_color: Array = []

var cur_kcolor: Array = [Vector4.ONE, Vector4.ONE, Vector4.ONE, Vector4.ONE]
var cur_tev_ksel: Array = [Vector3i.ZERO, Vector3i.ZERO, Vector3i.ZERO]
var cur_swap_table: Array = [
	Vector4i(0, 1, 2, 3), Vector4i(0, 1, 2, 3),
	Vector4i(0, 1, 2, 3), Vector4i(0, 1, 2, 3)
]

var cur_alpha_ctrl: Vector3i = Vector3i(7, 0, 7)
var cur_alpha_refs: Vector2i = Vector2i(0, 0)
var cur_scissor: Vector4i = Vector4i.ZERO
var cur_num_ind_stages: int = 0

# Profiling stats
var stats_draw_calls: int = 0
var stats_opaque_draws: int = 0
var stats_transparent_draws: int = 0
var stats_ui_draws: int = 0
var stats_water_draws: int = 0
var stats_efb_copies: int = 0
var stats_mesh_cache_hits: int = 0
var stats_mesh_cache_misses: int = 0
var stats_mesh_cache_evictions: int = 0
var stats_tex_cache_hits: int = 0
var stats_tex_cache_misses: int = 0
var stats_material_updates: int = 0

func _init():
	# Load base shader text and extract body
	var full_shader = FileAccess.get_file_as_string("res://shaders/acgc_unlit.gdshader")
	if full_shader.is_empty():
		full_shader = FileAccess.get_file_as_string("res://godot/shaders/acgc_unlit.gdshader")
	var second_newline = full_shader.find("\n", full_shader.find("\n") + 1)
	if second_newline != -1:
		shader_base_body = full_shader.substr(second_newline + 1)
	else:
		shader_base_body = full_shader

	var lit_source = FileAccess.get_file_as_string("res://shaders/acgc_lit.gdshader")
	lit_shader_body = lit_source.substr(lit_source.find("\n", lit_source.find("\n") + 1) + 1)

	# Water shader: a self-contained PBR shader (not a TEV variant), loaded whole
	# and compiled once. Its own render_mode (depth_draw_always, PBR) is fixed.
	var water_source = FileAccess.get_file_as_string("res://shaders/acgc_water.gdshader")
	if water_source.is_empty():
		water_source = FileAccess.get_file_as_string("res://godot/shaders/acgc_water.gdshader")
	water_shader_body = water_source
	water_shader_rid = RenderingServer.shader_create()
	RenderingServer.shader_set_code(water_shader_rid, water_source)

	# Water surface texture hashes (river). Identified visually via the F6
	# texture-PNG dump (res://debug_textures/). Add more (e.g. ocean) here or via
	# add_water_texture_hash().
	water_texture_hashes[0x2655e7d4baeb9375] = true
	# Same 64 bits as unsigned a504accedef27169; GDScript literals are signed.
	water_texture_hashes[-6555925153040928407] = true
	water_texture_hashes[0x4f1afe2885c65edb] = true # captured river texture variant

	# Create dummy 1x1 white texture
	var img = Image.create(1, 1, false, Image.FORMAT_RGBA8)
	img.set_pixel(0, 0, Color.WHITE)
	dummy_white_tex = RenderingServer.texture_2d_create(img)

	# Initialize default light arrays
	cur_light_pos.resize(8)
	cur_light_color.resize(8)
	for i in range(8):
		cur_light_pos[i] = Vector3.ZERO
		cur_light_color[i] = Vector4.ZERO

	# Pre-allocate instance pool & material pool with 256 slots
	_ensure_instance_pool_size(256)

var efb_textures: Dictionary = {}

func get_efb_requests(data: PackedByteArray) -> Array:
	var requests: Array = []
	if data.size() < 80: return requests
	var cursor = data.decode_u32(60)
	var draws = 0
	while cursor + 4 <= data.size():
		var op = data.decode_u16(cursor)
		var size = data.decode_u16(cursor + 2)
		var p = cursor + 4
		if op == CMD_END_FRAME: break
		if op == CMD_DRAW: draws += 1
		if op == CMD_EFB_COPY and size >= 20 and data.decode_u8(p + 14) == 1:
			var seq = data.decode_u8(p + 15)
			requests.append({"draws": draws, "handle": data.decode_u32(p + 16),
				"seq": seq,
				"rect": Rect2i(data.decode_u16(p), data.decode_u16(p + 2), data.decode_u16(p + 4), data.decode_u16(p + 6)),
				"size": Vector2i(data.decode_u16(p + 8), data.decode_u16(p + 10))})
		cursor = p + size
	return requests

func store_efb_image(request: Dictionary, image: Image):
	var rect: Rect2i = request.rect
	rect = rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	if rect.size.x <= 0 or rect.size.y <= 0: return
	var copy = image.get_region(rect)
	copy.convert(Image.FORMAT_RGBA8)
	copy.resize(request.size.x, request.size.y, Image.INTERPOLATE_NEAREST)
	var texture = RenderingServer.texture_2d_create(copy)
	if efb_textures.has(request.handle):
		RenderingServer.texture_replace(efb_textures[request.handle], texture)
	else:
		efb_textures[request.handle] = texture

var _current_frame_index: int = 0
var _static_draw_cache: Dictionary = {}
var _cell_occurrence_counts: Dictionary = {}

func clear_static_cache() -> void:
	_static_draw_cache.clear()
	_cell_occurrence_counts.clear()

func _is_static_draw(mesh_hash: int, xform: Transform3D, mat_hash: int = 0) -> bool:
	# Quantize world position into 1.0m spatial buckets
	var cx := int(floor(xform.origin.x))
	var cy := int(floor(xform.origin.y))
	var cz := int(floor(xform.origin.z))
	var base_key := Vector4i(mesh_hash & 0x7FFFFFFF, cx, cy, cz)

	# Intra-cell occurrence counter guarantees identical meshes in the same cell never collide
	var occ: int = _cell_occurrence_counts.get(base_key, 0)
	_cell_occurrence_counts[base_key] = occ + 1

	var key := [mesh_hash, cx, cy, cz, occ]
	var hist = _static_draw_cache.get(key, null)
	if hist == null:
		_static_draw_cache[key] = {
			"pos": xform.origin,
			"basis_x": xform.basis.x,
			"basis_y": xform.basis.y,
			"basis_z": xform.basis.z,
			"mat": mat_hash,
			"frames": 1,
			"last_frame": _current_frame_index
		}
		return false

	var d_pos: float = (hist["pos"] - xform.origin).length_squared()
	var d_basis: float = (hist["basis_x"] - xform.basis.x).length_squared() + \
	                     (hist["basis_y"] - xform.basis.y).length_squared() + \
	                     (hist["basis_z"] - xform.basis.z).length_squared()
	var mat_match: bool = (hist.get("mat", 0) == mat_hash)

	# Verify position, orientation (rotation), and material
	if d_pos < 0.04 and d_basis < 0.01 and mat_match:
		var is_consecutive: bool = (hist["last_frame"] == _current_frame_index - 1)
		if is_consecutive:
			hist["frames"] += 1
		else:
			hist["frames"] = 1
		hist["last_frame"] = _current_frame_index
		return hist["frames"] >= 30
	else:
		hist["pos"] = xform.origin
		hist["basis_x"] = xform.basis.x
		hist["basis_y"] = xform.basis.y
		hist["basis_z"] = xform.basis.z
		hist["mat"] = mat_hash
		hist["frames"] = 0
		hist["last_frame"] = _current_frame_index
		return false

func get_frame_draw_descriptors() -> Array[Dictionary]:
	return frame_draw_descriptors

func cleanup():
	# Detach and free all instances
	for i in range(instance_pool.size()):
		var inst = instance_pool[i]
		RenderingServer.instance_set_scenario(inst, RID())
		RenderingServer.instance_geometry_set_material_override(inst, RID())
		RenderingServer.instance_set_base(inst, RID())
		RenderingServer.free_rid(inst)
	instance_pool.clear()
	instance_materials.clear()
	instance_meshes.clear()

	# Free all cached materials
	for h in mat_cache:
		RenderingServer.free_rid(mat_cache[h])
	mat_cache.clear()
	mat_last_frame.clear()
	tex_to_materials.clear()

	# Materials are detached and freed before their EFB texture dependencies.
	for texture in efb_textures.values(): RenderingServer.free_rid(texture)
	efb_textures.clear()

	# Free all cached meshes and pool
	for hash_val in mesh_cache:
		RenderingServer.free_rid(mesh_cache[hash_val])
	mesh_cache.clear()
	mesh_last_frame.clear()
	mesh_is_ground.clear()
	mesh_avg_color.clear()
	mesh_vertex_count.clear()
	for m_rid in mesh_free_pool:
		RenderingServer.free_rid(m_rid)
	mesh_free_pool.clear()

	# Free all cached textures
	for hash_val in tex_cache:
		RenderingServer.free_rid(tex_cache[hash_val])
	tex_cache.clear()
	tex_last_frame.clear()

	# Free all compiled shader variants
	for key in shader_variants:
		RenderingServer.free_rid(shader_variants[key])
	shader_variants.clear()
	if water_shader_rid.is_valid():
		RenderingServer.free_rid(water_shader_rid)
		water_shader_rid = RID()

	if dummy_white_tex.is_valid():
		RenderingServer.free_rid(dummy_white_tex)
		dummy_white_tex = RID()

func _ensure_instance_pool_size(needed_count: int):
	while instance_pool.size() < needed_count:
		var inst = RenderingServer.instance_create()
		RenderingServer.instance_set_visible(inst, false)
		RenderingServer.instance_set_ignore_culling(inst, true)
		RenderingServer.instance_geometry_set_shader_parameter(inst, "u_normal_r0", Vector3(1, 0, 0))
		RenderingServer.instance_geometry_set_shader_parameter(inst, "u_normal_r1", Vector3(0, 1, 0))
		RenderingServer.instance_geometry_set_shader_parameter(inst, "u_normal_r2", Vector3(0, 0, 1))
		instance_pool.append(inst)
		instance_materials.append(RID())
		instance_meshes.append(RID())

func _get_shader_variant(cull_mode: int, z_test: int, z_write: int, blend_mode: int, ordered_opaque: bool = false, menu_blend: bool = false, use_lit: bool = false) -> RID:
	var key = cull_mode | (z_test << 2) | (z_write << 3) | (blend_mode << 4) | (int(ordered_opaque) << 8) | (int(menu_blend) << 9) | (int(use_lit) << 10)
	if shader_variants.has(key):
		return shader_variants[key]

	var rm = [] if use_lit else ["unshaded", "fog_disabled"]
	if use_lit:
		# GX face selection belongs to the game camera, not the light camera.
		rm.append("cull_disabled")
	elif cull_mode == 1:
		rm.append("cull_back")
	elif cull_mode == 2:
		rm.append("cull_front")
	else:
		rm.append("cull_disabled")

	if z_test == 0:
		rm.append("depth_test_disabled")

	if z_write == 0:
		rm.append("depth_draw_never")
	else:
		rm.append("depth_draw_always")

	var is_blend = (blend_mode == 1 or blend_mode == 3)
	if blend_mode == 3:
		rm.append("blend_sub")
	elif blend_mode == 1:
		rm.append("blend_mix")

	var header = "shader_type spatial;\nrender_mode " + ", ".join(rm) + ";\n"
	var body = lit_shader_body if use_lit else shader_base_body
	if use_lit and (cull_mode == 1 or cull_mode == 2):
		# Preserve the color-pass culling exactly, but keep both faces in shadows.
		# Instance DOUBLE_SIDED alone does not override shader render-mode culling.
		var face_reject = "!FRONT_FACING" if cull_mode == 1 else "FRONT_FACING"
		body = body.replace("void fragment() {", "void fragment() {\n\tif (v_shadow_pass < 0.5 && (%s)) discard;" % face_reject)
	if ordered_opaque:
		body = body.replace("// ##ALPHA_OUTPUT##", "ALPHA = 1.0;")
	elif is_blend:
		var alpha_output = "ALPHA = clamp(outCol.a, 0.0, 1.0);" if menu_blend else "ALPHA = 1.0 - pow(1.0 - clamp(outCol.a, 0.0, 1.0), 2.2);"
		body = body.replace("// ##ALPHA_OUTPUT##", alpha_output)
	else:
		body = body.replace("// ##ALPHA_OUTPUT##", "")

	var code = header + body
	var s_rid = RenderingServer.shader_create()
	RenderingServer.shader_set_code(s_rid, code)
	shader_variants[key] = s_rid
	return s_rid

func warmup_shaders(scenario: RID) -> Dictionary:
	var t0 = Time.get_ticks_usec()
	var count = 0

	var dummy_mesh = RenderingServer.mesh_create()
	var arr = []
	arr.resize(Mesh.ARRAY_MAX)
	var verts = PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0)])
	var uvs = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(0, 1)])
	var normals = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_NORMAL] = normals
	RenderingServer.mesh_add_surface_from_arrays(dummy_mesh, RenderingServer.PRIMITIVE_TRIANGLES, arr)

	var dummy_instances: Array[RID] = []
	var dummy_materials: Array[RID] = []

	for cull in [0, 1, 2]:
		for z_test in [0, 1]:
			for z_write in [0, 1]:
				for blend in [0, 1, 3]:
					var s_rid = _get_shader_variant(cull, z_test, z_write, blend)
					var mat = RenderingServer.material_create()
					RenderingServer.material_set_shader(mat, s_rid)
					dummy_materials.append(mat)
					var inst = RenderingServer.instance_create()
					RenderingServer.instance_set_base(inst, dummy_mesh)
					RenderingServer.instance_set_scenario(inst, scenario)
					RenderingServer.instance_geometry_set_material_override(inst, mat)
					RenderingServer.instance_set_transform(inst, Transform3D(Basis(), Vector3(0, 0, -10000)))
					RenderingServer.instance_set_visible(inst, false)
					dummy_instances.append(inst)
					count += 1

	var warmup_us = Time.get_ticks_usec() - t0
	print("[ACFP Warm-up] Precompiled %d shader pipeline variants in %.2f ms" % [count, warmup_us / 1000.0])

	for inst in dummy_instances:
		RenderingServer.free_rid(inst)
	for mat in dummy_materials:
		RenderingServer.free_rid(mat)
	RenderingServer.free_rid(dummy_mesh)

	return {
		"variants_compiled": count,
		"warmup_ms": warmup_us / 1000.0
	}

## TEMPORARY DEBUG: frame-to-frame diff of ALL shadow casters in the trace ring.
## The last recorded frame is the F9 trigger point.
func dump_shadow_trace() -> String:
	var lines: Array[String] = []
	lines.append("SHADOW TRACE all-casters frames=%d cap=%d (last frame = F9 trigger)" % [dbg_trace.size(), DBG_TRACE_FRAMES])
	if dbg_trace.size() < 2:
		lines.append("not enough frames")
		return "\n".join(lines)
	var transitions := 0
	for i in range(1, dbg_trace.size()):
		var prev: Dictionary = dbg_trace[i - 1]
		var cur: Dictionary = dbg_trace[i]
		var pm: Dictionary = _dbg_index(prev["casters"])
		var cm: Dictionary = _dbg_index(cur["casters"])
		var gone: Array = []
		for k in pm.keys():
			if not cm.has(k):
				gone.append(k)
		var added: Array = []
		for k in cm.keys():
			if not pm.has(k):
				added.append(k)
		var cast_flipped := 0
		var mat_changed := 0
		var pool_moved := 0
		for k in cm.keys():
			if pm.has(k):
				var a: Array = pm[k]
				var b: Array = cm[k]
				if int(a[8]) != int(b[8]) or int(a[9]) != int(b[9]):
					cast_flipped += 1
				if int(a[1]) != int(b[1]):
					mat_changed += 1
				if int(a[6]) != int(b[6]):
					pool_moved += 1
		if gone.size() == 0 and added.size() == 0 and cast_flipped == 0 and mat_changed == 0:
			continue
		transitions += 1
		lines.append("=== %d->%d draws %d->%d casters %d->%d(gone=%d new=%d) ambiguous=%d/%d pool_moved=%d cast_flip=%d mat_change=%d" % [
			prev["frame"], cur["frame"], prev["draws"], cur["draws"],
			prev["casters"].size(), cur["casters"].size(), gone.size(), added.size(),
			prev["casters"].size() - pm.size(), cur["casters"].size() - cm.size(),
			pool_moved, cast_flipped, mat_changed])
		var shown := 0
		for k in gone:
			if shown >= 8:
				break
			lines.append("   GONE " + _dbg_desc(pm[k]))
			shown += 1
		shown = 0
		for k in added:
			if shown >= 8:
				break
			lines.append("   NEW  " + _dbg_desc(cm[k]))
			shown += 1
	lines.append("--- transitions reported: %d of %d frame pairs ---" % [transitions, dbg_trace.size() - 1])
	return "\n".join(lines)

## Identity: geometry hash + material + world origin quantised to 64 units.
## TOLERANCE: cur_world_transform is reconstructed as view_inverse * modelview, so
## the recovered world origin jitters by 1-2 units at large coordinates. A 4-unit
## bucket reported those jitters as GONE+NEW pairs that in fact shared the same hash,
## material, pool index and instance RID. 64 units absorbs the jitter while still
## separating distinct props. Duplicates are counted as "ambiguous".
func _dbg_index(casters: Array) -> Dictionary:
	var out: Dictionary = {}
	for c in casters:
		var key := "%d|%d|%d|%d|%d" % [
			int(c[0]), int(c[1]), int(round(float(c[2]) / 64.0)),
			int(round(float(c[3]) / 64.0)), int(round(float(c[4]) / 64.0))]
		if not out.has(key):
			out[key] = c
	return out

func _dbg_desc(c: Array) -> String:
	return "hash=%d mat=%d o=(%.0f,%.0f,%.0f) r=%.0f verts=%d pool=%d inst=%d cast=%d ground=%d" % [
		int(c[0]), int(c[1]), float(c[2]), float(c[3]), float(c[4]),
		float(c[5]), int(c[10]), int(c[6]), int(c[7]), int(c[8]), int(c[9])]
func _reset_frame_state():
	cur_transform = Transform3D.IDENTITY
	cur_world_transform = Transform3D.IDENTITY
	cur_view_transform = Transform3D.IDENTITY
	cur_view_inverse = Transform3D.IDENTITY
	has_3d_view = false
	frame_has_3d_view = false
	active_camera_transform = Transform3D.IDENTITY
	frame_draw_descriptors.clear()
	_cell_occurrence_counts.clear()
	if _current_frame_index % 120 == 0:
		var stale_keys := []
		for k in _static_draw_cache:
			if _current_frame_index - _static_draw_cache[k].get("last_frame", _current_frame_index) > 60:
				stale_keys.append(k)
		for k in stale_keys:
			_static_draw_cache.erase(k)
	cur_proj_matrix = Projection.IDENTITY
	cur_mv_matrix = Projection.IDENTITY
	cur_nrm_matrix = Basis.IDENTITY
	cur_vp_transform = Vector4(1.0, 1.0, 0.0, 0.0)
	cur_pass_type = PASS_OPAQUE
	cur_cull_mode = 0
	cur_z_test = 1
	cur_z_write = 1
	cur_blend_mode = 0
	cur_texmtx_row0 = [Vector4.ZERO, Vector4.ZERO]
	cur_texmtx_row1 = [Vector4.ZERO, Vector4.ZERO]
	cur_texmtx_enable = [0, 0]
	cur_texgen_src = [4, 4]
	cur_fog_enable = 0
	cur_fog_params = Vector4.ZERO
	cur_fog_color = Vector4.ZERO
	cur_tev_prev = Vector4.ZERO
	cur_tev_reg0 = Vector4.ZERO
	cur_tev_reg1 = Vector4.ZERO
	cur_tev_reg2 = Vector4.ZERO
	cur_num_tev_stages = 1
	cur_tev_color_in = [Vector4i.ZERO, Vector4i.ZERO, Vector4i.ZERO]
	cur_tev_alpha_in = [Vector4i.ZERO, Vector4i.ZERO, Vector4i.ZERO]
	cur_tev_color_op = [0, 0, 0]
	cur_tev_alpha_op = [0, 0, 0]
	cur_tev_tc_src = [0, 0, 0]
	cur_tev_bsc = [Vector4i.ZERO, Vector4i.ZERO, Vector4i.ZERO]
	cur_tev_out = [Vector4i.ZERO, Vector4i.ZERO, Vector4i.ZERO]
	cur_tev_swap = [Vector2i.ZERO, Vector2i.ZERO, Vector2i.ZERO]
	cur_bound_textures = [dummy_white_tex, dummy_white_tex, dummy_white_tex]
	cur_bound_texture_hash = [0, 0, 0]
	cur_use_texture = [0, 0, 0]
	cur_tex_wrap = [Vector2i.ZERO, Vector2i.ZERO, Vector2i.ZERO]
	cur_lighting_cfg0 = Vector4i.ZERO
	cur_lighting_cfg1 = Vector4i.ZERO
	cur_chan_color = [Vector4.ONE, Vector4.ONE]
	for i in range(8):
		cur_light_pos[i] = Vector3.ZERO
		cur_light_color[i] = Vector4.ZERO
	cur_kcolor = [Vector4.ONE, Vector4.ONE, Vector4.ONE, Vector4.ONE]
	cur_tev_ksel = [Vector3i.ZERO, Vector3i.ZERO, Vector3i.ZERO]
	cur_swap_table = [
		Vector4i(0, 1, 2, 3), Vector4i(0, 1, 2, 3),
		Vector4i(0, 1, 2, 3), Vector4i(0, 1, 2, 3)
	]
	cur_alpha_ctrl = Vector3i(7, 0, 7)
	cur_alpha_refs = Vector2i(0, 0)
	cur_scissor = Vector4i.ZERO
	cur_num_ind_stages = 0

func render_packet(data: PackedByteArray, scenario: RID, max_draws: int = -1, debug_color: bool = false) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	stats_draw_calls = 0
	stats_opaque_draws = 0
	stats_transparent_draws = 0
	stats_ui_draws = 0
	stats_water_draws = 0
	stats_efb_copies = 0
	transparent_tex_hashes.clear()
	transparent_mesh_colors.clear()
	all_mesh_colors.clear()
	stats_mesh_cache_hits = 0
	stats_mesh_cache_misses = 0
	stats_mesh_cache_evictions = 0
	stats_tex_cache_hits = 0
	stats_tex_cache_misses = 0
	stats_material_updates = 0
	active_instance_count = 0

	if data.size() < 64:
		return { "success": false, "error": "Packet smaller than header" }

	var magic := data.decode_u32(0)
	if magic != ACFP_MAGIC:
		return { "success": false, "error": "Invalid magic 0x%08x" % magic }

	var version := data.decode_u32(4)
	var frame_index := data.decode_u32(8)
	_current_frame_index = frame_index
	_reset_frame_state()
	var tick_count := data.decode_u32(12)
	var width := data.decode_u32(16)
	var height := data.decode_u32(20)
	var clear_col := Color(
		data.decode_float(24),
		data.decode_float(28),
		data.decode_float(32),
		data.decode_float(36)
	)
	var clear_depth := data.decode_float(40)

	var tex_table_offset := data.decode_u32(44)
	var tex_table_count := data.decode_u32(48)
	var vbo_table_offset := data.decode_u32(52)
	var vbo_table_count := data.decode_u32(56)
	var cmd_stream_offset := data.decode_u32(60)
	var cmd_stream_size := data.decode_u32(64)

	var total_ui_draws = 0
	var has_subview = false
	var total_draws = 0
	var cur_scan = cmd_stream_offset
	var scan_end = cmd_stream_offset + cmd_stream_size
	while cur_scan + 8 <= scan_end:
		var scan_op := data.decode_u16(cur_scan)
		var scan_sz := data.decode_u16(cur_scan + 2)
		if scan_op == CMD_END_FRAME:
			break
		if scan_op == CMD_SET_VIEWPORT_SCISSOR:
			var v = cur_scan + 4
			has_subview = has_subview or data.decode_float(v) != 0.0 or data.decode_float(v + 4) != 0.0 or data.decode_float(v + 8) != float(width) or data.decode_float(v + 12) != float(height)
		if scan_op == CMD_DRAW:
			total_draws += 1
			var ptype := data.decode_u16(cur_scan + 6)
			if ptype == PASS_UI:
				total_ui_draws += 1
		cur_scan += 4 + scan_sz

	var ui_priority_base = 10
	if total_ui_draws > 100:
		ui_priority_base = clampi(125 - total_ui_draws, -110, 0)

	# 1. Process Texture Table
	frame_textures.clear()
	frame_textures.resize(tex_table_count)
	frame_texture_hashes.clear()
	frame_texture_hashes.resize(tex_table_count)
	frame_texture_colors.clear()
	frame_texture_colors.resize(tex_table_count)
	var tex_hdr_size = 28 # sizeof(ACFPTextureHeader)
	var tex_hdr_array_size = tex_table_count * tex_hdr_size

	for i in range(tex_table_count):
		var base = tex_table_offset + i * tex_hdr_size
		var tex_id := data.decode_u32(base)
		var hash_val := data.decode_u64(base + 4)
		frame_texture_hashes[i] = hash_val
		var w := data.decode_u16(base + 12)
		var h := data.decode_u16(base + 14)
		var orig_fmt := data.decode_u8(base + 16)
		var data_offset := data.decode_u32(base + 20)
		var data_size := data.decode_u32(base + 24)

		if (hash_val & -4294967296) == 0x4546420000000000:
			frame_textures[i] = efb_textures.get(hash_val & 0xffffffff, dummy_white_tex)
			frame_texture_colors[i] = Color.BLACK
			continue
		if tex_cache.has(hash_val):
			stats_tex_cache_hits += 1
			frame_textures[i] = tex_cache[hash_val]
			frame_texture_colors[i] = tex_color_cache.get(hash_val, Color.BLACK)
			tex_last_frame[hash_val] = frame_index
		else:
			stats_tex_cache_misses += 1
			var pixel_start = tex_table_offset + tex_hdr_array_size + data_offset
			var img_data = data.slice(pixel_start, pixel_start + data_size)
			var tex_rid: RID = RID()
			if w > 0 and h > 0 and img_data.size() == int(w) * int(h) * 4:
				var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, img_data)
				if img and not img.is_empty():
					tex_rid = RenderingServer.texture_2d_create(img)
			if not tex_rid.is_valid():
				tex_rid = dummy_white_tex
			tex_cache[hash_val] = tex_rid
			tex_color_cache[hash_val] = _avg_tex_color(img_data)
			tex_last_frame[hash_val] = frame_index
			frame_textures[i] = tex_rid
			frame_texture_colors[i] = tex_color_cache[hash_val]

	# 2. Process VBO Table
	frame_vbos.clear()
	frame_vbos.resize(vbo_table_count)
	var vbo_hdr_size = 28 # sizeof(ACFPVertexBufferHeader)
	var vbo_hdr_array_size = vbo_table_count * vbo_hdr_size

	for i in range(vbo_table_count):
		var base = vbo_table_offset + i * vbo_hdr_size
		var vbo_id := data.decode_u32(base)
		var hash_val := data.decode_u64(base + 4)
		var vertex_count := data.decode_u32(base + 12)
		var stride := data.decode_u32(base + 16)
		var data_offset := data.decode_u32(base + 20)
		var data_size := data.decode_u32(base + 24)

		var vbo_pixel_start = vbo_table_offset + vbo_hdr_array_size + data_offset
		frame_vbos[i] = {
			"hash": hash_val,
			"vbo_offset": vbo_pixel_start,
			"vertex_count": vertex_count,
			"stride": stride
		}

	# 3. Process Command Stream
	var cmd_cursor = cmd_stream_offset
	var cmd_end = cmd_stream_offset + cmd_stream_size

	cur_transform = Transform3D.IDENTITY
	cur_pass_type = PASS_OPAQUE

	while cmd_cursor + 4 <= cmd_end:
		var opcode := data.decode_u16(cmd_cursor)
		var payload_size := data.decode_u16(cmd_cursor + 2)
		var payload_offset = cmd_cursor + 4
		cmd_cursor += 4 + payload_size

		if opcode == CMD_END_FRAME:
			break

		match opcode:
			CMD_SET_VIEWPORT_SCISSOR:
				var vp_x := data.decode_float(payload_offset + 0)
				var vp_y := data.decode_float(payload_offset + 4)
				var vp_w := data.decode_float(payload_offset + 8)
				var vp_h := data.decode_float(payload_offset + 12)
				var sc_l := data.decode_s32(payload_offset + 24)
				var sc_t := data.decode_s32(payload_offset + 28)
				var sc_w := data.decode_s32(payload_offset + 32)
				var sc_h := data.decode_s32(payload_offset + 36)

				if vp_w > 0.0 and vp_h > 0.0 and (vp_w < float(width) - 1.0 or vp_h < float(height) - 1.0 or vp_x > 0.0 or vp_y > 0.0):
					var sx = vp_w / float(width)
					var sy = vp_h / float(height)
					var ox = (2.0 * vp_x + vp_w - float(width)) / float(width)
					# POSITION.y is already flipped in the shader: top offsets are negative.
					var oy = (2.0 * vp_y + vp_h - float(height)) / float(height)
					cur_vp_transform = Vector4(sx, sy, ox, oy)
				else:
					cur_vp_transform = Vector4(1.0, 1.0, 0.0, 0.0)

				if sc_w > 0 and sc_h > 0 and (sc_w < int(width) or sc_h < int(height) or sc_l > 0 or sc_t > 0):
					cur_scissor = Vector4i(sc_l, sc_t, sc_w, sc_h)
				else:
					cur_scissor = Vector4i.ZERO

			CMD_EFB_COPY:
				stats_efb_copies += 1

			CMD_SET_TRANSFORMS:
				var p = payload_offset + 4 # skip mtx_slot
				var m00 := data.decode_float(p + 0);  var m01 := data.decode_float(p + 4);  var m02 := data.decode_float(p + 8);  var m03 := data.decode_float(p + 12)
				var m10 := data.decode_float(p + 16); var m11 := data.decode_float(p + 20); var m12 := data.decode_float(p + 24); var m13 := data.decode_float(p + 28)
				var m20 := data.decode_float(p + 32); var m21 := data.decode_float(p + 36); var m22 := data.decode_float(p + 40); var m23 := data.decode_float(p + 44)

				var basis := Basis(
					Vector3(m00, m10, m20),
					Vector3(m01, m11, m21),
					Vector3(m02, m12, m22)
				)
				var origin := Vector3(m03, m13, m23)
				cur_transform = Transform3D(basis, origin)
				if has_3d_view:
					cur_world_transform = cur_view_inverse * cur_transform
				else:
					cur_world_transform = cur_transform

				# ModelView Projection Matrix (column-major)
				cur_mv_matrix = Projection(
					Vector4(m00, m10, m20, 0.0),
					Vector4(m01, m11, m21, 0.0),
					Vector4(m02, m12, m22, 0.0),
					Vector4(m03, m13, m23, 1.0)
				)

				# Normal matrix
				var np = p + 48
				var n00 := data.decode_float(np + 0);  var n01 := data.decode_float(np + 4);  var n02 := data.decode_float(np + 8)
				var n10 := data.decode_float(np + 12); var n11 := data.decode_float(np + 16); var n12 := data.decode_float(np + 20)
				var n20 := data.decode_float(np + 24); var n21 := data.decode_float(np + 28); var n22 := data.decode_float(np + 32)
				cur_nrm_matrix = Basis(
					Vector3(n00, n10, n20),
					Vector3(n01, n11, n21),
					Vector3(n02, n12, n22)
				)

			CMD_SET_PROJECTION:
				var p = payload_offset + 4 # skip proj_type
				var col0 := Vector4(data.decode_float(p + 0),  data.decode_float(p + 16), data.decode_float(p + 32), data.decode_float(p + 48))
				var col1 := Vector4(data.decode_float(p + 4),  data.decode_float(p + 20), data.decode_float(p + 36), data.decode_float(p + 52))
				var col2 := Vector4(data.decode_float(p + 8),  data.decode_float(p + 24), data.decode_float(p + 40), data.decode_float(p + 56))
				var col3 := Vector4(data.decode_float(p + 12), data.decode_float(p + 28), data.decode_float(p + 44), data.decode_float(p + 60))
				cur_proj_matrix = Projection(col0, col1, col2, col3)

			CMD_SET_VIEW_MATRIX:
				var is_3d := data.decode_u32(payload_offset + 0) != 0
				var p = payload_offset + 4
				var m00 := data.decode_float(p + 0);  var m01 := data.decode_float(p + 4);  var m02 := data.decode_float(p + 8);  var m03 := data.decode_float(p + 12)
				var m10 := data.decode_float(p + 16); var m11 := data.decode_float(p + 20); var m12 := data.decode_float(p + 24); var m13 := data.decode_float(p + 28)
				var m20 := data.decode_float(p + 32); var m21 := data.decode_float(p + 36); var m22 := data.decode_float(p + 40); var m23 := data.decode_float(p + 44)

				if is_3d:
					var basis := Basis(
						Vector3(m00, m10, m20),
						Vector3(m01, m11, m21),
						Vector3(m02, m12, m22)
					)
					var origin := Vector3(m03, m13, m23)
					cur_view_transform = Transform3D(basis, origin)
					cur_view_inverse = cur_view_transform.affine_inverse()
					has_3d_view = true
					if not frame_has_3d_view:
						active_camera_transform = cur_view_inverse
					frame_has_3d_view = true
				else:
					cur_view_transform = Transform3D.IDENTITY
					cur_view_inverse = Transform3D.IDENTITY
					has_3d_view = false

			CMD_SET_DEPTH_BLEND:
				cur_z_test = data.decode_u8(payload_offset + 0)
				cur_z_write = data.decode_u8(payload_offset + 2)
				cur_cull_mode = data.decode_u8(payload_offset + 3)
				cur_blend_mode = data.decode_u8(payload_offset + 4)

			CMD_SET_CULL:
				cur_cull_mode = data.decode_u32(payload_offset)

			CMD_SET_ALPHA_TEST:
				cur_alpha_ctrl = Vector3i(
					data.decode_u8(payload_offset + 0),
					data.decode_u8(payload_offset + 2),
					data.decode_u8(payload_offset + 3)
				)
				cur_alpha_refs = Vector2i(
					data.decode_u8(payload_offset + 1),
					data.decode_u8(payload_offset + 4)
				)

			CMD_SET_FOG:
				var ftype := data.decode_u32(payload_offset + 0)
				cur_fog_enable = 1 if ftype != 0 else 0
				cur_fog_params = Vector4(
					0.0,
					data.decode_float(payload_offset + 4),
					data.decode_float(payload_offset + 8),
					0.0
				)
				cur_fog_color = Vector4(
					data.decode_float(payload_offset + 20),
					data.decode_float(payload_offset + 24),
					data.decode_float(payload_offset + 28),
					data.decode_float(payload_offset + 32)
				)

			CMD_SET_LIGHTING:
				var nch := data.decode_u32(payload_offset + 0)
				var mat_en := data.decode_u32(payload_offset + 68)
				var a_mat_en := data.decode_u32(payload_offset + 72)
				var mat_src := data.decode_u32(payload_offset + 76)
				var a_mat_src := data.decode_u32(payload_offset + 80)
				var amb_src := data.decode_u32(payload_offset + 84)
				var lmask := data.decode_u32(payload_offset + 92)
				cur_lighting_cfg0 = Vector4i(mat_en, mat_src, amb_src, nch)
				cur_lighting_cfg1 = Vector4i(a_mat_en, a_mat_src, lmask, 0)

				cur_chan_color[0] = Vector4(
					data.decode_float(payload_offset + 36),
					data.decode_float(payload_offset + 40),
					data.decode_float(payload_offset + 44),
					data.decode_float(payload_offset + 48)
				)
				cur_chan_color[1] = Vector4(
					data.decode_float(payload_offset + 4),
					data.decode_float(payload_offset + 8),
					data.decode_float(payload_offset + 12),
					data.decode_float(payload_offset + 16)
				)

				for i in range(8):
					var lp = payload_offset + 100 + i * 64
					cur_light_pos[i] = Vector3(
						data.decode_float(lp + 0),
						data.decode_float(lp + 4),
						data.decode_float(lp + 8)
					)
					cur_light_color[i] = Vector4(
						data.decode_float(lp + 24),
						data.decode_float(lp + 28),
						data.decode_float(lp + 32),
						data.decode_float(lp + 36)
					)

			CMD_SET_TEV_STAGE:
				var stg := data.decode_u8(payload_offset + 0)
				if stg < 3:
					cur_tev_color_in[stg] = Vector4i(
						data.decode_u8(payload_offset + 1),
						data.decode_u8(payload_offset + 2),
						data.decode_u8(payload_offset + 3),
						data.decode_u8(payload_offset + 4)
					)
					cur_tev_alpha_in[stg] = Vector4i(
						data.decode_u8(payload_offset + 5),
						data.decode_u8(payload_offset + 6),
						data.decode_u8(payload_offset + 7),
						data.decode_u8(payload_offset + 8)
					)
					cur_tev_color_op[stg] = data.decode_u8(payload_offset + 9)
					cur_tev_alpha_op[stg] = data.decode_u8(payload_offset + 14)
					cur_tev_bsc[stg] = Vector4i(
						data.decode_u8(payload_offset + 10),
						data.decode_u8(payload_offset + 11),
						data.decode_u8(payload_offset + 15),
						data.decode_u8(payload_offset + 16)
					)
					cur_tev_out[stg] = Vector4i(
						data.decode_u8(payload_offset + 12),
						data.decode_u8(payload_offset + 17),
						data.decode_u8(payload_offset + 13),
						data.decode_u8(payload_offset + 18)
					)
					var tc := data.decode_u8(payload_offset + 19)
					if tc > 1:
						tc = 1
					cur_tev_tc_src[stg] = tc
					cur_tev_ksel[stg] = Vector3i(
						data.decode_u8(payload_offset + 22),
						data.decode_u8(payload_offset + 23),
						0
					)
					cur_tev_swap[stg] = Vector2i(
						data.decode_u8(payload_offset + 24),
						data.decode_u8(payload_offset + 25)
					)

			CMD_SET_TEV_REGISTERS:
				cur_num_tev_stages = data.decode_u32(payload_offset + 0)
				cur_tev_prev = Vector4(
					data.decode_float(payload_offset + 4),
					data.decode_float(payload_offset + 8),
					data.decode_float(payload_offset + 12),
					data.decode_float(payload_offset + 16)
				)
				cur_tev_reg0 = Vector4(
					data.decode_float(payload_offset + 20),
					data.decode_float(payload_offset + 24),
					data.decode_float(payload_offset + 28),
					data.decode_float(payload_offset + 32)
				)
				cur_tev_reg1 = Vector4(
					data.decode_float(payload_offset + 36),
					data.decode_float(payload_offset + 40),
					data.decode_float(payload_offset + 44),
					data.decode_float(payload_offset + 48)
				)
				cur_tev_reg2 = Vector4(
					data.decode_float(payload_offset + 52),
					data.decode_float(payload_offset + 56),
					data.decode_float(payload_offset + 60),
					data.decode_float(payload_offset + 64)
				)
				for i in range(4):
					var kp = payload_offset + 68 + i * 16
					cur_kcolor[i] = Vector4(
						data.decode_float(kp + 0),
						data.decode_float(kp + 4),
						data.decode_float(kp + 8),
						data.decode_float(kp + 12)
					)
					var sp = payload_offset + 132 + i * 4
					cur_swap_table[i] = Vector4i(
						data.decode_u8(sp + 0),
						data.decode_u8(sp + 1),
						data.decode_u8(sp + 2),
						data.decode_u8(sp + 3)
					)

			CMD_SET_TEXGEN:
				cur_texmtx_enable[0] = data.decode_u32(payload_offset + 0)
				cur_texmtx_enable[1] = data.decode_u32(payload_offset + 4)
				cur_texgen_src[0] = data.decode_u32(payload_offset + 8)
				cur_texgen_src[1] = data.decode_u32(payload_offset + 12)
				for i in range(2):
					var r0p = payload_offset + 16 + i * 16
					cur_texmtx_row0[i] = Vector4(
						data.decode_float(r0p + 0),
						data.decode_float(r0p + 4),
						data.decode_float(r0p + 8),
						data.decode_float(r0p + 12)
					)
					var r1p = payload_offset + 48 + i * 16
					cur_texmtx_row1[i] = Vector4(
						data.decode_float(r1p + 0),
						data.decode_float(r1p + 4),
						data.decode_float(r1p + 8),
						data.decode_float(r1p + 12)
					)

			CMD_BIND_TEXTURE:
				var stage := data.decode_u32(payload_offset)
				var tex_id := data.decode_u32(payload_offset + 4)
				var wrap_s := data.decode_u8(payload_offset + 8)
				var wrap_t := data.decode_u8(payload_offset + 9)
				if stage < 3:
					cur_tex_wrap[stage] = Vector2i(wrap_s, wrap_t)
					if tex_id != 0xFFFFFFFF and tex_id < frame_textures.size() and frame_textures[tex_id].is_valid():
						cur_bound_textures[stage] = frame_textures[tex_id]
						cur_bound_texture_hash[stage] = int(frame_texture_hashes[tex_id])
						cur_use_texture[stage] = 1
					else:
						cur_bound_textures[stage] = dummy_white_tex
						cur_bound_texture_hash[stage] = 0
						cur_use_texture[stage] = 0

			CMD_DRAW:
				if max_draws >= 0 and stats_draw_calls >= max_draws:
					continue
				var prim_type := data.decode_u16(payload_offset)
				var pass_type := data.decode_u16(payload_offset + 2)
				var vbo_id := data.decode_u32(payload_offset + 4)
				var vertex_offset := data.decode_u32(payload_offset + 8)
				var vertex_count := data.decode_u32(payload_offset + 12)

				# Track textures bound to transparent draws (water is a translucent
				# surface) for the F6 water-identification debug dump.
				if pass_type == PASS_TRANSPARENT:
					var th = int(cur_bound_texture_hash[0])
					if th != 0:
						transparent_tex_hashes[th] = true

				if vbo_id < frame_vbos.size() and vertex_count > 0:
					var vbo_info: Dictionary = frame_vbos[vbo_id]
					var water_mesh = lighting_mode == 1 and pass_type != PASS_UI and not has_subview and is_water_texture(int(cur_bound_texture_hash[0]))
					var mesh_hash = (vbo_info.hash ^ (int(prim_type) << 32) ^ (int(vertex_count) << 48)) + vertex_offset
					if water_mesh: mesh_hash ^= 0x1000000000000000
					var mesh_rid := RID()

					if mesh_cache.has(mesh_hash):
						stats_mesh_cache_hits += 1
						mesh_rid = mesh_cache[mesh_hash]
						mesh_last_frame[mesh_hash] = frame_index
					else:
						stats_mesh_cache_misses += 1
						var vbo_start = vbo_info.vbo_offset + vertex_offset * vbo_info.stride
						var mesh_result = _create_mesh_from_vbo(data, vbo_start, vertex_count, vbo_info.stride, prim_type, water_mesh)
						mesh_rid = mesh_result.rid
						if mesh_rid.is_valid():
							mesh_cache[mesh_hash] = mesh_rid
							mesh_is_ground[mesh_hash] = mesh_result.is_ground
							mesh_avg_color[mesh_hash] = mesh_result.avg_color
							mesh_radius[mesh_hash] = mesh_result.radius
							mesh_vertex_count[mesh_hash] = mesh_result.get("vertex_count", 0)
							mesh_last_frame[mesh_hash] = frame_index

					if mesh_rid.is_valid():
						var inst_idx = active_instance_count
						active_instance_count += 1
						_ensure_instance_pool_size(active_instance_count)

						var inst: RID = instance_pool[inst_idx]

						# Pass ordering & submission order:
						var priority = 0
						if pass_type == PASS_TRANSPARENT:
							priority = clampi(-60 + stats_transparent_draws, -60, -1)
							stats_transparent_draws += 1
						elif pass_type == PASS_UI:
							priority = clampi(ui_priority_base + stats_ui_draws, -120, 127)
							stats_ui_draws += 1
						else:
							priority = -128
							stats_opaque_draws += 1

						# 1. Select / compile shader variant
						# Screen-space 3D must stay between the surrounding menu draws.
						# Godot normally submits opaque geometry before all transparent UI.
						var in_subview = cur_vp_transform != Vector4(1.0, 1.0, 0.0, 0.0)
						var ordered_overlay = has_subview and (in_subview or stats_ui_draws > 0)
						var z_test = cur_z_test
						var z_write = cur_z_write
						if ordered_overlay:
							priority = -128 + int(255.0 * stats_draw_calls / maxi(total_draws - 1, 1))
							# Flat menu layers compose in order; retain depth within 3D subviews.
							if not in_subview:
								z_test = 0
								z_write = 0
						# Water surfaces (lit mode) use the dedicated PBR water shader.
						# Detected by the bound texture hash only (no color heuristics).
						var use_water = lighting_mode == 1 and pass_type != PASS_UI and not ordered_overlay and is_water_texture(int(cur_bound_texture_hash[0]))
						if use_water:
							stats_water_draws += 1
						var s_rid = water_shader_rid if use_water else _get_shader_variant(cur_cull_mode, z_test, z_write, cur_blend_mode, ordered_overlay and cur_blend_mode != 1 and cur_blend_mode != 3, ordered_overlay, lighting_mode == 1 and pass_type != PASS_UI and not ordered_overlay)

						# 2. Compute material state hash
						var mat_key = [
							s_rid,
							priority,
							cur_proj_matrix,
							cur_texmtx_row0,
							cur_texmtx_row1,
							cur_texmtx_enable,
							cur_texgen_src,
							cur_scissor,
							cur_vp_transform,
							cur_fog_enable,
							cur_fog_params,
							cur_fog_color,
							cur_tev_prev,
							cur_tev_reg0,
							cur_tev_reg1,
							cur_tev_reg2,
							cur_num_tev_stages,
							cur_tev_color_in,
							cur_tev_alpha_in,
							cur_tev_color_op,
							cur_tev_alpha_op,
							cur_tev_tc_src,
							cur_tev_bsc,
							cur_tev_out,
							cur_tev_swap,
							cur_bound_textures,
							cur_use_texture,
							cur_tex_wrap,
							cur_lighting_cfg0,
							cur_lighting_cfg1,
							cur_chan_color,
							cur_light_pos,
							cur_light_color,
							cur_kcolor,
							cur_tev_ksel,
							cur_swap_table,
							cur_alpha_ctrl,
							cur_alpha_refs,
							debug_color,
							inst_idx if debug_color else 0,
							cur_num_ind_stages
						]
						var mat_hash := hash(mat_key)

						var mat: RID
						if mat_cache.has(mat_hash):
							mat = mat_cache[mat_hash]
							mat_last_frame[mat_hash] = frame_index
						else:
							mat = RenderingServer.material_create()
							RenderingServer.material_set_shader(mat, s_rid)
							RenderingServer.material_set_render_priority(mat, priority)

							# Upload transforms & matrices
							RenderingServer.material_set_param(mat, "u_projection", cur_proj_matrix)
							if use_water:
								RenderingServer.material_set_param(mat, "u_inverse_projection", cur_proj_matrix.inverse())
							RenderingServer.material_set_param(mat, "u_texmtx_row0", cur_texmtx_row0.duplicate())
							RenderingServer.material_set_param(mat, "u_texmtx_row1", cur_texmtx_row1.duplicate())
							RenderingServer.material_set_param(mat, "u_texmtx_enable", cur_texmtx_enable.duplicate())
							RenderingServer.material_set_param(mat, "u_texgen_src", cur_texgen_src.duplicate())
							RenderingServer.material_set_param(mat, "u_scissor", cur_scissor)
							RenderingServer.material_set_param(mat, "u_vp_transform", cur_vp_transform)

							# Upload Fog
							RenderingServer.material_set_param(mat, "u_fog_enable", cur_fog_enable)
							RenderingServer.material_set_param(mat, "u_fog_params", cur_fog_params)
							RenderingServer.material_set_param(mat, "u_fog_color", cur_fog_color)

							# Upload TEV Registers
							RenderingServer.material_set_param(mat, "u_tev_prev", cur_tev_prev)
							RenderingServer.material_set_param(mat, "u_tev_reg0", cur_tev_reg0)
							RenderingServer.material_set_param(mat, "u_tev_reg1", cur_tev_reg1)
							RenderingServer.material_set_param(mat, "u_tev_reg2", cur_tev_reg2)

							# Upload Per-Stage TEV Config
							RenderingServer.material_set_param(mat, "u_num_tev_stages", cur_num_tev_stages)
							RenderingServer.material_set_param(mat, "u_tev_color_in", cur_tev_color_in.duplicate())
							RenderingServer.material_set_param(mat, "u_tev_alpha_in", cur_tev_alpha_in.duplicate())
							RenderingServer.material_set_param(mat, "u_tev_color_op", cur_tev_color_op.duplicate())
							RenderingServer.material_set_param(mat, "u_tev_alpha_op", cur_tev_alpha_op.duplicate())
							RenderingServer.material_set_param(mat, "u_tev_tc_src", cur_tev_tc_src.duplicate())
							RenderingServer.material_set_param(mat, "u_tev_bsc", cur_tev_bsc.duplicate())
							RenderingServer.material_set_param(mat, "u_tev_out", cur_tev_out.duplicate())
							RenderingServer.material_set_param(mat, "u_tev_swap", cur_tev_swap.duplicate())

							# Upload Textures
							for s in range(3):
								var t = cur_bound_textures[s]
								if not t.is_valid() or t == RID():
									t = dummy_white_tex
								RenderingServer.material_set_param(mat, "u_texture%d" % s, t)
							RenderingServer.material_set_param(mat, "u_use_texture", cur_use_texture.duplicate())
							RenderingServer.material_set_param(mat, "u_tex_wrap", cur_tex_wrap.duplicate())

							# Upload Lighting & Constants
							RenderingServer.material_set_param(mat, "u_lighting_cfg0", cur_lighting_cfg0)
							RenderingServer.material_set_param(mat, "u_lighting_cfg1", cur_lighting_cfg1)
							RenderingServer.material_set_param(mat, "u_chan_color", cur_chan_color.duplicate())
							RenderingServer.material_set_param(mat, "u_light_pos", cur_light_pos.duplicate())
							RenderingServer.material_set_param(mat, "u_light_color", cur_light_color.duplicate())

							RenderingServer.material_set_param(mat, "u_kcolor", cur_kcolor.duplicate())
							RenderingServer.material_set_param(mat, "u_tev_ksel", cur_tev_ksel.duplicate())
							RenderingServer.material_set_param(mat, "u_swap_table", cur_swap_table.duplicate())

							# Upload Alpha Compare
							RenderingServer.material_set_param(mat, "u_alpha_ctrl", cur_alpha_ctrl)
							RenderingServer.material_set_param(mat, "u_alpha_refs", cur_alpha_refs)

							# Upload Debug Color Mode
							if debug_color:
								var r = float((inst_idx * 37 + 17) % 256) / 255.0
								var g = float((inst_idx * 79 + 53) % 256) / 255.0
								var b = float((inst_idx * 131 + 89) % 256) / 255.0
								RenderingServer.material_set_param(mat, "u_debug_color", Vector4(r, g, b, 1.0))
							else:
								RenderingServer.material_set_param(mat, "u_debug_color", Vector4(0.0, 0.0, 0.0, 0.0))

							RenderingServer.material_set_param(mat, "u_num_ind_stages", cur_num_ind_stages)
							stats_material_updates += 1

							mat_cache[mat_hash] = mat
							mat_last_frame[mat_hash] = frame_index

							# Track texture dependencies to evict materials if textures are freed
							for s in range(3):
								var t = cur_bound_textures[s]
								if t.is_valid() and t != dummy_white_tex:
									var list = tex_to_materials.get(t, null)
									if list == null:
										list = []
										tex_to_materials[t] = list
									list.append(mat_hash)

						# 9. Bind to RenderingServer Instance
						RenderingServer.instance_set_scenario(inst, scenario)
						if instance_meshes[inst_idx] != mesh_rid:
							RenderingServer.instance_set_base(inst, mesh_rid)
							instance_meshes[inst_idx] = mesh_rid
						if instance_materials[inst_idx] != mat:
							RenderingServer.instance_geometry_set_material_override(inst, mat)
							instance_materials[inst_idx] = mat
						# Upright meshes (actors, trees, fences, buildings, signs)
						# cast shadows; flat ground and flat decal quads (whose
						# normals point steeply up) do not. The ground classification
						# is cached per mesh hash at creation time. Foliage is
						# alpha-blended but upright, so it still casts.
						var is_ground: bool = mesh_is_ground.get(mesh_hash, false)
						var casts_shadow = lighting_mode == 1 and pass_type != PASS_UI and not ordered_overlay and not is_ground
						RenderingServer.instance_geometry_set_cast_shadows_setting(inst, RenderingServer.SHADOW_CASTING_SETTING_ON if casts_shadow else RenderingServer.SHADOW_CASTING_SETTING_OFF)

						var is_3d_geom: bool = lighting_mode == 1 and has_3d_view and pass_type != PASS_UI and not ordered_overlay
						var final_xform: Transform3D = cur_world_transform if is_3d_geom else cur_transform
						RenderingServer.instance_set_transform(inst, final_xform)
						# Keep casters that are just outside the view in the shadow
						# pass; otherwise their shadow vanishes the moment the object
						# leaves the screen edge (offscreen-caster culling).
						RenderingServer.instance_set_extra_visibility_margin(
							inst, SHADOW_CASTER_CULL_MARGIN if casts_shadow else 0.0)

						var v_count: int = mesh_vertex_count.get(mesh_hash, 0)
						var is_static: bool = is_3d_geom and not force_dynamic_gi and (is_ground or (v_count >= 60 and _is_static_draw(mesh_hash, cur_world_transform, mat_hash)))
						# GI flags are pinned OFF on purpose: _is_static_draw keys the world
						# cell with floor(origin), and the reconstructed world origin jitters
						# by 1-2 units, so that cell flipped between frames and is_static
						# toggled per frame. The flip changed baked-light vs dynamic-GI
						# shading, which reads exactly like a large shadow popping in and
						# out. SDFGI is disabled anyway, so these flags bought nothing but
						# instability. is_static is still computed for the draw descriptor.
						RenderingServer.instance_geometry_set_flag(inst, RenderingServer.INSTANCE_FLAG_USE_BAKED_LIGHT, false)
						RenderingServer.instance_geometry_set_flag(inst, RenderingServer.INSTANCE_FLAG_USE_DYNAMIC_GI, false)

						frame_draw_descriptors.append({
							"mesh_hash": mesh_hash,
							"pass_type": pass_type,
							"is_ground": is_ground,
							"is_static": is_static,
							"cur_transform": cur_transform,
							"world_transform": cur_world_transform,
						})
						RenderingServer.instance_geometry_set_shader_parameter(inst, "u_normal_r0", cur_nrm_matrix.x)
						RenderingServer.instance_geometry_set_shader_parameter(inst, "u_normal_r1", cur_nrm_matrix.y)
						RenderingServer.instance_geometry_set_shader_parameter(inst, "u_normal_r2", cur_nrm_matrix.z)
						RenderingServer.instance_set_visible(inst, true)
						# TEMPORARY DEBUG: record EVERY shadow caster of this frame (not
						# only the largest) as a compact array for the frame-diff trace.
						# Layout: [hash, mat, ox, oy, oz, radius, pool, inst, cast, ground, verts]
						if DBG_TRACE_ENABLED and casts_shadow and is_3d_geom:
							dbg_frame_casters.append([
								mesh_hash, mat_hash,
								final_xform.origin.x, final_xform.origin.y, final_xform.origin.z,
								mesh_radius.get(mesh_hash, 0.0),
								inst_idx, inst.get_id(),
								1 if casts_shadow else 0, 1 if is_ground else 0,
								mesh_vertex_count.get(mesh_hash, 0),
							])

						stats_draw_calls += 1

	# TEMPORARY DEBUG: push the full caster set of this frame into the trace ring.
	dbg_trace.append({
		"frame": _current_frame_index,
		"draws": stats_draw_calls,
		"instances": active_instance_count,
		"casters": dbg_frame_casters,
	})
	while dbg_trace.size() > DBG_TRACE_FRAMES:
		dbg_trace.pop_front()
	dbg_frame_casters = []

	# Hide, detach, and clear overrides on all unused instances in pool
	for i in range(active_instance_count, instance_pool.size()):
		RenderingServer.instance_set_scenario(instance_pool[i], RID())
		RenderingServer.instance_set_visible(instance_pool[i], false)
		if instance_materials[i] != RID():
			RenderingServer.instance_geometry_set_material_override(instance_pool[i], RID())
			instance_materials[i] = RID()
		if instance_meshes[i] != RID():
			RenderingServer.instance_set_base(instance_pool[i], RID())
			instance_meshes[i] = RID()
		RenderingServer.instance_geometry_set_shader_parameter(instance_pool[i], "u_normal_r0", Vector3(1, 0, 0))
		RenderingServer.instance_geometry_set_shader_parameter(instance_pool[i], "u_normal_r1", Vector3(0, 1, 0))
		RenderingServer.instance_geometry_set_shader_parameter(instance_pool[i], "u_normal_r2", Vector3(0, 0, 1))

	# Evict stale materials if cache exceeds limit
	if mat_cache.size() > MAX_CACHED_MATERIALS:
		var evict_target = mat_cache.size() - MAX_CACHED_MATERIALS
		var to_remove = []
		for h in mat_cache:
			if to_remove.size() >= evict_target:
				break
			if mat_last_frame.get(h, 0) != frame_index:
				to_remove.append(h)
		for h in to_remove:
			var m_rid = mat_cache[h]
			# Active resources have frame_index; inactive slots are detached above.
			RenderingServer.free_rid(m_rid)
			mat_cache.erase(h)
			mat_last_frame.erase(h)

	# Evict stale meshes if cache exceeds limit
	if mesh_cache.size() > MAX_CACHED_MESHES:
		var evict_target = mesh_cache.size() - MAX_CACHED_MESHES
		var to_remove = []
		for h in mesh_cache:
			if to_remove.size() >= evict_target:
				break
			if mesh_last_frame.get(h, 0) != frame_index:
				to_remove.append(h)
		for h in to_remove:
			var m_rid = mesh_cache[h]
			# Active resources have frame_index; inactive slots are detached above.
			if mesh_free_pool.size() < 128:
				RenderingServer.mesh_clear(m_rid)
				mesh_free_pool.append(m_rid)
			else:
				RenderingServer.free_rid(m_rid)
			mesh_cache.erase(h)
			mesh_last_frame.erase(h)
			mesh_is_ground.erase(h)
			mesh_avg_color.erase(h)
			mesh_vertex_count.erase(h)
			stats_mesh_cache_evictions += 1

	# Evict stale textures if cache exceeds limit
	if tex_cache.size() > MAX_CACHED_TEXTURES:
		var evict_target = tex_cache.size() - MAX_CACHED_TEXTURES
		var to_remove = []
		for h in tex_cache:
			if to_remove.size() >= evict_target:
				break
			if tex_last_frame.get(h, 0) != frame_index:
				to_remove.append(h)
		for h in to_remove:
			var t_rid = tex_cache[h]
			if tex_to_materials.has(t_rid):
				for m_hash in tex_to_materials[t_rid]:
					if mat_cache.has(m_hash):
						var m_rid = mat_cache[m_hash]
						RenderingServer.free_rid(m_rid)
						mat_cache.erase(m_hash)
						mat_last_frame.erase(m_hash)
				tex_to_materials.erase(t_rid)
			RenderingServer.free_rid(t_rid)
			tex_cache.erase(h)
			tex_last_frame.erase(h)

	var elapsed_us := Time.get_ticks_usec() - t0
	return {
		"success": true,
		"frame_index": frame_index,
		"clear_color": clear_col,
		"clear_depth": clear_depth,
		"draw_calls": stats_draw_calls,
		"opaque_draws": stats_opaque_draws,
		"transparent_draws": stats_transparent_draws,
		"ui_draws": stats_ui_draws,
		"water_draws": stats_water_draws,
		"efb_copies": stats_efb_copies,
		"active_instances": active_instance_count,
		"mesh_cache_hits": stats_mesh_cache_hits,
		"mesh_cache_misses": stats_mesh_cache_misses,
		"mesh_cache_evictions": stats_mesh_cache_evictions,
		"tex_cache_hits": stats_tex_cache_hits,
		"tex_cache_misses": stats_tex_cache_misses,
		"material_updates": stats_material_updates,
		"shader_variants": shader_variants.size(),
		"mesh_cache_total": mesh_cache.size(),
		"tex_cache_total": tex_cache.size(),
		"time_ms": elapsed_us / 1000.0
	}

func _create_mesh_from_vbo(data: PackedByteArray, vbo_offset: int, vertex_count: int, stride: int, prim_type: int, subdivide_water: bool = false) -> Dictionary:
	if prim_type == 0x80 and vertex_count < 4:
		return { "rid": RID(), "is_ground": false, "avg_color": Color.BLACK, "radius": 0.0 }
	if (prim_type == 0x90 or prim_type == 0x98) and vertex_count < 3:
		return { "rid": RID(), "is_ground": false, "avg_color": Color.BLACK, "radius": 0.0 }
	if vertex_count <= 0:
		return { "rid": RID(), "is_ground": false, "avg_color": Color.BLACK, "radius": 0.0 }

	var positions := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var normal_sum := Vector3.ZERO
	var color_sum := Color(0, 0, 0, 0)

	positions.resize(vertex_count)
	normals.resize(vertex_count)
	colors.resize(vertex_count)
	uvs.resize(vertex_count)

	for v in range(vertex_count):
		var base := vbo_offset + v * stride
		var px := data.decode_float(base)
		var py := data.decode_float(base + 4)
		var pz := data.decode_float(base + 8)
		positions[v] = Vector3(px, py, pz)

		var nx := data.decode_float(base + 12)
		var ny := data.decode_float(base + 16)
		var nz := data.decode_float(base + 20)
		var n_len_sq := nx * nx + ny * ny + nz * nz
		if n_len_sq > 0.0001:
			normals[v] = Vector3(nx, ny, nz)
		else:
			normals[v] = Vector3.UP
		normal_sum += normals[v]

		var r := data.decode_u8(base + 24) / 255.0
		var g := data.decode_u8(base + 25) / 255.0
		var b := data.decode_u8(base + 26) / 255.0
		var a := data.decode_u8(base + 27) / 255.0
		colors[v] = Color(r, g, b, a)
		color_sum += colors[v]

		var u := data.decode_float(base + 32)
		var v_coord := data.decode_float(base + 36)
		uvs[v] = Vector2(u, v_coord)

	var indices := PackedInt32Array()
	var godot_prim := RenderingServer.PRIMITIVE_TRIANGLES

	if prim_type == 0x80: # GX_QUADS -> convert to triangles
		var num_quads: int = vertex_count / 4
		indices.resize(num_quads * 6)
		var idx := 0
		for q in range(num_quads):
			var b := q * 4
			indices[idx] = b
			indices[idx + 1] = b + 1
			indices[idx + 2] = b + 2
			indices[idx + 3] = b
			indices[idx + 4] = b + 2
			indices[idx + 5] = b + 3
			idx += 6
	elif prim_type == 0x90: # GX_TRIANGLES (non-indexed)
		godot_prim = RenderingServer.PRIMITIVE_TRIANGLES
	elif prim_type == 0x98: # GX_TRIANGLE_STRIP
		godot_prim = RenderingServer.PRIMITIVE_TRIANGLE_STRIP
	elif prim_type == 0xA8 or prim_type == 0xB0: # LINES
		godot_prim = RenderingServer.PRIMITIVE_LINES
	elif prim_type == 0xB8: # POINTS
		godot_prim = RenderingServer.PRIMITIVE_POINTS
	else:
		godot_prim = RenderingServer.PRIMITIVE_TRIANGLES

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = positions
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	if indices.size() > 0:
		arrays[Mesh.ARRAY_INDEX] = indices

	if subdivide_water and godot_prim == RenderingServer.PRIMITIVE_TRIANGLES:
		arrays = _subdivide_water_surface(arrays)

	var mesh_rid: RID
	if mesh_free_pool.size() > 0:
		mesh_rid = mesh_free_pool.pop_back()
	else:
		mesh_rid = RenderingServer.mesh_create()
	RenderingServer.mesh_add_surface_from_arrays(mesh_rid, godot_prim, arrays)

	# Classify flat ground/path by the dominant vertex-normal direction: a mesh
	# whose averaged object-space normal points mostly upward is treated as a
	# shadow receiver only, not a caster. Mixed/sideways normals keep casting.
	var avg_normal := normal_sum.normalized()
	var is_ground: bool = avg_normal.y > GROUND_NORMAL_THRESHOLD
	var avg_color: Color = color_sum / float(vertex_count)
	# TEMPORARY DEBUG: bounding radius for caster identification in the trace ring.
	var bb_min := Vector3(INF, INF, INF)
	var bb_max := Vector3(-INF, -INF, -INF)
	for p in positions:
		bb_min = bb_min.min(p)
		bb_max = bb_max.max(p)
	var b_radius: float = (bb_max - bb_min).length() * 0.5
	return { "rid": mesh_rid, "is_ground": is_ground, "avg_color": avg_color, "vertex_count": vertex_count, "radius": b_radius }


func _subdivide_water_surface(source: Array) -> Array:
	# Cache only: original meshes remain untouched. Three midpoint splits give
	# the vertex shader enough points to bend the original broad water quads.
	var points: PackedVector3Array = source[Mesh.ARRAY_VERTEX]
	var source_uvs: PackedVector2Array = source[Mesh.ARRAY_TEX_UV]
	var source_normals: PackedVector3Array = source[Mesh.ARRAY_NORMAL]
	var source_indices: PackedInt32Array = source[Mesh.ARRAY_INDEX] if source[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	var texcoords := PackedVector2Array()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var count = source_indices.size() if not source_indices.is_empty() else points.size()
	for i in range(count):
		var index = source_indices[i] if not source_indices.is_empty() else i
		vertices.append(points[index])
		texcoords.append(source_uvs[index])
		normals.append(source_normals[index].normalized())
	for level in range(3):
		var next_vertices := PackedVector3Array()
		var next_normals := PackedVector3Array()
		var next_uvs := PackedVector2Array()
		for i in range(0, vertices.size() - 2, 3):
			var a = vertices[i]
			var b = vertices[i + 1]
			var c = vertices[i + 2]
			var ab = (a + b) * 0.5
			var bc = (b + c) * 0.5
			var ca = (c + a) * 0.5
			var ta = texcoords[i]
			var tb = texcoords[i + 1]
			var tc = texcoords[i + 2]
			var tab = (ta + tb) * 0.5
			var tbc = (tb + tc) * 0.5
			var tca = (tc + ta) * 0.5
			next_uvs.append_array(PackedVector2Array([ta, tab, tca, tab, tb, tbc, tca, tbc, tc, tab, tbc, tca]))
			var n = normals[i]
			next_vertices.append_array(PackedVector3Array([a, ab, ca, ab, b, bc, ca, bc, c, ab, bc, ca]))
			for j in range(12): next_normals.append(n)
		texcoords = next_uvs
		vertices = next_vertices
		normals = next_normals
	var result: Array = []
	result.resize(Mesh.ARRAY_MAX)
	result[Mesh.ARRAY_VERTEX] = vertices
	result[Mesh.ARRAY_NORMAL] = normals
	result[Mesh.ARRAY_TEX_UV] = texcoords
	return result
