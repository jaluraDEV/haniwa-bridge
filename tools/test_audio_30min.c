/* Asset-free regression: 30-minute simulated run (108,000 ticks = 1800s)
 * Tests consumer-driven production with 7,040 samples (~110ms) latency target.
 */
#include "../port/pc/src/pc_audio.c"
#include <assert.h>
#include <stdio.h>
#include <time.h>

PCSettings g_pc_settings = {0};
static unsigned generated;

void pc_audio_process_frame(void) {
    s16 block[1120];
    for (unsigned i = 0; i < 1120; ++i)
        block[i] = (s16)((generated++ % 30000) - 15000);
    AIInitDMA((u32)(uintptr_t)block, sizeof(block));
}

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    unsigned consumed = 0, discontinuities = 0, callbacks = 0;
    audio_device = 1;
    g_pc_settings.master_volume = 100;
    SDL_AtomicSet(&audio_prefill_done, 1);
    
    /* Pre-fill with ~7,840 samples (7 blocks of 1,120) */
    for (int i = 0; i < 7; ++i) pc_audio_process_frame();

    /* 30 simulated minutes = 1,800 seconds = 108,000 ticks at 60 Hz */
    const int total_ticks = 108000;
    SDL_AtomicSet(&ring_write_pos, (int)(0x7fff0000u + 7840));
    SDL_AtomicSet(&ring_read_pos, (int)0x7fff0000u);

    clock_t t0 = clock();
    int min_fill = 65536;
    int max_fill = 0;

    /* Callback size matches AIInit: 1024 samples = 512 stereo frames = 16ms */
    const int cb_samples = 1024;

    for (int tick = 1; tick <= total_ticks; ++tick) {
        unsigned due = (unsigned)((unsigned long long)tick * 32000 / (60 * (cb_samples / 2)));
        while (callbacks < due) {
            s16 out[1024];
            pc_audio_callback(NULL, (Uint8 *)out, sizeof(out));
            for (int i = 0; i < cb_samples; ++i) {
                s16 expected = (s16)((consumed++ % 30000) - 15000);
                if (out[i] != expected) ++discontinuities;
            }
            ++callbacks;
        }

        /* Periodic 50ms OS scheduling hitch (3 frames = 50ms) every 15 seconds (every 900 ticks) */
        if (tick > 100 && tick % 900 >= 1 && tick % 900 <= 3) continue;

        pc_audio_service_tick();

        int fill = pc_audio_get_buffer_fill();
        if (fill < min_fill) min_fill = fill;
        if (fill > max_fill) max_fill = fill;

        if (tick % 36000 == 0) {
            printf("[30MIN AUDIO] %2d min (%6d ticks): fill=%d dropped=%d underruns=%d discontinuities=%u\n",
                   tick / 3600, tick, fill, pc_audio_get_dropped_samples(),
                   pc_audio_get_underruns(), discontinuities);
        }
    }

    clock_t t1 = clock();
    double cpu_sec = (double)(t1 - t0) / CLOCKS_PER_SEC;

    printf("\n=== 30-MINUTE AUDIO RUN COMPLETED ===\n");
    printf("Simulated duration:     30 minutes (1800.00 seconds)\n");
    printf("Simulated ticks:        108,000 @ 60 Hz\n");
    printf("Samples consumed:       %u stereo samples (%u audio callbacks)\n", consumed, callbacks);
    printf("Buffer cushion target:  7,040 samples (110.0 ms)\n");
    printf("Min buffer fill:        %d samples (%.1f ms)\n", min_fill, (float)min_fill / 64.0f);
    printf("Max buffer fill:        %d samples (%.1f ms)\n", max_fill, (float)max_fill / 64.0f);
    printf("Dropped samples:        %d\n", pc_audio_get_dropped_samples());
    printf("Audio underruns:        %d\n", pc_audio_get_underruns());
    printf("Discontinuities:        %u\n", discontinuities);
    printf("CPU calculation time:   %.3f seconds\n", cpu_sec);

    assert(pc_audio_get_dropped_samples() == 0);
    assert(pc_audio_get_underruns() == 0);
    assert(discontinuities == 0);
    assert(min_fill >= 2000);
    assert(max_fill < 7040 + 1120 * 2);

    printf("RESULT: PASSED (100%% sample continuity, 0 drops, 0 underruns, ~110ms latency)\n");
    return 0;
}
