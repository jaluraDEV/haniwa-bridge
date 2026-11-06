# ACGC Frame Packet Format Specification (v1.0)

## 1. Übersicht & Entwurfsprinzipien

Das **ACGC Frame-Paket** ist ein eigenständiges, versioniertes Binärformat zur vollständigen Erfassung aller Zeichenbefehle und GPU-Zustände eines gerenderten Einzelframes der GameCube-Decompilation *Animal Crossing* (`GAFE01_00`).

### Entwurfsziele:
1. **Verlustfreie Rekonstruktion:** Der Replay-Renderer oder die Godot-Rendering-Engine können aus dem Frame-Paket ein pixel-identisches Bild rendern, ohne die Spiellogik auszuführen.
2. **Resource Deduplication per Hash:** Vertexpuffer und dekodierte Texturen werden in vorgelagerten Ressourcentabellen mit 64-Bit-FNV-1a-Hashes abgelegt. Gleiche Geometrie und Texturen werden innerhalb eines Frames und über Frame-Grenzen hinweg nur einmal übertragen.
3. **Kompaktes Opcode-Kommando-Streaming:** Render-Zustände (Matrizen, TEV-Kombinierer, Blending, Z-Puffer, Beleuchtung, Viewports) werden als sequenzieller Befehlsstrom (`Command Stream`) aufgezeichnet.
4. **Pass-Klassifizierung:** Jeder Drawcall ist einem Render-Pass zugeordnet (Opak, Transparent/Decal, UI/Orthografisch), um Godot eine optimale Sortierung und Beleuchtungsintegration zu ermöglichen.

---

## 2. Binäres Gesamtlayout

Eine Frame-Paket-Datei (`.acfp`) bzw. ein In-Memory-Paket besteht aus 4 aufeinanderfolgenden Abschnitten:

```
┌──────────────────────────────────────────────────────────┐
│ 1. Frame Header (64 Bytes)                              │
│    Magic: 'ACFP', Version: 1, Frame-ID, Auflösung,       │
│    Tabellen-Offsets und Längen                           │
├──────────────────────────────────────────────────────────┤
│ 2. Texture Resource Table                                │
│    Array von Textur-Headern (Breite, Höhe, Format, Hash) │
│    + dekodierte RGBA8-Pixeldaten                         │
├──────────────────────────────────────────────────────────┤
│ 3. Vertex Buffer Resource Table                          │
│    Array von VBO-Headern (Vertex-Count, Stride, Hash)    │
│    + 64-Byte PCGXVertex Array                            │
├──────────────────────────────────────────────────────────┤
│ 4. Command Stream                                        │
│    Sequenz von Befehlen: [Opcode (u16)][Payload...]      │
│    Terminiert durch CMD_END_FRAME (0xFFFF)               │
└──────────────────────────────────────────────────────────┘
```

Alle Multibyte-Werte liegen im **Little-Endian**-Format (Host-Format für x86_32 / Godot).

---

## 3. Datenstrukturen & Header

### 3.1 Frame Header (`ACFPHeader`, 64 Bytes)

```c
typedef struct {
    char     magic[4];            /* "ACFP" (0x50464341) */
    uint32_t version;             /* 1 */
    uint32_t frame_index;         /* Fortlaufender Frame-Zähler */
    uint32_t tick_count;          /* Logischer 60-Hz Zeitschritt */
    uint32_t width;               /* z. B. 640 */
    uint32_t height;              /* z. B. 480 */
    float    clear_color[4];      /* RGBA Clear-Farbe */
    float    clear_depth;         /* Default 1.0f */
    
    /* Offsets und Größen der Abschnitte */
    uint32_t tex_table_offset;    /* Byte-Offset zur Texturtabelle */
    uint32_t tex_table_count;     /* Anzahl Texturen im Frame */
    uint32_t vbo_table_offset;    /* Byte-Offset zur Vertexpuffertabelle */
    uint32_t vbo_table_count;     /* Anzahl Vertexpuffer im Frame */
    uint32_t cmd_stream_offset;   /* Byte-Offset zum Befehlsstrom */
    uint32_t cmd_stream_size;     /* Gesamtlänge des Befehlsstroms in Bytes */
    
    uint32_t reserved[2];         /* 0-Padding für 64-Byte Ausrichtung */
} ACFPHeader;
```

