#!/usr/bin/env bash
# Build the 64-bit GDExtension SHM client (Plan B consumer) for Godot 4.7.
# Run inside the MSYS2 MINGW64 shell. Produces godot/bin/acgc_shm_client_x64.dll.
set -e
export PATH="/mingw64/bin:/usr/bin:${PATH}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${ROOT_DIR}/godot/bin"
cd "${ROOT_DIR}"

echo "=== Building acgc_shm_client_x64.dll (x86_64) ==="
# -static statically links the MinGW runtime (libgcc_s_seh-1.dll, libwinpthread-1.dll)
# so the DLL is fully self-contained: Godot's LoadLibraryW fails silently if those
# runtime DLLs are missing from its search path.
gcc -m64 -shared -O2 \
    -static -static-libgcc -static-libstdc++ \
    -Ibridge/include -Iport/include \
    bridge/src/acgc_shm_client.c \
    -lkernel32 -luser32 \
    -o godot/bin/acgc_shm_client_x64.dll

echo "=== Build finished: godot/bin/acgc_shm_client_x64.dll ==="
