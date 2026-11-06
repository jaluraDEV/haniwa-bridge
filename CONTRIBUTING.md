# Contributing to ACGC Godot Hybrid

Thank you for your interest in contributing! This document provides guidelines for contributors.

---

## ⚖️ Zero-Asset Policy (CRITICAL)

**Never commit or submit pull requests containing:**
- Nintendo ROMs or disc images (`.iso`, `.ciso`, `.gcm`).
- Extracted game assets (`.dol`, `.rel`, `.szs`, `.arc`, `.bin`, `.aw`, `.afc`).
- In-game screenshots containing Nintendo copyrighted logos or characters (`.png`, `.jpg`).
- Frame dump recordings (`.acfp`).
- Save files (`.gci`).

### Automated Verification
Before submitting any pull request or committing changes, run:
```powershell
python tools/verify_clean.py
```
This script scans all git-tracked files and will fail if any proprietary asset, forbidden file extension, or binary signature is found. Every PR must pass with 0 violations.

---

## 🛠️ Development Setup

1. **Toolchain**:
   - MSYS2 with `i686` (32-bit for host) and `x86_64` (64-bit for Godot client) GCC toolchains.
   - Godot 4.3+ (Standard 64-bit Windows build).
   - Python 3.10+.

2. **Building**:
   - Build 32-bit host: see instructions in `README.md`.
   - Build 64-bit client DLL: `./tools/build_client_x64.sh`.

3. **Running the Launcher / Development**:
   - Double-click `run_launcher.bat` or run `Godot_v4.7.2-stable_win64.exe --path godot`.

---

## 💡 Code Architecture Guidelines

- **Game Logic Preservation**: The GameCube decompiled logic in `port/` must remain intact. Do not rewrite gameplay logic in GDScript; the C host runs the original game code deterministically.
- **Shared Memory IPC (`ACGC_SHM_V1`)**: Changes to the IPC layout in `port/include/acgc_shm.h` must maintain lock-free SPSC guarantees and 32-bit/64-bit structure alignment.
- **Rendering**: Godot 4 renders via `RenderingServer` in `ACFPRenderer`. Avoid spawning SceneTree nodes for every mesh; reuse RIDs and mesh hash caches for 60 FPS performance.
- **Retro Parity (F4 Mode)**: Any enhancements made to shaders (`acgc_lit.gdshader`, `acgc_water.gdshader`) must not alter or regress the unlit GameCube TEV combiner pipeline (`acgc_unlit.gdshader`).
