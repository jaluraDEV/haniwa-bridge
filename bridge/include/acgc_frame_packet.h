#ifndef ACGC_FRAME_PACKET_H
#define ACGC_FRAME_PACKET_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ACFP_MAGIC 0x50464341 /* "ACFP" in little endian */
#define ACFP_VERSION 1

/* --- Pass Types --- */
#define ACFP_PASS_OPAQUE      0
#define ACFP_PASS_TRANSPARENT 1
#define ACFP_PASS_UI          2

/* --- Opcodes --- */
#define ACFP_CMD_SET_VIEWPORT_SCISSOR 0x0001
#define ACFP_CMD_SET_PROJECTION       0x0002
#define ACFP_CMD_SET_TRANSFORMS       0x0003
#define ACFP_CMD_SET_DEPTH_BLEND      0x0004
#define ACFP_CMD_SET_ALPHA_TEST       0x0005
#define ACFP_CMD_SET_CULL             0x0006
#define ACFP_CMD_SET_FOG              0x0007
#define ACFP_CMD_SET_LIGHTING         0x0008
#define ACFP_CMD_SET_TEV_STAGE        0x0009
#define ACFP_CMD_SET_TEV_REGISTERS    0x000A
#define ACFP_CMD_BIND_TEXTURE         0x000B
#define ACFP_CMD_SET_INDIRECT         0x000C
#define ACFP_CMD_DRAW                 0x000D
#define ACFP_CMD_EFB_COPY             0x000E
#define ACFP_CMD_SET_TEXGEN           0x000F
#define ACFP_CMD_SET_VIEW_MATRIX       0x0010
#define ACFP_CMD_END_FRAME            0xFFFF

#pragma pack(push, 1)

typedef struct {
    char     magic[4];            /* "ACFP" */
    uint32_t version;             /* 1 */
    uint32_t frame_index;         /* Frame counter */
    uint32_t tick_count;          /* Logical 60Hz tick */
    uint32_t width;               /* 640 */
    uint32_t height;              /* 480 */
    float    clear_color[4];      /* RGBA */
    float    clear_depth;         /* 1.0f */
    
    uint32_t tex_table_offset;
    uint32_t tex_table_count;
    uint32_t vbo_table_offset;
    uint32_t vbo_table_count;
    uint32_t cmd_stream_offset;
    uint32_t cmd_stream_size;
    
    uint32_t reserved[2];
} ACFPHeader;

typedef struct {
    uint32_t tex_id;
    uint64_t hash;                /* 64-bit content hash */
    uint16_t width;
    uint16_t height;
    uint8_t  original_format;
    uint8_t  mipmaps;
    uint8_t  reserved[2];
    uint32_t data_offset;         /* Relative to tex_table_offset */
    uint32_t data_size;           /* width * height * 4 */
} ACFPTextureHeader;

typedef struct {
    float    position[3];         /* X, Y, Z */
    float    normal[3];           /* Nx, Ny, Nz */
    uint8_t  color0[4];           /* R, G, B, A */
    uint8_t  color1[4];           /* R, G, B, A */
    float    texcoord[8][2];      /* UV for up to 8 stages */
} ACFPVertex; /* 12 + 12 + 4 + 4 + 64 = 96 Bytes */

typedef struct {
    uint32_t vbo_id;
    uint64_t hash;
    uint32_t vertex_count;
    uint32_t stride;              /* sizeof(ACFPVertex) */
    uint32_t data_offset;         /* Relative to vbo_table_offset */
    uint32_t data_size;           /* vertex_count * stride */
} ACFPVertexBufferHeader;

typedef struct {
    uint16_t opcode;
    uint16_t payload_size;
} ACFPCommandHeader;

typedef struct {
    float    x, y, w, h, near_z, far_z;
    int32_t  sc_left, sc_top, sc_w, sc_h;
} ACFP_Cmd_ViewportScissor;

typedef struct {
    uint32_t proj_type;          /* 0 = Persp, 1 = Ortho */
    float    matrix[4][4];
} ACFP_Cmd_Projection;

typedef struct {
    uint32_t mtx_slot;
    float    pos_mtx[3][4];
    float    nrm_mtx[3][3];
    float    tex_mtx[3][4];
} ACFP_Cmd_Transforms;

