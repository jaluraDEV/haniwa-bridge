#include "pc_capture.h"
#include "pc_gx_internal.h"
#include "pc_platform.h"
#include <dolphin/gx/GXEnum.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <direct.h>

int         g_pc_capture_enabled = 0;
int         g_pc_capture_frame = -1;
const char* g_pc_capture_path = NULL;
int         g_pc_capture_hotkey_pressed = 0;

static int  s_is_recording = 0;
static uint32_t s_current_frame = 0;
static uint32_t s_current_tick = 0;
static int  s_frame_w = 640;
static int  s_frame_h = 480;

/* Hybrid EFB targets: stable synthetic handles, never OpenGL objects. */
static uintptr_t s_efb_targets[64];
static int s_efb_target_count;
static uint32_t s_efb_seq = 0;
static uint32_t s_efb_ack = 0;
static ACFP_Cmd_EfbCopy s_unacked_efb;
static int s_has_unacked_efb = 0;
static int s_efb_recorded_this_frame = 0;

void pc_capture_set_efb_ack(uint32_t ack_seq) {
    s_efb_ack = ack_seq;
    if (s_has_unacked_efb && s_efb_ack >= s_efb_seq) {
        s_has_unacked_efb = 0;
    }
}

uint32_t pc_capture_get_efb_seq(void) {
    return s_efb_seq;
}
uint32_t pc_capture_find_efb_target(uint32_t address) {
    for (int i = 0; i < s_efb_target_count; ++i)
        if (s_efb_targets[i] == address) return 0x7e000000u + i;
    return 0;
}
void pc_capture_register_efb_target(void* dest) {
    if (pc_capture_find_efb_target((uint32_t)(uintptr_t)dest)) return;
    if (s_efb_target_count < 64) s_efb_targets[s_efb_target_count++] = (uintptr_t)dest;
}

/* --- FNV-1a 64-bit Hash --- */
static uint64_t fnv1a_64(const void* data, size_t len) {
    const uint64_t FNV_OFFSET_BASIS = 0xcbf29ce484222325ULL;
    const uint64_t FNV_PRIME = 0x100000001b3ULL;
    uint64_t hash = FNV_OFFSET_BASIS;
    const uint8_t* p = (const uint8_t*)data;
    for (size_t i = 0; i < len; i++) {
        hash ^= (uint64_t)p[i];
        hash *= FNV_PRIME;
    }
    return hash;
}

/* --- Dynamic Growth Buffer --- */
typedef struct {
    uint8_t* data;
    size_t   size;
    size_t   capacity;
} ByteBuffer;

static void buf_init(ByteBuffer* b, size_t initial_cap) {
    b->data = (uint8_t*)malloc(initial_cap);
    b->size = 0;
    b->capacity = b->data ? initial_cap : 0;
}

static void buf_reset(ByteBuffer* b) {
    b->size = 0;
    if (b->capacity > 4 * 1024 * 1024) {
        uint8_t* n = (uint8_t*)realloc(b->data, 1024 * 1024);
        if (n) {
            b->data = n;
            b->capacity = 1024 * 1024;
        }
    }
}

static void buf_free(ByteBuffer* b) {
    if (b->data) free(b->data);
    b->data = NULL;
    b->size = 0;
    b->capacity = 0;
}

static void buf_append(ByteBuffer* b, const void* src, size_t len) {
    if (!b->data || b->size + len > b->capacity) {
        size_t new_cap = b->capacity ? b->capacity * 2 : 1024;
        while (new_cap < b->size + len) new_cap *= 2;
        uint8_t* n = (uint8_t*)realloc(b->data, new_cap);
        if (!n) return;
        b->data = n;
        b->capacity = new_cap;
    }
    memcpy(b->data + b->size, src, len);
    b->size += len;
}

/* --- Capture State Buffers --- */
static ByteBuffer s_cmd_buf;
static ByteBuffer s_tex_headers_buf;
static ByteBuffer s_tex_data_buf;
static ByteBuffer s_vbo_headers_buf;
static ByteBuffer s_vbo_data_buf;
static ByteBuffer s_packet_buf;

static uint32_t s_tex_count = 0;
static uint32_t s_vbo_count = 0;

/* Temporary diagnostic only: correlate actor decisions with actual ACFP DRAWs.
 * The capture does not modify geometry, actor state or rendering decisions. */
#define ACGC_SHADOW_TRACE_MAX_ACTORS 4096
#define ACGC_SHADOW_TRACE_DROP_THRESHOLD 20

typedef struct {
    uintptr_t instance;
    int profile_id, name_id, part;
    float x, y, z;
    int block_x, block_z;
    uint32_t flags;
    int reason;
    uint32_t draw_count;
} AcgcShadowTraceActor;

static AcgcShadowTraceActor s_trace_actor_now[ACGC_SHADOW_TRACE_MAX_ACTORS];
static AcgcShadowTraceActor s_trace_actor_prev[ACGC_SHADOW_TRACE_MAX_ACTORS];
static int s_trace_actor_now_count = 0;
static int s_trace_actor_prev_count = 0;
static int s_trace_actor_overflow = 0;
static uint32_t s_trace_draw_now = 0;
static uint32_t s_trace_draw_prev = 0;
static uint32_t s_trace_non_actor_draw_now = 0;
static uint32_t s_trace_non_actor_draw_prev = 0;
static uint32_t s_trace_frame_prev = 0;
static int s_trace_prev_valid = 0;

static uintptr_t s_trace_current_actor = 0;
static int s_trace_current_actor_slot = -1;

