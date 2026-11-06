#include "acgc_api.h"
#include "acgc_shm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#endif

/* Symbols in port */
extern int g_pc_running;
extern int g_pc_headless;
extern int g_pc_as_library;
extern int g_pc_verbose;
extern unsigned int pc_image_base;
extern unsigned int pc_image_end;
extern uint32_t g_frame_limiter;
extern uint32_t pc_frame_counter;

/* Audio routing in port */
extern void pc_audio_set_shm_ring(void* ring, void* samples);
extern void pc_audio_set_sdl_enabled(int enabled);

/* Subsystem inits in port */
extern void SDL_SetMainReady(void);
extern void pc_settings_load(void);
extern void pc_keybindings_load(void);
extern void pc_platform_init(void);
extern void pc_platform_shutdown(void);
extern int  pc_disc_init(void);
extern void pc_disc_shutdown(void);
extern int  pc_assets_init(void);
extern void ac_entry(void);
extern int  boot_main(int argc, const char* argv[]);
extern void boot_cleanup(void);

/* Graph step functions */
extern void graph_proc_init(void);
extern int  graph_proc_step(void);
extern void graph_proc_cleanup(void);

/* Pad external input functions */
extern void pc_pad_set_external_input(uint16_t buttons, int8_t stick_x, int8_t stick_y,
                                      int8_t substick_x, int8_t substick_y,
                                      uint8_t trigger_l, uint8_t trigger_r);
extern void pc_pad_clear_external_input(void);
extern void pc_get_game_state(uint16_t* year, uint8_t* month, uint8_t* day,
                              uint8_t* hour, uint8_t* min, uint8_t* sec,
                              uint8_t* season, uint8_t* weather, int32_t* now_sec);
extern void pc_time_set_initial(uint16_t year, uint8_t month, uint8_t day,
                                uint8_t hour, uint8_t min, uint8_t sec);
extern uint64_t pc_get_arena_hash(void);
extern int      g_pc_use_fixed_addresses;
extern int      pc_get_scene_no(void);
extern int      pc_get_scene_mode(void);
extern int      pc_get_actor_count(void);
extern int      pc_is_game_running(void);
extern uint32_t qrand_get_seed(void);
extern void     pc_poke_arena_byte(size_t offset, uint8_t val);
extern uint8_t  pc_peek_arena_byte(size_t offset);
extern void     pc_poke_actor_byte(size_t offset, uint8_t val);
extern uint8_t  pc_peek_actor_byte(size_t offset);
extern void     pc_poke_rng_seed(uint32_t seed);
extern int      pc_dump_state_breakdown(const char* dir_prefix, int run_id);
extern int      g_pc_capture_enabled;
extern int      g_pc_scene_override;
extern void     pc_capture_init(void);
extern void     pc_capture_shutdown(void);
extern void     pc_capture_begin_frame(uint32_t frame_index, uint32_t tick_count, int width, int height);
extern const void* pc_capture_get_packet_data(size_t* out_size);
extern int      pc_capture_has_packet(void);

static int s_initialized = 0;

int acgc_init(const ACGCConfig* config) {
    if (s_initialized) {
        return 1;
    }

    g_pc_as_library = 1;
    g_pc_headless = (config != NULL) ? config->headless : 1;
    g_pc_running = 1;
    g_frame_limiter = 0; /* Frame pacing handled by Godot */
    g_pc_verbose = 1;
    g_pc_use_fixed_addresses = (config != NULL) ? config->use_fixed_addresses : 0;
    if (config && !config->enable_audio) {
        pc_audio_set_sdl_enabled(0);
    }
    if (config && config->scene_override >= 0) {
        g_pc_scene_override = config->scene_override;
    }

    /* Enable render-capture backend for Godot frame packets */
    g_pc_capture_enabled = 1;
    pc_capture_init();
    pc_capture_begin_frame(0, 0, 640, 480);

#ifdef _WIN32
    {
        HMODULE exe = NULL;
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)&g_pc_headless, &exe);
        if (!exe) exe = GetModuleHandle(NULL);
        IMAGE_DOS_HEADER* dos = (IMAGE_DOS_HEADER*)exe;
        IMAGE_NT_HEADERS* nt = (IMAGE_NT_HEADERS*)((char*)exe + dos->e_lfanew);
        pc_image_base = (unsigned int)(uintptr_t)exe;
        pc_image_end = pc_image_base + nt->OptionalHeader.SizeOfImage;
        fprintf(stderr, "[ACGC API] pc_image_base = 0x%08x, pc_image_end = 0x%08x\n", pc_image_base, pc_image_end);
    }
