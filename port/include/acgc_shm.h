#ifndef ACGC_SHM_H
#define ACGC_SHM_H
/*
 * ACGC Shared-Memory IPC (Plan B) — Windows Shared Memory layout between the
 * 32-bit headless host (producer) and the 64-bit Godot process (consumer).
 *
 * A single 32 MB file mapping (CreateFileMappingA) carries, at fixed offsets:
 *
 *   +0                         ACGCShmHeader
 *   +sizeof(ACGCShmHeader)     ACGCShmFrameSlot frames[2]  (double buffer)
 *   +... + 2*slot              ACGCShmInputBlock           (Godot -> host)
 *   +... + input               ACGCShmAudioRing + samples  (host -> Godot PCM)
 *
 * All offsets are fixed and derived from the struct sizes below, so the 32-bit
 * host (mingw32) and the 64-bit consumer agree on the layout without a shared
 * process. Pointers are never stored; only offsets and fixed-size arrays.
 */

#include <stdint.h>

#define ACGC_SHM_MAGIC              0x4143534Du  /* "ACSM" little-endian */
#define ACGC_SHM_VERSION            1
#define ACGC_SHM_TOTAL_SIZE         (32u * 1024u * 1024u)  /* 32 MiB */

#define ACGC_SHM_FRAME_SLOT_SIZE    (12u * 1024u * 1024u)  /* raw ACFP payload */
#define ACGC_SHM_AUDIO_BUFFER_SIZE  (4u * 1024u * 1024u)   /* int16 interleaved */

/* Named Win32 events (cross-process, same session) */
#define ACGC_SHM_EVENT_FRAME_READY  "Global\\ACGC_EVT_FRAME_READY"
#define ACGC_SHM_EVENT_INPUT_ACK    "Global\\ACGC_EVT_INPUT_ACK"
#define ACGC_SHM_MAPPING_NAME       "Local\\ACGC_SHM_V1"

/* ACFP magic used to validate a produced frame slot (see acgc_frame_packet.h) */
#define ACGC_SHM_ACFP_MAGIC         0x50464341u  /* "ACFP" little-endian */