void pc_capture_debug_actor_begin(uintptr_t instance, int profile_id, int part) {
    if (!s_is_recording) return;
    int slot = -1;
    for (int i = 0; i < s_trace_actor_now_count; ++i) {
        if (s_trace_actor_now[i].instance == instance &&
            s_trace_actor_now[i].profile_id == profile_id) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        if (s_trace_actor_now_count >= ACGC_SHADOW_TRACE_MAX_ACTORS) {
            ++s_trace_actor_overflow;
            s_trace_current_actor = 0;
            s_trace_current_actor_slot = -1;
            return;
        }
        slot = s_trace_actor_now_count++;
        memset(&s_trace_actor_now[slot], 0, sizeof(s_trace_actor_now[slot]));
        s_trace_actor_now[slot].instance = instance;
        s_trace_actor_now[slot].profile_id = profile_id;
        s_trace_actor_now[slot].part = part;
    }
    s_trace_current_actor = instance;
    s_trace_current_actor_slot = slot;
}

void pc_capture_debug_actor_end(void) {
    s_trace_current_actor = 0;
    s_trace_current_actor_slot = -1;
}

void pc_capture_debug_actor_status(uintptr_t instance, int profile_id, int name_id,
                                   int part, float x, float y, float z,
                                   int block_x, int block_z, uint32_t flags,
                                   int reason) {
    if (!s_is_recording) return;
    int slot = -1;
    for (int i = 0; i < s_trace_actor_now_count; ++i) {
        if (s_trace_actor_now[i].instance == instance &&
            s_trace_actor_now[i].profile_id == profile_id) {
            slot = i;
            break;
        }
    }
    if (slot < 0) {
        if (s_trace_actor_now_count >= ACGC_SHADOW_TRACE_MAX_ACTORS) {
            ++s_trace_actor_overflow;
            return;
        }
        slot = s_trace_actor_now_count++;
        memset(&s_trace_actor_now[slot], 0, sizeof(s_trace_actor_now[slot]));
    }
    AcgcShadowTraceActor* a = &s_trace_actor_now[slot];
    a->instance = instance;
    a->profile_id = profile_id;
    a->name_id = name_id;
    a->part = part;
    a->x = x; a->y = y; a->z = z;
    a->block_x = block_x; a->block_z = block_z;
    a->flags = flags;
    a->reason = reason;
}

static const char* pc_capture_trace_reason(int reason) {
    switch (reason) {
        case 0: return "DRAWN";
        case 1: return "draw_chk_proc";
        case 2: return "ct_proc_pending";
        case 3: return "dw_proc_NULL";
        case 4: return "ACTOR_CULL_GATE";
        case 5: return "ACTOR_INVISIBLE";
        case 6: return "cull_while_talking";
        case 7: return "skip_drawing";
        default: return "unknown";
    }
}

static void pc_capture_trace_finish_frame(void) {
    if (s_trace_prev_valid &&
        s_trace_draw_prev >= s_trace_draw_now + ACGC_SHADOW_TRACE_DROP_THRESHOLD) {
        int total_loss = (int)s_trace_draw_prev - (int)s_trace_draw_now;
        int non_actor_prev = (int)s_trace_non_actor_draw_prev;
        int non_actor_now = (int)s_trace_non_actor_draw_now;
        int non_actor_loss = non_actor_prev - non_actor_now;

        int prev_drawn = 0, now_drawn = 0;
        int gone_actors = 0, newly_rejected = 0;
        int total_attributed_loss = (non_actor_loss > 0) ? non_actor_loss : 0;

        for (int i = 0; i < s_trace_actor_prev_count; ++i)
            if (s_trace_actor_prev[i].reason == 0) ++prev_drawn;
        for (int i = 0; i < s_trace_actor_now_count; ++i)
            if (s_trace_actor_now[i].reason == 0) ++now_drawn;

        fprintf(stderr,
            "\n[ACGC SHADOW TRACE] ====================================================================\n"
            "[ACGC SHADOW TRACE] ACFP DRAW DROP frame %u -> %u: %u -> %u (TOTAL LOSS: -%d)\n"
            "[ACGC SHADOW TRACE] Actors drawn: %d -> %d | Actors seen: %d -> %d | Overflow: %d\n"
            "[ACGC SHADOW TRACE] --------------------------------------------------------------------\n",
            s_trace_frame_prev, s_current_frame, s_trace_draw_prev, s_trace_draw_now, total_loss,
            prev_drawn, now_drawn, s_trace_actor_prev_count, s_trace_actor_now_count,
            s_trace_actor_overflow);

        for (int i = 0; i < s_trace_actor_prev_count; ++i) {
            const AcgcShadowTraceActor* old = &s_trace_actor_prev[i];
            const AcgcShadowTraceActor* now = NULL;
            for (int j = 0; j < s_trace_actor_now_count; ++j) {
                if (s_trace_actor_now[j].instance == old->instance &&
                    s_trace_actor_now[j].profile_id == old->profile_id) {
                    now = &s_trace_actor_now[j];
                    break;
                }
            }

            uint32_t old_draws = old->draw_count;
            uint32_t now_draws = (now && now->reason == 0) ? now->draw_count : 0;
            int actor_loss = (int)old_draws - (int)now_draws;

            if (actor_loss > 0 || (old->reason == 0 && (!now || now->reason != 0))) {
                if (actor_loss > 0) total_attributed_loss += actor_loss;
                if (!now) ++gone_actors;
                else if (now->reason != 0) ++newly_rejected;

                const char* cur_status = now ? pc_capture_trace_reason(now->reason) : "ABSENT_FROM_ACTOR_LIST";
                fprintf(stderr,
                    "[ACGC SHADOW TRACE] ACTOR ptr=%p profile=%d part=%d name=%d block=(%d,%d) pos=(%.1f,%.1f,%.1f)\n"
                    "                    draws: %u -> %u (loss: -%d) | reason: %s\n"
                    "                    prev_flags=0x%08x current_flags=0x%08x\n",
                    (void*)old->instance, old->profile_id, old->part, old->name_id,
                    old->block_x, old->block_z, old->x, old->y, old->z,
                    old_draws, now_draws, actor_loss, cur_status,
                    old->flags, now ? now->flags : 0u);
            }
        }

        fprintf(stderr,
            "[ACGC SHADOW TRACE] NON_ACTOR (Terrain/Field/Water/UI)\n"
            "                    draws: %u -> %u (loss: -%d)\n"
            "[ACGC SHADOW TRACE] --------------------------------------------------------------------\n"
            "[ACGC SHADOW TRACE] TOTAL LOSS: %d | ATTRIBUTED TO ACTORS + NON_ACTOR: %d\n"
            "[ACGC SHADOW TRACE] Summary: absent_actors=%d rejected_actors=%d\n"
            "[ACGC SHADOW TRACE] ====================================================================\n\n",
            non_actor_prev, non_actor_now, non_actor_loss,
            total_loss, total_attributed_loss,
            gone_actors, newly_rejected);
        fflush(stderr);
    }
    s_trace_actor_prev_count = s_trace_actor_now_count;
    if (s_trace_actor_now_count > 0)
        memcpy(s_trace_actor_prev, s_trace_actor_now,
               (size_t)s_trace_actor_now_count * sizeof(s_trace_actor_prev[0]));
    s_trace_draw_prev = s_trace_draw_now;
    s_trace_non_actor_draw_prev = s_trace_non_actor_draw_now;
    s_trace_frame_prev = s_current_frame;
    s_trace_prev_valid = 1;
}


