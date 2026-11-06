# GX Graphics Layer Mapping & Profiling Analysis

## 1. Architektur der Grafikschicht

Das Spiel rendert über eine 3-stufige Pipeline:
```
Spiellogik (N64 Display Lists)
      │
      ▼
emu64 (Display List Interpreter & Emulation)
      │
      ▼
GX (GameCube GPU API)
      │
      ▼
PC-Backend (`port/pc/src/pc_gx.c`, `pc_gx_tev.c`, `pc_gx_texture.c`)
      │
      ▼
OpenGL 3.3 Core (GLAD)
```

### Zeichenpfad:
1. Spiellogik ruft `game_main() -> scene->exec()` auf und erzeugt N64 GBI Display Lists.
2. `graph_task_set00() -> emu64_taskstart()` traversiert Display Lists und konvertiert sie in native GameCube GX-Aufrufe.
3. `pc_gx.c` fängt die GX-Aufrufe ab.
4. Vertices werden über ein Deferred-Commit-Modell gepuffert (`GXBegin`, `GXPosition*`, `GXColor*`, `GXTexCoord*`, `GXEnd`).
5. Sobald sich Pipeline-Zustände (Textur, Matrix, Blend, Shader, Z-Mode, Fog) ändern oder ein Puffer voll ist, wird ein Batch geflusht (`pc_gx_flush()`).
6. Am Frame-Ende (`VIWaitForRetrace`) werden verbleibende Batches gezeichnet und `SDL_GL_SwapWindow` aufgerufen.

---

## 2. Tatsächlich genutzte GX-Aufrufe (Runtime)

Analyse der Dirty-Flags und Profiler-Zähler:

### Matrizen & Projektion
- `GXSetProjection` (~7–13 Aufrufe/Frame)
- `GXLoadPosMtxImm`, `GXSetCurrentMtx` (~80–165 Aufrufe/Frame)
  - Slot 0 (GX_PNMTX0): SHARED Vertices (Skinning / Charakter-Gelenke)
  - Slot 1 (GX_PNMTX1): NONSHARED Vertices (Objekt-Transformationen)

### Vertex-Submission & Formate
- `GXBegin(primitive, vtxfmt, nverts)` (meist `GX_TRIANGLES` oder `GX_QUADS`)
- `GXPosition3f32`, `GXPosition3s16`, `GXPosition1x16`
- `GXNormal3s8`, `GXNormal1x16` (oft nicht gesetzt oder flach)
- `GXColor4u8`, `GXColor1x16` (Vertexfarben enthalten teils vorab berechnetes Shading)
- `GXTexCoord2f32`, `GXTexCoord2s16`, `GXTexCoord1x16`
- `GXSetVtxAttrFmt`, `GXSetArray`

### TEV & Shader-Zustand (GameCube Texture Environment)
- `GXSetNumTevStages` (1 bis 3 Stages genutzt)
- `GXSetTevOrder` (Kanal- und Texturzuordnung pro Stage)
- `GXSetTevColorIn`, `GXSetTevAlphaIn`
- `GXSetTevColorOp`, `GXSetTevAlphaOp` (Bias: ADDHALF/SUBHALF, Scale: 2x/4x/0.5x, Clamp)
- `GXSetTevColor`, `GXSetTevColorS10`, `GXSetTevKColor` (Konstante TEV-Register)
- `GXSetTevSwapMode`, `GXSetTevSwapModeTable` (Kanal-Remapping)

### Texturen & Filterung
- `GXLoadTexObj` (~80–140 Binds/Frame)
- 10 Texturformate im Spiel: I4, I8, IA4, IA8, RGB565, RGB5A3, RGBA8, CI4, CI8, CMPR (DXT1/S3TC)
- `GXSetTexCoordGen2` (~60–100 Aufrufe/Frame)

### Renderzustände & Post/EFB
- `GXSetAlphaCompare` (Alpha-Test)
- `GXSetBlendMode` (Alpha-Blending)
- `GXSetZMode` (Z-Test, Z-Write)
- `GXSetCullMode` (Culling)
- `GXSetFog` (Linearer Nebel)
- `GXSetColorUpdate`, `GXSetAlphaUpdate`
- `GXCopyDisp`, `GXCopyTex` (EFB-Framebuffer-Kopien für Spezialeffekte)
- `GXSetNumIndStages`, `GXSetTevIndirect`, `GXSetIndTexMtx` (Indirekte Texturen)

---

## 3. Drawcall- und Geometrie-Statistik

Gemessen mit dem internen Frame-Profiler (`--profile 60`):

| Metrik | Model Viewer | Titelbildschirm / Demo |
|---|---|---|
| **Drawcalls (Flushes)** | 6 | 210 – 255 |
| **Vertices / Frame** | 78 | 7.000 – 7.300 |
| **Puffer-Uploads / Frame** | 7,3 KB | 660 – 685 KB |
| **Texturbindungen / Frame** | 12 | 236 – 248 |
| **Shader-Wechsel / Frame** | 3 | 17 – 21 |
| **Uniform-Uploads / Frame** | 31 | 750 – 795 |
| **CPU-Zeit Spiellogik** | ~0,01 ms | ~0,20 ms |
| **CPU-Zeit emu64** | ~0,06 ms | ~0,85 ms |
| **CPU-Zeit GX-Flush** | ~0,03 ms | ~0,30 ms |
| **Gesamte CPU-Frame-Zeit** | ~0,4 ms | ~1,4 ms (von 16,67 ms Budget) |

### Erkenntnis für die Godot-Bridge:
- Mit ~220 Drawcalls und ~7.200 Vertices pro Frame ist das Datenvolumen sehr moderat (ca. 670 KB Roh-Vertexdaten pro Frame).
- Dies ist für eine GDExtension-Brücke im 32-Bit-Adressraum exzellent handhabbar.
- Bei 60 FPS entspricht das Datenvolumen von ~670 KB/Frame einem Durchsatz von ca. 40 MB/s, was auch für dynamische Buffer-Updates oder Ringpuffer völlig unkritisch ist.