---

## 4. Ressourcentabellen

### 4.1 Textur-Ressourcentabelle (`ACFPTextureHeader`)

Jede Textur wird im Paket als 32-Bit RGBA8 dekodiert abgelegt:

```c
typedef struct {
    uint32_t tex_id;              /* Lokale ID für diesen Frame */
    uint64_t hash;                /* 64-Bit FNV-1a Content-Hash */
    uint16_t width;               /* Texturbreite in Pixeln */
    uint16_t height;              /* Texturhöhe in Pixeln */
    uint8_t  original_format;     /* GameCube GXTexFmt (z. B. GX_TF_RGB5A3, CI4) */
    uint8_t  mipmaps;             /* 1 wenn keine Mipmaps */
    uint8_t  reserved[2];
    uint32_t data_offset;         /* Offset zu RGBA8 Pixeldaten (relativ zu tex_table_offset) */
    uint32_t data_size;           /* width * height * 4 */
} ACFPTextureHeader;
```

### 4.2 Vertexpuffer-Ressourcentabelle (`ACFPVertexBufferHeader`)

Vertexdaten nutzen das standardisierte 64-Byte Format des PC-Backends:

```c
typedef struct {
    float    position[3];         /* X, Y, Z (12 Bytes) */
    float    normal[3];           /* Nx, Ny, Nz (12 Bytes) */
    uint8_t  color0[4];           /* R, G, B, A (4 Bytes) */
    uint8_t  color1[4];           /* R, G, B, A (4 Bytes) */
    float    texcoord[8][2];      /* UV-Koordinaten für bis zu 8 Texturen (64 Bytes -> 32 Bytes für 8x2) */
} ACFPVertex; /* 64 Bytes Gesamtgröße */

typedef struct {
    uint32_t vbo_id;              /* Lokale Puffer-ID */
    uint64_t hash;                /* 64-Bit FNV-1a Hash über Vertexdaten */
    uint32_t vertex_count;        /* Anzahl Vertices */
    uint32_t stride;              /* sizeof(ACFPVertex) = 64 */
    uint32_t data_offset;         /* Offset zum Vertex-Array (relativ zu vbo_table_offset) */
    uint32_t data_size;           /* vertex_count * stride */
} ACFPVertexBufferHeader;
```

---

## 5. Befehlsstrom (`Command Stream`)

Der Befehlsstrom besteht aus einer Folge von typisierten Befehlen:
`[uint16_t opcode][uint16_t payload_size][payload...]`

### 5.1 Opcode-Definitionen

| Opcode | Name | Beschreibung |
|:---|:---|:---|
| `0x0001` | `CMD_SET_VIEWPORT_SCISSOR` | Viewport & Scissor Rechtecke |
| `0x0002` | `CMD_SET_PROJECTION` | 4x4 Projektionsmatrix & Typ (Persp / Ortho) |
| `0x0003` | `CMD_SET_TRANSFORMS` | Slot, ModelView- (3x4), Normal- (3x3), Tex-Matrix (3x4) |
| `0x0004` | `CMD_SET_DEPTH_BLEND` | Z-Test, Z-Write, Z-Func, Blending, Color- & Alpha-Mask |
| `0x0005` | `CMD_SET_ALPHA_TEST` | Alpha-Compare Funktionen & Schwellenwerte |
| `0x0006` | `CMD_SET_CULL` | Culling-Modus (None, Front, Back, All) |
| `0x0007` | `CMD_SET_FOG` | Linearer GX-Nebel: Typ, Start, Ende, Near, Far, Farbe |
| `0x0008` | `CMD_SET_LIGHTING` | Kanalsteuerungen, Ambient-, Materialfarben, 8 GX-Lichter |
| `0x0009` | `CMD_SET_TEV_STAGE` | Vollständige Konfiguration einer TEV-Stage (0–15) |
| `0x000A` | `CMD_SET_TEV_REGISTERS` | Konstante TEV-Register PREV, REG0..2, K0..K3, Swap-Tables |
| `0x000B` | `CMD_BIND_TEXTURE` | Texturbindung an Stage: `tex_id`, Wrap S/T, Min/Mag Filter |
| `0x000C` | `CMD_SET_INDIRECT` | Indirekte Texturierung (Stages, Order, Ind-Matrizen, Scales) |
| `0x000D` | `CMD_DRAW` | Drawcall: Primitivtyp, VBO-ID, Offset, Count, Pass |
| `0x000E` | `CMD_EFB_COPY` | Framebuffer-Kopie (Quelle, Ziel, Clear-Flag, Format) |
| `0xFFFF` | `CMD_END_FRAME` | Ende des Frames |

