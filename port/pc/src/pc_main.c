/* pc_main.c - PC entry point: SDL2/GL init and boot sequence */
#include "pc_platform.h"
#include "pc_gx_internal.h"
#include "pc_capture.h"
#include "pc_texture_pack.h"
#include "pc_settings.h"
#include "pc_keybindings.h"
#include "pc_assets.h"
#include "pc_disc.h"
#include "pc_typing.h"
#include "pc_pause_menu.h"
#include "pc_settings_menu.h"
#include "pc_profiler.h"
#include "m_kankyo.h"
#include "m_common_data.h"
#include "m_scene.h"
#include "m_play.h"
#include "m_player_lib.h"

/* prefer discrete GPU on laptops */
#ifdef _WIN32
__declspec(dllexport) unsigned long NvOptimusEnablement = 1;
__declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
#endif

SDL_Window*   g_pc_window = NULL;
SDL_GLContext  g_pc_gl_context = NULL;
int           g_pc_running = 1;
int           g_pc_headless = 0;
int           g_pc_as_library = 0;
int           g_pc_frame_limit_override = -1;
int           g_pc_speedhack_enabled = 0;
int           g_pc_verbose = 0;
int           g_pc_time_override = -1; /* -1=system clock, 0-23=override hour */
int           g_pc_min_override = -1; /* -1=system clock, 0-59=override minute */
int           g_pc_sec_override = -1; /* -1=system clock, 0-59=override second */
int           g_pc_date_month = -1; /* -1=system clock, 1-12=override month */
int           g_pc_date_day = -1; /* -1=system clock, 1-31=override day */
int           g_pc_date_year = -1; /* -1=system clock, else override year */
int           g_pc_weather_override = -1;
int           g_pc_weather_intensity_override = mEnv_WEATHER_INTENSITY_HEAVY;
int           g_pc_window_w = PC_SCREEN_WIDTH;
int           g_pc_window_h = PC_SCREEN_HEIGHT;
int           g_pc_widescreen_stretch = 0;

/* exe image range -- used by seg2k0 to distinguish pointers from segment addresses */
unsigned int pc_image_base = 0;
unsigned int pc_image_end  = 0;
int g_pc_scene_override = -1;
extern GAME* gamePT;

#ifdef _WIN32
#include <windows.h>

static void pc_print_addr_module(const char* prefix, void* addr) {
    HMODULE mod = NULL;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           (LPCSTR)addr, &mod) && mod != NULL) {
        char modname[MAX_PATH];
        if (GetModuleFileNameA(mod, modname, sizeof(modname))) {
            char* base_name = strrchr(modname, '\\');
            if (!base_name) base_name = strrchr(modname, '/');
            base_name = base_name ? base_name + 1 : modname;
            unsigned int ofs = (unsigned int)((uintptr_t)addr - (uintptr_t)mod);
            fprintf(stderr, "%s %p [%s + 0x%06x]\n", prefix, addr, base_name, ofs);
            return;
        }
    }
    uintptr_t uaddr = (uintptr_t)addr;
    if (uaddr >= pc_image_base && uaddr < pc_image_end) {
        fprintf(stderr, "%s %p [acgc_bridge.dll + 0x%06x]\n", prefix, addr, (unsigned int)(uaddr - pc_image_base));
    } else {
        fprintf(stderr, "%s %p\n", prefix, addr);
    }
}

