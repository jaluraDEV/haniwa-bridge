/* pc_audio.c - SDL2 audio backend with dedicated producer thread.
 *
 * Architecture (matches GC):
 *   Game thread:  Na_GameFrame() queues commands via message queues
 *   Audio thread: pc_audio_process_frame() produces samples into ring buffer
 *   SDL callback: reads ring buffer → speakers
 *
 * The audio thread decouples sample production from the game frame,
 * so OS preemption of the game thread doesn't cause audio dropouts.
 */
#include "pc_platform.h"
#include "pc_settings.h"
#include "jaudio_NES/audiothread.h"
#include "acgc_shm.h"

#ifdef _WIN32
#include <windows.h>
#endif

#define PC_AUDIO_SAMPLE_RATE 32000

/* SHM audio output (Plan B / Godot IPC) */
static ACGCShmAudioRing* s_shm_audio_ring = NULL;
static int16_t*          s_shm_audio_samples = NULL;
static int               s_sdl_audio_enabled = 1;

void pc_audio_set_shm_ring(void* ring, void* samples) {
    s_shm_audio_ring = (ACGCShmAudioRing*)ring;
    s_shm_audio_samples = (int16_t*)samples;
}

void pc_audio_set_sdl_enabled(int enabled) {
    s_sdl_audio_enabled = enabled;
}

/* lock-free SPSC ring buffer (producer=audio thread, consumer=SDL callback) */
#define RING_BUF_SAMPLES (65536) /* ~1024ms at 32kHz stereo */
#define RING_BUF_MASK    (RING_BUF_SAMPLES - 1)

/* Produce more samples when buffer drops below this level.
 * Keep the producer target at least as high as the startup prefill. */
#define AUDIO_PRODUCE_THRESHOLD 7040
#define AUDIO_PREFILL_SAMPLES    7040 /* ~16 frames = ~280ms cushion */

static s16 ring_buffer[RING_BUF_SAMPLES];
static SDL_atomic_t ring_write_pos; /* written by audio producer thread */
static SDL_atomic_t ring_read_pos;  /* written by SDL audio callback */
static SDL_atomic_t audio_prefill_done;
static SDL_atomic_t audio_dma_started;
static SDL_atomic_t audio_underrun_count;
static SDL_atomic_t audio_dropped_samples;
static SDL_AudioDeviceID audio_device = 0;

typedef void (*AIDMACallback)(void);
static AIDMACallback ai_dma_callback = NULL;
static u32 ai_dsp_sample_rate = PC_AUDIO_SAMPLE_RATE;

/* --- Audio producer thread --- */
static SDL_Thread* audio_producer_thread = NULL;
static SDL_atomic_t audio_thread_running;

static int pc_audio_producer_func(void* data) {
    (void)data;
    while (SDL_AtomicGet(&audio_thread_running)) {
        int fill = pc_audio_get_buffer_fill();
        if (fill < AUDIO_PRODUCE_THRESHOLD) {
            pc_audio_process_frame();
        } else {
            SDL_Delay(1);
        }
    }
    return 0;
}

void pc_audio_start_producer_thread(void) {
    if (audio_producer_thread) return;
    SDL_AtomicSet(&audio_thread_running, 1);
    audio_producer_thread = SDL_CreateThread(pc_audio_producer_func, "AudioProducer", NULL);
    if (audio_producer_thread) {
        printf("[AUDIO] Producer thread started\n");
    } else {
        printf("[AUDIO] Failed to create producer thread: %s\n", SDL_GetError());
    }
}

