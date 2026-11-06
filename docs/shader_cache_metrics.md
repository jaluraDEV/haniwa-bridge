# Shader Cache Analysis & Benchmark Report

## 1. Root Cause Analysis of Warnings (`f.is_null()`)

### Symptom
When closing or rendering dynamically generated shader pipelines (specifically during `cleanup()` or shader release), the following error occurred:
```text
ERROR: Condition "f.is_null()" is true.
   at: _save_to_cache (servers/rendering/renderer_rd/shader_rd.cpp:696)
```

### Root Cause
1. **Missing Intermediate Directories in Godot 4.7 Forward+ RD**:
   In `servers/rendering/renderer_rd/shader_rd.cpp::_save_to_cache`, Godot generates a relative cache file path formatted as:
   `user://shader_cache/SceneForwardClusteredShaderRD/<group_sha256>/<variant_sha1>.<api>.cache`
   Godot invokes `FileAccess::open(path, FileAccess::WRITE)` prior to writing **without** first checking whether the intermediate directory for the shader group hash (`<group_sha256>`) exists (`make_dir_recursive` is absent at this location in engine code).
2. **Dynamic Shader Compilation vs. Standard Import**:
   During Godot editor imports, directories for group hashes of static built-in shaders are pre-created automatically. However, when a new custom shader is compiled at runtime (such as the PBR water shader `acgc_water.gdshader` introduced in Phase 5.5), this hash directory does not exist yet. The write attempt fails with `f.is_null()`.
3. **Persistent Cache Activation**:
   In `godot/project.godot`, `rendering/shader_compiler/shader_cache/enabled=true` had not yet been explicitly configured.

---

## 2. Technical Solution

1. **IAT Auto-Directory Hook in `bridge/src/acgc_shm_client.c`**:
   - Because `Godot_v4.7.2-stable_win64.exe` performs C file accesses via `msvcrt.dll` (`_wfopen` and `_wfopen_s`), the 64-bit GDExtension intercepts the IAT entries for `_wfopen` and `_wfopen_s` upon loading.
   - If a write attempt to a path containing `shader_cache` fails, `Hook_wfopen` / `Hook_wfopen_s` automatically creates all missing parent directories (`ensure_parent_dirs_w`) and re-attempts the open operation successfully.
   - Fully thread-safe and transparent to the engine.
2. **Project Configuration (`godot/project.godot`)**:
   - `rendering/shader_compiler/shader_cache/enabled=true` enabled.

---

## 3. Measurements: Cold Start vs. Warm Start (First Frame)

Measured on NVIDIA GeForce RTX 4060 Laptop GPU (Vulkan 1.4.351 Forward+), scene `captures/scene_village_day.acfp` (51 draw calls, 36 pipeline variants):

| Metric | Cold Start (Empty Cache) | Warm Start (Persistent Cache) | Difference |
| :--- | :---: | :---: | :---: |
| **Shader Warmup (36 variants)** | 1168.06 ms | 1009.52 ms | **-158.54 ms (-13.6 %)** |
| **First Frame `render_packet`** | 4.45 ms | 4.51 ms | Parity |
| **Startup to First Frame Complete** | **1179.32 ms** | **1049.77 ms** | **-129.55 ms** |
| **`Condition f.is_null()` Errors** | **0** | **0** | **Resolved** |