static LONG WINAPI pc_vectored_exception_handler(PEXCEPTION_POINTERS ep) {
    DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (code == 0xE06D7363 || code == 0x40010006 || code == 0x406D1388) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    if (code == EXCEPTION_ACCESS_VIOLATION ||
        code == EXCEPTION_ILLEGAL_INSTRUCTION ||
        code == EXCEPTION_STACK_OVERFLOW ||
        code == EXCEPTION_INT_DIVIDE_BY_ZERO ||
        code == EXCEPTION_PRIV_INSTRUCTION) {

        fprintf(stderr, "\n=======================================================\n");
        fprintf(stderr, "[CRASH] FATAL EXCEPTION 0x%08lX at address %p\n", code, ep->ExceptionRecord->ExceptionAddress);
        pc_print_addr_module("[CRASH] Faulting location:", ep->ExceptionRecord->ExceptionAddress);

        if (code == EXCEPTION_ACCESS_VIOLATION && ep->ExceptionRecord->NumberParameters >= 2) {
            ULONG_PTR type = ep->ExceptionRecord->ExceptionInformation[0];
            ULONG_PTR target = ep->ExceptionRecord->ExceptionInformation[1];
            fprintf(stderr, "[CRASH] Access Violation %s at %p\n",
                    (type == 0 ? "READ" : (type == 1 ? "WRITE" : "EXEC")), (void*)target);
        }
        fprintf(stderr, "[CRASH] pc_image_base = 0x%08x, pc_image_end = 0x%08x\n", pc_image_base, pc_image_end);

        PCONTEXT ctx = ep->ContextRecord;
        if (ctx) {
#if defined(_M_IX86) || defined(__i386__)
            fprintf(stderr, "[CRASH] EIP=%08lX ESP=%08lX EBP=%08lX\n", (unsigned long)ctx->Eip, (unsigned long)ctx->Esp, (unsigned long)ctx->Ebp);
            fprintf(stderr, "[CRASH] EAX=%08lX EBX=%08lX ECX=%08lX EDX=%08lX ESI=%08lX EDI=%08lX\n",
                    (unsigned long)ctx->Eax, (unsigned long)ctx->Ebx, (unsigned long)ctx->Ecx,
                    (unsigned long)ctx->Edx, (unsigned long)ctx->Esi, (unsigned long)ctx->Edi);

            uintptr_t* sp = (uintptr_t*)ctx->Esp;
            fprintf(stderr, "[CRASH] Callstack from stack scan (ESP=%p):\n", (void*)sp);
            int frame = 0;
            for (int i = 0; i < 256 && frame < 32; i++) {
                MEMORY_BASIC_INFORMATION mbi;
                if (!VirtualQuery(&sp[i], &mbi, sizeof(mbi)) || !(mbi.State & MEM_COMMIT) || (mbi.Protect & PAGE_NOACCESS)) {
                    break;
                }
                uintptr_t val = sp[i];
                HMODULE mod = NULL;
                if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                       (LPCSTR)val, &mod) && mod != NULL) {
                    char modname[MAX_PATH];
                    if (GetModuleFileNameA(mod, modname, sizeof(modname))) {
                        char* base_name = strrchr(modname, '\\');
                        if (!base_name) base_name = strrchr(modname, '/');
                        base_name = base_name ? base_name + 1 : modname;
                        unsigned int ofs = (unsigned int)(val - (uintptr_t)mod);
                        fprintf(stderr, "  #%02d: %p [%s + 0x%06x]\n", frame++, (void*)val, base_name, ofs);
                    }
                }
            }
#endif
        }

        fprintf(stderr, "=======================================================\n\n");
        fflush(stderr);
    }
    return EXCEPTION_CONTINUE_SEARCH;
}
#endif

void pc_trigger_scene_change(int scene_id) {
    if (gamePT) {
        GAME_PLAY* play = (GAME_PLAY*)gamePT;
        if (play->fb_wipe_mode != WIPE_MODE_NONE) {
            if (play->fbdemo_wipe.wipe_procs.cleanup_proc) {
                play->fbdemo_wipe.wipe_procs.cleanup_proc(&play->fbdemo_wipe.wipe_data);
            }
            play->fb_wipe_mode = WIPE_MODE_NONE;
            play->fbdemo_wipe.wipe_type = -1;
        }
        Door_data_c door;
        memset(&door, 0, sizeof(door));
        door.next_scene_id = scene_id;
        door.exit_orientation = 4;
        door.exit_position.x = 160;
        door.exit_position.y = 0;
        door.exit_position.z = 300;
        door.wipe_type = WIPE_TYPE_TRIFORCE;

        Door_data_c* out_door = Common_GetPointer(structure_exit_door_data);
        out_door->next_scene_id = Save_Get(scene_no);
        out_door->exit_orientation = mSc_DIRECT_SOUTH_WEST;
        out_door->exit_type = 0;
        out_door->extra_data = 2;
        out_door->exit_position.x = 0;
        out_door->exit_position.y = 0;
        out_door->exit_position.z = 0;
        out_door->door_actor_name = 0x00A0; /* POST_OFFICE */
        out_door->wipe_type = WIPE_TYPE_TRIFORCE;

        int res = goto_other_scene(play, &door, FALSE);
        fprintf(stderr, "[PC] goto_other_scene returned %d, player=%p, wipe_mode=%d\n",
                res, (void*)get_player_actor_withoutCheck(play), play->fb_wipe_mode);
    }
}

