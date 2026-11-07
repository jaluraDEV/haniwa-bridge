#!/usr/bin/env bash
# Build the standalone 32-bit headless host (Plan B producer).
# Run inside the MSYS2 MINGW32 shell. Produces HaniwaHost.exe in the repo root.
# Requires the port to be built first (port/pc/build32/libacgc_port.a).
set -e
export PATH="/mingw32/bin:/usr/bin:${PATH}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/port/pc/build32"

echo "=== Updating libacgc_port.a archive ==="
cd "${BUILD_DIR}"
find CMakeFiles/ac_pc.dir -name "*.obj" > objects.rsp
ar rcs libacgc_port.a @objects.rsp
rm -f objects.rsp

cd "${ROOT_DIR}"

echo "=== Building HaniwaHost.exe ==="
gcc -m32 -O2 \
    -static-libgcc -static-libstdc++ \
    -Wl,--large-address-aware \
    -Wl,--disable-dynamicbase \
    -Wl,--allow-multiple-definition \
    -Ibridge/include -Iport/pc/include -Iport/include \
    bridge/src/acgc_host.c \
    bridge/src/acgc_api_impl.c \
    -L"${BUILD_DIR}" \
    -Wl,--start-group "${BUILD_DIR}/libacgc_port.a" "${BUILD_DIR}/libglad.a" -Wl,--end-group \
    -lSDL2 -lopengl32 -lwinmm -limm32 -lversion -lsetupapi \
    -lkernel32 -luser32 -lgdi32 -lshell32 -lole32 -loleaut32 -luuid -lcomdlg32 -ladvapi32 -lstdc++ \
    -o HaniwaHost.exe

# Copy required runtime DLLs next to the host if absent.
cp -f /mingw32/bin/SDL2.dll . 2>/dev/null || true
cp -f /mingw32/bin/libwinpthread-1.dll . 2>/dev/null || true
cp -f /mingw32/bin/libstdc++-6.dll . 2>/dev/null || true
cp -f /mingw32/bin/libgcc_s_dw2-1.dll . 2>/dev/null || true

echo "=== Build finished: HaniwaHost.exe ==="
echo "Smoke test: ./HaniwaHost.exe --test-shm --frames 60 --rom rom/animal_crossing.iso"
