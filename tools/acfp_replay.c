/* tools/acfp_replay.c - Standalone OpenGL Replay-Renderer for ACFP frame packets */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>

#define SDL_MAIN_HANDLED
#include <glad/gl.h>
#include <SDL2/SDL.h>

#include "acgc_frame_packet.h"

#define MAX_TEX_SLOTS 256
#define MAX_VBO_SLOTS 4096
#define MAX_QUAD_VERTS 65536

static GLuint s_gl_textures[MAX_TEX_SLOTS];
static uint32_t s_num_gl_textures = 0;

static GLuint s_gl_vbos[MAX_VBO_SLOTS];
static uint32_t s_num_gl_vbos = 0;

static GLuint s_quad_ebo = 0;
static GLuint s_vao = 0;

/* Uniform locations */
typedef struct {
    GLint projection;
    GLint modelview;
    GLint normal_mtx;
    GLint tev_prev, tev_reg0, tev_reg1, tev_reg2;
    GLint num_tev_stages;
    GLint tev_color_in0, tev_alpha_in0;
    GLint tev_color_op0, tev_alpha_op0;
    GLint tev_tc_src0, tev_bsc0, tev_out0, tev_swap0;
    GLint kcolor, tev_ksel;
    GLint alpha_ctrl, alpha_refs;
    GLint lighting_enabled, alpha_lighting_enabled;
    GLint mat_color, light_pos0, light_color0;
    GLint texmtx_enable0, texmtx_row0, texmtx_row1, texgen_src0;
    GLint use_texture0;
    GLint texture0, texture1, texture2;
    GLint swap_table;
    GLint fog_enable, fog_params, fog_color;
    GLint num_ind_stages;
    GLint debug_color;
} ReplayUloc;

static ReplayUloc s_uloc;
static GLuint     s_program = 0;

/* TEV CPU tracking matching pc_gx.c */
static int               s_num_tev_stages = 1;
static ACFP_Cmd_TevStage s_tev_stages[3];
static int               s_use_texture[3] = { 0, 0, 0 };
static int               s_tev_dirty = 1;