void pc_platform_init(void) {
#ifdef _WIN32
    static int s_crash_handler_installed = 0;
    if (!s_crash_handler_installed) {
        AddVectoredExceptionHandler(0, pc_vectored_exception_handler);
        s_crash_handler_installed = 1;
    }
#endif
    if (g_pc_headless) {
        if (SDL_Init(SDL_INIT_AUDIO | SDL_INIT_TIMER | SDL_INIT_GAMECONTROLLER) < 0) {
            fprintf(stderr, "SDL_Init headless failed: %s\n", SDL_GetError());
        }
        pc_gx_init();
        return;
    }
#ifdef _WIN32
    SetProcessDPIAware();
    SDL_SetHint(SDL_HINT_WINDOWS_INTRESOURCE_ICON, "1");
#endif
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMECONTROLLER | SDL_INIT_AUDIO | SDL_INIT_TIMER) < 0) {
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        exit(1);
    }

    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
#ifdef PC_ENHANCEMENTS
    if (g_pc_settings.msaa > 0) {
        SDL_GL_SetAttribute(SDL_GL_MULTISAMPLEBUFFERS, 1);
        SDL_GL_SetAttribute(SDL_GL_MULTISAMPLESAMPLES, g_pc_settings.msaa);
    }
#endif

    {
        Uint32 flags = SDL_WINDOW_OPENGL | SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE;
        int win_w = g_pc_settings.window_width;
        int win_h = g_pc_settings.window_height;
        if (g_pc_settings.fullscreen == 1) {
            flags |= SDL_WINDOW_FULLSCREEN;
        } else if (g_pc_settings.fullscreen == 2) {
            flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;
        }
        g_pc_window = SDL_CreateWindow(
            PC_WINDOW_TITLE,
            SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
            win_w, win_h, flags
        );
    }
    if (!g_pc_window) {
        fprintf(stderr, "SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        exit(1);
    }

    g_pc_gl_context = SDL_GL_CreateContext(g_pc_window);
    if (!g_pc_gl_context) {
        fprintf(stderr, "SDL_GL_CreateContext failed: %s\n", SDL_GetError());
        SDL_DestroyWindow(g_pc_window);
        SDL_Quit();
        exit(1);
    }

    if (!gladLoadGL((GLADloadfunc)SDL_GL_GetProcAddress)) {
        fprintf(stderr, "gladLoadGL failed\n");
        SDL_GL_DeleteContext(g_pc_gl_context);
        SDL_DestroyWindow(g_pc_window);
        SDL_Quit();
        exit(1);
    }

    SDL_GL_SetSwapInterval(g_pc_settings.vsync);

    pc_platform_update_window_size();

#ifdef PC_ENHANCEMENTS
    if (g_pc_settings.msaa > 0) {
        glEnable(GL_MULTISAMPLE);
    }
#endif

    pc_gx_init();
    pc_capture_init();
    pc_capture_begin_frame(0, 0, g_pc_window_w, g_pc_window_h);
    pc_texture_pack_init();
#ifdef PC_ENHANCEMENTS
    if (g_pc_settings.preload_textures) {
        pc_texture_pack_preload_all();
    }
#endif
}

extern void PADCleanup(void);