/* Mapping GL texture IDs to frame-local texture IDs */
typedef struct {
    GLuint   gl_tex;
    uint32_t local_id;
    uint64_t hash;
} RegisteredTex;

#define MAX_FRAME_TEXTURES 2048
static RegisteredTex s_reg_textures[MAX_FRAME_TEXTURES];
static int           s_reg_tex_count = 0;

/* --- CPU Texture Cache for GL-free capture --- */
typedef struct {
    uint32_t handle;
    int      width;
    int      height;
    int      format;
    size_t   size;
    uint8_t* rgba;
    uint32_t last_frame;
} CpuCachedTexture;

#define MAX_CPU_CACHED_TEXTURES 4096
static CpuCachedTexture s_cpu_tex_cache[MAX_CPU_CACHED_TEXTURES];
static int              s_cpu_tex_cache_count = 0;

void pc_capture_cache_texture_rgba(uint32_t handle, int width, int height, int fmt, const uint8_t* rgba, size_t size) {
    if (!rgba || size == 0 || handle == 0) return;
    for (int i = 0; i < s_cpu_tex_cache_count; i++) {
        if (s_cpu_tex_cache[i].handle == handle) {
            if (s_cpu_tex_cache[i].size != size) {
                free(s_cpu_tex_cache[i].rgba);
                s_cpu_tex_cache[i].rgba = (uint8_t*)malloc(size);
                s_cpu_tex_cache[i].size = size;
            }
            s_cpu_tex_cache[i].width = width;
            s_cpu_tex_cache[i].height = height;
            s_cpu_tex_cache[i].format = fmt;
            s_cpu_tex_cache[i].last_frame = s_current_frame;
            if (s_cpu_tex_cache[i].rgba) memcpy(s_cpu_tex_cache[i].rgba, rgba, size);
            return;
        }
    }

    CpuCachedTexture* c = NULL;
    if (s_cpu_tex_cache_count < MAX_CPU_CACHED_TEXTURES) {
        c = &s_cpu_tex_cache[s_cpu_tex_cache_count++];
        c->rgba = NULL;
        c->size = 0;
    } else {
        /* Evict least recently used texture */
        int lru_idx = 0;
        uint32_t min_frame = s_cpu_tex_cache[0].last_frame;
        for (int i = 1; i < s_cpu_tex_cache_count; i++) {
            if (s_cpu_tex_cache[i].last_frame < min_frame) {
                min_frame = s_cpu_tex_cache[i].last_frame;
                lru_idx = i;
            }
        }
        c = &s_cpu_tex_cache[lru_idx];
    }

    if (c->size != size) {
        if (c->rgba) free(c->rgba);
        c->rgba = (uint8_t*)malloc(size);
        c->size = size;
    }
    c->handle = handle;
    c->width = width;
    c->height = height;
    c->format = fmt;
    c->last_frame = s_current_frame;
    if (c->rgba) memcpy(c->rgba, rgba, size);
}

const void* pc_capture_get_cached_texture_rgba(uint32_t handle, int* out_w, int* out_h, int* out_fmt, size_t* out_size) {
    for (int i = 0; i < s_cpu_tex_cache_count; i++) {
        if (s_cpu_tex_cache[i].handle == handle) {
            s_cpu_tex_cache[i].last_frame = s_current_frame;
            if (out_w) *out_w = s_cpu_tex_cache[i].width;
            if (out_h) *out_h = s_cpu_tex_cache[i].height;
            if (out_fmt) *out_fmt = s_cpu_tex_cache[i].format;
            if (out_size) *out_size = s_cpu_tex_cache[i].size;
            return s_cpu_tex_cache[i].rgba;
        }
    }
    return NULL;
}

void pc_capture_evict_texture(uint32_t handle) {
    if (handle == 0) return;
    for (int i = 0; i < s_cpu_tex_cache_count; i++) {
        if (s_cpu_tex_cache[i].handle == handle) {
            if (s_cpu_tex_cache[i].rgba) free(s_cpu_tex_cache[i].rgba);
            s_cpu_tex_cache[i] = s_cpu_tex_cache[s_cpu_tex_cache_count - 1];
            s_cpu_tex_cache_count--;
            return;
        }
    }
}

/* State change tracking */
static int  s_state_initialized = 0;
static ACFP_Cmd_ViewportScissor s_last_vp;
static ACFP_Cmd_Projection      s_last_proj;
static ACFP_Cmd_ViewMatrix      s_last_view;
static ACFP_Cmd_Transforms      s_last_trans;
static ACFP_Cmd_DepthBlend      s_last_depth_blend;
static ACFP_Cmd_AlphaTest       s_last_alpha;
static ACFP_Cmd_Fog             s_last_fog;
static ACFP_Cmd_Lighting        s_last_light;
static ACFP_Cmd_TevRegisters    s_last_tev_regs;
static ACFP_Cmd_TevStage        s_last_tev_stages[PC_GX_MAX_TEV_STAGES];
static uint32_t                 s_last_num_tev_stages = 0;
static uint32_t                 s_last_bound_tex_id[8];
static ACFP_Cmd_TexGen          s_last_texgen;