static char* read_file_text(const char* filepath) {
    FILE* f = fopen(filepath, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    char* buf = (char*)malloc(sz + 1);
    if (!buf) { fclose(f); return NULL; }
    fread(buf, 1, sz, f);
    buf[sz] = '\0';
    fclose(f);
    return buf;
}

static GLuint compile_shader(GLenum type, const char* src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetShaderInfoLog(s, sizeof(log), NULL, log);
        fprintf(stderr, "[Replay] Shader compile error: %s\n", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

static GLuint build_program(const char* vert_path, const char* frag_path) {
    char* vs_src = read_file_text(vert_path);
    char* fs_src = read_file_text(frag_path);
    if (!vs_src || !fs_src) {
        fprintf(stderr, "[Replay] Failed to load shader files: %s, %s\n", vert_path, frag_path);
        if (vs_src) free(vs_src);
        if (fs_src) free(fs_src);
        return 0;
    }

    GLuint vs = compile_shader(GL_VERTEX_SHADER, vs_src);
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, fs_src);
    free(vs_src);
    free(fs_src);

    if (!vs || !fs) return 0;

    GLuint prog = glCreateProgram();
    glAttachShader(prog, vs);
    glAttachShader(prog, fs);

    glBindAttribLocation(prog, 0, "a_position");
    glBindAttribLocation(prog, 1, "a_normal");
    glBindAttribLocation(prog, 2, "a_color0");
    glBindAttribLocation(prog, 3, "a_texcoord0");

    glLinkProgram(prog);
    GLint ok;
    glGetProgramiv(prog, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[1024];
        glGetProgramInfoLog(prog, sizeof(log), NULL, log);
        fprintf(stderr, "[Replay] Program link error: %s\n", log);
        glDeleteProgram(prog);
        return 0;
    }

    glDeleteShader(vs);
    glDeleteShader(fs);
    return prog;
}

static void cache_ulocs(GLuint prog, ReplayUloc* u) {
    #define UL(name) glGetUniformLocation(prog, name)
    u->projection = UL("u_projection");
    u->modelview  = UL("u_modelview");
    u->normal_mtx = UL("u_normal_mtx");

    u->tev_prev = UL("u_tev_prev");
    u->tev_reg0 = UL("u_tev_reg0");
    u->tev_reg1 = UL("u_tev_reg1");
    u->tev_reg2 = UL("u_tev_reg2");

    u->num_tev_stages = UL("u_num_tev_stages");
    u->tev_color_in0  = UL("u_tev_color_in[0]");
    u->tev_alpha_in0  = UL("u_tev_alpha_in[0]");
    u->tev_color_op0  = UL("u_tev_color_op[0]");
    u->tev_alpha_op0  = UL("u_tev_alpha_op[0]");
    u->tev_tc_src0    = UL("u_tev_tc_src[0]");
    u->tev_bsc0       = UL("u_tev_bsc[0]");
    u->tev_out0       = UL("u_tev_out[0]");
    u->tev_swap0      = UL("u_tev_swap[0]");

    u->kcolor   = UL("u_kcolor");
    u->tev_ksel = UL("u_tev_ksel");
    u->swap_table = UL("u_swap_table");

    u->alpha_ctrl = UL("u_alpha_ctrl");
    u->alpha_refs = UL("u_alpha_refs");

    u->lighting_enabled = UL("u_lighting_cfg0");
    u->alpha_lighting_enabled = UL("u_lighting_cfg1");
    u->mat_color   = UL("u_chan_color[0]");
    u->light_pos0   = UL("u_light_pos[0]");
    u->light_color0 = UL("u_light_color[0]");

    u->texmtx_enable0 = UL("u_texmtx_enable[0]");
    u->texmtx_row0    = UL("u_texmtx_row0[0]");
    u->texmtx_row1    = UL("u_texmtx_row1[0]");
    u->texgen_src0    = UL("u_texgen_src[0]");

    u->use_texture0 = UL("u_use_texture[0]");
    u->texture0     = UL("u_texture0");
    u->texture1     = UL("u_texture1");
    u->texture2     = UL("u_texture2");

    u->fog_enable = UL("u_fog_enable");
    u->fog_params = UL("u_fog_params");
    u->fog_color  = UL("u_fog_color");
    u->num_ind_stages = UL("u_num_ind_stages");
    u->debug_color = UL("u_debug_color");
    #undef UL
}

static void flush_tev_stages(void) {
    if (!s_tev_dirty) return;

    GLint color_in[3][4];
    GLint alpha_in[3][4];
    GLint color_op[3];
    GLint alpha_op[3];
    GLint bsc[3][4];
    GLint out_cfg[3][4];
    GLint swap[3][2];
    GLint ksel[3][3];
    GLint tc_src[3];

    for (int s = 0; s < 3; s++) {
        ACFP_Cmd_TevStage* ts = &s_tev_stages[s];
        color_in[s][0] = ts->color_a;
        color_in[s][1] = ts->color_b;
        color_in[s][2] = ts->color_c;
        color_in[s][3] = ts->color_d;
        alpha_in[s][0] = ts->alpha_a;
        alpha_in[s][1] = ts->alpha_b;
        alpha_in[s][2] = ts->alpha_c;
        alpha_in[s][3] = ts->alpha_d;
        color_op[s] = ts->color_op;
        alpha_op[s] = ts->alpha_op;
        bsc[s][0] = ts->color_bias;
        bsc[s][1] = ts->color_scale;
        bsc[s][2] = ts->alpha_bias;
        bsc[s][3] = ts->alpha_scale;
        out_cfg[s][0] = ts->color_clamp;
        out_cfg[s][1] = ts->alpha_clamp;
        out_cfg[s][2] = ts->color_out;
        out_cfg[s][3] = ts->alpha_out;
        swap[s][0] = ts->ras_swap;
        swap[s][1] = ts->tex_swap;
        ksel[s][0] = ts->k_color_sel;
        ksel[s][1] = ts->k_alpha_sel;
        ksel[s][2] = s;
        if (s < s_num_tev_stages) {
            int tc = ts->tex_coord;
            if (tc < 0 || tc >= 8) tc = s;
            if (tc > 1) tc = 1;
            tc_src[s] = tc;
        } else {
            tc_src[s] = 0;
        }
    }

    if (s_uloc.tev_color_in0 >= 0) glUniform4iv(s_uloc.tev_color_in0, 3, &color_in[0][0]);
    if (s_uloc.tev_alpha_in0 >= 0) glUniform4iv(s_uloc.tev_alpha_in0, 3, &alpha_in[0][0]);
    if (s_uloc.tev_color_op0 >= 0) glUniform1iv(s_uloc.tev_color_op0, 3, color_op);
    if (s_uloc.tev_alpha_op0 >= 0) glUniform1iv(s_uloc.tev_alpha_op0, 3, alpha_op);
    if (s_uloc.tev_bsc0 >= 0)      glUniform4iv(s_uloc.tev_bsc0, 3, &bsc[0][0]);
    if (s_uloc.tev_out0 >= 0)      glUniform4iv(s_uloc.tev_out0, 3, &out_cfg[0][0]);
    if (s_uloc.tev_swap0 >= 0)     glUniform2iv(s_uloc.tev_swap0, 3, &swap[0][0]);
    if (s_uloc.tev_ksel >= 0)      glUniform3iv(s_uloc.tev_ksel, 3, &ksel[0][0]);
    if (s_uloc.tev_tc_src0 >= 0)   glUniform1iv(s_uloc.tev_tc_src0, 3, tc_src);

    s_tev_dirty = 0;
}

static void save_bmp(const char* filepath, int w, int h, const uint8_t* pixels) {
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

    FILE* f = fopen(filepath, "wb");
    if (!f) {
        fprintf(stderr, "[Replay] Failed to open %s for writing\n", filepath);
        return;
    }
    fwrite(header, 1, 54, f);
    fwrite(pixels, 1, w * h * 4, f);
    fclose(f);
    printf("[Replay] Saved output to %s (%dx%d)\n", filepath, w, h);
}

int main(int argc, char** argv) {
    if (argc < 2) {
        printf("Usage: acfp_replay <frame.acfp> [output.bmp] [shader_dir] [--max-draws N] [--debug-color]\n");
        return 1;
    }

    const char* packet_path = NULL;
    char out_path[256] = "";
    const char* shader_dir = "port/pc/shaders";
    int max_draws = -1;
    int debug_color = 0;

    int pos_idx = 0;
    for (int i = 1; i < argc; i++) {
        // printf("[Arg %d] '%s'\n", i, argv[i]);
        if (strcmp(argv[i], "--max-draws") == 0 && i + 1 < argc) {
            max_draws = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--debug-color") == 0) {
            debug_color = 1;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "[Replay] Unknown option: %s\n", argv[i]);
        } else {
            if (pos_idx == 0) {
                packet_path = argv[i];
            } else if (pos_idx == 1) {
                snprintf(out_path, sizeof(out_path), "%s", argv[i]);
            } else if (pos_idx == 2) {
                shader_dir = argv[i];
            }
            pos_idx++;
        }
    }

    if (!packet_path) {
        printf("Usage: acfp_replay <frame.acfp> [output.bmp] [shader_dir] [--max-draws N] [--debug-color]\n");
        return 1;
    }

    if (out_path[0] == '\0') {
        snprintf(out_path, sizeof(out_path), "%.*s_replay.bmp",
                 (int)(strlen(packet_path) > 5 && strcmp(packet_path + strlen(packet_path) - 5, ".acfp") == 0 ?
                       strlen(packet_path) - 5 : strlen(packet_path)),
                 packet_path);
    }

    FILE* f = fopen(packet_path, "rb");
    if (!f) {
        fprintf(stderr, "[Replay] Cannot open packet file: %s\n", packet_path);
        return 1;
    }

    ACFPHeader hdr;
    if (fread(&hdr, 1, sizeof(hdr), f) != sizeof(hdr)) {
        fprintf(stderr, "[Replay] Failed to read header\n");
        fclose(f);
        return 1;
    }

    if (memcmp(hdr.magic, "ACFP", 4) != 0) {
        fprintf(stderr, "[Replay] Invalid magic: %.4s\n", hdr.magic);
        fclose(f);
        return 1;
    }

    printf("[Replay] Loaded ACFP Packet: Frame %u, Dim %ux%u, %u Tex, %u VBOs, %u Cmd bytes\n",
           hdr.frame_index, hdr.width, hdr.height,
           hdr.tex_table_count, hdr.vbo_table_count, hdr.cmd_stream_size);
    printf("[Replay] Clear Color: (%f, %f, %f, %f)\n",
           hdr.clear_color[0], hdr.clear_color[1], hdr.clear_color[2], hdr.clear_color[3]);

    /* 1. Initialize SDL2 and OpenGL 3.3 Core */
    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        fprintf(stderr, "[Replay] SDL_Init failed: %s\n", SDL_GetError());
        fclose(f);
        return 1;
    }

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);

    SDL_Window* win = SDL_CreateWindow("ACFP Replay", SDL_WINDOWPOS_UNDEFINED, SDL_WINDOWPOS_UNDEFINED,
                                       (int)hdr.width, (int)hdr.height, SDL_WINDOW_OPENGL | SDL_WINDOW_HIDDEN);
    if (!win) {
        fprintf(stderr, "[Replay] SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        fclose(f);
        return 1;
    }

    SDL_GLContext ctx = SDL_GL_CreateContext(win);
    if (!ctx) {
        fprintf(stderr, "[Replay] SDL_GL_CreateContext failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(win);
        SDL_Quit();
        fclose(f);
        return 1;
    }

    if (!gladLoadGL((GLADloadfunc)SDL_GL_GetProcAddress)) {
        fprintf(stderr, "[Replay] Failed to initialize GLAD\n");
        SDL_GL_DeleteContext(ctx);
        SDL_DestroyWindow(win);
        SDL_Quit();
        fclose(f);
        return 1;
    }

    /* 2. Create Offscreen FBO */
    GLuint fbo = 0, fbo_tex = 0, fbo_depth = 0;
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);

    glGenTextures(1, &fbo_tex);
    glBindTexture(GL_TEXTURE_2D, fbo_tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)hdr.width, (GLsizei)hdr.height, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, fbo_tex, 0);

    glGenRenderbuffers(1, &fbo_depth);
    glBindRenderbuffer(GL_RENDERBUFFER, fbo_depth);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, (GLsizei)hdr.width, (GLsizei)hdr.height);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT, GL_RENDERBUFFER, fbo_depth);

    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        fprintf(stderr, "[Replay] Incomplete FBO\n");
    }

    /* 3. Build Shader Program */
    char vert_file[512], frag_file[512];
    snprintf(vert_file, sizeof(vert_file), "%s/default.vert", shader_dir);
    snprintf(frag_file, sizeof(frag_file), "%s/default.frag", shader_dir);

    s_program = build_program(vert_file, frag_file);
    if (!s_program) {
        /* try fallback in current directory shaders/ */
        s_program = build_program("shaders/default.vert", "shaders/default.frag");
    }
    if (!s_program) {
        fprintf(stderr, "[Replay] Failed to compile replay shaders\n");
        return 1;
    }
    glUseProgram(s_program);
    cache_ulocs(s_program, &s_uloc);

    /* Bind samplers */
    if (s_uloc.texture0 >= 0) glUniform1i(s_uloc.texture0, 0);
    if (s_uloc.texture1 >= 0) glUniform1i(s_uloc.texture1, 1);
    if (s_uloc.texture2 >= 0) glUniform1i(s_uloc.texture2, 2);

    /* 4. Setup Quad EBO */
    GLushort quad_indices[(MAX_QUAD_VERTS / 4) * 6];
    for (int q = 0; q < MAX_QUAD_VERTS / 4; q++) {
        GLushort base = (GLushort)(q * 4);
        quad_indices[q * 6 + 0] = base + 0;
        quad_indices[q * 6 + 1] = base + 1;
        quad_indices[q * 6 + 2] = base + 2;
        quad_indices[q * 6 + 3] = base + 0;
        quad_indices[q * 6 + 4] = base + 2;
        quad_indices[q * 6 + 5] = base + 3;
    }
    glGenBuffers(1, &s_quad_ebo);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, s_quad_ebo);
    glBufferData(GL_ELEMENT_ARRAY_BUFFER, sizeof(quad_indices), quad_indices, GL_STATIC_DRAW);

    /* 5. Load and Upload Textures */
    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    fseek(f, hdr.tex_table_offset, SEEK_SET);
    s_num_gl_textures = hdr.tex_table_count;
    if (s_num_gl_textures > MAX_TEX_SLOTS) s_num_gl_textures = MAX_TEX_SLOTS;

    ACFPTextureHeader* tex_hdrs = (ACFPTextureHeader*)malloc(s_num_gl_textures * sizeof(ACFPTextureHeader));
    fread(tex_hdrs, sizeof(ACFPTextureHeader), s_num_gl_textures, f);

    long tex_data_base = hdr.tex_table_offset + hdr.tex_table_count * sizeof(ACFPTextureHeader);

    for (uint32_t i = 0; i < s_num_gl_textures; i++) {
        fseek(f, tex_data_base + tex_hdrs[i].data_offset, SEEK_SET);
        uint8_t* pix = (uint8_t*)malloc(tex_hdrs[i].data_size);
        fread(pix, 1, tex_hdrs[i].data_size, f);

        glGenTextures(1, &s_gl_textures[i]);
        glBindTexture(GL_TEXTURE_2D, s_gl_textures[i]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, tex_hdrs[i].width, tex_hdrs[i].height, 0,
                     GL_RGBA, GL_UNSIGNED_BYTE, pix);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
        free(pix);
    }
    free(tex_hdrs);

    /* 6. Load and Upload VBOs */
    fseek(f, hdr.vbo_table_offset, SEEK_SET);
    s_num_gl_vbos = hdr.vbo_table_count;
    if (s_num_gl_vbos > MAX_VBO_SLOTS) s_num_gl_vbos = MAX_VBO_SLOTS;

    ACFPVertexBufferHeader* vbo_hdrs = (ACFPVertexBufferHeader*)malloc(s_num_gl_vbos * sizeof(ACFPVertexBufferHeader));
    fread(vbo_hdrs, sizeof(ACFPVertexBufferHeader), s_num_gl_vbos, f);

    long vbo_data_base = hdr.vbo_table_offset + hdr.vbo_table_count * sizeof(ACFPVertexBufferHeader);

    glGenVertexArrays(1, &s_vao);
    glBindVertexArray(s_vao);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, s_quad_ebo);

    for (uint32_t i = 0; i < s_num_gl_vbos; i++) {
        fseek(f, vbo_data_base + vbo_hdrs[i].data_offset, SEEK_SET);
        uint8_t* vdata = (uint8_t*)malloc(vbo_hdrs[i].data_size);
        fread(vdata, 1, vbo_hdrs[i].data_size, f);

        glGenBuffers(1, &s_gl_vbos[i]);
        glBindBuffer(GL_ARRAY_BUFFER, s_gl_vbos[i]);
        glBufferData(GL_ARRAY_BUFFER, vbo_hdrs[i].data_size, vdata, GL_STATIC_DRAW);
        free(vdata);
    }
    free(vbo_hdrs);

    /* 7. Read Command Stream into Memory */
    fseek(f, hdr.cmd_stream_offset, SEEK_SET);
    uint8_t* cmd_stream = (uint8_t*)malloc(hdr.cmd_stream_size);
    fread(cmd_stream, 1, hdr.cmd_stream_size, f);
    fclose(f);

    /* 8. Initial GL State */
    glDisable(GL_SCISSOR_TEST);
    glViewport(0, 0, (GLsizei)hdr.width, (GLsizei)hdr.height);
    glClearColor(hdr.clear_color[0], hdr.clear_color[1], hdr.clear_color[2], hdr.clear_color[3]);
    glClearDepth(hdr.clear_depth);
    glDepthMask(GL_TRUE);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    GLint init_texmtx_enable[2] = { 0, 0 };
    GLint init_texgen_src[2] = { 4, 4 };
    if (s_uloc.texmtx_enable0 >= 0) glUniform1iv(s_uloc.texmtx_enable0, 2, init_texmtx_enable);
    if (s_uloc.texgen_src0 >= 0)    glUniform1iv(s_uloc.texgen_src0, 2, init_texgen_src);
    if (s_uloc.use_texture0 >= 0)   glUniform1iv(s_uloc.use_texture0, 3, s_use_texture);

    /* 9. Execute Command Stream */
    uint32_t cmd_ptr = 0;
    uint32_t draw_count = 0;

    while (cmd_ptr + sizeof(ACFPCommandHeader) <= hdr.cmd_stream_size) {
        ACFPCommandHeader* ch = (ACFPCommandHeader*)(cmd_stream + cmd_ptr);
        uint8_t* payload = cmd_stream + cmd_ptr + sizeof(ACFPCommandHeader);
        cmd_ptr += sizeof(ACFPCommandHeader) + ch->payload_size;

        switch (ch->opcode) {
            case ACFP_CMD_SET_VIEWPORT_SCISSOR: {
                ACFP_Cmd_ViewportScissor* vp = (ACFP_Cmd_ViewportScissor*)payload;
                GLint gl_x = (GLint)vp->x;
                GLint gl_w = (GLint)vp->w;
                GLint gl_h = (GLint)vp->h;
                GLint gl_y = (GLint)hdr.height - (GLint)vp->y - gl_h;
                glViewport(gl_x, gl_y, gl_w, gl_h);
                glDepthRange((double)vp->near_z, (double)vp->far_z);

                if (vp->sc_w > 0 && vp->sc_h > 0) {
                    glEnable(GL_SCISSOR_TEST);
                    GLint sy = (GLint)hdr.height - ((GLint)vp->sc_top + (GLint)vp->sc_h);
                    if (sy < 0) sy = 0;
                    glScissor((GLint)vp->sc_left, sy, (GLsizei)vp->sc_w, (GLsizei)vp->sc_h);
                } else {
                    glDisable(GL_SCISSOR_TEST);
                }
                break;
            }
            case ACFP_CMD_SET_PROJECTION: {
                ACFP_Cmd_Projection* pr = (ACFP_Cmd_Projection*)payload;
                if (s_uloc.projection >= 0) {
                    glUniformMatrix4fv(s_uloc.projection, 1, GL_TRUE, (const float*)pr->matrix);
                }
                break;
            }
            case ACFP_CMD_SET_TRANSFORMS: {
                ACFP_Cmd_Transforms* tr = (ACFP_Cmd_Transforms*)payload;
                float mv44[16];
                mv44[0] = tr->pos_mtx[0][0]; mv44[1] = tr->pos_mtx[0][1]; mv44[2] = tr->pos_mtx[0][2]; mv44[3] = tr->pos_mtx[0][3];
                mv44[4] = tr->pos_mtx[1][0]; mv44[5] = tr->pos_mtx[1][1]; mv44[6] = tr->pos_mtx[1][2]; mv44[7] = tr->pos_mtx[1][3];
                mv44[8] = tr->pos_mtx[2][0]; mv44[9] = tr->pos_mtx[2][1]; mv44[10]= tr->pos_mtx[2][2]; mv44[11]= tr->pos_mtx[2][3];
                mv44[12]= 0.0f;              mv44[13]= 0.0f;              mv44[14]= 0.0f;              mv44[15]= 1.0f;

                if (s_uloc.modelview >= 0) glUniformMatrix4fv(s_uloc.modelview, 1, GL_TRUE, mv44);
                if (s_uloc.normal_mtx >= 0) glUniformMatrix3fv(s_uloc.normal_mtx, 1, GL_TRUE, (float*)tr->nrm_mtx);
                break;
            }
            case ACFP_CMD_SET_TEXGEN: {
                ACFP_Cmd_TexGen* tg = (ACFP_Cmd_TexGen*)payload;
                GLint en[2] = { (GLint)tg->texmtx_enable[0], (GLint)tg->texmtx_enable[1] };
                GLint src[2] = { (GLint)tg->texgen_src[0], (GLint)tg->texgen_src[1] };
                if (s_uloc.texmtx_enable0 >= 0) glUniform1iv(s_uloc.texmtx_enable0, 2, en);
                if (s_uloc.texgen_src0 >= 0)    glUniform1iv(s_uloc.texgen_src0, 2, src);
                if (s_uloc.texmtx_row0 >= 0)    glUniform4fv(s_uloc.texmtx_row0, 2, &tg->texmtx_row0[0][0]);
                if (s_uloc.texmtx_row1 >= 0)    glUniform4fv(s_uloc.texmtx_row1, 2, &tg->texmtx_row1[0][0]);
                break;
            }
            case ACFP_CMD_SET_DEPTH_BLEND: {
                ACFP_Cmd_DepthBlend* db = (ACFP_Cmd_DepthBlend*)payload;
                if (db->z_test_enable) {
                    glEnable(GL_DEPTH_TEST);
                    GLenum zfunc = GL_LEQUAL;
                    switch (db->z_func) {
                        case 0: zfunc = GL_NEVER; break;
                        case 1: zfunc = GL_LESS; break;
                        case 2: zfunc = GL_EQUAL; break;
                        case 3: zfunc = GL_LEQUAL; break;
                        case 4: zfunc = GL_GREATER; break;
                        case 5: zfunc = GL_NOTEQUAL; break;
                        case 6: zfunc = GL_GEQUAL; break;
                        case 7: zfunc = GL_ALWAYS; break;
                    }
                    glDepthFunc(zfunc);
                } else {
                    glDisable(GL_DEPTH_TEST);
                }
                glDepthMask(db->z_write_enable ? GL_TRUE : GL_FALSE);

                glColorMask(db->color_mask ? GL_TRUE : GL_FALSE,
                            db->color_mask ? GL_TRUE : GL_FALSE,
                            db->color_mask ? GL_TRUE : GL_FALSE,
                            db->alpha_mask ? GL_TRUE : GL_FALSE);

                switch (db->cull_mode) {
                    case 0: glDisable(GL_CULL_FACE); break;
                    case 1: glEnable(GL_CULL_FACE); glCullFace(GL_FRONT); break;
                    case 2: glEnable(GL_CULL_FACE); glCullFace(GL_BACK); break;
                    case 3: glEnable(GL_CULL_FACE); glCullFace(GL_FRONT_AND_BACK); break;
                }

                glBlendEquation(db->blend_mode == 3 ? GL_FUNC_REVERSE_SUBTRACT : GL_FUNC_ADD);
                if (db->blend_mode == 1 || db->blend_mode == 3) {
                    glEnable(GL_BLEND);
                    GLenum src = GL_SRC_ALPHA, dst = GL_ONE_MINUS_SRC_ALPHA;
                    static const GLenum s_blend_factors[] = {
                        GL_ZERO, GL_ONE, GL_SRC_COLOR, GL_ONE_MINUS_SRC_COLOR,
                        GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_DST_ALPHA, GL_ONE_MINUS_DST_ALPHA
                    };
                    if (db->blend_src < 8) src = s_blend_factors[db->blend_src];
                    if (db->blend_dst < 8) dst = s_blend_factors[db->blend_dst];
                    if (db->blend_src == 6 && db->blend_dst == 7) {
                        src = GL_SRC_ALPHA; dst = GL_ONE_MINUS_SRC_ALPHA;
                    }
                    glBlendFunc(src, dst);
                } else {
                    glDisable(GL_BLEND);
                }
                break;
            }
            case ACFP_CMD_SET_ALPHA_TEST: {
                ACFP_Cmd_AlphaTest* at = (ACFP_Cmd_AlphaTest*)payload;
                GLint ctrl[3] = { at->comp0, at->op, at->comp1 };
                GLint refs[2] = { at->ref0, at->ref1 };
                if (s_uloc.alpha_ctrl >= 0) glUniform3iv(s_uloc.alpha_ctrl, 1, ctrl);
                if (s_uloc.alpha_refs >= 0) glUniform2iv(s_uloc.alpha_refs, 1, refs);
                break;
            }
            case ACFP_CMD_SET_FOG: {
                ACFP_Cmd_Fog* fg = (ACFP_Cmd_Fog*)payload;
                if (s_uloc.fog_enable >= 0) glUniform1i(s_uloc.fog_enable, fg->type != 0);
                if (s_uloc.fog_params >= 0) {
                    float p[4] = { (float)fg->type, fg->start_z, fg->end_z, 0.0f };
                    glUniform4fv(s_uloc.fog_params, 1, p);
                }
                if (s_uloc.fog_color >= 0) glUniform4fv(s_uloc.fog_color, 1, fg->color);
                break;
            }
            case ACFP_CMD_SET_LIGHTING: {
                ACFP_Cmd_Lighting* lt = (ACFP_Cmd_Lighting*)payload;
                GLint cfg0[4] = { (GLint)lt->chan_enable[0], (GLint)lt->chan_mat_src[0], (GLint)lt->chan_amb_src[0], (GLint)lt->num_chans };
                GLint cfg1[4] = { (GLint)lt->chan_enable[1], (GLint)lt->chan_mat_src[1], (GLint)lt->light_mask[0], 0 };
                if (s_uloc.lighting_enabled >= 0) glUniform4iv(s_uloc.lighting_enabled, 1, cfg0);
                if (s_uloc.alpha_lighting_enabled >= 0) glUniform4iv(s_uloc.alpha_lighting_enabled, 1, cfg1);
                if (s_uloc.mat_color >= 0) {
                    float cc[2][4];
                    memcpy(cc[0], lt->mat_color[0], sizeof(cc[0]));
                    memcpy(cc[1], lt->amb_color[0], sizeof(cc[1]));
                    glUniform4fv(s_uloc.mat_color, 2, &cc[0][0]);
                }
                float lpos[8][3], lcol[8][4];
                for (int i = 0; i < 8; i++) {
                    memcpy(lpos[i], lt->lights[i].pos, sizeof(lpos[i]));
                    memcpy(lcol[i], lt->lights[i].color, sizeof(lcol[i]));
                }
                if (s_uloc.light_pos0 >= 0)   glUniform3fv(s_uloc.light_pos0, 8, &lpos[0][0]);
                if (s_uloc.light_color0 >= 0) glUniform4fv(s_uloc.light_color0, 8, &lcol[0][0]);
                break;
            }
            case ACFP_CMD_SET_TEV_STAGE: {
                ACFP_Cmd_TevStage* ts = (ACFP_Cmd_TevStage*)payload;
                if (ts->stage < 3) {
                    s_tev_stages[ts->stage] = *ts;
                    s_tev_dirty = 1;
                }
                break;
            }
            case ACFP_CMD_SET_TEV_REGISTERS: {
                ACFP_Cmd_TevRegisters* tr = (ACFP_Cmd_TevRegisters*)payload;
                s_num_tev_stages = (int)tr->num_stages;
                if (s_uloc.num_tev_stages >= 0) glUniform1i(s_uloc.num_tev_stages, (GLint)tr->num_stages);
                if (s_uloc.tev_prev >= 0) glUniform4fv(s_uloc.tev_prev, 1, tr->tev_colors[0]);
                if (s_uloc.tev_reg0 >= 0) glUniform4fv(s_uloc.tev_reg0, 1, tr->tev_colors[1]);
                if (s_uloc.tev_reg1 >= 0) glUniform4fv(s_uloc.tev_reg1, 1, tr->tev_colors[2]);
                if (s_uloc.tev_reg2 >= 0) glUniform4fv(s_uloc.tev_reg2, 1, tr->tev_colors[3]);
                if (s_uloc.kcolor >= 0)   glUniform4fv(s_uloc.kcolor, 4, (const float*)tr->tev_k_colors);

                if (s_uloc.swap_table >= 0) {
                    int sw[16];
                    for (int t = 0; t < 4; t++) {
                        sw[t*4+0] = tr->swap_table[t][0];
                        sw[t*4+1] = tr->swap_table[t][1];
                        sw[t*4+2] = tr->swap_table[t][2];
                        sw[t*4+3] = tr->swap_table[t][3];
                    }
                    glUniform4iv(s_uloc.swap_table, 4, sw);
                }
                s_tev_dirty = 1;
                break;
            }
            case ACFP_CMD_BIND_TEXTURE: {
                ACFP_Cmd_BindTexture* bt = (ACFP_Cmd_BindTexture*)payload;
                if (bt->stage < 3) {
                    if (bt->tex_id != 0xFFFFFFFF && bt->tex_id < s_num_gl_textures) {
                        glActiveTexture(GL_TEXTURE0 + bt->stage);
                        glBindTexture(GL_TEXTURE_2D, s_gl_textures[bt->tex_id]);

                        GLint ws = (bt->wrap_s == 0) ? GL_CLAMP_TO_EDGE : (bt->wrap_s == 1 ? GL_REPEAT : GL_MIRRORED_REPEAT);
                        GLint wt = (bt->wrap_t == 0) ? GL_CLAMP_TO_EDGE : (bt->wrap_t == 1 ? GL_REPEAT : GL_MIRRORED_REPEAT);
                        GLint flt = (bt->min_filter == 0) ? GL_NEAREST : GL_LINEAR;
                        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, ws);
                        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, wt);
                        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, flt);
                        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, flt);

                        s_use_texture[bt->stage] = 1;
                    } else {
                        s_use_texture[bt->stage] = 0;
                    }
                }
                glActiveTexture(GL_TEXTURE0);
                if (s_uloc.use_texture0 >= 0) glUniform1iv(s_uloc.use_texture0, 3, s_use_texture);
                break;
            }
            case ACFP_CMD_DRAW: {
                if (max_draws >= 0 && draw_count >= (uint32_t)max_draws) {
                    break;
                }
                ACFP_Cmd_Draw* dc = (ACFP_Cmd_Draw*)payload;
                if (dc->vbo_id < s_num_gl_vbos && dc->vertex_count > 0) {
                    flush_tev_stages();

                    if (debug_color) {
                        float r = (float)((draw_count * 37 + 17) % 256) / 255.0f;
                        float g = (float)((draw_count * 79 + 53) % 256) / 255.0f;
                        float b = (float)((draw_count * 131 + 89) % 256) / 255.0f;
                        if (s_uloc.debug_color >= 0) glUniform4f(s_uloc.debug_color, r, g, b, 1.0f);
                    } else {
                        if (s_uloc.debug_color >= 0) glUniform4f(s_uloc.debug_color, 0.0f, 0.0f, 0.0f, 0.0f);
                    }

                    glBindBuffer(GL_ARRAY_BUFFER, s_gl_vbos[dc->vbo_id]);
                    size_t stride = sizeof(ACFPVertex);

                    glEnableVertexAttribArray(0);
                    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, (GLsizei)stride, (void*)offsetof(ACFPVertex, position));
                    glEnableVertexAttribArray(1);
                    glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, (GLsizei)stride, (void*)offsetof(ACFPVertex, normal));
                    glEnableVertexAttribArray(2);
                    glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, GL_TRUE, (GLsizei)stride, (void*)offsetof(ACFPVertex, color0));
                    glEnableVertexAttribArray(3);
                    glVertexAttribPointer(3, 2, GL_FLOAT, GL_FALSE, (GLsizei)stride, (void*)offsetof(ACFPVertex, texcoord[0]));

                    if (dc->prim_type == 0x80) { /* GX_QUADS */
                        int num_indices = (dc->vertex_count / 4) * 6;
                        glDrawElements(GL_TRIANGLES, num_indices, GL_UNSIGNED_SHORT, (void*)(uintptr_t)(dc->vertex_offset * sizeof(GLushort)));
                    } else {
                        GLenum prim = GL_TRIANGLES;
                        switch (dc->prim_type) {
                            case 0x90: prim = GL_TRIANGLES; break;
                            case 0x98: prim = GL_TRIANGLE_STRIP; break;
                            case 0xA0: prim = GL_TRIANGLE_FAN; break;
                            case 0xA8: prim = GL_LINES; break;
                            case 0xB0: prim = GL_LINE_STRIP; break;
                            case 0xB8: prim = GL_POINTS; break;
                            default:   prim = GL_TRIANGLES; break;
                        }
                        glDrawArrays(prim, (GLint)dc->vertex_offset, (GLsizei)dc->vertex_count);
                    }
                    draw_count++;
                }
                break;
            }
            case ACFP_CMD_EFB_COPY: {
                ACFP_Cmd_EfbCopy* efb = (ACFP_Cmd_EfbCopy*)payload;
                if (efb->dest_tex_id < MAX_TEX_SLOTS) {
                    if (s_gl_textures[efb->dest_tex_id] == 0) {
                        glGenTextures(1, &s_gl_textures[efb->dest_tex_id]);
                    }
                    glBindTexture(GL_TEXTURE_2D, s_gl_textures[efb->dest_tex_id]);
                    glCopyTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, efb->src_x, efb->src_y, efb->dst_w, efb->dst_h, 0);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
                    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                }
                break;
            }
            case ACFP_CMD_END_FRAME:
                break;
            default:
                break;
        }
    }

    glFinish();
    free(cmd_stream);

    printf("[Replay] Executed %u draw calls\n", draw_count);

    /* 10. Read back FBO and Save BMP */
    uint8_t* out_pixels = (uint8_t*)malloc(hdr.width * hdr.height * 4);
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, (GLsizei)hdr.width, (GLsizei)hdr.height, GL_BGRA, GL_UNSIGNED_BYTE, out_pixels);

    save_bmp(out_path, (int)hdr.width, (int)hdr.height, out_pixels);
    free(out_pixels);

    /* 11. Cleanup */
    glDeleteFramebuffers(1, &fbo);
    glDeleteTextures(1, &fbo_tex);
    glDeleteRenderbuffers(1, &fbo_depth);
    glDeleteBuffers(1, &s_quad_ebo);
    glDeleteVertexArrays(1, &s_vao);
    for (uint32_t i = 0; i < s_num_gl_textures; i++) {
        if (s_gl_textures[i]) glDeleteTextures(1, &s_gl_textures[i]);
    }
    for (uint32_t i = 0; i < s_num_gl_vbos; i++) {
        if (s_gl_vbos[i]) glDeleteBuffers(1, &s_gl_vbos[i]);
    }
    glDeleteProgram(s_program);

    SDL_GL_DeleteContext(ctx);
    SDL_DestroyWindow(win);
    SDL_Quit();

    printf("[Replay] Frame %u replay complete!\n", hdr.frame_index);
    return 0;
}