static void pc_speedhack_toggle(void) {
    g_pc_speedhack_enabled = !g_pc_speedhack_enabled;
    if (g_pc_window != NULL) {
        SDL_SetWindowTitle(g_pc_window, g_pc_speedhack_enabled ? "Animal Crossing [5x]" : PC_WINDOW_TITLE);
    }

    if (g_pc_verbose) {
        printf("[PC] speedhack %s\n", g_pc_speedhack_enabled ? "5x" : "off");
    }
}

void pc_platform_shutdown(void) {
    static int shutdown_done = 0;
    if (shutdown_done) return;
    shutdown_done = 1;

    pc_audio_shutdown();
    pc_audio_mq_shutdown();
    PADCleanup();
    pc_texture_pack_shutdown();
    pc_gx_shutdown();
    pc_capture_shutdown();

    if (g_pc_gl_context) {
        SDL_GL_DeleteContext(g_pc_gl_context);
        g_pc_gl_context = NULL;
    }
    if (g_pc_window) {
        SDL_DestroyWindow(g_pc_window);
        g_pc_window = NULL;
    }
    SDL_Quit();
}

void pc_platform_update_window_size(void) {
    SDL_GL_GetDrawableSize(g_pc_window, &g_pc_window_w, &g_pc_window_h);
    if (g_pc_window_w <= 0) g_pc_window_w = PC_SCREEN_WIDTH;
    if (g_pc_window_h <= 0) g_pc_window_h = PC_SCREEN_HEIGHT;
}

void pc_platform_swap_buffers(void) {
    pc_gx_draw_pending();
    SDL_GL_SwapWindow(g_pc_window);
}

int pc_platform_poll_events(void) {
    SDL_Event event;

    pc_typing_update();

    while (SDL_PollEvent(&event)) {
        switch (event.type) {
            case SDL_QUIT:
                g_pc_running = 0;
                return 0;
            case SDL_WINDOWEVENT:
                if (event.window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
                    pc_platform_update_window_size();
                }
                break;
            case SDL_KEYDOWN:
                /* Keybinding capture eats all input first (works from both
                 * the pause menu and the title Options menu). */
                if (pc_settings_menu_capture_active()) {
                    pc_settings_menu_handle_capture_event(&event);
                    break;
                }
                if (event.key.keysym.sym == SDLK_F3 && !event.key.repeat) {
                    pc_speedhack_toggle();
                    break;
                }
                if (event.key.keysym.sym == SDLK_F10 && !event.key.repeat) {
                    extern u32 pc_frame_counter;
                    g_pc_capture_hotkey_pressed = 1;
                    printf("[PC Capture] F10 pressed - capturing frame %u\n", (unsigned int)pc_frame_counter);
                    break;
                }
                if (event.key.keysym.sym == SDLK_F12 && !event.key.repeat) {
                    char fname[64];
                    extern u32 pc_frame_counter;
                    snprintf(fname, sizeof(fname), "screenshot_%u.bmp", (unsigned int)pc_frame_counter);
                    pc_take_screenshot(fname);
                    break;
                }
                if (event.key.keysym.sym == SDLK_ESCAPE && !event.key.repeat) {
                    if (g_pc_paused) {
                        pc_pause_menu_handle_event(&event);
                    } else {
                        pc_pause_menu_toggle();
                    }
                    break;
                }
                if (g_pc_paused) {
                    pc_pause_menu_handle_event(&event);
                    break; /* swallow all keys while paused */
                }
                pc_typing_handle_event(&event);
                break;
            case SDL_MOUSEBUTTONDOWN:
                if (pc_settings_menu_capture_active()) {
                    pc_settings_menu_handle_capture_event(&event);
                }
                break;
            case SDL_CONTROLLERBUTTONDOWN:
                if (pc_settings_menu_capture_active()) {
                    pc_settings_menu_handle_capture_event(&event);
                    break;
                }
                if (g_pc_paused) {
                    pc_pause_menu_handle_event(&event);
                    break;
                }
                /* Back/Select opens the pause menu (controller Esc). */
                if (event.cbutton.button == SDL_CONTROLLER_BUTTON_BACK) {
                    pc_pause_menu_toggle();
                }
                break;
            case SDL_CONTROLLERAXISMOTION:
                if (pc_settings_menu_capture_active()) {
                    pc_settings_menu_handle_capture_event(&event);
                    break;
                }
                if (g_pc_paused) {
                    pc_pause_menu_handle_event(&event);
                }
                break;
            case SDL_TEXTINPUT:
                if (g_pc_paused) break;
                pc_typing_handle_event(&event);
                break;
        }
    }
    return 1;
}

