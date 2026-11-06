#ifndef ACGC_API_H
#define ACGC_API_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const char* rom_path;       /* Optional custom path to animal_crossing.iso */
    const char* save_dir;       /* Optional path for save data (default: "save") */
    int headless;               /* 1 = headless / no OpenGL */
    int enable_audio;           /* 1 = enable SDL audio output (default: 1) */
    /* Injectable deterministic RTC starting time */
    uint16_t initial_year;      /* 0 = default (2002) */
    uint8_t  initial_month;     /* 1-12 */
    uint8_t  initial_day;       /* 1-31 */
    uint8_t  initial_hour;      /* 0-23 */
    uint8_t  initial_min;       /* 0-59 */
    uint8_t  initial_sec;       /* 0-59 */
    int      use_fixed_addresses; /* 1 = try fixed 0x30000000 base, 0 = dynamic base */
    int      scene_override;      /* -1 = default (title demo), >=0 = force scene */
} ACGCConfig;

typedef struct {
    uint16_t buttons;           /* GameCube button mask (ACGC_PAD_BUTTON_*) */
    int8_t   stick_x;           /* Main analog stick X (-80 .. +80) */
    int8_t   stick_y;           /* Main analog stick Y (-80 .. +80) */
    int8_t   substick_x;        /* C-stick X (-80 .. +80) */
    int8_t   substick_y;        /* C-stick Y (-80 .. +80) */
    uint8_t  trigger_l;         /* Left trigger analog (0 .. 255) */
    uint8_t  trigger_r;         /* Right trigger analog (0 .. 255) */
} ACGCPadInput;

typedef struct {
    uint32_t frame_count;       /* Total elapsed frames */
    uint16_t year;
    uint8_t  month;
    uint8_t  day;
    uint8_t  hour;
    uint8_t  minute;
    uint8_t  second;
    uint8_t  season;            /* 0=Spring, 1=Summer, 2=Autumn, 3=Winter */
    uint8_t  weather;           /* 0=Fine, 1=Rain, 2=Snow */
    int32_t  now_sec;           /* Seconds elapsed in current day (0..86399) */
    int32_t  is_running;        /* 1 if game is running, 0 if ended */
    int32_t  scene_no;          /* Current scene ID (SCENE_*) */
    int32_t  scene_mode;        /* Audio / game scene mode (SCENE_MODE_*) */
    uint32_t rng_seed;          /* Current qrand RNG seed */
    int32_t  actor_count;       /* Number of active actors in scene */
} ACGCState;

/* Standard GameCube button bitmasks for ACGCPadInput.buttons */
#define ACGC_PAD_BUTTON_LEFT        0x0001
#define ACGC_PAD_BUTTON_RIGHT       0x0002
#define ACGC_PAD_BUTTON_DOWN        0x0004
#define ACGC_PAD_BUTTON_UP          0x0008
#define ACGC_PAD_TRIGGER_Z          0x0010
#define ACGC_PAD_TRIGGER_R          0x0020
#define ACGC_PAD_TRIGGER_L          0x0040
#define ACGC_PAD_BUTTON_A           0x0100
#define ACGC_PAD_BUTTON_B           0x0200
#define ACGC_PAD_BUTTON_X           0x0400
#define ACGC_PAD_BUTTON_Y           0x0800
#define ACGC_PAD_BUTTON_START       0x1000

/* Public API */
int      acgc_init(const ACGCConfig* config);
int      acgc_tick(const ACGCPadInput* input);
void     acgc_get_state(ACGCState* out_state);
uint64_t acgc_get_arena_hash(void);
int      acgc_dump_arena(const char* filepath);
int      acgc_get_scene_no(void);
int      acgc_get_scene_mode(void);
uint32_t acgc_get_rng_seed(void);
int      acgc_get_actor_count(void);
int      acgc_is_game_running(void);
void     acgc_poke_arena_byte(uint32_t offset, uint8_t val);
uint8_t  acgc_peek_arena_byte(uint32_t offset);
void     acgc_poke_actor_byte(uint32_t offset, uint8_t val);
uint8_t  acgc_peek_actor_byte(uint32_t offset);
void     acgc_poke_rng_seed(uint32_t seed);
int      acgc_dump_state_breakdown(const char* dir_prefix, int run_id);
const void* acgc_get_frame_packet(size_t* out_size);
int      acgc_has_frame_packet(void);
void     acgc_set_scene(int scene_id);
void     acgc_change_scene(int scene_id);
void     acgc_set_shm_audio(void* shm_base);
void     acgc_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif /* ACGC_API_H */
