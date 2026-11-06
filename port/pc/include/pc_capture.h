#ifndef PC_CAPTURE_H
#define PC_CAPTURE_H

#include "pc_platform.h"
#include "acgc_frame_packet.h"

#ifdef __cplusplus
extern "C" {
#endif

extern int         g_pc_capture_enabled;        /* 1 = Dual-Modus active */
extern int         g_pc_capture_frame;          /* Specific frame N to capture (-1 for none) */
extern const char* g_pc_capture_path;           /* Optional path override */
extern int         g_pc_capture_hotkey_pressed; /* Triggered by F10 */

void pc_capture_init(void);
void pc_capture_shutdown(void);

/* Check if capture recording is currently active for this frame */
int  pc_capture_is_recording(void);

/* Check if the current frame index matches the requested capture target */
int  pc_capture_should_save_frame(uint32_t frame_idx);

/* Called at the start of a frame before any rendering */
void pc_capture_begin_frame(uint32_t frame_index, uint32_t tick_count, int width, int height);

/* Called when a draw call is about to be executed */
void pc_capture_record_draw(int prim, const void* verts, int count);

/* Called when an EFB copy occurs */
void pc_capture_record_efb_copy(int src_x, int src_y, int src_w, int src_h,
                                int dst_w, int dst_h, uint8_t format, int clear, void* dest_ptr);
void pc_capture_set_efb_ack(uint32_t ack_seq);
uint32_t pc_capture_get_efb_seq(void);

/* Temporary shadow-popping diagnostic: actor visibility decisions in each ACFP frame.
 * reason: 0=drawn, 1=draw_chk, 2=ctor_pending, 3=no_draw_proc,
 * 4=cull_gate, 5=invisible, 6=talking, 7=skip_drawing. */
void pc_capture_debug_actor_begin(uintptr_t instance, int profile_id, int part);
void pc_capture_debug_actor_end(void);
void pc_capture_debug_actor_status(uintptr_t instance, int profile_id, int name_id,
                                   int part, float x, float y, float z,
                                   int block_x, int block_z, uint32_t flags,
                                   int reason);

/* Called at the end of a frame (before swap buffers) */
void pc_capture_end_frame(void);

/* Save the captured packet to a file */
int  pc_capture_save_packet(const char* filepath);

/* CPU texture caching for GL-free capture */
void        pc_capture_cache_texture_rgba(uint32_t handle, int width, int height, int fmt, const uint8_t* rgba, size_t size);
const void* pc_capture_get_cached_texture_rgba(uint32_t handle, int* out_w, int* out_h, int* out_fmt, size_t* out_size);
void        pc_capture_evict_texture(uint32_t handle);

/* In-memory packet access */
const void* pc_capture_get_packet_data(size_t* out_size);
int         pc_capture_has_packet(void);

#ifdef __cplusplus
}
#endif

#endif /* PC_CAPTURE_H */
