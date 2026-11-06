#!/usr/bin/env bash
set -euo pipefail
export PATH="/mingw32/bin:/usr/bin:${PATH}"
cd "$(dirname "$0")/.."
mkdir -p scratch
gcc -m32 -O2 -DTARGET_PC -D_LANGUAGE_C -DF3DEX_GBI_2 -Iport/pc/include -Iport/include \
    -Iport/pc/lib/glad/include -I/mingw32/include/SDL2 \
    tools/test_audio_clock.c -lSDL2 -o scratch/test_audio_clock.exe
scratch/test_audio_clock.exe --legacy
scratch/test_audio_clock.exe
