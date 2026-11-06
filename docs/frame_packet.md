# ACGC Frame Packet Format Specification (v1.0)

## 1. Overview & Design Principles

The **ACGC Frame Packet** is a self-contained, versioned binary format designed to capture all draw commands and GPU states of a rendered single frame from the GameCube decompilation *Animal Crossing* (`GAFE01_00`).

### Design Goals:
1. **Lossless Reconstruction:** The replay renderer or the Godot rendering engine can reproduce a pixel-identical image from the frame packet without executing game logic.
2. **Resource Deduplication via Hash:** Vertex buffers and decoded textures are stored in dedicated resource tables keyed by 64-bit FNV-1a content hashes. Identical geometry and textures are transferred only once intra-frame and across frame boundaries.
3. **Compact Opcode Command Streaming:** Render states (matrices, TEV combiners, blending, Z-buffer, lighting, viewports) are recorded as a sequential command stream (`Command Stream`).
4. **Pass Classification:** Each draw call is assigned to a render pass (Opaque, Transparent/Decal, UI/Orthographic) enabling Godot to optimize batch sorting and lighting integration.

---

## 2. Overall Binary Layout

An ACFP file (`.acfp`) or in-memory packet consists of 4 contiguous sections:

```
┌──────────────────────────────────────────────────────────┐
│ 1. Frame Header (64 Bytes)                              │
│    Magic: 'ACFP', Version: 1, Frame ID, Resolution,      │
│    Table offsets and counts                              │
├──────────────────────────────────────────────────────────┤
│ 2. Texture Resource Table                                │
│    Array of texture headers (width, height, format, hash)│
│    + decoded RGBA8 pixel data                            │
├──────────────────────────────────────────────────────────┤
│ 3. Vertex Buffer Resource Table                          │
│    Array of VBO headers (vertex count, stride, hash)     │
│    + 64-byte PCGXVertex array                            │
├──────────────────────────────────────────────────────────┤
│ 4. Command Stream                                        │
│    Sequence of commands: [Opcode (u16)][Payload...]      │
│    Terminated by CMD_END_FRAME (0xFFFF)                  │
└──────────────────────────────────────────────────────────┘
```

All multi-byte values use **Little-Endian** byte ordering (host format for x86_32 / Godot).

---

## 3. Data Structures & Headers

### 3.1 Frame Header (`ACFPHeader`, 64 Bytes)

```c
typedef struct {
    char     magic[4];            /* "ACFP" (0x50464341) */
    uint32_t version;             /* 1 */
    uint32_t frame_index;         /* Monotonic frame counter */
    uint32_t tick_count;          /* Logical 60 Hz simulation tick */
    uint32_t width;               /* e.g. 640 */
    uint32_t height;              /* e.g. 480 */
    float    clear_color[4];      /* RGBA clear color */
    float    clear_depth;         /* Default 1.0f */
    
    /* Section offsets and counts */
    uint32_t tex_table_offset;    /* Byte offset to texture table */
    uint32_t tex_table_count;     /* Number of textures in frame */
    uint32_t vbo_table_offset;    /* Byte offset to vertex buffer table */
    uint32_t vbo_table_count;     /* Number of vertex buffers in frame */
    uint32_t cmd_stream_offset;   /* Byte offset to command stream */
    uint32_t cmd_stream_size;     /* Total length of command stream in bytes */
    
    uint32_t reserved[2];         /* Zero padding for 64-byte alignment */
} ACFPHeader;
```

---

## 4. Resource Tables

### 4.1 Texture Resource Table (`ACFPTextureHeader`)

Each texture is decoded to 32-bit RGBA8 prior to packet insertion:

```c
typedef struct {
    uint32_t tex_id;              /* Frame-local texture ID */
    uint64_t hash;                /* 64-bit FNV-1a content hash */
    uint16_t width;               /* Texture width in pixels */
    uint16_t height;              /* Texture height in pixels */
    uint8_t  original_format;     /* GameCube GXTexFmt (e.g. GX_TF_RGB5A3, CI4) */
    uint8_t  mipmaps;             /* 1 if no mipmaps */
    uint8_t  reserved[2];
    uint32_t data_offset;         /* Offset to RGBA8 pixel data (relative to tex_table_offset) */
    uint32_t data_size;           /* width * height * 4 */
} ACFPTextureHeader;
```