/* Library mode: run on the game worker, never concurrently with game state. */
void pc_audio_service_tick(void) {
    if (s_shm_audio_ring && s_shm_audio_samples) {
        uint32_t cap = s_shm_audio_ring->buffer_samples;
        if (cap > 0) {
            int catchup = 0;
            while (catchup < 4) {
#ifdef _WIN32
                uint32_t h = (uint32_t)InterlockedCompareExchange((volatile LONG*)&s_shm_audio_ring->head_sample, 0, 0);
                uint32_t t = (uint32_t)InterlockedCompareExchange((volatile LONG*)&s_shm_audio_ring->tail_sample, 0, 0);
#else
                uint32_t h = s_shm_audio_ring->head_sample;
                uint32_t t = s_shm_audio_ring->tail_sample;
#endif
                uint32_t cushion = (h >= t) ? (h - t) : (cap - t + h);
                /* TARGET_CUSHION_SAMPLES: 3200 stereo frames = 6400 interleaved samples (~100 ms) */
                if (cushion >= 6400) {
                    break;
                }
                uint32_t before_h = h;
                pc_audio_process_frame();
#ifdef _WIN32
                uint32_t after_h = (uint32_t)InterlockedCompareExchange((volatile LONG*)&s_shm_audio_ring->head_sample, 0, 0);
#else
                uint32_t after_h = s_shm_audio_ring->head_sample;
#endif
                if (after_h == before_h) {
                    break; /* No samples produced */
                }
                catchup++;
            }
        }
        return;
    }

    if (!pc_audio_is_active()) {
        /* Offline deterministic ticking has no device clock. */
        pc_audio_process_frame();
    } else {
        /* A DAC block is 560 stereo frames (17.5 ms), not 1/60 s.
         * Produce only what the device consumed, including catch-up.
         * Unconditionally producing once per tick eventually overflows
         * the ring and drops PCM even while underruns remain zero. */
        int catchup = 0;
        while (pc_audio_get_buffer_fill() < AUDIO_PRODUCE_THRESHOLD && catchup < 4) {
            int before = pc_audio_get_buffer_fill();
            pc_audio_process_frame();
            if (pc_audio_get_buffer_fill() <= before) break;
            catchup++;
        }
    }
}

/* --- SDL audio callback (runs on SDL's audio device thread) --- */
static void pc_audio_callback(void* userdata, Uint8* stream, int len) {
    (void)userdata;
    s16* out = (s16*)stream;
    int total_samples = len / sizeof(s16);

    if (!SDL_AtomicGet(&audio_prefill_done)) {
        memset(stream, 0, len);
        return;
    }

    u32 wp = (u32)SDL_AtomicGet(&ring_write_pos);
    SDL_MemoryBarrierAcquire();
    u32 rp = (u32)SDL_AtomicGet(&ring_read_pos);
    u32 used = wp - rp;

    /* overrun: producer lapped us */
    if (used > RING_BUF_SAMPLES) {
        rp = wp - RING_BUF_SAMPLES;
        rp &= ~1u; /* stereo-align */
        used = wp - rp;
    }

    int avail = (int)used;
    avail &= ~1; /* whole stereo frames only */
    int copy = (avail < total_samples) ? avail : total_samples;
    copy &= ~1;

    for (int i = 0; i < copy; i++) {
        out[i] = ring_buffer[(rp + i) & RING_BUF_MASK];
    }
    if (copy < total_samples) {
        memset(&out[copy], 0, (total_samples - copy) * sizeof(s16));
        SDL_AtomicAdd(&audio_underrun_count, 1);
    }

    SDL_MemoryBarrierRelease();
    SDL_AtomicSet(&ring_read_pos, (int)(rp + copy));
}

/* --- AI (Audio Interface) --- */