static void emit_cmd(uint16_t opcode, const void* payload, uint16_t payload_size) {
    ACFPCommandHeader hdr;
    hdr.opcode = opcode;
    hdr.payload_size = payload_size;
    buf_append(&s_cmd_buf, &hdr, sizeof(hdr));
    if (payload && payload_size > 0) {
        buf_append(&s_cmd_buf, payload, payload_size);
    }
}

void pc_capture_init(void) {
    buf_init(&s_cmd_buf, 512 * 1024);
    buf_init(&s_tex_headers_buf, 64 * sizeof(ACFPTextureHeader));
    buf_init(&s_tex_data_buf, 2 * 1024 * 1024);
    buf_init(&s_vbo_headers_buf, 256 * sizeof(ACFPVertexBufferHeader));
    buf_init(&s_vbo_data_buf, 1024 * 1024);
    buf_init(&s_packet_buf, 1024 * 1024);
}

void pc_capture_shutdown(void) {
    s_efb_target_count = 0;
    buf_free(&s_cmd_buf);
    buf_free(&s_tex_headers_buf);
    buf_free(&s_tex_data_buf);
    buf_free(&s_vbo_headers_buf);
    buf_free(&s_vbo_data_buf);
    buf_free(&s_packet_buf);
    for (int i = 0; i < s_cpu_tex_cache_count; i++) {
        if (s_cpu_tex_cache[i].rgba) free(s_cpu_tex_cache[i].rgba);
    }
    s_cpu_tex_cache_count = 0;
}

int pc_capture_is_recording(void) {
    return s_is_recording;
}

int pc_capture_should_save_frame(uint32_t frame_idx) {
    if (g_pc_capture_hotkey_pressed) return 1;
    if (g_pc_capture_frame > 0 && (int)frame_idx == g_pc_capture_frame) return 1;
    if (g_pc_capture_enabled) return 1;
    return 0;
}

void pc_capture_begin_frame(uint32_t frame_index, uint32_t tick_count, int width, int height) {
    s_efb_recorded_this_frame = 0;
    s_current_frame = frame_index;
    s_current_tick = tick_count;
    s_frame_w = width > 0 ? width : 640;
    s_frame_h = height > 0 ? height : 480;

    buf_reset(&s_cmd_buf);
    buf_reset(&s_tex_headers_buf);
    buf_reset(&s_tex_data_buf);
    buf_reset(&s_vbo_headers_buf);
    buf_reset(&s_vbo_data_buf);

    s_tex_count = 0;
    s_vbo_count = 0;
    s_reg_tex_count = 0;
    s_trace_draw_now = 0;
    s_trace_actor_now_count = 0;
    s_trace_actor_overflow = 0;
    s_trace_non_actor_draw_now = 0;
    s_trace_current_actor = 0;
    s_trace_current_actor_slot = -1;
    s_state_initialized = 0;
    memset(s_last_bound_tex_id, 0xFF, sizeof(s_last_bound_tex_id));

    s_is_recording = pc_capture_should_save_frame(frame_index);
}

static uint32_t register_texture(int stage, int tex_map) {
    if (tex_map < 0 || tex_map >= 8) return 0xFFFFFFFF;
    GLuint gl_tex = g_gx.gl_textures[tex_map];
    if (gl_tex == 0) return 0xFFFFFFFF;

    /* Check if already registered */
    for (int i = 0; i < s_reg_tex_count; i++) {
        if (s_reg_textures[i].gl_tex == gl_tex) {
            return s_reg_textures[i].local_id;
        }
    }

    int real_w = g_gx.tex_obj_w[tex_map];
    int real_h = g_gx.tex_obj_h[tex_map];
    int fmt = g_gx.tex_obj_fmt[tex_map];
    const uint8_t* pixels = NULL;
    size_t pixel_bytes = 0;
    int need_free_pixels = 0;

    /* Check CPU texture cache first */
    for (int i = 0; i < s_cpu_tex_cache_count; i++) {
        if (s_cpu_tex_cache[i].handle == gl_tex) {
            real_w = s_cpu_tex_cache[i].width;
            real_h = s_cpu_tex_cache[i].height;
            fmt = s_cpu_tex_cache[i].format;
            pixels = s_cpu_tex_cache[i].rgba;
            pixel_bytes = s_cpu_tex_cache[i].size;
            break;
        }
    }

    /* Fallback to OpenGL if not in CPU cache and not headless */
    if (!pixels && !g_pc_headless) {
        GLint prev_tex = 0;
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &prev_tex);
        glBindTexture(GL_TEXTURE_2D, gl_tex);

        GLint gw = 0, gh = 0;
        glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_WIDTH, &gw);
        glGetTexLevelParameteriv(GL_TEXTURE_2D, 0, GL_TEXTURE_HEIGHT, &gh);

        if (gw > 0 && gh > 0) {
            real_w = gw;
            real_h = gh;
        }
        if (real_w <= 0 || real_h <= 0 || real_w > 2048 || real_h > 2048) {
            real_w = 1; real_h = 1;
        }

        pixel_bytes = (size_t)real_w * real_h * 4;
        uint8_t* gl_pixels = (uint8_t*)malloc(pixel_bytes);
        if (gl_pixels) {
            GLint prev_pack = 4;
            glGetIntegerv(GL_PACK_ALIGNMENT, &prev_pack);
            glPixelStorei(GL_PACK_ALIGNMENT, 1);

            glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, gl_pixels);

            glPixelStorei(GL_PACK_ALIGNMENT, prev_pack);
            pixels = gl_pixels;
            need_free_pixels = 1;
        }
        glBindTexture(GL_TEXTURE_2D, (GLuint)prev_tex);
    }

    if (!pixels || pixel_bytes == 0) {
        return 0xFFFFFFFF;
    }

    if (s_reg_tex_count >= MAX_FRAME_TEXTURES) {
        if (need_free_pixels) {
            free((void*)pixels);
        }
        return s_reg_textures[MAX_FRAME_TEXTURES - 1].local_id;
    }

    uint64_t hash = fnv1a_64(pixels, pixel_bytes);
    if ((gl_tex & 0xffffffc0u) == 0x7e000000u) hash = 0x4546420000000000ULL | gl_tex;

    uint32_t new_id = s_tex_count++;
    ACFPTextureHeader th;
    th.tex_id = new_id;
    th.hash = hash;
    th.width = (uint16_t)real_w;
    th.height = (uint16_t)real_h;
    th.original_format = (uint8_t)fmt;
    th.mipmaps = 1;
    th.reserved[0] = 0;
    th.reserved[1] = 0;
    th.data_offset = (uint32_t)s_tex_data_buf.size;
    th.data_size = (uint32_t)pixel_bytes;

    buf_append(&s_tex_headers_buf, &th, sizeof(th));
    buf_append(&s_tex_data_buf, pixels, pixel_bytes);
    if (need_free_pixels) {
        free((void*)pixels);
    }

    if (s_reg_tex_count < MAX_FRAME_TEXTURES) {
        s_reg_textures[s_reg_tex_count].gl_tex = gl_tex;
        s_reg_textures[s_reg_tex_count].local_id = new_id;
        s_reg_textures[s_reg_tex_count].hash = hash;
        s_reg_tex_count++;
    }

    return new_id;
}