### 4.2 Vertex Buffer Resource Table (`ACFPVertexBufferHeader`)

Vertex data utilizes the standardized 64-byte layout of the PC backend:

```c
typedef struct {
    float    position[3];         /* X, Y, Z (12 Bytes) */
    float    normal[3];           /* Nx, Ny, Nz (12 Bytes) */
    uint8_t  color0[4];           /* R, G, B, A (4 Bytes) */
    uint8_t  color1[4];           /* R, G, B, A (4 Bytes) */
    float    texcoord[8][2];      /* UV coordinates for up to 8 textures (64 Bytes -> 32 Bytes for 8x2) */
} ACFPVertex; /* 64 Bytes total size */

typedef struct {
    uint32_t vbo_id;              /* Local buffer ID */
    uint64_t hash;                /* 64-bit FNV-1a hash over vertex data */
    uint32_t vertex_count;        /* Number of vertices */
    uint32_t stride;              /* sizeof(ACFPVertex) = 64 */
    uint32_t data_offset;         /* Offset to vertex array (relative to vbo_table_offset) */
    uint32_t data_size;           /* vertex_count * stride */
} ACFPVertexBufferHeader;
```

---

## 5. Command Stream

The command stream comprises a contiguous sequence of typed instructions:
`[uint16_t opcode][uint16_t payload_size][payload...]`

### 5.1 Opcode Definitions

| Opcode | Name | Description |
|:---|:---|:---|
| `0x0001` | `CMD_SET_VIEWPORT_SCISSOR` | Viewport & scissor rectangles |
| `0x0002` | `CMD_SET_PROJECTION` | 4x4 projection matrix & projection type (Persp / Ortho) |
| `0x0003` | `CMD_SET_TRANSFORMS` | Slot, ModelView (3x4), Normal (3x3), Tex Matrix (3x4) |
| `0x0004` | `CMD_SET_DEPTH_BLEND` | Z-test, Z-write, Z-func, blending, color & alpha mask |
| `0x0005` | `CMD_SET_ALPHA_TEST` | Alpha compare functions & threshold values |
| `0x0006` | `CMD_SET_CULL` | Culling mode (None, Front, Back, All) |
| `0x0007` | `CMD_SET_FOG` | Linear GX fog: type, start, end, near, far, color |
| `0x0008` | `CMD_SET_LIGHTING` | Channel controls, ambient & material colors, 8 GX lights |
| `0x0009` | `CMD_SET_TEV_STAGE` | Complete configuration of a TEV stage (0–15) |
| `0x000A` | `CMD_SET_TEV_REGISTERS` | Constant TEV registers PREV, REG0..2, K0..K3, swap tables |
| `0x000B` | `CMD_BIND_TEXTURE` | Texture binding to stage: `tex_id`, Wrap S/T, Min/Mag filter |
| `0x000C` | `CMD_SET_INDIRECT` | Indirect texturing (stages, order, ind matrices, scales) |
| `0x000D` | `CMD_DRAW` | Draw call: primitive type, VBO ID, offset, count, pass |
| `0x000E` | `CMD_EFB_COPY` | Framebuffer copy (source, dest, clear flag, format) |
| `0xFFFF` | `CMD_END_FRAME` | End of frame |

---

## 6. Command Payload Definitions

### 6.1 `CMD_SET_VIEWPORT_SCISSOR` (`0x0001`)
```c
typedef struct {
    float    x, y, w, h, near_z, far_z; /* Viewport */
    int32_t  sc_left, sc_top, sc_w, sc_h; /* Scissor Box */
} ACFP_Cmd_ViewportScissor;
```

### 6.2 `CMD_SET_PROJECTION` (`0x0002`)
```c
typedef struct {
    uint32_t proj_type;          /* 0 = Perspective, 1 = Orthographic */
    float    matrix[4][4];       /* 4x4 Projection Matrix */
} ACFP_Cmd_Projection;
```

### 6.3 `CMD_SET_TRANSFORMS` (`0x0003`)
```c
typedef struct {
    uint32_t mtx_slot;           /* 0..9 (Active matrix index) */
    float    pos_mtx[3][4];      /* ModelView Matrix (3 rows x 4 columns) */
    float    nrm_mtx[3][3];      /* Inverse-Transpose Normal Matrix */
    float    tex_mtx[3][4];      /* Texture Generation Matrix */
} ACFP_Cmd_Transforms;
```