#endif

    if (config && config->rom_path && config->rom_path[0]) {
#ifdef _WIN32
        SetEnvironmentVariableA("ACGC_ROM_PATH", config->rom_path);
#else
        setenv("ACGC_ROM_PATH", config->rom_path, 1);
#endif
    }

    SDL_SetMainReady();
    pc_settings_load();
    pc_keybindings_load();
    pc_platform_init();

    if (config) {
        pc_time_set_initial(config->initial_year, config->initial_month, config->initial_day,
                            config->initial_hour, config->initial_min, config->initial_sec);
    } else {
        pc_time_set_initial(2002, 9, 15, 12, 0, 0);
    }

    if (!pc_disc_init()) {
        fprintf(stderr, "[ACGC API] No disc image mounted; using extracted data in orig/GAFE01_00/...\n");
    }
    if (!pc_assets_init()) {
        fprintf(stderr, "[ACGC API] pc_assets_init failed! Neither ISO nor extracted data in orig/GAFE01_00/ found.\n");
        return 0;
    }

    ac_entry();
    const char* argv[] = { "acgc_bridge", NULL };
    boot_main(1, argv);

    s_initialized = 1;
    fprintf(stderr, "[ACGC API] acgc_init completed successfully!\n");
    return 1;
}

int acgc_tick(const ACGCPadInput* input) {
    if (!s_initialized || !g_pc_running) {
        return 0;
    }

    if (input) {
        pc_pad_set_external_input(input->buttons, input->stick_x, input->stick_y,
                                  input->substick_x, input->substick_y,
                                  input->trigger_l, input->trigger_r);
    } else {
        pc_pad_clear_external_input();
    }

    int active = graph_proc_step();
    return active;
}

void acgc_get_state(ACGCState* out_state) {
    if (!out_state) return;
    memset(out_state, 0, sizeof(ACGCState));
    out_state->frame_count = pc_frame_counter;
    out_state->is_running = (s_initialized && g_pc_running);

    if (s_initialized) {
        pc_get_game_state(&out_state->year, &out_state->month, &out_state->day,
                          &out_state->hour, &out_state->minute, &out_state->second,
                          &out_state->season, &out_state->weather, &out_state->now_sec);
        out_state->scene_no = pc_get_scene_no();
        out_state->scene_mode = pc_get_scene_mode();
        out_state->rng_seed = qrand_get_seed();
        out_state->actor_count = pc_get_actor_count();
    }
}

uint64_t acgc_get_arena_hash(void) {
    return pc_get_arena_hash();
}

int acgc_dump_arena(const char* filepath) {
    extern uint8_t* pc_get_arena_memory(void);
    uint8_t* mem = pc_get_arena_memory();
    if (!mem || !filepath) return 0;
    FILE* f = fopen(filepath, "wb");
    if (!f) return 0;
    size_t count = 24 * 1024 * 1024 - 0x1000;
    size_t written = fwrite(mem, 1, count, f);
    fclose(f);
    return (written == count);
}

int acgc_get_scene_no(void) {
    return s_initialized ? pc_get_scene_no() : 0;
}

int acgc_get_scene_mode(void) {
    return s_initialized ? pc_get_scene_mode() : 0;
}

uint32_t acgc_get_rng_seed(void) {
    return qrand_get_seed();
}

int acgc_get_actor_count(void) {
    return s_initialized ? pc_get_actor_count() : 0;
}

int acgc_is_game_running(void) {
    return s_initialized && pc_is_game_running();
}

void acgc_poke_arena_byte(uint32_t offset, uint8_t val) {
    pc_poke_arena_byte(offset, val);
}

uint8_t acgc_peek_arena_byte(uint32_t offset) {
    return pc_peek_arena_byte(offset);
}

void acgc_poke_actor_byte(uint32_t offset, uint8_t val) {
    pc_poke_actor_byte(offset, val);
}

uint8_t acgc_peek_actor_byte(uint32_t offset) {
    return pc_peek_actor_byte(offset);
}

void acgc_poke_rng_seed(uint32_t seed) {
    pc_poke_rng_seed(seed);
}

int acgc_dump_state_breakdown(const char* dir_prefix, int run_id) {
    return pc_dump_state_breakdown(dir_prefix, run_id);
}

const void* acgc_get_frame_packet(size_t* out_size) {
    return pc_capture_get_packet_data(out_size);
}

int acgc_has_frame_packet(void) {
    return pc_capture_has_packet();
}

void acgc_set_scene(int scene_id) {
    g_pc_scene_override = scene_id;
}

extern void pc_trigger_scene_change(int scene_id);

void acgc_change_scene(int scene_id) {
    pc_trigger_scene_change(scene_id);
}

void acgc_set_shm_audio(void* shm_base) {
    if (shm_base) {
        pc_audio_set_shm_ring(ACGC_SHM_AUDIO(shm_base), ACGC_SHM_AUDIO_SAMPLES(shm_base));
        pc_audio_set_sdl_enabled(0);
    } else {
        pc_audio_set_shm_ring(NULL, NULL);
    }
}

void acgc_shutdown(void) {
    if (!s_initialized) return;

    pc_capture_shutdown();
    graph_proc_cleanup();
    pc_disc_shutdown();
    pc_platform_shutdown();

    s_initialized = 0;
    g_pc_running = 0;
    fprintf(stderr, "[ACGC API] acgc_shutdown completed.\n");
}
