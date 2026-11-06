# GX Graphics Layer Mapping & Profiling Analysis

## 1. Graphics Layer Architecture

The game renders through a 3-tier pipeline:
```
Game Logic (N64 Display Lists)
      │
      ▼
emu64 (Display List Interpreter & Emulation)
      │
      ▼
GX (GameCube GPU API)
      │
      ▼
PC Backend (`port/pc/src/pc_gx.c`, `pc_gx_tev.c`, `pc_gx_texture.c`)
      │
      ▼
OpenGL 3.3 Core (GLAD)
```

### Render Path:
1. Game logic invokes `game_main() -> scene->exec()`, generating N64 GBI Display Lists.
2. `graph_task_set00() -> emu64_taskstart()` traverses the display lists and translates them into native GameCube GX calls.
3. `pc_gx.c` intercepts the GX calls.
4. Vertices are buffered using a deferred commit model (`GXBegin`, `GXPosition*`, `GXColor*`, `GXTexCoord*`, `GXEnd`).
5. Whenever pipeline state (texture, matrix, blend, shader, Z-mode, fog) changes or a buffer fills up, a batch is flushed (`pc_gx_flush()`).
6. At frame end (`VIWaitForRetrace`), remaining batches are dispatched and `SDL_GL_SwapWindow` is called.

---

## 2. GX Calls Used in Practice (Runtime)

Analysis of dirty flags and profiler counters:

### Matrices & Projection
- `GXSetProjection` (~7–13 calls/frame)
- `GXLoadPosMtxImm`, `GXSetCurrentMtx` (~80–165 calls/frame)
  - Slot 0 (GX_PNMTX0): SHARED vertices (skinning / character joints)
  - Slot 1 (GX_PNMTX1): NONSHARED vertices (world object transforms)

### Vertex Submission & Formats
- `GXBegin(primitive, vtxfmt, nverts)` (predominantly `GX_TRIANGLES` or `GX_QUADS`)
- `GXPosition3f32`, `GXPosition3s16`, `GXPosition1x16`
- `GXNormal3s8`, `GXNormal1x16` (frequently unassigned or flat)
- `GXColor4u8`, `GXColor1x16` (vertex colors frequently carry pre-baked shading)
- `GXTexCoord2f32`, `GXTexCoord2s16`, `GXTexCoord1x16`
- `GXSetVtxAttrFmt`, `GXSetArray`

### TEV & Shader State (GameCube Texture Environment)
- `GXSetNumTevStages` (1 to 3 stages active)
- `GXSetTevOrder` (channel and texture assignment per stage)
- `GXSetTevColorIn`, `GXSetTevAlphaIn`
- `GXSetTevColorOp`, `GXSetTevAlphaOp` (Bias: ADDHALF/SUBHALF, Scale: 2x/4x/0.5x, Clamp)
- `GXSetTevColor`, `GXSetTevColorS10`, `GXSetTevKColor` (constant TEV registers)
- `GXSetTevSwapMode`, `GXSetTevSwapModeTable` (channel remapping)

### Textures & Filtering
- `GXLoadTexObj` (~80–140 binds/frame)
- 10 texture formats utilized in-game: I4, I8, IA4, IA8, RGB565, RGB5A3, RGBA8, CI4, CI8, CMPR (DXT1/S3TC)
- `GXSetTexCoordGen2` (~60–100 calls/frame)

### Render States & Post/EFB
- `GXSetAlphaCompare` (Alpha test)
- `GXSetBlendMode` (Alpha blending)
- `GXSetZMode` (Z-test, Z-write)
- `GXSetCullMode` (Culling)
- `GXSetFog` (Linear fog)
- `GXSetColorUpdate`, `GXSetAlphaUpdate`
- `GXCopyDisp`, `GXCopyTex` (EFB framebuffer copies for special effects)
- `GXSetNumIndStages`, `GXSetTevIndirect`, `GXSetIndTexMtx` (Indirect texturing)

---

## 3. Draw Call & Geometry Statistics

Measured with the built-in frame profiler (`--profile 60`):

| Metric | Model Viewer | Title Screen / Demo |
|---|---|---|
| **Draw Calls (Flushes)** | 6 | 210 – 255 |
| **Vertices / Frame** | 78 | 7,000 – 7,300 |
| **Buffer Uploads / Frame** | 7.3 KB | 660 – 685 KB |
| **Texture Binds / Frame** | 12 | 236 – 248 |
| **Shader Switches / Frame** | 3 | 17 – 21 |
| **Uniform Uploads / Frame** | 31 | 750 – 795 |
| **Game Logic CPU Time** | ~0.01 ms | ~0.20 ms |
| **emu64 CPU Time** | ~0.06 ms | ~0.85 ms |
| **GX Flush CPU Time** | ~0.03 ms | ~0.30 ms |
| **Total CPU Frame Time** | ~0.4 ms | ~1.4 ms (of 16.67 ms budget) |

### Implications for the Godot Bridge:
- At ~220 draw calls and ~7,200 vertices per frame, data volume is extremely light (~670 KB raw vertex data per frame).
- This is trivially handled by a GDExtension bridge in 32-bit address space or over shared memory.
- At 60 FPS, ~670 KB/frame corresponds to ~40 MB/s throughput, easily accommodated by dynamic buffer updates or ring buffers without latency concerns.