### 6.4 `CMD_SET_DEPTH_BLEND` (`0x0004`)
```c
typedef struct {
    uint8_t  z_test_enable;      /* 0 / 1 */
    uint8_t  z_func;             /* GXCompare: 0=NEVER, 1=LESS, 2=EQUAL, 3=LEQUAL, 4=GREATER, 5=NEQUAL, 6=GEQUAL, 7=ALWAYS */
    uint8_t  z_write_enable;     /* 0 / 1 */
    uint8_t  cull_mode;          /* 0=NONE, 1=FRONT, 2=BACK, 3=ALL */
    
    uint8_t  blend_mode;         /* 0=NONE, 1=BLEND, 2=LOGIC, 3=SUBTRACT */
    uint8_t  blend_src;          /* GXBlendFactor (e.g. SRC_ALPHA, ONE) */
    uint8_t  blend_dst;          /* GXBlendFactor (e.g. INV_SRC_ALPHA, ZERO) */
    uint8_t  blend_logic_op;     /* GXLogicOp */
    
    uint8_t  color_mask;         /* RGB Write Mask (1=Enable, 0=Disable) */
    uint8_t  alpha_mask;         /* Alpha Write Mask (1=Enable, 0=Disable) */
    uint8_t  reserved[2];
} ACFP_Cmd_DepthBlend;
```

### 6.5 `CMD_SET_ALPHA_TEST` (`0x0005`)
```c
typedef struct {
    uint8_t  comp0;              /* GXCompare for threshold 0 */
    uint8_t  ref0;               /* Reference value 0 (0..255) */
    uint8_t  op;                 /* 0=AND, 1=OR, 2=XOR, 3=XNOR */
    uint8_t  comp1;              /* GXCompare for threshold 1 */
    uint8_t  ref1;               /* Reference value 1 (0..255) */
    uint8_t  reserved[3];
} ACFP_Cmd_AlphaTest;
```

### 6.6 `CMD_SET_FOG` (`0x0007`)
```c
typedef struct {
    uint32_t type;               /* 0 = Off, >0 = Linear GX Fog */
    float    start_z;            /* Start distance in world units */
    float    end_z;              /* End distance */
    float    near_z;             /* Camera near plane */
    float    far_z;              /* Camera far plane */
    float    color[4];           /* Fog color (RGBA) */
} ACFP_Cmd_Fog;
```

### 6.7 `CMD_SET_LIGHTING` (`0x0008`)
```c
typedef struct {
    uint32_t num_chans;          /* Number of active color channels */
    float    amb_color[2][4];    /* RGBA ambient for channels 0 & 1 */
    float    mat_color[2][4];    /* RGBA material color for channels 0 & 1 */
    uint32_t chan_enable[2];     /* Lighting enabled per channel */
    uint32_t light_mask[2];      /* Bitmask of active lights (0..7) */
    
    struct {
        float pos[3];            /* Light position */
        float dir[3];            /* Light direction */
        float color[4];          /* RGBA light color */
        float dist_atten[3];     /* k0, k1, k2 distance attenuation */
        float dir_atten[3];      /* a0, a1, a2 angular attenuation */
    } lights[8];
} ACFP_Cmd_Lighting;
```

### 6.8 `CMD_SET_TEV_STAGE` (`0x0009`)
```c
typedef struct {
    uint8_t  stage;              /* 0 .. 15 */
    uint8_t  color_a, color_b, color_c, color_d;
    uint8_t  alpha_a, alpha_b, alpha_c, alpha_d;
    uint8_t  color_op, color_bias, color_scale, color_clamp, color_out;
    uint8_t  alpha_op, alpha_bias, alpha_scale, alpha_clamp, alpha_out;
    uint8_t  tex_coord, tex_map, color_chan;
    uint8_t  k_color_sel, k_alpha_sel;
    uint8_t  ras_swap, tex_swap;
} ACFP_Cmd_TevStage;
```

### 6.9 `CMD_SET_TEV_REGISTERS` (`0x000A`)
```c
typedef struct {
    float    tev_colors[4][4];   /* PREV, REG0, REG1, REG2 (RGBA) */
    float    tev_k_colors[4][4]; /* K0, K1, K2, K3 (RGBA) */
    uint8_t  swap_table[4][4];   /* 4 swap tables with [R, G, B, A] channel remapping */
} ACFP_Cmd_TevRegisters;
```