void AIInit(u8* stack) {
    (void)stack;
    if (audio_device != 0) return;

    if (!s_sdl_audio_enabled || s_shm_audio_ring != NULL || g_pc_headless) {
        printf("[AUDIO] SDL audio device disabled (shm=%d, sdl_enabled=%d, headless=%d)\n",
               s_shm_audio_ring != NULL, s_sdl_audio_enabled, g_pc_headless);
        return;
    }

    SDL_AtomicSet(&ring_write_pos, 0);
    SDL_AtomicSet(&ring_read_pos, 0);
    SDL_AtomicSet(&audio_prefill_done, 0);
    SDL_AtomicSet(&audio_underrun_count, 0);
    SDL_AtomicSet(&audio_dropped_samples, 0);
    SDL_AudioSpec want, have;
    memset(&want, 0, sizeof(want));
    want.freq = PC_AUDIO_SAMPLE_RATE;
    want.format = AUDIO_S16SYS;
    want.channels = 2;
    want.samples = 1024;
    want.callback = pc_audio_callback;

    audio_device = SDL_OpenAudioDevice(NULL, 0, &want, &have, 0);
    if (audio_device != 0) {
        printf("[AUDIO] Opened: freq=%d fmt=0x%04X ch=%d samples=%d (requested: freq=%d)\n",
               have.freq, have.format, have.channels, have.samples, want.freq);
    } else {
        printf("[AUDIO] Failed to open: %s\n", SDL_GetError());
    }
}

void AIInitDMA(u32 addr, u32 size) {
    s16* src = (s16*)(uintptr_t)addr;
    u32 n_samples = size / sizeof(s16);
    n_samples &= ~1u; /* whole stereo frames */

    int vol = g_pc_settings.master_volume;
    if (vol < 0)   vol = 0;
    if (vol > 100) vol = 100;

    /* Write directly to Windows Shared Memory if active */
    if (s_shm_audio_ring && s_shm_audio_samples) {
        uint32_t cap = s_shm_audio_ring->buffer_samples;
        if (cap > 0) {
#ifdef _WIN32
            uint32_t head = (uint32_t)InterlockedCompareExchange((volatile LONG*)&s_shm_audio_ring->head_sample, 0, 0);
#else
            uint32_t head = s_shm_audio_ring->head_sample;
#endif
            for (u32 i = 0; i < n_samples; i++) {
                int s = ((int)src[i] * vol) / 100;
                if (s >  32767) s =  32767;
                if (s < -32768) s = -32768;
                s_shm_audio_samples[(head + i) % cap] = (s16)s;
            }
#ifdef _WIN32
            MemoryBarrier();
            InterlockedExchange((volatile LONG*)&s_shm_audio_ring->head_sample, (LONG)((head + n_samples) % cap));
#else
            SDL_MemoryBarrierRelease();
            s_shm_audio_ring->head_sample = (head + n_samples) % cap;
#endif
        }
        return;
    }

    u32 wp = (u32)SDL_AtomicGet(&ring_write_pos);
    u32 rp = (u32)SDL_AtomicGet(&ring_read_pos);
    SDL_MemoryBarrierAcquire();
    u32 used = wp - rp;
    u32 free = used < RING_BUF_SAMPLES ? RING_BUF_SAMPLES - used : 0;

    if (n_samples > free) {
        SDL_AtomicAdd(&audio_dropped_samples, (int)(n_samples - (free & ~1u)));
        n_samples = free & ~1u;
    }

    for (u32 i = 0; i < n_samples; i++) {
        int s = ((int)src[i] * vol) / 100;
        if (s >  32767) s =  32767;
        if (s < -32768) s = -32768;
        ring_buffer[(wp + i) & RING_BUF_MASK] = (s16)s;
    }

    SDL_MemoryBarrierRelease();
    SDL_AtomicSet(&ring_write_pos, (int)(wp + n_samples));

    /* Check if pre-fill threshold reached */
    if (SDL_AtomicGet(&audio_dma_started) && !SDL_AtomicGet(&audio_prefill_done)) {
        u32 new_used = (wp + n_samples) - rp;
        if (new_used >= AUDIO_PREFILL_SAMPLES) {
            SDL_AtomicSet(&audio_prefill_done, 1);
            SDL_AtomicSet(&audio_underrun_count, 0);
            if (audio_device != 0) {
                SDL_PauseAudioDevice(audio_device, 0);
            }
            printf("[AUDIO] Pre-fill reached %u samples (~%.1f ms). Audio playback unpaused.\n",
                   (unsigned int)new_used, (float)new_used / (PC_AUDIO_SAMPLE_RATE * 2) * 1000.0f);
        }
    }
}

