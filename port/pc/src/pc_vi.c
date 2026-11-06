/* pc_vi.c - video interface → SDL window swap + frame pacing */
#include "pc_platform.h"
#include "pc_profiler.h"
#include "pc_capture.h"

#define VI_TVMODE_NTSC_INT    0
#define VI_TVMODE_NTSC_DS     1
#define VI_TVMODE_PAL_INT     4
#define VI_TVMODE_MPAL_INT    8
#define VI_TVMODE_EURGB60_INT 20

static u32 retrace_count = 0;
u32 pc_frame_counter = 0;
static Uint64 frame_start_time = 0;
static Uint64 perf_freq = 0;

// 16667us = 60.0 Hz (NTSC).
u32 g_frame_limiter = 60; // 60Hz
int g_pc_screenshot_frame = -1;
const char* g_pc_screenshot_path = NULL;
int g_pc_quit_after_frame = -1;
static void (*vi_pre_callback)(u32) = NULL;
static void (*vi_post_callback)(u32) = NULL;

void pc_take_screenshot(const char* filename) {
    int w = g_pc_window_w;
    int h = g_pc_window_h;
    if (w <= 0 || h <= 0) return;
    uint8_t* pixels = (uint8_t*)malloc(w * h * 4);
    if (!pixels) return;

    extern void pc_gx_draw_pending(void);
    pc_gx_draw_pending();
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_BGRA, GL_UNSIGNED_BYTE, pixels);

    uint8_t header[54] = {
        'B', 'M',
        0, 0, 0, 0,
        0, 0, 0, 0,
        54, 0, 0, 0,
        40, 0, 0, 0,
        (uint8_t)(w), (uint8_t)(w >> 8), (uint8_t)(w >> 16), (uint8_t)(w >> 24),
        (uint8_t)(h), (uint8_t)(h >> 8), (uint8_t)(h >> 16), (uint8_t)(h >> 24),
        1, 0,
        32, 0,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    };
    uint32_t file_size = 54 + w * h * 4;
    header[2] = (uint8_t)(file_size);
    header[3] = (uint8_t)(file_size >> 8);
    header[4] = (uint8_t)(file_size >> 16);
    header[5] = (uint8_t)(file_size >> 24);

    FILE* f = fopen(filename, "wb");
    if (f) {
        fwrite(header, 1, 54, f);
        fwrite(pixels, 1, w * h * 4, f);
        fclose(f);
        printf("[Screenshot] Saved %s (%dx%d)\n", filename, w, h);
    } else {
        printf("[Screenshot] Failed to open %s for writing\n", filename);
    }
    free(pixels);
}

void VIInit(void) {
    if (g_frame_limiter > 0) {
        printf("[VI] frame limit=%luus (%lu Hz)\n",
               (u32)((1.0 / (double)g_frame_limiter) * 1000000), (unsigned long)g_frame_limiter);
    } else {
        printf("[VI] frame limit=disabled\n");
    }
}

void VIConfigure(void* rm) { (void)rm; }

void VISetNextFrameBuffer(void* fb) { (void)fb; }

void VIFlush(void) {}