void pc_capture_record_draw(int prim, const void* verts, int count) {
    if (!s_is_recording || count <= 0 || !verts) return;

    /* 1. Viewport & Scissor */
    ACFP_Cmd_ViewportScissor vp;
    vp.x = g_gx.viewport[0];
    vp.y = g_gx.viewport[1];
    vp.w = g_gx.viewport[2];
    vp.h = g_gx.viewport[3];
    vp.near_z = g_gx.viewport[4];
    vp.far_z = g_gx.viewport[5];
    vp.sc_left = g_gx.scissor[0];
    vp.sc_top = g_gx.scissor[1];
    vp.sc_w = g_gx.scissor[2];
    vp.sc_h = g_gx.scissor[3];

    if (!s_state_initialized || memcmp(&vp, &s_last_vp, sizeof(vp)) != 0) {
        emit_cmd(ACFP_CMD_SET_VIEWPORT_SCISSOR, &vp, sizeof(vp));
        s_last_vp = vp;
    }

    /* 2. Projection */
    ACFP_Cmd_Projection proj;
    proj.proj_type = (uint32_t)g_gx.projection_type;
    memcpy(proj.matrix, g_gx.projection_mtx, sizeof(proj.matrix));

    if (!s_state_initialized || memcmp(&proj, &s_last_proj, sizeof(proj)) != 0) {
        emit_cmd(ACFP_CMD_SET_PROJECTION, &proj, sizeof(proj));
        s_last_proj = proj;
    }

    /* 2b. View Matrix (Camera LookAt: World -> Eye) */
    extern float g_emu64_current_view_mtx[3][4];
    extern int g_emu64_has_3d_view;
    ACFP_Cmd_ViewMatrix vm;
    vm.has_3d_view = (uint32_t)g_emu64_has_3d_view;
    memcpy(vm.view_mtx, g_emu64_current_view_mtx, sizeof(vm.view_mtx));
    if (!s_state_initialized || memcmp(&vm, &s_last_view, sizeof(vm)) != 0) {
        emit_cmd(ACFP_CMD_SET_VIEW_MATRIX, &vm, sizeof(vm));
        s_last_view = vm;
    }

    /* 3. Transforms */
    ACFP_Cmd_Transforms trans;
    trans.mtx_slot = (uint32_t)g_gx.current_mtx;
    memcpy(trans.pos_mtx, g_gx.pos_mtx[g_gx.current_mtx], sizeof(trans.pos_mtx));
    memcpy(trans.nrm_mtx, g_gx.nrm_mtx[g_gx.current_mtx], sizeof(trans.nrm_mtx));
    memcpy(trans.tex_mtx, g_gx.tex_mtx[g_gx.current_mtx], sizeof(trans.tex_mtx));

    if (!s_state_initialized || memcmp(&trans, &s_last_trans, sizeof(trans)) != 0) {
        emit_cmd(ACFP_CMD_SET_TRANSFORMS, &trans, sizeof(trans));
        s_last_trans = trans;
    }

    /* 3b. TexGen */
    ACFP_Cmd_TexGen tg;
    for (int i = 0; i < 2; i++) {
        int slot = -1;
        int id = g_gx.tex_gen_mtx[i];
        if (id >= 0 && id < 10) slot = id;
        else if (id >= GX_TEXMTX0 && id < GX_IDENTITY) slot = (id - GX_TEXMTX0) / 3;

        tg.texmtx_enable[i] = (slot >= 0 && slot < 10);
        tg.texgen_src[i] = (uint32_t)g_gx.tex_gen_src[i];
        memset(tg.texmtx_row0[i], 0, sizeof(tg.texmtx_row0[i]));
        memset(tg.texmtx_row1[i], 0, sizeof(tg.texmtx_row1[i]));
        tg.texmtx_row0[i][0] = 1.0f;
        tg.texmtx_row1[i][1] = 1.0f;
        if (tg.texmtx_enable[i]) {
            const float* tm = (const float*)g_gx.tex_mtx[slot];
            memcpy(tg.texmtx_row0[i], &tm[0], sizeof(tg.texmtx_row0[i]));
            memcpy(tg.texmtx_row1[i], &tm[4], sizeof(tg.texmtx_row1[i]));
        }
    }

    if (!s_state_initialized || memcmp(&tg, &s_last_texgen, sizeof(tg)) != 0) {
        emit_cmd(ACFP_CMD_SET_TEXGEN, &tg, sizeof(tg));
        s_last_texgen = tg;
    }

    /* 4. Depth & Blend */
    ACFP_Cmd_DepthBlend db;
    db.z_test_enable = (uint8_t)g_gx.z_compare_enable;
    db.z_func = (uint8_t)g_gx.z_compare_func;
    db.z_write_enable = (uint8_t)g_gx.z_update_enable;
    db.cull_mode = (uint8_t)g_gx.cull_mode;
    db.blend_mode = (uint8_t)g_gx.blend_mode;
    db.blend_src = (uint8_t)g_gx.blend_src;
    db.blend_dst = (uint8_t)g_gx.blend_dst;
    db.blend_logic_op = (uint8_t)g_gx.blend_logic_op;
    db.color_mask = (uint8_t)g_gx.color_update_enable;
    db.alpha_mask = (uint8_t)g_gx.alpha_update_enable;
    db.reserved[0] = 0; db.reserved[1] = 0;

    if (!s_state_initialized || memcmp(&db, &s_last_depth_blend, sizeof(db)) != 0) {
        emit_cmd(ACFP_CMD_SET_DEPTH_BLEND, &db, sizeof(db));
        s_last_depth_blend = db;
    }

    /* 5. Alpha Test */
    ACFP_Cmd_AlphaTest at;
    at.comp0 = (uint8_t)g_gx.alpha_comp0;
    at.ref0 = (uint8_t)g_gx.alpha_ref0;
    at.op = (uint8_t)g_gx.alpha_op;
    at.comp1 = (uint8_t)g_gx.alpha_comp1;
    at.ref1 = (uint8_t)g_gx.alpha_ref1;
    at.reserved[0] = 0; at.reserved[1] = 0; at.reserved[2] = 0;

    if (!s_state_initialized || memcmp(&at, &s_last_alpha, sizeof(at)) != 0) {
        emit_cmd(ACFP_CMD_SET_ALPHA_TEST, &at, sizeof(at));
        s_last_alpha = at;
    }

    /* 6. Fog */
    ACFP_Cmd_Fog fog;
    fog.type = (uint32_t)g_gx.fog_type;
    fog.start_z = g_gx.fog_start;
    fog.end_z = g_gx.fog_end;
    fog.near_z = g_gx.fog_near;
    fog.far_z = g_gx.fog_far;
    memcpy(fog.color, g_gx.fog_color, sizeof(fog.color));

    if (!s_state_initialized || memcmp(&fog, &s_last_fog, sizeof(fog)) != 0) {
        emit_cmd(ACFP_CMD_SET_FOG, &fog, sizeof(fog));
        s_last_fog = fog;
    }

    /* 7. Lighting */
    ACFP_Cmd_Lighting light;
    light.num_chans = (uint32_t)g_gx.num_chans;
    memcpy(light.amb_color, g_gx.chan_amb_color, sizeof(light.amb_color));
    memcpy(light.mat_color, g_gx.chan_mat_color, sizeof(light.mat_color));
    light.chan_enable[0] = (uint32_t)g_gx.chan_ctrl_enable[0];
    light.chan_enable[1] = (uint32_t)g_gx.chan_ctrl_enable[1];
    light.chan_mat_src[0] = (uint32_t)g_gx.chan_ctrl_mat_src[0];
    light.chan_mat_src[1] = (uint32_t)g_gx.chan_ctrl_mat_src[1];
    light.chan_amb_src[0] = (uint32_t)g_gx.chan_ctrl_amb_src[0];
    light.chan_amb_src[1] = (uint32_t)g_gx.chan_ctrl_amb_src[1];
    light.light_mask[0] = (uint32_t)g_gx.chan_ctrl_light_mask[0];
    light.light_mask[1] = (uint32_t)g_gx.chan_ctrl_light_mask[1];
    for (int i = 0; i < 8; i++) {
        memcpy(light.lights[i].pos, g_gx.lights[i].pos, sizeof(light.lights[i].pos));
        memcpy(light.lights[i].dir, g_gx.lights[i].dir, sizeof(light.lights[i].dir));
        memcpy(light.lights[i].color, g_gx.lights[i].color, sizeof(light.lights[i].color));
        light.lights[i].dist_atten[0] = g_gx.lights[i].k0;
        light.lights[i].dist_atten[1] = g_gx.lights[i].k1;
        light.lights[i].dist_atten[2] = g_gx.lights[i].k2;
        light.lights[i].dir_atten[0] = g_gx.lights[i].a0;
        light.lights[i].dir_atten[1] = g_gx.lights[i].a1;
        light.lights[i].dir_atten[2] = g_gx.lights[i].a2;
    }

    if (!s_state_initialized || memcmp(&light, &s_last_light, sizeof(light)) != 0) {
        emit_cmd(ACFP_CMD_SET_LIGHTING, &light, sizeof(light));
        s_last_light = light;
    }

    /* 8. TEV Stages */
    for (int s = 0; s < g_gx.num_tev_stages && s < PC_GX_MAX_TEV_STAGES; s++) {
        PCGXTevStage* src = &g_gx.tev_stages[s];
        ACFP_Cmd_TevStage dst;
        dst.stage = (uint8_t)s;
        dst.color_a = (uint8_t)src->color_a;
        dst.color_b = (uint8_t)src->color_b;
        dst.color_c = (uint8_t)src->color_c;
        dst.color_d = (uint8_t)src->color_d;
        dst.alpha_a = (uint8_t)src->alpha_a;
        dst.alpha_b = (uint8_t)src->alpha_b;
        dst.alpha_c = (uint8_t)src->alpha_c;
        dst.alpha_d = (uint8_t)src->alpha_d;
        dst.color_op = (uint8_t)src->color_op;
        dst.color_bias = (uint8_t)src->color_bias;
        dst.color_scale = (uint8_t)src->color_scale;
        dst.color_clamp = (uint8_t)src->color_clamp;
        dst.color_out = (uint8_t)src->color_out;
        dst.alpha_op = (uint8_t)src->alpha_op;
        dst.alpha_bias = (uint8_t)src->alpha_bias;
        dst.alpha_scale = (uint8_t)src->alpha_scale;
        dst.alpha_clamp = (uint8_t)src->alpha_clamp;
        dst.alpha_out = (uint8_t)src->alpha_out;
        dst.tex_coord = (uint8_t)src->tex_coord;
        dst.tex_map = (uint8_t)src->tex_map;
        dst.color_chan = (uint8_t)src->color_chan;
        dst.k_color_sel = (uint8_t)src->k_color_sel;
        dst.k_alpha_sel = (uint8_t)src->k_alpha_sel;
        dst.ras_swap = (uint8_t)src->ras_swap;
        dst.tex_swap = (uint8_t)src->tex_swap;

        if (!s_state_initialized || memcmp(&dst, &s_last_tev_stages[s], sizeof(dst)) != 0) {
            emit_cmd(ACFP_CMD_SET_TEV_STAGE, &dst, sizeof(dst));
            s_last_tev_stages[s] = dst;
        }
    }
    s_last_num_tev_stages = (uint32_t)g_gx.num_tev_stages;

    /* 9. TEV Registers */
    ACFP_Cmd_TevRegisters tr;
    tr.num_stages = (uint32_t)g_gx.num_tev_stages;
    memcpy(tr.tev_colors, g_gx.tev_colors, sizeof(tr.tev_colors));
    memcpy(tr.tev_k_colors, g_gx.tev_k_colors, sizeof(tr.tev_k_colors));
    for (int t = 0; t < 4; t++) {
        tr.swap_table[t][0] = (uint8_t)g_gx.tev_swap_table[t].r;
        tr.swap_table[t][1] = (uint8_t)g_gx.tev_swap_table[t].g;
        tr.swap_table[t][2] = (uint8_t)g_gx.tev_swap_table[t].b;
        tr.swap_table[t][3] = (uint8_t)g_gx.tev_swap_table[t].a;
    }

    if (!s_state_initialized || memcmp(&tr, &s_last_tev_regs, sizeof(tr)) != 0) {
        emit_cmd(ACFP_CMD_SET_TEV_REGISTERS, &tr, sizeof(tr));
        s_last_tev_regs = tr;
    }

    /* 10. Texture bindings */
    for (int s = 0; s < 3; s++) {
        uint32_t local_tex_id = 0xFFFFFFFF;
        if (s < g_gx.num_tev_stages) {
            int tex_map = g_gx.tev_stages[s].tex_map;
            if (tex_map >= 0 && tex_map < 8 && g_gx.gl_textures[tex_map] != 0) {
                local_tex_id = register_texture(s, tex_map);
            }
        }
        if (!s_state_initialized || s_last_bound_tex_id[s] != local_tex_id) {
            ACFP_Cmd_BindTexture bt;
            bt.stage = (uint32_t)s;
            bt.tex_id = local_tex_id;
            if (local_tex_id != 0xFFFFFFFF) {
                int tex_map = g_gx.tev_stages[s].tex_map;
                bt.wrap_s = (uint8_t)g_gx.tex_obj_wrap_s[tex_map];
                bt.wrap_t = (uint8_t)g_gx.tex_obj_wrap_t[tex_map];
                bt.min_filter = (uint8_t)g_gx.tex_obj_filter[tex_map];
                bt.mag_filter = (uint8_t)g_gx.tex_obj_filter[tex_map];
            } else {
                bt.wrap_s = bt.wrap_t = bt.min_filter = bt.mag_filter = 0;
            }
            emit_cmd(ACFP_CMD_BIND_TEXTURE, &bt, sizeof(bt));
            s_last_bound_tex_id[s] = local_tex_id;
        }
    }

    s_state_initialized = 1;

    /* 11. Vertex buffer deduplication and storage */
    size_t vbo_bytes = (size_t)count * sizeof(PCGXVertex);
    uint64_t vbo_hash = fnv1a_64(verts, vbo_bytes);

    uint32_t target_vbo_id = 0xFFFFFFFF;
    ACFPVertexBufferHeader* existing_vbos = (ACFPVertexBufferHeader*)s_vbo_headers_buf.data;
    for (uint32_t i = 0; i < s_vbo_count; i++) {
        if (existing_vbos[i].hash == vbo_hash && existing_vbos[i].vertex_count == (uint32_t)count) {
            target_vbo_id = existing_vbos[i].vbo_id;
            break;
        }
    }

    if (target_vbo_id == 0xFFFFFFFF) {
        target_vbo_id = s_vbo_count++;
        ACFPVertexBufferHeader vh;
        vh.vbo_id = target_vbo_id;
        vh.hash = vbo_hash;
        vh.vertex_count = (uint32_t)count;
        vh.stride = (uint32_t)sizeof(PCGXVertex);
        vh.data_offset = (uint32_t)s_vbo_data_buf.size;
        vh.data_size = (uint32_t)vbo_bytes;

        buf_append(&s_vbo_headers_buf, &vh, sizeof(vh));
        buf_append(&s_vbo_data_buf, verts, vbo_bytes);
    }

    /* 12. Draw call command */
    uint16_t pass_type = ACFP_PASS_OPAQUE;
    if (g_gx.projection_type == 1 || !g_gx.z_compare_enable) {
        pass_type = ACFP_PASS_UI;
    } else if (g_gx.blend_mode == GX_BM_BLEND || (g_gx.alpha_comp0 != 7 && g_gx.alpha_comp0 != 0)) {
        pass_type = ACFP_PASS_TRANSPARENT;
    }

    if (pass_type == ACFP_PASS_UI && !s_efb_recorded_this_frame && s_has_unacked_efb) {
        emit_cmd(ACFP_CMD_EFB_COPY, &s_unacked_efb, sizeof(s_unacked_efb));
        s_efb_recorded_this_frame = 1;
    }

    ACFP_Cmd_Draw dc;
    dc.prim_type = (uint16_t)prim;
    dc.pass_type = pass_type;
    dc.vbo_id = target_vbo_id;
    dc.vertex_offset = 0;
    dc.vertex_count = (uint32_t)count;
    emit_cmd(ACFP_CMD_DRAW, &dc, sizeof(dc));
    ++s_trace_draw_now;
    if (s_trace_current_actor_slot >= 0 && s_trace_current_actor_slot < s_trace_actor_now_count) {
        s_trace_actor_now[s_trace_current_actor_slot].draw_count++;
    } else {
        ++s_trace_non_actor_draw_now;
    }
}