### 6.10 `CMD_BIND_TEXTURE` (`0x000B`)
```c
typedef struct {
    uint32_t stage;              /* Texture Unit / Stage Slot (0..7) */
    uint32_t tex_id;             /* ID from Texture Resource Table */
    uint8_t  wrap_s;             /* 0=CLAMP, 1=REPEAT, 2=MIRROR */
    uint8_t  wrap_t;             /* 0=CLAMP, 1=REPEAT, 2=MIRROR */
    uint8_t  min_filter;         /* 0=NEAR, 1=LINEAR */
    uint8_t  mag_filter;         /* 0=NEAR, 1=LINEAR */
} ACFP_Cmd_BindTexture;
```

### 6.11 `CMD_DRAW` (`0x000D`)
```c
typedef struct {
    uint16_t prim_type;          /* GX_TRIANGLES (0x80), GX_QUADS (0x90), GX_TRIANGLESTRIP, etc. */
    uint16_t pass_type;          /* 0 = Opaque, 1 = Transparent/Decal, 2 = UI/2D */
    uint32_t vbo_id;             /* ID from Vertex Buffer Resource Table */
    uint32_t vertex_offset;      /* Start index in vertex buffer */
    uint32_t vertex_count;       /* Number of vertices to render */
} ACFP_Cmd_Draw;
```

### 6.12 `CMD_EFB_COPY` (`0x000E`)
```c
typedef struct {
    uint16_t src_x, src_y, src_w, src_h;  /* Source rectangle in framebuffer */
    uint16_t dst_w, dst_h;                /* Destination resolution */
    uint8_t  format;                      /* Destination texture format */
    uint8_t  clear;                       /* 1 = Clear framebuffer after copy */
    uint8_t  reserved[2];
    uint32_t dest_tex_id;                 /* Assigned destination texture ID for subsequent commands */
} ACFP_Cmd_EfbCopy;
```

---

## 7. Pass Classification & Rendering Order

Within `CMD_DRAW`, each draw call is categorized into one of three logical passes:

1. **`ACFP_PASS_OPAQUE` (0):**
   * Geometry with `z_write_enable == 1` and `blend_mode == GX_BM_NONE` or solid alpha.
   * Rendered first. In Godot 4: standard 3D Forward+ pipeline with full depth testing and shadow/lighting reception.
2. **`ACFP_PASS_TRANSPARENT` (1):**
   * Geometry with `blend_mode == GX_BM_BLEND` or alpha blending (windows, water, smoke, shadow blobs).
   * Rendered after opaque meshes with back-to-front sorting.
3. **`ACFP_PASS_UI` (2):**
   * Orthographic geometry (`proj_type == 1` or Z-test disabled), menus, text boxes, clock overlay.
   * Rendered as screen-space overlay.

---

## 8. File Extension & Memory Representation

* File extension for standalone dumps: `.acfp` (Animal Crossing Frame Packet).
* In-memory streaming: Transfer from the GDExtension bridge to Godot occurs via direct pointer to the contiguous memory block (`const uint8_t* packet_data, size_t size`) for zero-copy performance.

---

## 9. Hybrid EFB Target Extension (2026-11-02)

For headless library capture, `ACFP_CMD_EFB_COPY.reserved[0] == 1` marks `dest_tex_id` as a persistent synthetic target handle (`0x7e000000..0x7e00003f`), rather than a frame-local texture index. The remaining command fields retain their standard semantics.
Texture resources referencing that target carry the hash `0x4546420000000000 | handle` along with a one-pixel black fallback payload. The Godot consumer resolves this namespace against its persistent EFB texture map. Legacy commands (`reserved[0] == 0`) retain prior encoding.

The main loop renders the packet prefix preceding the copy, awaits completed render frames, reads the viewport, crops/resizes the image to the copy target, and stores the resulting texture. Existing target RIDs are replaced in-place so cached materials maintain valid references. The full packet is subsequently dispatched.
Copies occur exclusively on explicit original-game `GXCopyTex` commands. This is currently utilized for the full-screen inventory snapshot, rather than an exhaustive emulation of all GX copy formats, depth copies, clear operations, or scaled source rectangles. Standalone replay of an isolated downstream packet requires the preceding EFB copy frame and its captured texture; the one-pixel fallback does not constitute a self-contained snapshot.