---

## 6. Detaildefinitionen der Befehls-Payloads

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
    float    matrix[4][4];       /* 4x4 Projektionsmatrix */
} ACFP_Cmd_Projection;
```

### 6.3 `CMD_SET_TRANSFORMS` (`0x0003`)
```c
typedef struct {
    uint32_t mtx_slot;           /* 0..9 (Aktiver Matrix-Index) */
    float    pos_mtx[3][4];      /* ModelView Matrix (3 Zeilen x 4 Spalten) */
    float    nrm_mtx[3][3];      /* Inverse-Transpose Normalenmatrix */
    float    tex_mtx[3][4];      /* Texturgenerierungsmatrix */
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
    uint8_t  blend_src;          /* GXBlendFactor (z. B. SRC_ALPHA, ONE) */
    uint8_t  blend_dst;          /* GXBlendFactor (z. B. INV_SRC_ALPHA, ZERO) */
    uint8_t  blend_logic_op;     /* GXLogicOp */
    
    uint8_t  color_mask;         /* RGB Write Mask (1=Enable, 0=Disable) */
    uint8_t  alpha_mask;         /* Alpha Write Mask (1=Enable, 0=Disable) */
    uint8_t  reserved[2];
} ACFP_Cmd_DepthBlend;
```

### 6.5 `CMD_SET_ALPHA_TEST` (`0x0005`)
```c
typedef struct {
    uint8_t  comp0;              /* GXCompare für Schwellenwert 0 */
    uint8_t  ref0;               /* Referenzwert 0 (0..255) */
    uint8_t  op;                 /* 0=AND, 1=OR, 2=XOR, 3=XNOR */
    uint8_t  comp1;              /* GXCompare für Schwellenwert 1 */
    uint8_t  ref1;               /* Referenzwert 1 (0..255) */
    uint8_t  reserved[3];
} ACFP_Cmd_AlphaTest;
```

### 6.6 `CMD_SET_FOG` (`0x0007`)
```c
typedef struct {
    uint32_t type;               /* 0 = Aus, >0 = Linearer GX-Nebel */
    float    start_z;            /* Startdistanz in Weltkoordinaten */
    float    end_z;              /* Enddistanz */
    float    near_z;             /* Kamera Near Plane */
    float    far_z;              /* Kamera Far Plane */
    float    color[4];           /* Nebelfarbe (RGBA) */
} ACFP_Cmd_Fog;
```

### 6.7 `CMD_SET_LIGHTING` (`0x0008`)
```c
typedef struct {
    uint32_t num_chans;          /* Anzahl aktiver Farbkanäle */
    float    amb_color[2][4];    /* RGBA Ambient für Kanal 0 & 1 */
    float    mat_color[2][4];    /* RGBA Materialfarbe für Kanal 0 & 1 */
    uint32_t chan_enable[2];     /* Beleuchtung aktiv pro Kanal */
    uint32_t light_mask[2];      /* Bitmaske aktiver Lichter (0..7) */
    
    struct {
        float pos[3];            /* Lichtposition */
        float dir[3];            /* Lichtrichtung */
        float color[4];          /* RGBA Lichtfarbe */
        float dist_atten[3];     /* k0, k1, k2 Distanzdämpfung */
        float dir_atten[3];      /* a0, a1, a2 Winkeldämpfung */
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
    uint8_t  swap_table[4][4];   /* 4 Swap-Tabellen mit je [R, G, B, A] Kanal-Remapping */
} ACFP_Cmd_TevRegisters;
```

### 6.10 `CMD_BIND_TEXTURE` (`0x000B`)
```c
typedef struct {
    uint32_t stage;              /* Texture Unit / Stage Slot (0..7) */
    uint32_t tex_id;             /* ID aus der Texture Resource Table */
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
    uint32_t vbo_id;             /* ID aus der Vertex Buffer Resource Table */
    uint32_t vertex_offset;      /* Start-Index im Vertexpuffer */
    uint32_t vertex_count;       /* Anzahl zu rendernder Vertices */
} ACFP_Cmd_Draw;
```

### 6.12 `CMD_EFB_COPY` (`0x000E`)
```c
typedef struct {
    uint16_t src_x, src_y, src_w, src_h;  /* Quell-Rechteck im Framebuffer */
    uint16_t dst_w, dst_h;                /* Ziel-Auflösung */
    uint8_t  format;                      /* Ziel-Texturformat */
    uint8_t  clear;                       /* 1 = Framebuffer nach Kopie leeren */
    uint8_t  reserved[2];
    uint32_t dest_tex_id;                 /* Zugewiesene Zieltextur-ID für Folgebefehle */
} ACFP_Cmd_EfbCopy;
```

---

## 7. Pass-Klassifizierung & Rendering-Reihenfolge

Im `CMD_DRAW`-Befehl wird jeder Drawcall in einen von drei logischen Passes kategorisiert:

1. **`ACFP_PASS_OPAQUE` (0):**
   * Geometrie mit `z_write_enable == 1` und `blend_mode == GX_BM_NONE` oder solidem Alpha.
   * Wird zuerst gerendert. In Godot 4: Standard 3D PBR/Unshaded Pipeline mit voller Tiefenprüfung, Licht- und Schattenempfang.
2. **`ACFP_PASS_TRANSPARENT` (1):**
   * Geometrie mit `blend_mode == GX_BM_BLEND` oder Alpha-Blending (Fenster, Wasser, Rauch, Schatten-Blobs).
   * Wird nach den opaken Meshes mit Back-to-Front-Sortierung gerendert.
3. **`ACFP_PASS_UI` (2):**
   * Orthografische Geometrie (`proj_type == 1` oder Z-Test deaktiviert), Menüs, Textboxen, Uhrenanzeige.
   * Wird als Overlay im Screen-Space gerendert.

---

## 8. Dateiendung & Speicherform

* Dateiendung für Frame-Dumps: `.acfp` (Animal Crossing Frame Packet).
* In-Memory Streaming: Übertragung von der GDExtension-Bridge an Godot erfolgt als direkter Pointer auf den zusammenhängenden Speicherblock (`const uint8_t* packet_data, size_t size`) für Zero-Copy-Performance.


## Hybrid EFB target extension (2026-11-02)

For headless library capture, `ACFP_CMD_EFB_COPY.reserved[0] == 1` marks
`dest_tex_id` as a persistent synthetic target handle (`0x7e000000..0x7e00003f`),
not a frame-local texture index. The other command fields retain their meaning.
Texture resources referring to that target carry hash
`0x4546420000000000 | handle` and a one-pixel black fallback payload. The Godot
consumer resolves this namespace against its persistent EFB texture map.
Legacy commands (`reserved[0] == 0`) retain the previous encoding.

The main loop renders the packet prefix preceding the copy, waits for completed
render frames, reads the viewport, crops/resizes the image to the copy target,
and stores the texture. Existing target RIDs are replaced in place so cached
materials keep valid references. The normal full packet is then submitted.
Copies occur only on explicit original-game GXCopyTex commands. This is currently
intended for the full-screen inventory snapshot, not a general implementation of
all GX copy formats, depth copies, clear operations or scaled source rectangles.
Standalone replay of a later isolated packet needs the earlier EFB copy frame
and its saved image; the one-pixel fallback is not a self-contained snapshot.
