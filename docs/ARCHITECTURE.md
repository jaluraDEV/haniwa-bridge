# ACGC Godot Hybrid — Architecture Specification

This document details the internal design of the **ACGC Godot Hybrid** engine.

---

## 1. System Overview

```
┌───────────────────────────────── 32-Bit C Host (HaniwaHost.exe) ─────────────────────────────────┐
│  - Decompiled GameCube Logic (ac-decomp / GAFE01_00)                                                │
│  - Integer 60.00 Hz Pacer (QueryPerformanceCounter)                                                  │
│  - DVD Emulation & FST loader from orig/GAFE01_00/                                                   │
│  - GX Display List Interpreter (emu64) -> ACFP Frame Capture                                        │
│  - DSP Audio Synthesizer -> 32 kHz Stereo PCM                                                        │
└──────────────────────────────────────────────────┬──────────────────────────────────────────────────┘
                                                   │ Writes ACFP Frames & Audio
                                                   ▼
┌────────────────────────────── Windows Shared Memory (Local\ACGC_SHM_V1, 32 MB) ──────────────────────┐
│  - Double-Buffered ACFP Frame Slots (2 × 12 MB, Tear-Free Monotonic frame_id)                        │
│  - SPSC Lock-Free Audio Ring Buffer (4 MB, ~100 ms Cushion Pacing)                                  │
│  - Game State Block (RTC: Hour/Min/Sec, Weather, Season, Scene ID)                                   │
│  - Input Block (PAD, XInput buttons/axes, RTC injection, Exit Flag, EFB ACK)                          │
└──────────────────────────────────────────────────┬──────────────────────────────────────────────────┘
                                                   │ Reads Frames & Audio, Writes Input
                                                   ▼
┌────────────────────────────── 64-Bit Godot 4 Client (Forward+ / Vulkan) ──────────────────────────────┐
│  - GDExtension Consumer (acgc_shm_client_x64.dll): SHM map, poll_frame, XInput polling               │
│  - ACFPRenderer: RenderingServer Low-Level Mesh/Material/RID Cache, View Matrix Inversion            │
│  - Shaders: PBR Lit + Cascaded Directional Shadows, TEV Unlit (F4 Mode), Tessellated Water          │
│  - EnvironmentController: Continuous 24h Sun/Moon Orbit, 4-Phase Color Palette, Fog                  │
│  - AudioStreamGenerator: 32 kHz Stereo Low-Latency Playback                                          │
└──────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Shared Memory IPC Layout (`port/include/acgc_shm.h`)

Total Shared Memory allocation: `32 MB` (`0x02000000` bytes) via Win32 `CreateFileMappingA` under named mapping `Local\ACGC_SHM_V1`.

### Memory Map:
| Section | Size | Description |
| :--- | :--- | :--- |
| **Header (`ACGCShmHeader`)** | `128 B` | Magic (`0x4143534D` / "ACSM"), version `1`, `frame_id`, slot indices, alive flags |
| **Input Block (`ACGCShmInputBlock`)** | `128 B` | GameCube PAD buttons/axes, analog triggers, RTC injection, EFB sequence ACK, exit flag |
| **State Block (`ACGCShmStateBlock`)** | `128 B` | Host frame timestamp, hour, minute, second, weather ID, season ID, scene ID |
| **Slot 0 (`ACFP` Frame)** | `12 MB` | Double-buffer slot 0: `payload_size` + binary `ACFP` frame packet |
| **Slot 1 (`ACFP` Frame)** | `12 MB` | Double-buffer slot 1: `payload_size` + binary `ACFP` frame packet |
| **Audio Ring (`ACGCShmAudioRing`)** | `4 MB` | SPSC lock-free ring buffer (2,097,152 `int16_t` samples = 1,048,576 stereo frames) |

---

## 3. Frame Packet Format (`bridge/include/acgc_frame_packet.h`)

Each rendered frame is transmitted as an `ACFP` packet containing:
1. **Packet Header**: Magic `ACFP`, frame number, draw call count, viewport/scissor dimensions, and camera projection parameters.
2. **Draw Commands**:
   - `ACFP_Cmd_Draw`: Vertex buffer (positions, colors, UVs, normals), index buffer, texture bindings, material flags (blend mode, alpha test, culling, z-test).
   - `ACFP_Cmd_EfbCopy`: Embedded Framebuffer copy commands (used for inventory character previews and blur transitions). Includes a sequence number `efb_seq` for reliable retransmission and Godot ACK.
   - `ACFP_Cmd_SetView`: View matrix updates.

---

## 4. Audio Pacing Architecture

Animal Crossing synthesizes audio at `32,000 Hz` in 560-sample blocks (~17.5 ms). A 60 Hz frame tick is ~16.67 ms (~533 samples).
To prevent drift and buffer overflow:
- The host monitors the consumer buffer cushion (`head - tail`).
- Target cushion: `6,400 samples` (~100 ms).
- If the cushion exceeds the target, synthesis for that tick yields.
- Godot reads available samples per frame via `AudioStreamGeneratorPlayback.get_frames_available()` and feeds them without blocking or buffer underrun.

---

## 5. One-Time ROM Extraction Engine

The host binary (`HaniwaHost.exe`) supports direct extraction via `--extract-rom <path> --out-dir <dir>`:
1. **Magic Verification**: Confirms GameCube disc magic `0xC2339F3D`.
2. **Game ID & Revision Check**: Requires `GAFE01` (Animal Crossing USA) and Revision `0`.
3. **Execution Extraction**:
   - Reads `main.dol` from the disc offset to `sys/main.dol`.
   - Locates `foresta.rel.szs` in the FST, performs Yaz0 decompression, and writes `sys/foresta.rel`.
4. **FST Asset Extraction**: Extracts all game files (sound banks, `.arc` archives, strings) into `files/`.
5. **Manifest Generation**: Generates `manifest.json` with file sizes and counts for launcher status verification.
