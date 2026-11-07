/*
 * acgc_host.c — standalone 32-bit headless host (Plan B producer).
 *
 * Runs the GameCube game headless at 60 Hz, produces ACFP frame packets via the
 * render-capture backend, and publishes them into the Windows shared-memory
 * mapping described by port/include/acgc_shm.h. A 64-bit Godot process consumes
 * the frames and drives input back through the input block.
 *
 * This file deliberately has no GDExtension dependency: it links the plain
 * acgc_api_impl.c + libacgc_port.a + libglad.a + SDL2 (headless, audio disabled).
 */

#include "acgc_api.h"
#include "acgc_shm.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#endif

/* --- shared-memory / event handles (module scope for the Ctrl+C handler) --- */
static void*  s_map              = NULL;
static HANDLE s_hmap             = NULL;
static HANDLE s_ev_frame_ready   = NULL;
static HANDLE s_ev_input_ack     = NULL;
static volatile LONG s_stop      = 0;  /* set by Ctrl+C handler */

static void cleanup(void) {
    if (s_ev_frame_ready) { CloseHandle(s_ev_frame_ready); s_ev_frame_ready = NULL; }
    if (s_ev_input_ack)   { CloseHandle(s_ev_input_ack);   s_ev_input_ack   = NULL; }
    if (s_map)            { UnmapViewOfFile(s_map);        s_map = NULL; }
    if (s_hmap)           { CloseHandle(s_hmap);           s_hmap = NULL; }
}

static BOOL WINAPI ctrl_handler(DWORD ctrl_type) {
    (void)ctrl_type;
    InterlockedExchange(&s_stop, 1);
    return TRUE; /* handled */
}

static int fail(const char* msg) {
    fprintf(stderr, "[ACGC HOST] %s (Win32 error %lu)\n", msg, (unsigned long)GetLastError());
    cleanup();
    return 1;
}

/* Precise sleep until (freq, target_ticks) is reached; coarse Sleep + busy-wait. */
static void sleep_until(const LARGE_INTEGER* freq, LONGLONG target_ticks) {
    LARGE_INTEGER now;
    QueryPerformanceCounter(&now);
    LONGLONG remain = target_ticks - now.QuadPart;
    if (remain <= 0) return;
    double ms = (double)remain * 1000.0 / (double)freq->QuadPart;
    if (ms > 2.0) {
        Sleep((DWORD)(ms - 1.0));
    }
    /* busy-wait the final remainder */
    for (;;) {
        QueryPerformanceCounter(&now);
        if (now.QuadPart >= target_ticks) break;
        Sleep(0);
    }
}

int main(int argc, char** argv) {
    extern int g_pc_system_rtc;
    int         fixed_clock    = 0;
    int         test_shm       = 0;
    int         frames         = 60;   /* frames for --test-shm */
    int         scene_override = -1;
    const char* rom_path       = NULL;
    const char* extract_rom_path = NULL;
    const char* extract_out_dir  = "orig/GAFE01_00";
    const char* log_file_path    = NULL;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--test-shm") == 0) { test_shm = 1; }
        else if (strcmp(argv[i], "--fixed-clock") == 0) { fixed_clock = 1; }
        else if (strcmp(argv[i], "--frames") == 0 && i + 1 < argc) { frames = atoi(argv[++i]); }
        else if (strcmp(argv[i], "--scene") == 0 && i + 1 < argc) { scene_override = atoi(argv[++i]); }
        else if (strcmp(argv[i], "--rom") == 0 && i + 1 < argc) { rom_path = argv[++i]; }
        else if (strcmp(argv[i], "--extract-rom") == 0 && i + 1 < argc) { extract_rom_path = argv[++i]; }
        else if (strcmp(argv[i], "--out-dir") == 0 && i + 1 < argc) { extract_out_dir = argv[++i]; }
        else if (strcmp(argv[i], "--log-file") == 0 && i + 1 < argc) { log_file_path = argv[++i]; }
        else if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("usage: HaniwaHost.exe [--extract-rom ISO_PATH] [--out-dir DIR] [--log-file PATH] [--test-shm] [--fixed-clock] [--frames N] [--scene ID] [--rom PATH]\n");
            return 0;
        }
    }

    if (log_file_path != NULL && log_file_path[0] != '\0') {
        (void)freopen(log_file_path, "w", stdout);
        (void)freopen(log_file_path, "a", stderr);
        setvbuf(stdout, NULL, _IONBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);
    }

    if (extract_rom_path != NULL) {
        extern int pc_disc_extract_all(const char* rom_path, const char* out_dir);
        return pc_disc_extract_all(extract_rom_path, extract_out_dir) ? 0 : 1;
    }