#ifdef __cplusplus
extern "C" {
#endif

#pragma pack(push, 8)

typedef struct {
    uint32_t magic;              /* ACGC_SHM_MAGIC */
    uint32_t version;            /* ACGC_SHM_VERSION */
    uint32_t total_size;         /* ACGC_SHM_TOTAL_SIZE */
    uint32_t header_size;        /* sizeof(ACGCShmHeader) */
    uint64_t frame_id;           /* monotonic frame counter (producer) */
    uint32_t active_read_slot;   /* slot (0/1) the consumer reads next */
    uint32_t active_write_slot;  /* slot (0/1) the producer writes next */
    uint32_t producer_alive;     /* 1 while the host is running */
    uint32_t consumer_alive;     /* 1 while Godot is attached */
    uint32_t exit_requested;     /* 1 = Godot asks the host to shut down */
    uint32_t audio_sample_rate;  /* e.g. 32000 */
    uint32_t audio_channels;     /* e.g. 2 (interleaved stereo) */
    uint32_t efb_seq;            /* monotonic EFB copy sequence counter */
    uint32_t reserved[3];
} ACGCShmHeader;

typedef struct {
    uint32_t payload_size;       /* valid bytes in data[] (<= FRAME_SLOT_SIZE) */
    uint32_t frame_id;           /* header.frame_id of this payload */
    uint32_t tick_count;         /* logical 60 Hz tick */
    uint32_t reserved[5];
    uint8_t  data[ACGC_SHM_FRAME_SLOT_SIZE];  /* raw ACFP packet */
} ACGCShmFrameSlot;

typedef struct {
    uint16_t buttons;            /* ACGC_PAD_BUTTON_* mask */
    int8_t   stick_x;            /* -80 .. +80 */
    int8_t   stick_y;
    int8_t   substick_x;         /* C-stick */
    int8_t   substick_y;
    uint8_t  trigger_l;          /* 0 .. 255 */
    uint8_t  trigger_r;
    uint32_t input_seq;          /* increments each new input write (Godot) */
    uint32_t rtc_year;           /* injected RTC (0 = keep host clock) */
    uint8_t  rtc_month;
    uint8_t  rtc_day;
    uint8_t  rtc_hour;
    uint8_t  rtc_min;
    uint8_t  rtc_sec;
    uint8_t  rtc_inject;         /* 1 = apply rtc_* on next tick */
    uint32_t efb_ack;            /* Godot acknowledged EFB copy sequence number */
    uint32_t reserved[1];
} ACGCShmInputBlock;

typedef struct {
    uint32_t hour;               /* game RTC hour (0-23) */
    uint32_t minute;             /* game RTC minute (0-59) */
    uint32_t second;             /* game RTC second (0-59) */
    uint32_t weather;            /* 0=Fine, 1=Rain, 2=Snow (+season variants) */
    uint32_t season;             /* 0=Spring, 1=Summer, 2=Autumn, 3=Winter */
    int32_t  scene_no;           /* current scene ID (SCENE_*) */
    int32_t  scene_mode;         /* audio/game scene mode */
    uint32_t is_running;         /* 1 while the game is running */
    uint32_t reserved[4];
} ACGCShmStateBlock;

typedef struct {
    uint32_t buffer_samples;     /* capacity in int16 samples (interleaved) */
    uint32_t head_sample;        /* producer write position (monotonic) */
    uint32_t tail_sample;        /* consumer read position (monotonic) */
    uint32_t reserved[5];
    /* int16_t samples[buffer_samples] follows immediately after this struct */
} ACGCShmAudioRing;

#pragma pack(pop)

/* --- Fixed offsets derived from the struct sizes --- */
#define ACGC_SHM_OFF_HEADER  0u
#define ACGC_SHM_OFF_FRAME0  (ACGC_SHM_OFF_HEADER + sizeof(ACGCShmHeader))
#define ACGC_SHM_OFF_FRAME1  (ACGC_SHM_OFF_FRAME0 + sizeof(ACGCShmFrameSlot))
#define ACGC_SHM_OFF_INPUT   (ACGC_SHM_OFF_FRAME1 + sizeof(ACGCShmFrameSlot))
#define ACGC_SHM_OFF_STATE   (ACGC_SHM_OFF_INPUT  + sizeof(ACGCShmInputBlock))
#define ACGC_SHM_OFF_AUDIO   (ACGC_SHM_OFF_STATE  + sizeof(ACGCShmStateBlock))

/* --- Accessor helpers (base = mapped SHM pointer) --- */
#define ACGC_SHM_HEADER(base) \
    ((ACGCShmHeader*)((char*)(base) + ACGC_SHM_OFF_HEADER))
#define ACGC_SHM_FRAME(base, i) \
    ((ACGCShmFrameSlot*)((char*)(base) + ACGC_SHM_OFF_FRAME0 + (i) * sizeof(ACGCShmFrameSlot)))
#define ACGC_SHM_INPUT(base) \
    ((ACGCShmInputBlock*)((char*)(base) + ACGC_SHM_OFF_INPUT))
#define ACGC_SHM_STATE(base) \
    ((ACGCShmStateBlock*)((char*)(base) + ACGC_SHM_OFF_STATE))
#define ACGC_SHM_AUDIO(base) \
    ((ACGCShmAudioRing*)((char*)(base) + ACGC_SHM_OFF_AUDIO))
#define ACGC_SHM_AUDIO_SAMPLES(base) \
    ((int16_t*)((char*)(base) + ACGC_SHM_OFF_AUDIO + sizeof(ACGCShmAudioRing)))

#ifdef __cplusplus
}
#endif

#endif /* ACGC_SHM_H */