/* game's main() renamed to ac_entry via -Dmain=ac_entry, boot.c's to boot_main */
extern void ac_entry(void);
extern int boot_main(int argc, const char** argv);

static int pc_parse_rain_intensity(const char* text) {
    if (strcmp(text, "light") == 0) {
        return mEnv_WEATHER_INTENSITY_LIGHT;
    }

    if (strcmp(text, "normal") == 0) {
        return mEnv_WEATHER_INTENSITY_NORMAL;
    }

    if (strcmp(text, "heavy") == 0) {
        return mEnv_WEATHER_INTENSITY_HEAVY;
    }

    return -1;
}

int main(int argc, char* argv[]) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            printf("Usage: AnimalCrossing [options]\n");
            printf("  --verbose, -v       Enable diagnostic output\n");
            printf("  --no-framelimit     Alias for --framelimit 0 (uncapped)\n");
            printf("  --framelimit N      Set the target frame rate (default 60, 0 = uncapped)\n");
            printf("  --profile [N]       Print frame profiler summary every N frames (default 120)\n");
            printf("  --model-viewer [N]  Launch model viewer (optional start index)\n");
            printf("  --time H[:M[:S]]    Override in-game time (e.g. 5, 17:30, 5:55:00)\n");
            printf("  --date M/D[/Y]      Override in-game date (e.g. 7/4, 12/24/2026)\n");
            printf("  --rain [intensity]  Force rainy weather; intensity is light, normal, or heavy\n");
            printf("  --uber-shader       Disable shader specialization (single uber shader)\n");
            printf("  --screenshot-frame N PATH Capture frame N to PATH as BMP\n");
            printf("  --capture-frame N [PATH] Capture frame N to PATH (.acfp + .bmp)\n");
            printf("  --capture-dual           Enable continuous Dual-Modus capture\n");
            printf("  --quit-after N      Quit after N frames\n");
            printf("  --headless          Run in headless mode (no window, no GL)\n");
            printf("  --help, -h          Show this help message\n");
            return 0;
        } else if (strcmp(argv[i], "--headless") == 0) {
            g_pc_headless = 1;
        } else if (strcmp(argv[i], "--screenshot-frame") == 0 && i + 2 < argc) {
            g_pc_screenshot_frame = atoi(argv[++i]);
            g_pc_screenshot_path = argv[++i];
        } else if (strcmp(argv[i], "--capture-frame") == 0 && i + 1 < argc) {
            g_pc_capture_frame = atoi(argv[++i]);
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                g_pc_capture_path = argv[++i];
            }
        } else if (strcmp(argv[i], "--capture-dual") == 0) {
            g_pc_capture_enabled = 1;
        } else if ((strcmp(argv[i], "--quit-after") == 0 || strcmp(argv[i], "--quit-after-frame") == 0) && i + 1 < argc) {
            g_pc_quit_after_frame = atoi(argv[++i]);
        } else if (strcmp(argv[i], "--framelimit") == 0) {
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                int v = atoi(argv[i + 1]);
                if (v > 0) {
                    g_pc_frame_limit_override = v;
                } else if (v == 0) {
                    g_pc_frame_limit_override = 0;
                }
                i++;
            }
        } else if (strcmp(argv[i], "--no-framelimit") == 0) {
            g_pc_frame_limit_override = 0;
        } else if (strcmp(argv[i], "--uber-shader") == 0) {
            extern int g_pc_uber_shader_only;
            g_pc_uber_shader_only = 1;
        } else if (strcmp(argv[i], "--verbose") == 0 || strcmp(argv[i], "-v") == 0) {
            g_pc_verbose = 1;
        } else if (strcmp(argv[i], "--profile") == 0) {
            g_pc_profile_enabled = 1;
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                int interval = atoi(argv[i + 1]);
                if (interval > 0) g_pc_profile_interval = interval;
                i++;
            }
        } else if (strcmp(argv[i], "--model-viewer") == 0) {
            g_pc_model_viewer = 1;
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                g_pc_model_viewer_start = atoi(argv[i + 1]);
                i++;
            }
        } else if (strcmp(argv[i], "--scene") == 0 && i + 1 < argc) {
            const char* sc = argv[++i];
            if (strcmp(sc, "village") == 0 || strcmp(sc, "dorf") == 0 || strcmp(sc, "fg") == 0) {
                g_pc_scene_override = 7; /* SCENE_FG */
            } else if (strcmp(sc, "train") == 0 || strcmp(sc, "zug") == 0) {
                g_pc_scene_override = 19; /* SCENE_PLAYERSELECT */
            } else if (strcmp(sc, "start_demo") == 0) {
                g_pc_scene_override = 15; /* SCENE_START_DEMO */
            } else if (strcmp(sc, "house") == 0 || strcmp(sc, "interior") == 0) {
                g_pc_scene_override = 20; /* SCENE_MY_ROOM_S */
            } else if (strcmp(sc, "shop") == 0) {
                g_pc_scene_override = 9; /* SCENE_SHOP0 */
            } else if (strcmp(sc, "water") == 0) {
                g_pc_scene_override = 11; /* SCENE_BG_TEST_RIVER */
            } else if (strcmp(sc, "watertest") == 0) {
                g_pc_scene_override = 3; /* SCENE_WATER_TEST */
            } else if (strcmp(sc, "title") == 0) {
                g_pc_scene_override = 33; /* SCENE_TITLE_DEMO */
            } else {
                g_pc_scene_override = atoi(sc);
            }
        } else if (strcmp(argv[i], "--time") == 0 && i + 1 < argc) {
            int h = -1, m = -1, s = -1;
            sscanf(argv[i + 1], "%d:%d:%d", &h, &m, &s);
            if (h >= 0 && h <= 23) g_pc_time_override = h;
            if (m >= 0 && m <= 59) g_pc_min_override = m;
            if (s >= 0 && s <= 59) g_pc_sec_override = s;
            i++;
        } else if (strcmp(argv[i], "--date") == 0 && i + 1 < argc) {
            int mo = -1, d = -1, y = -1;
            sscanf(argv[i + 1], "%d/%d/%d", &mo, &d, &y);
            if (mo >= 1 && mo <= 12 && d >= 1 && d <= 31) {
                g_pc_date_month = mo;
                g_pc_date_day = d;
                if (y >= 2000) g_pc_date_year = y;
            }
            i++;
        } else if (strcmp(argv[i], "--rain") == 0) {
            g_pc_weather_override = mEnv_WEATHER_RAIN;
            g_pc_weather_intensity_override = mEnv_WEATHER_INTENSITY_HEAVY;
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                int intensity = pc_parse_rain_intensity(argv[i + 1]);
                if (intensity >= 0) {
                    g_pc_weather_intensity_override = intensity;
                    i++;
                }
            }
        }
    }

    /* Redirect stdout/stderr to NUL unless verbose or headless — unbuffered terminal writes
     * are extremely slow on Windows and tank FPS. */
    if (!g_pc_verbose && !g_pc_profile_enabled && !g_pc_headless) {
#ifdef _WIN32
        freopen("NUL", "w", stdout);
        freopen("NUL", "w", stderr);
#else
        freopen("/dev/null", "w", stdout);
        freopen("/dev/null", "w", stderr);
#endif
    } else {
        setvbuf(stdout, NULL, _IONBF, 0);
        setvbuf(stderr, NULL, _IONBF, 0);
    }

    /* exe image range for seg2k0 — BSS can overlap N64 segment addresses */
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
    }