#ifdef _WIN32
    /* Ensure working directory contains orig/GAFE01_00 or matches executable directory */
    {
        FILE* f_check = fopen("orig/GAFE01_00/sys/main.dol", "rb");
        if (f_check) {
            fclose(f_check);
        } else {
            char exe_path[MAX_PATH];
            DWORD len = GetModuleFileNameA(NULL, exe_path, MAX_PATH);
            if (len > 0 && len < MAX_PATH) {
                char* last_slash = strrchr(exe_path, '\\');
                if (!last_slash) last_slash = strrchr(exe_path, '/');
                if (last_slash) {
                    *last_slash = '\0';
                    SetCurrentDirectoryA(exe_path);
                }
            }
        }
    }
#endif

    if (frames < 1) frames = 1;

    SetConsoleCtrlHandler(ctrl_handler, TRUE);
    timeBeginPeriod(1);

    /* --- 1. Create and map the shared memory --- */
    s_hmap = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE,
                                0, ACGC_SHM_TOTAL_SIZE, ACGC_SHM_MAPPING_NAME);
    if (!s_hmap) return fail("CreateFileMappingA failed");
    s_map = MapViewOfFile(s_hmap, FILE_MAP_ALL_ACCESS, 0, 0, ACGC_SHM_TOTAL_SIZE);
    if (!s_map) return fail("MapViewOfFile failed");

    ACGCShmHeader* hdr = ACGC_SHM_HEADER(s_map);
    memset(s_map, 0, ACGC_SHM_TOTAL_SIZE);
    hdr->magic              = ACGC_SHM_MAGIC;
    hdr->version            = ACGC_SHM_VERSION;
    hdr->total_size         = ACGC_SHM_TOTAL_SIZE;
    hdr->header_size        = sizeof(ACGCShmHeader);
    hdr->frame_id           = 0;
    hdr->active_read_slot   = 0;
    hdr->active_write_slot  = 0;
    hdr->producer_alive     = 1;
    hdr->consumer_alive     = 0;
    hdr->exit_requested     = 0;
    hdr->audio_sample_rate  = 32000;
    hdr->audio_channels     = 2;

    ACGCShmAudioRing* audio = ACGC_SHM_AUDIO(s_map);
    audio->buffer_samples   = ACGC_SHM_AUDIO_BUFFER_SIZE / (int)sizeof(int16_t);
    audio->head_sample      = 0;
    audio->tail_sample      = 0;

    acgc_set_shm_audio(s_map);

    /* --- 2. Create named events --- */
    s_ev_frame_ready = CreateEventA(NULL, FALSE, FALSE, ACGC_SHM_EVENT_FRAME_READY);
    s_ev_input_ack   = CreateEventA(NULL, FALSE, FALSE, ACGC_SHM_EVENT_INPUT_ACK);
    if (!s_ev_frame_ready || !s_ev_input_ack) return fail("CreateEventA failed");

    /* --- 3. Boot the game headless --- */
    ACGCConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.headless           = 1;
    cfg.enable_audio       = 0;  /* audio over SHM is wired in a later gate */
    cfg.rom_path           = rom_path;
    cfg.initial_year       = 2002;
    cfg.initial_month      = 9;
    cfg.initial_day        = 15;
    cfg.initial_hour       = 12;
    cfg.initial_min        = 0;
    cfg.initial_sec        = 0;
    cfg.use_fixed_addresses = 0;
    cfg.scene_override     = scene_override;

    g_pc_system_rtc = !fixed_clock;
    printf("[ACGC HOST] RTC source: %s\n", fixed_clock ? "deterministic test clock" : "Windows local system time (saved offset ignored)");

    if (!acgc_init(&cfg)) {
        fprintf(stderr, "[ACGC HOST] acgc_init failed\n");
        cleanup();
        return 1;
    }
    printf("[ACGC HOST] game initialized (scene_override=%d)\n", scene_override);

    /* --- 4. 60 Hz producer loop --- */
    LARGE_INTEGER freq;
    QueryPerformanceFrequency(&freq);
    const double frame_time = 1.0 / 60.0;
    LARGE_INTEGER t0;
    QueryPerformanceCounter(&t0);

    uint64_t produced = 0;
    uint64_t bad_frames = 0;
    size_t   max_payload = 0;

    ACGCShmInputBlock* input = ACGC_SHM_INPUT(s_map);

    while (!s_stop && !hdr->exit_requested) {
        /* Read the latest input/control from Godot. */
        ACGCPadInput pad;
        memset(&pad, 0, sizeof(pad));
        pad.buttons    = input->buttons;
        pad.stick_x    = input->stick_x;
        pad.stick_y    = input->stick_y;
        pad.substick_x = input->substick_x;
        pad.substick_y = input->substick_y;
        pad.trigger_l  = input->trigger_l;
        pad.trigger_r  = input->trigger_r;

        extern void pc_capture_set_efb_ack(uint32_t ack_seq);
        extern uint32_t pc_capture_get_efb_seq(void);
        pc_capture_set_efb_ack(input->efb_ack);

        /* One 60 Hz tick: runs the game and finalizes an ACFP frame packet. */
        acgc_tick(&pad);
        hdr->efb_seq = pc_capture_get_efb_seq();

        /* Publish the game state (RTC/weather/season/scene) for the lighting path. */
        {
            ACGCState gs;
            acgc_get_state(&gs);
            ACGCShmStateBlock* st = ACGC_SHM_STATE(s_map);
            st->hour       = gs.hour;
            st->minute     = gs.minute;
            st->second     = gs.second;
            st->weather    = gs.weather;
            st->season     = gs.season;
            st->scene_no   = gs.scene_no;
            st->scene_mode = gs.scene_mode;
            st->is_running = gs.is_running ? 1 : 0;
        }

        if (acgc_has_frame_packet()) {
            size_t psize = 0;
            const void* pkt = acgc_get_frame_packet(&psize);
            if (pkt && psize > 0 && psize <= ACGC_SHM_FRAME_SLOT_SIZE) {
                uint32_t wslot = hdr->active_write_slot;
                ACGCShmFrameSlot* slot = ACGC_SHM_FRAME(s_map, wslot);
                memcpy(slot->data, pkt, psize);
                slot->payload_size = (uint32_t)psize;
                slot->frame_id     = (uint32_t)hdr->frame_id;
                slot->tick_count   = (uint32_t)hdr->frame_id;

                if (psize > max_payload) max_payload = psize;

                /* Validate the ACFP payload header. */
                uint32_t acfp_magic = (psize >= 4) ? *(const uint32_t*)pkt : 0;
                if (acfp_magic != ACGC_SHM_ACFP_MAGIC) bad_frames++;

                /* Double-buffer handoff: make the fresh slot readable, flip write. */
                InterlockedExchange((volatile LONG*)&hdr->active_read_slot, (LONG)wslot);
                InterlockedExchange((volatile LONG*)&hdr->active_write_slot, (LONG)(1u - wslot));
                InterlockedIncrement64((volatile LONG64*)&hdr->frame_id);

                SetEvent(s_ev_frame_ready);
                produced++;
                if (produced % 600 == 0) {
                    LARGE_INTEGER t_now;
                    QueryPerformanceCounter(&t_now);
                    double t_sec = (double)(t_now.QuadPart - t0.QuadPart) / (double)freq.QuadPart;
                    double expected_sec = (double)produced / 60.0;
                    double drift_ms = (t_sec - expected_sec) * 1000.0;
                    printf("[ACGC HOST PACER] tick=%llu wall_time=%.3f s expected=%.3f s drift=%+.3f ms (rate=%.3f Hz)\n",
                           (unsigned long long)produced, t_sec, expected_sec, drift_ms, (double)produced / t_sec);
                    fflush(stdout);
                }
            }
        }

        if (test_shm && produced >= (uint64_t)frames) break;

        /* Pace to exactly 60.000 Hz with 64-bit integer precision. */
        LONGLONG target = t0.QuadPart + (LONGLONG)((produced * (uint64_t)freq.QuadPart) / 60ULL);
        sleep_until(&freq, target);
    }

    /* --- 5. Report and shut down --- */
    double elapsed = 0.0;
    {
        LARGE_INTEGER t1;
        QueryPerformanceCounter(&t1);
        elapsed = (double)(t1.QuadPart - t0.QuadPart) / (double)freq.QuadPart;
    }
    double rate = (elapsed > 0.0) ? (double)produced / elapsed : 0.0;

    printf("[ACGC HOST] frames=%llu rate=%.1f fps max_payload=%zu bytes bad_frames=%llu\n",
           (unsigned long long)produced, rate, max_payload, (unsigned long long)bad_frames);

    hdr->producer_alive = 0;

    acgc_shutdown();
    cleanup();
    timeEndPeriod(1);

    if (bad_frames != 0) {
        fprintf(stderr, "[ACGC HOST] %llu frame(s) had an invalid ACFP header\n",
                (unsigned long long)bad_frames);
        return 1;
    }
    return 0;
}