void pc_capture_record_efb_copy(int src_x, int src_y, int src_w, int src_h,
                                int dst_w, int dst_h, uint8_t format, int clear, void* dest_ptr) {
    if (!s_is_recording) return;

    s_efb_seq++;
    s_efb_recorded_this_frame = 1;

    ACFP_Cmd_EfbCopy efb;
    efb.src_x = (uint16_t)src_x;
    efb.src_y = (uint16_t)src_y;
    efb.src_w = (uint16_t)src_w;
    efb.src_h = (uint16_t)src_h;
    efb.dst_w = (uint16_t)dst_w;
    efb.dst_h = (uint16_t)dst_h;
    efb.format = format;
    efb.clear = (uint8_t)(clear ? 1 : 0);
    efb.is_synthetic = g_pc_headless ? 1 : 0;
    efb.efb_seq = (uint8_t)(s_efb_seq & 0xFF);
    efb.dest_tex_id = g_pc_headless ? pc_capture_find_efb_target((uint32_t)(uintptr_t)dest_ptr) : s_tex_count;

    s_unacked_efb = efb;
    s_has_unacked_efb = 1;

    emit_cmd(ACFP_CMD_EFB_COPY, &efb, sizeof(efb));
}

void pc_capture_end_frame(void) {
    if (!s_is_recording) return;

    if (!s_efb_recorded_this_frame && s_has_unacked_efb) {
        emit_cmd(ACFP_CMD_EFB_COPY, &s_unacked_efb, sizeof(s_unacked_efb));
        s_efb_recorded_this_frame = 1;
    }

    emit_cmd(ACFP_CMD_END_FRAME, NULL, 0);

    /* Calculate section offsets */
    uint32_t header_size = (uint32_t)sizeof(ACFPHeader);
    uint32_t tex_hdr_size = (uint32_t)s_tex_headers_buf.size;
    uint32_t tex_data_size = (uint32_t)s_tex_data_buf.size;
    uint32_t vbo_hdr_size = (uint32_t)s_vbo_headers_buf.size;
    uint32_t vbo_data_size = (uint32_t)s_vbo_data_buf.size;
    uint32_t cmd_size = (uint32_t)s_cmd_buf.size;

    ACFPHeader hdr;
    memset(&hdr, 0, sizeof(hdr));
    hdr.magic[0] = 'A'; hdr.magic[1] = 'C'; hdr.magic[2] = 'F'; hdr.magic[3] = 'P';
    hdr.version = ACFP_VERSION;
    hdr.frame_index = s_current_frame;
    hdr.tick_count = s_current_tick;
    hdr.width = (uint32_t)s_frame_w;
    hdr.height = (uint32_t)s_frame_h;
    memcpy(hdr.clear_color, g_gx.clear_color, sizeof(hdr.clear_color));
    hdr.clear_depth = g_gx.clear_depth;

    hdr.tex_table_offset = header_size;
    hdr.tex_table_count = s_tex_count;

    hdr.vbo_table_offset = hdr.tex_table_offset + tex_hdr_size + tex_data_size;
    hdr.vbo_table_count = s_vbo_count;

    hdr.cmd_stream_offset = hdr.vbo_table_offset + vbo_hdr_size + vbo_data_size;
    hdr.cmd_stream_size = cmd_size;

    /* Assemble in-memory contiguous packet */
    buf_reset(&s_packet_buf);
    buf_append(&s_packet_buf, &hdr, sizeof(hdr));
    if (tex_hdr_size > 0)  buf_append(&s_packet_buf, s_tex_headers_buf.data, tex_hdr_size);
    if (tex_data_size > 0) buf_append(&s_packet_buf, s_tex_data_buf.data, tex_data_size);
    if (vbo_hdr_size > 0)  buf_append(&s_packet_buf, s_vbo_headers_buf.data, vbo_hdr_size);
    if (vbo_data_size > 0) buf_append(&s_packet_buf, s_vbo_data_buf.data, vbo_data_size);
    if (cmd_size > 0)      buf_append(&s_packet_buf, s_cmd_buf.data, cmd_size);

    pc_capture_trace_finish_frame();
}

const void* pc_capture_get_packet_data(size_t* out_size) {
    if (out_size) *out_size = s_packet_buf.size;
    return s_packet_buf.data;
}

int pc_capture_has_packet(void) {
    return (s_packet_buf.size >= sizeof(ACFPHeader));
}

int pc_capture_save_packet(const char* filepath) {
    if (!filepath) return 0;

    _mkdir("captures");

    FILE* f = fopen(filepath, "wb");
    if (!f) {
        printf("[PC Capture] Failed to open %s for writing\n", filepath);
        return 0;
    }

    if (s_packet_buf.size > 0) {
        fwrite(s_packet_buf.data, 1, s_packet_buf.size, f);
    }
    fclose(f);

    printf("[PC Capture] Wrote packet %s (%u textures, %u VBOs, %u cmds, %u KB)\n",
           filepath, (unsigned int)s_tex_count, (unsigned int)s_vbo_count,
           (unsigned int)(s_cmd_buf.size / sizeof(ACFPCommandHeader)),
           (unsigned int)(s_packet_buf.size / 1024));

    return 1;
}
