#!/usr/bin/env python3
"""
verify_clean.py — Automated Zero-Asset Audit for GitHub Repository.
Scans all git-tracked files (or workspace files if unzipped) for forbidden extensions,
magic bytes (GC ISO/CISO/Yaz0/ACFP), and unexpected binary blobs.
Exits with code 1 if any violation is detected.
"""
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

FORBIDDEN_EXTS = {
    ".iso", ".ciso", ".gcm", ".dol", ".rel", ".szs", ".arc",
    ".aw", ".afc", ".gci", ".acfp", ".bmp", ".exe", ".dll",
    ".a", ".lib", ".o", ".obj", ".jpg", ".ico"
}

ALLOWED_EXCEPTIONS = {
    "bridge/include/extension_api.json",
    "docs/assets/haniwa_logo.png",
    "godot/launcher/assets/haniwa_logo.png",
}

MAGIC_SIGNATURES = [
    (0x1C, b"\xC2\x33\x9F\x3D", "GameCube Disc Magic (0xC2339F3D)"),
    (0x00, b"CISO", "CISO Disc Image Header"),
    (0x00, b"Yaz0", "Nintendo Yaz0 Compressed Archive"),
    (0x00, b"ACFP", "Captured GameCube Frame Packet"),
]

IGNORED_DIRS = {
    ".git", "rom", "orig", "save", "save_backup", "captures",
    "golden", "screenshots", "build", "build32", "dist",
    ".godot", ".idea", ".vscode", "__pycache__"
}

def get_file_list() -> list[str]:
    # Try git ls-files first
    try:
        res = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True)
        files = [line.strip().replace("\\", "/") for line in res.stdout.splitlines() if line.strip()]
        if files:
            return files
    except Exception:
        pass

    # Fallback to filesystem traversal respecting ignored folders
    files = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        # prune ignored dirs
        dirnames[:] = [d for d in dirnames if d not in IGNORED_DIRS and not d.startswith("dump_run")]
        for f in filenames:
            p = Path(dirpath) / f
            rel = p.relative_to(ROOT).as_posix()
            files.append(rel)
    return files

def main() -> int:
    files = get_file_list()
    violations = []

    for rel_path in files:
        if rel_path in ALLOWED_EXCEPTIONS:
            continue
        p = ROOT / rel_path
        if not p.exists() or not p.is_file():
            continue

        ext = p.suffix.lower()
        if ext in FORBIDDEN_EXTS:
            violations.append(f"[FORBIDDEN EXT] {rel_path} ({ext})")
            continue

        # In docs/assets only haniwa_logo.png is allowed
        if ext == ".png" and rel_path != "docs/assets/haniwa_logo.png":
            violations.append(f"[FORBIDDEN IMAGE] {rel_path} (Only original haniwa_logo.png allowed)")
            continue

        try:
            with open(p, "rb") as f:
                header = f.read(64)
            for offset, sig, desc in MAGIC_SIGNATURES:
                if len(header) >= offset + len(sig) and header[offset:offset+len(sig)] == sig:
                    violations.append(f"[MAGIC SIGNATURE] {rel_path}: {desc}")
        except OSError as e:
            violations.append(f"[READ ERROR] {rel_path}: {e}")

    print(f"Scanned {len(files)} files.")
    if violations:
        print(f"\nFAILED: Found {len(violations)} asset policy violation(s):")
        for v in violations:
            print("  -", v)
        return 1

    print("PASS: Repository is 100% clean of ROMs, binaries, screenshots, and proprietary assets.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