typedef struct {
    uint32_t has_3d_view;        /* 1 if 3D perspective camera active, 0 if ortho/UI */
    float    view_mtx[3][4];     /* GameCube View Matrix (World -> Eye) */
} ACFP_Cmd_ViewMatrix;

typedef struct {
    uint8_t  z_test_enable;
    uint8_t  z_func;
    uint8_t  z_write_enable;
    uint8_t  cull_mode;
    
    uint8_t  blend_mode;
    uint8_t  blend_src;
    uint8_t  blend_dst;
    uint8_t  blend_logic_op;
    
    uint8_t  color_mask;
    uint8_t  alpha_mask;
    uint8_t  reserved[2];
} ACFP_Cmd_DepthBlend;

typedef struct {
    uint8_t  comp0;
    uint8_t  ref0;
    uint8_t  op;
    uint8_t  comp1;
    uint8_t  ref1;
    uint8_t  reserved[3];
} ACFP_Cmd_AlphaTest;

typedef struct {
    uint32_t type;
    float    start_z;
    float    end_z;
    float    near_z;
    float    far_z;
    float    color[4];
} ACFP_Cmd_Fog;

typedef struct {
    uint32_t num_chans;
    float    amb_color[2][4];
    float    mat_color[2][4];
    uint32_t chan_enable[2];
    uint32_t chan_mat_src[2];
    uint32_t chan_amb_src[2];
    uint32_t light_mask[2];
    
    struct {
        float pos[3];
        float dir[3];
        float color[4];
        float dist_atten[3];
        float dir_atten[3];
    } lights[8];
} ACFP_Cmd_Lighting;

typedef struct {
    uint8_t  stage;
    uint8_t  color_a, color_b, color_c, color_d;
    uint8_t  alpha_a, alpha_b, alpha_c, alpha_d;
    uint8_t  color_op, color_bias, color_scale, color_clamp, color_out;
    uint8_t  alpha_op, alpha_bias, alpha_scale, alpha_clamp, alpha_out;
    uint8_t  tex_coord, tex_map, color_chan;
    uint8_t  k_color_sel, k_alpha_sel;
    uint8_t  ras_swap, tex_swap;
} ACFP_Cmd_TevStage;

typedef struct {
    uint32_t num_stages;
    float    tev_colors[4][4];
    float    tev_k_colors[4][4];
    uint8_t  swap_table[4][4];
} ACFP_Cmd_TevRegisters;

typedef struct {
    uint32_t stage;
    uint32_t tex_id;
    uint8_t  wrap_s;
    uint8_t  wrap_t;
    uint8_t  min_filter;
    uint8_t  mag_filter;
} ACFP_Cmd_BindTexture;

typedef struct {
    uint32_t num_ind_stages;
    struct {
        uint8_t tex_coord;
        uint8_t tex_map;
        uint8_t scale_s;
        uint8_t scale_t;
    } ind_order[4];
    float ind_mtx[3][2][3];
    int32_t ind_mtx_scale[3];
} ACFP_Cmd_Indirect;

typedef struct {
    uint16_t prim_type;
    uint16_t pass_type;          /* 0=Opaque, 1=Transparent, 2=UI */
    uint32_t vbo_id;
    uint32_t vertex_offset;
    uint32_t vertex_count;
} ACFP_Cmd_Draw;

typedef struct {
    uint16_t src_x, src_y, src_w, src_h;
    uint16_t dst_w, dst_h;
    uint8_t  format;
    uint8_t  clear;
    uint8_t  is_synthetic;       /* 1 = synthetic target handle */
    uint8_t  efb_seq;            /* 1..255 sequence number */
    uint32_t dest_tex_id;
} ACFP_Cmd_EfbCopy;

typedef struct {
    uint32_t texmtx_enable[2];
    uint32_t texgen_src[2];
    float    texmtx_row0[2][4];
    float    texmtx_row1[2][4];
} ACFP_Cmd_TexGen;

#pragma pack(pop)

#ifdef __cplusplus
}
#endif

#endif /* ACGC_FRAME_PACKET_H */
