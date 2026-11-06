#include <windows.h>
#include <stdio.h>
#include <stdint.h>
#include <math.h>

#include "acgc_shm.h"

int main(int argc, char** argv) {
    int duration_sec = 5;
    if (argc >= 2) duration_sec = atoi(argv[1]);
    if (duration_sec < 1) duration_sec = 1;

    printf("[Verify SHM Audio] Connecting to %s (timeout 10s)...\n", ACGC_SHM_MAPPING_NAME);

    HANDLE hmap = NULL;
    for (int i = 0; i < 100; i++) {
        hmap = OpenFileMappingA(FILE_MAP_ALL_ACCESS, FALSE, ACGC_SHM_MAPPING_NAME);
        if (hmap) break;
        Sleep(100);
    }

    if (!hmap) {
        fprintf(stderr, "[Verify SHM Audio] Failed to open mapping: %lu\n", GetLastError());
        return 1;
    }

    void* map = MapViewOfFile(hmap, FILE_MAP_ALL_ACCESS, 0, 0, ACGC_SHM_TOTAL_SIZE);
    if (!map) {
        fprintf(stderr, "[Verify SHM Audio] MapViewOfFile failed: %lu\n", GetLastError());
        CloseHandle(hmap);
        return 1;
    }

    ACGCShmHeader* hdr = ACGC_SHM_HEADER(map);
    ACGCShmAudioRing* ring = ACGC_SHM_AUDIO(map);
    int16_t* samples = ACGC_SHM_AUDIO_SAMPLES(map);

    printf("[Verify SHM Audio] Connected! Magic=0x%08X Version=%u Rate=%u Channels=%u Cap=%u samples\n",
           hdr->magic, hdr->version, hdr->audio_sample_rate, hdr->audio_channels, ring->buffer_samples);

    uint32_t cap = ring->buffer_samples;
    if (cap == 0) {
        fprintf(stderr, "[Verify SHM Audio] Invalid buffer capacity!\n");
        UnmapViewOfFile(map);
        CloseHandle(hmap);
        return 1;
    }

    uint64_t total_popped_frames = 0;
    uint32_t non_zero_samples = 0;
    int16_t min_s = 0, max_s = 0;
    double sum_sq = 0.0;

    DWORD t_start = GetTickCount();
    DWORD t_last_report = t_start;

    while (GetTickCount() - t_start < (DWORD)(duration_sec * 1000)) {
        Sleep(16); /* ~60 Hz consumer tick */

        uint32_t head = ring->head_sample;
        uint32_t tail = ring->tail_sample;
        uint32_t avail = (head >= tail) ? (head - tail) : (cap - tail + head);
        uint32_t avail_frames = avail / 2;

        /* Consume up to 533 stereo frames (~16.66 ms) per tick to simulate Godot */
        uint32_t to_pop = (avail_frames > 533) ? 533 : avail_frames;
        if (to_pop > 0) {
            for (uint32_t i = 0; i < to_pop; i++) {
                int16_t l = samples[(tail + 2 * i) % cap];
                int16_t r = samples[(tail + 2 * i + 1) % cap];
                if (l != 0 || r != 0) non_zero_samples += 2;
                if (l < min_s) min_s = l;
                if (l > max_s) max_s = l;
                if (r < min_s) min_s = r;
                if (r > max_s) max_s = r;
                sum_sq += (double)l * (double)l + (double)r * (double)r;
            }
            MemoryBarrier();
            InterlockedExchange((volatile LONG*)&ring->tail_sample, (LONG)((tail + to_pop * 2) % cap));
            total_popped_frames += to_pop;
        }

        DWORD now = GetTickCount();
        if (now - t_last_report >= 1000) {
            uint32_t cur_head = ring->head_sample;
            uint32_t cur_tail = ring->tail_sample;
            uint32_t cushion = (cur_head >= cur_tail) ? (cur_head - cur_tail) : (cap - cur_tail + cur_head);
            printf("[Verify SHM Audio] Popped: %llu frames | Cushion: %u samples (%u frames, %.1f ms) | HostFrame: %llu\n",
                   (unsigned long long)total_popped_frames, cushion, cushion / 2, (double)(cushion / 2) * 1000.0 / 32000.0,
                   (unsigned long long)hdr->frame_id);
            t_last_report = now;
        }
    }

    double rms = (total_popped_frames > 0) ? sqrt(sum_sq / (double)(total_popped_frames * 2)) : 0.0;
    printf("\n=== Verification Summary ===\n");
    printf("Total popped frames: %llu (%.2f s of audio)\n",
           (unsigned long long)total_popped_frames, (double)total_popped_frames / 32000.0);
    printf("Non-zero samples:    %u\n", non_zero_samples);
    printf("Sample range:        [%d, %d]\n", min_s, max_s);
    printf("RMS amplitude:       %.1f (normalized: %.4f)\n", rms, rms / 32768.0);
    printf("Host producer alive: %u\n", hdr->producer_alive);

    UnmapViewOfFile(map);
    CloseHandle(hmap);

    if (total_popped_frames < 32000) {
        printf("RESULT: FAIL (not enough audio produced)\n");
        return 1;
    }
    printf("RESULT: PASS (audio produced and consumed smoothly over SHM)\n");
    return 0;
}
