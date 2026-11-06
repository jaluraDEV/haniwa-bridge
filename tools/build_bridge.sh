#!/usr/bin/env bash
export PATH="/mingw32/bin:/usr/bin:${PATH}"
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/port/pc/build32"

echo "=== Building port objects with ninja ==="
cd "${BUILD_DIR}"
ninja

echo "=== Updating libacgc_port.a archive ==="
# Find all obj files in CMakeFiles/ac_pc.dir and write to response file to avoid argument list limit
find CMakeFiles/ac_pc.dir -name "*.obj" > objects.rsp
ar rcs libacgc_port.a @objects.rsp
rm -f objects.rsp

echo "=== Building godot/bin/acgc_bridge.dll ==="
cd "${ROOT_DIR}"
mkdir -p godot/bin

gcc -m32 -shared -O2 \
    -static-libgcc -static-libstdc++ \
    -Wl,--large-address-aware \
    -Wl,--disable-dynamicbase -Wl,--image-base,0x68000000 \
    -Ibridge/include \
    -Iport/pc/include \
    -Iport/include \
    bridge/src/acgc_bridge.c \
    bridge/src/acgc_api_impl.c \
    -L"${BUILD_DIR}" \
    -Wl,--start-group "${BUILD_DIR}/libacgc_port.a" "${BUILD_DIR}/libglad.a" -Wl,--end-group \
    -lSDL2 -lopengl32 -lwinmm -limm32 -lversion -lsetupapi \
    -lkernel32 -luser32 -lgdi32 -lshell32 -lole32 -loleaut32 -luuid -lcomdlg32 -ladvapi32 -lstdc++ \
    -o godot/bin/acgc_bridge.dll

# Copy required runtime DLLs to godot/bin if not present
cp -f /mingw32/bin/SDL2.dll godot/bin/ 2>/dev/null || true
cp -f /mingw32/bin/libwinpthread-1.dll godot/bin/ 2>/dev/null || true

echo "=== Build finished successfully! ==="