#else
    {
        Dl_info dl;
        if (dladdr((void*)main, &dl) && dl.dli_fbase) {
            pc_image_base = (unsigned int)(uintptr_t)dl.dli_fbase;
            Elf32_Ehdr* ehdr = (Elf32_Ehdr*)dl.dli_fbase;
            Elf32_Phdr* phdr = (Elf32_Phdr*)((char*)dl.dli_fbase + ehdr->e_phoff);
            unsigned int max_end = 0;
            for (int i = 0; i < ehdr->e_phnum; i++) {
                if (phdr[i].p_type == PT_LOAD) {
                    unsigned int seg_end = phdr[i].p_vaddr + phdr[i].p_memsz;
                    if (seg_end > max_end) max_end = seg_end;
                }
            }
            /* ET_EXEC: p_vaddr is absolute. ET_DYN (PIE): relative to load address. */
            if (ehdr->e_type == ET_DYN) {
                pc_image_end = pc_image_base + max_end;
            } else {
                pc_image_end = max_end;
            }
        }
    }
#endif

    SDL_SetMainReady();
    pc_settings_load();
    pc_keybindings_load();
    pc_platform_init();
    pc_disc_init();
    if (!pc_assets_init()) {
        const char* msg =
            "No game data found.\n\n"
            "Animal Crossing needs the original GameCube ROM to run.\n"
            "Place a disc image (.iso, .gcm, or .ciso) to the \"rom\" subfolder.";
        fprintf(stderr, "[PC] %s\n", msg);
        if (!g_pc_headless) {
            SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR,
                                     "Animal Crossing - Missing ROM", msg, g_pc_window);
        }
        pc_platform_shutdown();
        return 1;
    }

    ac_entry();                         /* sets HotStartEntry = &entry */
    boot_main(argc, (const char**)argv); /* full init → HotStartEntry → game loop */

    pc_disc_shutdown();
    pc_platform_shutdown();
    return 0;
}

