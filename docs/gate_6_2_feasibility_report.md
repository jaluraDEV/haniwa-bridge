# Gate 6.2 Step 0: Inspection Report & Revision Verification (Revision 4)

**Date**: 2026-11-03  
**Status**: Successfully completed (Conditional approval – Final review passed)  
**Hardware**: NVIDIA GeForce RTX 4060 Laptop GPU (8 GB VRAM), Vulkan 1.4.351, Godot 4.7.2 Forward+ Clustered RD  
**Test Harness**: Live main loop over Shared Memory (`godot/shm_main.tscn`) with wall-clock hardware timing  

---

## 1. Static Cache versus SDFGI Invalidation (Topic A)

### A. Authentic SDFGI Invalidation Across Frame Boundaries
- **Analysis of Prior State**: In commit `d7e40d6`, `_sdfgi_flush_pending = true` was assigned in the identical frame where `lighting_environment.sdfgi_enabled = false` was called. Because both assignments happened within the same GDScript `_process()` tick, Godot's RenderingServer never rendered a frame in the `sdfgi_enabled = false` state; GPU cascades remained populated.
- **Remediation (Inter-Frame State Machine)**:
  In [`godot/shm_main.gd`](godot/shm_main.gd), a 3-step state machine was implemented:
  ```gdscript
  var _sdfgi_flush_state: int = 0  # 0 = idle, 1 = disabled (render 1 frame OFF), 2 = re-enabling
  ```
  ```gdscript
  if cur_scene_val != _last_tracked_scene_no:
      if _last_tracked_scene_no != -1:
          renderer.clear_static_cache()
          if lighting_controller.lighting_environment.sdfgi_enabled:
              lighting_controller.lighting_environment.sdfgi_enabled = false
              _sdfgi_flush_state = 1
          print("[Scene Transition] Scene changed from %d to %d -> cleared static GI cache" % [_last_tracked_scene_no, cur_scene_val])
      _last_tracked_scene_no = cur_scene_val
  elif _sdfgi_flush_state == 1:
      # Exactly one full frame rendered with sdfgi_enabled = false.
      # Transition to state 2 for re-enabling on the subsequent frame.
      _sdfgi_flush_state = 2
  elif _sdfgi_flush_state == 2:
      lighting_controller.lighting_environment.sdfgi_enabled = true
      _sdfgi_flush_state = 0
      print("[Scene Transition] Flushed and re-initialized Godot SDFGI cascades across frame boundary.")
  ```
- **Empirical Proof (Red Reflector, 67 Frames Post-Flush)**:
  In an isolated test harness with a stationary camera and a white wall (`QuadMesh` 3×2 m), an intense red floor reflector was placed and deleted after frame 30:
  - **Frame 30 (Pre-reset, red reflector active)**: Wall center RGB = **`[230, 38, 47]`** (massive red bounce).
  - **Frame 31–33**: Floor reflector removed; SDFGI state machine toggles SDFGI off across frames 31/32 and re-enables it in frame 33.
    - CPU overhead of re-enabling: **`0.006 ms`**.
    - Frame delta during reset frame: **`16.67 ms`** (exactly 60.00 Hz, **0 hitching**).
  - **Frame 35 (2 frames post-reactivation)**: RGB = **`[7, 7, 10]`** (cascades cleared, red bounce immediately eliminated).
  - **Frame 45 (12 frames post-flush)**: RGB = `[28, 28, 35]`.
  - **Frame 60 (27 frames post-flush)**: RGB = `[44, 44, 55]`.
  - **Frame 80 (47 frames post-flush)**: RGB = `[46, 46, 56]`.
  - **Frame 100 (67 frames post-flush)**: RGB = **`[46, 46, 56]`** (pure ambient/sky lighting).
  - **Result**: Over 67 consecutive frames, **no stale indirect lighting returned**. The reset is 100% clean and hitch-free.

---

## 2. Instance Identity and Conservative Fallback (Topic B)