void AIStartDMA(void) {
    SDL_AtomicSet(&audio_dma_started, 1);
    /* Unpause immediately only if pre-fill buffer is already satisfied */
    u32 wp = (u32)SDL_AtomicGet(&ring_write_pos);
    u32 rp = (u32)SDL_AtomicGet(&ring_read_pos);
    if ((wp - rp) >= AUDIO_PREFILL_SAMPLES) {
        SDL_AtomicSet(&audio_prefill_done, 1);
        SDL_AtomicSet(&audio_underrun_count, 0);
        if (audio_device != 0) SDL_PauseAudioDevice(audio_device, 0);
    }
}

void AIStopDMA(void) {
    SDL_AtomicSet(&audio_dma_started, 0);
    if (audio_device != 0) SDL_PauseAudioDevice(audio_device, 1);
}

void pc_audio_set_paused(int paused) {
    /* Currently unused */
    if (audio_device != 0) SDL_PauseAudioDevice(audio_device, paused ? 1 : 0);
}

u32  AIGetDMAStartAddr(void) { return 0; }
u16  AIGetDMALength(void) { return 0; }
u32  AIGetStreamTrigger(void) { return 0; }
u32  AIGetStreamSampleCount(void) { return 0; }
void AISetStreamPlayState(u32 state) { (void)state; }
u32  AIGetStreamPlayState(void) { return 0; }
void AISetStreamSampleRate(u32 rate) { (void)rate; }
u32  AIGetStreamSampleRate(void) { return PC_AUDIO_SAMPLE_RATE; }
void AISetStreamVolLeft(u8 vol) { (void)vol; }
void AISetStreamVolRight(u8 vol) { (void)vol; }
u8   AIGetStreamVolLeft(void) { return 0; }
u8   AIGetStreamVolRight(void) { return 0; }
void AIResetStreamSampleCount(void) {}
void AISetDSPSampleRate(u32 rate) { ai_dsp_sample_rate = rate; }
u32  AIGetDSPSampleRate(void) { return ai_dsp_sample_rate; }

void* AIRegisterDMACallback(void* callback) {
    void* old = (void*)ai_dma_callback;
    ai_dma_callback = (AIDMACallback)callback;
    return old;
}

/* --- DSP stubs (rspsim does everything in software) --- */

void DSPInit(void) {}
BOOL DSPCheckMailToDSP(void) { return FALSE; }
BOOL DSPCheckMailFromDSP(void) { return FALSE; }
u32  DSPReadMailFromDSP(void) { return 0; }
void DSPSendMailToDSP(u32 mail) { (void)mail; }
void DSPAssertInt(void) {}
void* DSPAddTask(void* task) { return task; }

/* --- ring buffer queries for frame pacing (pc_vi.c) --- */

int pc_audio_get_buffer_fill(void) {
    return (int)((u32)SDL_AtomicGet(&ring_write_pos) - (u32)SDL_AtomicGet(&ring_read_pos));
}

int pc_audio_get_underruns(void) {
    return SDL_AtomicGet(&audio_underrun_count);
}

int pc_audio_get_dropped_samples(void) {
    return SDL_AtomicGet(&audio_dropped_samples);
}

void pc_audio_reset_underruns(void) {
    SDL_AtomicSet(&audio_underrun_count, 0);
}

int pc_audio_is_active(void) {
    return (audio_device != 0) || (s_shm_audio_ring != NULL);
}

void pc_audio_shutdown(void) {
    /* Stop producer thread first */
    SDL_AtomicSet(&audio_thread_running, 0);
    SDL_AtomicSet(&audio_dma_started, 0);
    SDL_AtomicSet(&audio_prefill_done, 0);
    if (audio_producer_thread) {
        SDL_WaitThread(audio_producer_thread, NULL);
        audio_producer_thread = NULL;
    }
    if (audio_device != 0) {
        SDL_CloseAudioDevice(audio_device);
        audio_device = 0;
    }
    s_shm_audio_ring = NULL;
    s_shm_audio_samples = NULL;
}
