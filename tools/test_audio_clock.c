/* Asset-free regression: exercise the actual SDL backend with a synthetic DAC.
 * Build/run via tools/test_audio_clock.sh. No device or wall-clock sleeps.
 */
#include "../port/pc/src/pc_audio.c"
#include <assert.h>

PCSettings g_pc_settings = {0};
static unsigned generated;

void pc_audio_process_frame(void) {
    s16 block[1120];
    for (unsigned i = 0; i < 1120; ++i)
        block[i] = (s16)((generated++ % 30000) - 15000);
    AIInitDMA((u32)(uintptr_t)block, sizeof(block));
}

int main(int argc, char **argv) {
    int legacy = argc > 1 && strcmp(argv[1], "--legacy") == 0;
    unsigned consumed = 0, discontinuities = 0, callbacks = 0;
    /* Fake active device; DMA stays stopped so no SDL device calls occur. */
    audio_device = 1;
    g_pc_settings.master_volume = 100;
    SDL_AtomicSet(&audio_prefill_done, 1);
    for (int i = 0; i < 16; ++i) pc_audio_process_frame();

    /* 120 simulated seconds, 60 game ticks/s and 1024 stereo-frame callbacks.
     * Integer timebase avoids floating point clock drift. Also cross the
     * signed index boundary and wrap the physical ring many times. */
    SDL_AtomicSet(&ring_write_pos, (int)(0x7fff0000u + 17920));
    SDL_AtomicSet(&ring_read_pos, (int)0x7fff0000u);
    for (int tick = 1; tick <= 7200; ++tick) {
        unsigned due = (unsigned)((unsigned long long)tick * 32000 / (60 * 1024));
        while (callbacks < due) {
            s16 out[2048];
            pc_audio_callback(NULL, (Uint8 *)out, sizeof(out));
            for (unsigned i = 0; i < 2048; ++i) {
                s16 expected = (s16)((consumed++ % 30000) - 15000);
                if (out[i] != expected) ++discontinuities;
            }
            ++callbacks;
        }
        /* A 100 ms game-thread hitch every 15 seconds must preserve PCM. */
        if (!legacy && tick % 900 >= 1 && tick % 900 <= 6) continue;
        if (legacy) {
            pc_audio_process_frame();
            for (int i = 0; i < 4 && pc_audio_get_buffer_fill() < 17920; ++i)
                pc_audio_process_frame();
        } else {
            pc_audio_service_tick();
        }
    }
    printf("%s: dropped=%d underruns=%d discontinuous_samples=%u fill=%d\n",
           legacy ? "LEGACY" : "FIXED", pc_audio_get_dropped_samples(),
           pc_audio_get_underruns(), discontinuities, pc_audio_get_buffer_fill());
    if (legacy) {
        assert(pc_audio_get_dropped_samples() > 0 && discontinuities > 0);
    } else {
        assert(pc_audio_get_dropped_samples() == 0);
        assert(pc_audio_get_underruns() == 0);
        assert(discontinuities == 0);
        assert(pc_audio_get_buffer_fill() >= 17920);
        assert(pc_audio_get_buffer_fill() < 17920 + 1120);
    }
    return 0;
}