void VIWaitForRetrace(void) {
    if (g_pc_headless || g_pc_as_library) {
        retrace_count++;
        pc_frame_counter++;

        if (pc_capture_is_recording()) {
            extern void pc_gx_draw_pending(void);
            pc_gx_draw_pending();
            pc_capture_end_frame();
        }

        if (g_pc_capture_enabled) {
            pc_capture_begin_frame(pc_frame_counter, 0, g_pc_window_w > 0 ? g_pc_window_w : 640, g_pc_window_h > 0 ? g_pc_window_h : 480);
        }

        if (g_pc_quit_after_frame > 0 && (int)pc_frame_counter >= g_pc_quit_after_frame) {
            printf("[VI Headless] Reached tick %u (target %d), stopping.\n",
                   (unsigned int)pc_frame_counter, g_pc_quit_after_frame);
            g_pc_running = 0;
        }
        return;
    }

    if (!perf_freq) perf_freq = SDL_GetPerformanceFrequency();

    /* --- frame time diagnostic --- */
    Uint64 vi_enter = SDL_GetPerformanceCounter();
    double frame_ms = 0.0;
    if (frame_start_time) {
        frame_ms = (double)(vi_enter - frame_start_time) * 1000.0 / (double)perf_freq;
    }

    Uint64 t_before_poll = pc_profiler_begin_timer();
    if (!pc_platform_poll_events()) {
        g_pc_running = 0;
        return;
    }
    pc_profiler_add_time(PC_PROF_TIMER_POLL_EVENTS, t_before_poll);

    /* Drain the frame's last deferred batch here so its cost bills to
     * gx_flush instead of inflating the swap timer. */
    {
        extern void pc_gx_draw_pending(void);
        Uint64 t_drain = pc_profiler_begin_timer();
        pc_gx_draw_pending();
        pc_profiler_add_time(PC_PROF_TIMER_GX_FLUSH, t_drain);
    }

    if (pc_capture_is_recording()) {
        pc_capture_end_frame();
    }

    if (pc_capture_should_save_frame(pc_frame_counter)) {
        char acfp_path[256];
        char bmp_path[256];
        if (g_pc_capture_path && g_pc_capture_frame > 0) {
            snprintf(acfp_path, sizeof(acfp_path), "%s.acfp", g_pc_capture_path);
            snprintf(bmp_path, sizeof(bmp_path), "%s_gl.bmp", g_pc_capture_path);
        } else {
            snprintf(acfp_path, sizeof(acfp_path), "captures/frame_%u.acfp", (unsigned int)pc_frame_counter);
            snprintf(bmp_path, sizeof(bmp_path), "captures/frame_%u_gl.bmp", (unsigned int)pc_frame_counter);
        }
        pc_capture_save_packet(acfp_path);
        pc_take_screenshot(bmp_path);
        g_pc_capture_hotkey_pressed = 0;
    }

    Uint64 t_before_swap = SDL_GetPerformanceCounter();
    Uint64 t_before_swap_prof = pc_profiler_begin_timer();
    pc_platform_swap_buffers();
    pc_profiler_add_time(PC_PROF_TIMER_SWAP, t_before_swap_prof);
    Uint64 t_after_swap = SDL_GetPerformanceCounter();

    if (g_pc_screenshot_frame > 0 && (int)pc_frame_counter == g_pc_screenshot_frame) {
        pc_take_screenshot(g_pc_screenshot_path ? g_pc_screenshot_path : "screenshot.bmp");
    }
    if (g_pc_quit_after_frame > 0 && (int)pc_frame_counter >= g_pc_quit_after_frame) {
        printf("[PC] Reached frame %d, quitting as requested.\n", g_pc_quit_after_frame);
        exit(0);
    }

    Uint64 t_before_pace = SDL_GetPerformanceCounter();
    Uint64 t_before_pace_prof = pc_profiler_begin_timer();
    {
        extern int g_pc_nes_active;
        int pace_frame = g_pc_nes_active || g_frame_limiter > 0;
        int pace_us = 0;

        if (g_pc_nes_active) {
            pace_us = 16667;
        } else if (g_frame_limiter > 0) {
            pace_us = (int)((1.0 / (double)g_frame_limiter) * 1000000);
        }

        if (pace_frame) {
            /* Timer-based pacing: sleep until 16ms per frame (~60 FPS).
             * Audio production runs on a dedicated thread and is no longer
             * tied to game frame timing. */
            if (frame_start_time) {
                Uint64 now = SDL_GetPerformanceCounter();
                Uint64 elapsed_us = (now - frame_start_time) * 1000000 / perf_freq;
                /* Spin for sub-ms precision. */
                while (elapsed_us < (Uint64)pace_us) {
                    Uint64 remain_us = (Uint64)pace_us - elapsed_us;
                    if (remain_us > 2000) {
                        SDL_Delay(1);
                    }
                    now = SDL_GetPerformanceCounter();
                    elapsed_us = (now - frame_start_time) * 1000000 / perf_freq;
                }
            }
        }
    }
    pc_profiler_add_time(PC_PROF_TIMER_PACE, t_before_pace_prof);
    Uint64 t_after_pace = SDL_GetPerformanceCounter();
    double profile_frame_ms = frame_ms;
    if (frame_start_time) {
        profile_frame_ms = (double)(t_after_pace - frame_start_time) * 1000.0 / (double)perf_freq;
    }

    /* report slow frames (>20ms = missed 60fps by >4ms) */
    if (frame_ms > 20.0 && g_pc_verbose) {
        double swap_ms = (double)(t_after_swap - t_before_swap) * 1000.0 / (double)perf_freq;
        double pace_ms = (double)(t_after_pace - t_before_pace) * 1000.0 / (double)perf_freq;
        double work_ms = (double)(vi_enter - frame_start_time) * 1000.0 / (double)perf_freq;
        int audio_fill = pc_audio_get_buffer_fill();
        printf("[STUTTER] frame %lu: total=%.1fms work=%.1fms swap=%.1fms pace=%.1fms audio_fill=%d\n",
               (unsigned long)pc_frame_counter, frame_ms, work_ms - swap_ms - pace_ms, swap_ms, pace_ms, audio_fill);
    }

    pc_profiler_end_frame(profile_frame_ms, pc_audio_get_buffer_fill());

    {
        static Uint64 fps_start = 0;
        static int fps_count = 0;
        if (fps_start == 0) fps_start = SDL_GetPerformanceCounter();
        fps_count++;
        if (fps_count >= 60) {
            Uint64 now = SDL_GetPerformanceCounter();
            double secs = (double)(now - fps_start) / (double)perf_freq;
            double fps = (double)fps_count / secs;
            char title[64];
            snprintf(title, sizeof(title), "Animal Crossing - %.1f FPS", fps);
            SDL_SetWindowTitle(g_pc_window, title);
            fps_start = now;
            fps_count = 0;
        }
    }

    frame_start_time = SDL_GetPerformanceCounter();

    retrace_count++;
    pc_frame_counter++;
    pc_capture_begin_frame(pc_frame_counter, 0, g_pc_window_w, g_pc_window_h);
}

u32 VIGetRetraceCount(void) { return retrace_count; }

void VISetBlack(BOOL black) { (void)black; }

u32 VIGetTvFormat(void) { return 0; /* VI_NTSC */ }
u32 VIGetDTVStatus(void) { return 0; }

void* VISetPreRetraceCallback(void* cb) {
    void* old = (void*)vi_pre_callback;
    vi_pre_callback = (void (*)(u32))cb;
    return old;
}

void* VISetPostRetraceCallback(void* cb) {
    void* old = (void*)vi_post_callback;
    vi_post_callback = (void (*)(u32))cb;
    return old;
}

u32 VIGetCurrentLine(void) { return 0; }

void VISetNextXFB(void* xfb) { (void)xfb; }