int pc_run_headless(int ticks) {
    g_pc_headless = 1;
    g_pc_quit_after_frame = ticks;
    g_pc_running = 1;
    g_pc_verbose = 1;

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
    }
#endif

    SDL_SetMainReady();
    pc_settings_load();
    pc_keybindings_load();
    pc_platform_init();
    pc_disc_init();
    if (!pc_assets_init()) {
        fprintf(stderr, "[PC Headless] Failed to initialize assets from ROM!\n");
        return -1;
    }

    ac_entry();
    char* argv[] = { "acgc_bridge", NULL };
    boot_main(1, (const char**)argv);

    pc_disc_shutdown();
    pc_platform_shutdown();

    extern u32 pc_frame_counter;
    return (int)pc_frame_counter;
}

void pc_get_game_state(u16* year, u8* month, u8* day,
                       u8* hour, u8* min, u8* sec,
                       u8* season, u8* weather, s32* now_sec) {
    if (year) *year = common_data.time.rtc_time.year;
    if (month) *month = common_data.time.rtc_time.month;
    if (day) *day = common_data.time.rtc_time.day;
    if (hour) *hour = common_data.time.rtc_time.hour;
    if (min) *min = common_data.time.rtc_time.min;
    if (sec) *sec = common_data.time.rtc_time.sec;
    if (season) *season = (u8)common_data.time.season;
    if (weather) *weather = (u8)common_data.weather;
    if (now_sec) *now_sec = common_data.time.now_sec;
}

int pc_get_scene_no(void) {
    return Save_Get(scene_no);
}

int pc_get_scene_mode(void) {
    extern u8 sou_scene_mode;
    return (int)sou_scene_mode;
}

int pc_get_actor_count(void) {
    extern int mPl_get_actor_count(void);
    return mPl_get_actor_count();
}

int pc_is_game_running(void) {
    extern int s_graph_active;
    return g_pc_running && s_graph_active;
}