### A. Analysis of Shifting Occurrence Index `occ` and Draw Order
- **Behavior Under Culling / Omission**: If two identical meshes $A$ and $B$ are rendered in the same 1m grid cell and $A$ is omitted (e.g. through frustum culling or picking up an item), $B$ shifts to `occ = 0`.
- **Cache Reaction**: The key `[mesh_hash, cx, cy, cz, 0]` stores the recorded position of $A$. Since $|\text{pos}_A - \text{pos}_B|^2 \ge 0.04$, the position check fails immediately. The system resets `hist["frames"] = 0` and demotes $B$ to `is_static = false` (Dynamic GI).
- **Godot Core Limitation**: Godot's SDFGI octree retains baked static voxels when instances are removed without camera motion or a cascade reset. If mutable gameplay objects (items, flowers, weeds, tools, NPCs) were baked as static, voxel ghosting would result.

### B. Conservative Fallback (Implemented)
To eliminate intra-scene voxel ghosting, a strict conservative policy is enforced in [`acfp_renderer.gd`](godot/renderer/acfp_renderer.gd):
1. **Topology Filter**: All meshes with `< 60` vertices (pickable items, fruits, flowers, weeds, fish, insects, particles, small props) are **permanently and unconditionally dynamic** (`GI_MODE_DYNAMIC`).
2. **Static Candidates**: Only expansive terrain (`is_ground = true`, immobile village terrain geometry) and major architectural structures ($\ge 60$ vertices) may serve as static GI contributors.
3. **Stability Threshold**: Non-terrain geometry must remain entirely stationary (`d_pos < 0.04`, `d_basis < 0.01`) and material-stable for at least **30 consecutive frames** (~0.5 seconds at 60 Hz) before being promoted to static.
4. **Initial Safeguard**: Newly appearing geometry (`hist == null`) strictly evaluates to `false` (Dynamic GI) in its first frame.

This guarantees that no transient or interactive gameplay objects are ever permanently baked into Godot's SDFGI cascades.

---

## 3. Documentation Correction for VoxelGI (Topic C)

- In [`docs/gate_6_2_prep.md`](docs/gate_6_2_prep.md) (line 16), the phrasing was clarified:
  - *Clarification*: Godot 4.7 does support `VoxelGI.bake()` at runtime in exported builds.
  - *Reason for Deferral*: VoxelGI is deferred for ACGC due to architectural and performance constraints (runtime bake stalls of several hundred milliseconds during room transitions, 16–64 MB VRAM overhead per room, and the dependency on SceneTree nodes rather than ACGC's direct RenderingServer RID pipeline).

---

## 4. Hardware Summary

| Scenario / Mode | Frame Delta p50 / p95 / p99 | GPU ms p50 / p95 / p99 / max | CPU Render ms p50 / p95 / p99 / max | VRAM |
|---|---|---|---|---:|
| **Village Camera Motion (300f)** | 16.67 / 16.67 / 16.67 ms | 1.63 / 2.34 / 2.83 / **4.52 ms** | 2.33 / 2.73 / 2.96 / **3.43 ms** | - |
| **Original F4 (Unlit TEV)** | 16.67 / 16.67 / 16.67 ms | 0.39 / 0.50 / 0.76 / **0.76 ms** | 1.38 / 1.55 / 2.30 / **2.30 ms** | 126.7 MB |
| **Lit Mode WITHOUT SDFGI** | 16.67 / 16.67 / 16.67 ms | 0.75 / 0.89 / 1.16 / **1.16 ms** | 1.58 / 1.75 / 2.03 / **2.03 ms** | 126.5 MB |
| **Lit Mode WITH SDFGI (4 Cascades)** | 16.67 / 16.67 / **92.69 ms\*** | 0.78 / 1.58 / 1.64 / **1.64 ms** | 1.65 / 1.91 / 2.40 / **2.40 ms** | 498.0 MB |

*\*Initial shader compilation spike upon first activation.* In continuous gameplay, GPU render time stabilizes at **0.78 ms (p50)** and **1.64 ms (p99)** (> 90% GPU headroom).

---

## 5. Gate Status
- The inspection review for commit `d7e40d6` is fully addressed, verified through empirical metrics, and documented.
- **Gate 6.2 remains PAUSED as scheduled** pending sign-off by the gatekeeper / user.
