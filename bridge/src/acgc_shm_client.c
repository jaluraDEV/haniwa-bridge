/*
 * acgc_shm_client.c — 64-bit GDExtension SHM consumer (Plan B, Gate 5.2).
 *
 * Opens the ACGC_SHM_V1 shared-memory mapping produced by acgc_host_x86.exe and
 * exposes it to GDScript through a small RefCounted class "ACGCShmClient":
 *
 *   open() -> bool                         open the mapping + named events
 *   poll_frame() -> PackedByteArray        latest readable double-buffer slot (tear-free)
 *   send_input(buttons, stick_x, stick_y, substick_x, substick_y, trigger_l, trigger_r)
 *   send_rtc_sync(year, month, day, hour, min, sec)
 *   send_exit_signal()
 *   pop_audio_samples() -> PackedVector2Array   int16 interleaved stereo -> float Vector2
 *   is_host_running() -> bool
 *   get_frame_id() -> int
 *
 * This file is architecture-agnostic (compiles as 64-bit or 32-bit); it uses the
 * raw GDExtension C interface exactly like acgc_bridge.c. It must NOT be linked
 * against libacgc_port.a — the game runs in the separate 32-bit host process.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include "gdextension_interface.h"
#include "acgc_shm.h"

#ifdef _WIN32
#include <windows.h>
#define GDE_EXPORT __declspec(dllexport)

typedef FILE* (*pfn_wfopen)(const wchar_t* filename, const wchar_t* mode);
typedef errno_t (*pfn_wfopen_s)(FILE** pFile, const wchar_t* filename, const wchar_t* mode);

static pfn_wfopen s_orig_wfopen = NULL;
static pfn_wfopen_s s_orig_wfopen_s = NULL;
static int s_wfopen_hook_installed = 0;

static void ensure_parent_dirs_w(const wchar_t* path) {
    wchar_t buf[MAX_PATH * 2];
    wcsncpy(buf, path, MAX_PATH * 2 - 1);
    buf[MAX_PATH * 2 - 1] = L'\0';
    wchar_t* last_slash = wcsrchr(buf, L'\\');
    wchar_t* last_fwd = wcsrchr(buf, L'/');
    if (last_fwd && (!last_slash || last_fwd > last_slash)) last_slash = last_fwd;
    if (!last_slash) return;
    *last_slash = L'\0';
    for (wchar_t* p = buf + 3; *p; p++) {
        if (*p == L'\\' || *p == L'/') {
            wchar_t orig = *p;
            *p = L'\0';
            CreateDirectoryW(buf, NULL);
            *p = orig;
        }
    }
    CreateDirectoryW(buf, NULL);
}

static FILE* Hook_wfopen(const wchar_t* filename, const wchar_t* mode) {
    FILE* f = s_orig_wfopen ? s_orig_wfopen(filename, mode) : _wfopen(filename, mode);
    if (!f && filename && wcsstr(filename, L"shader_cache") && mode && (wcschr(mode, L'w') || wcschr(mode, L'a'))) {
        ensure_parent_dirs_w(filename);
        f = s_orig_wfopen ? s_orig_wfopen(filename, mode) : _wfopen(filename, mode);
    }
    return f;
}

static errno_t Hook_wfopen_s(FILE** pFile, const wchar_t* filename, const wchar_t* mode) {
    errno_t err = s_orig_wfopen_s ? s_orig_wfopen_s(pFile, filename, mode) : (pFile ? (*pFile = _wfopen(filename, mode), *pFile ? 0 : 2) : 22);
    if (err != 0 && filename && wcsstr(filename, L"shader_cache") && mode && (wcschr(mode, L'w') || wcschr(mode, L'a'))) {
        ensure_parent_dirs_w(filename);
        err = s_orig_wfopen_s ? s_orig_wfopen_s(pFile, filename, mode) : (pFile ? (*pFile = _wfopen(filename, mode), *pFile ? 0 : 2) : 22);
    }
    return err;
}

static void install_shader_cache_hook(void) {
    if (s_wfopen_hook_installed) return;
    const char* env_hook = getenv("ACGC_ENABLE_SHADER_CACHE_IAT_HOOK");
    if (!env_hook || strcmp(env_hook, "1") != 0) {
        /* Default: OFF. Avoid patching Godot process imports at runtime unless explicitly opted-in. */
        return;
    }
    HMODULE hExe = GetModuleHandleA(NULL);
    HMODULE hMsvcrt = GetModuleHandleA("msvcrt.dll");
    if (!hExe || !hMsvcrt) return;

    s_orig_wfopen = (pfn_wfopen)GetProcAddress(hMsvcrt, "_wfopen");
    s_orig_wfopen_s = (pfn_wfopen_s)GetProcAddress(hMsvcrt, "_wfopen_s");

    PIMAGE_DOS_HEADER dos = (PIMAGE_DOS_HEADER)hExe;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return;
    PIMAGE_NT_HEADERS nt = (PIMAGE_NT_HEADERS)((uint8_t*)hExe + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return;
    DWORD importRva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    if (!importRva) return;
    PIMAGE_IMPORT_DESCRIPTOR imp = (PIMAGE_IMPORT_DESCRIPTOR)((uint8_t*)hExe + importRva);

    int hooked = 0;
    while (imp->Name) {
        char* name = (char*)((uint8_t*)hExe + imp->Name);
        if (_stricmp(name, "msvcrt.dll") == 0) {
            PIMAGE_THUNK_DATA thunk = (PIMAGE_THUNK_DATA)((uint8_t*)hExe + imp->FirstThunk);
            while (thunk->u1.Function) {
                if (s_orig_wfopen && (void*)thunk->u1.Function == (void*)s_orig_wfopen) {
                    DWORD old;
                    VirtualProtect(&thunk->u1.Function, sizeof(void*), PAGE_READWRITE, &old);
                    thunk->u1.Function = (uintptr_t)Hook_wfopen;
                    VirtualProtect(&thunk->u1.Function, sizeof(void*), old, &old);
                    hooked++;
                }
                if (s_orig_wfopen_s && (void*)thunk->u1.Function == (void*)s_orig_wfopen_s) {
                    DWORD old;
                    VirtualProtect(&thunk->u1.Function, sizeof(void*), PAGE_READWRITE, &old);
                    thunk->u1.Function = (uintptr_t)Hook_wfopen_s;
                    VirtualProtect(&thunk->u1.Function, sizeof(void*), old, &old);
                    hooked++;
                }
                thunk++;
            }
        }
        imp++;
    }
    s_wfopen_hook_installed = 1;
    fprintf(stderr, "[GDExtension] Shader cache IAT auto-dir hook installed (%d functions hooked)\n", hooked);
    fflush(stderr);
}
#else
#define GDE_EXPORT
#endif

/* --- Godot interface function pointers --- */
static GDExtensionInterfaceGetProcAddress gd_get_proc_address = NULL;
static GDExtensionClassLibraryPtr gd_library = NULL;

static GDExtensionInterfaceStringNameNewWithUtf8Chars gd_string_name_new_with_utf8_chars = NULL;
static GDExtensionInterfaceStringNewWithUtf8Chars gd_string_new_with_utf8_chars = NULL;
static GDExtensionInterfaceClassdbRegisterExtensionClass6 gd_classdb_register_extension_class6 = NULL;
static GDExtensionInterfaceClassdbRegisterExtensionClassMethod gd_classdb_register_extension_class_method = NULL;
static GDExtensionInterfaceClassdbConstructObject3 gd_classdb_construct_object3 = NULL;
static GDExtensionInterfaceObjectSetInstance gd_object_set_instance = NULL;
static GDExtensionInterfaceGetVariantFromTypeConstructor gd_get_variant_from_type_constructor = NULL;
static GDExtensionInterfaceGetVariantToTypeConstructor gd_get_variant_to_type_constructor = NULL;
static GDExtensionInterfaceVariantGetPtrConstructor gd_variant_get_ptr_constructor = NULL;
static GDExtensionInterfaceVariantGetPtrDestructor gd_variant_get_ptr_destructor = NULL;
static GDExtensionInterfaceVariantGetPtrBuiltinMethod gd_variant_get_ptr_builtin_method = NULL;
static GDExtensionInterfacePackedByteArrayOperatorIndex gd_packed_byte_array_operator_index = NULL;
static GDExtensionInterfacePackedVector2ArrayOperatorIndex gd_packed_vector2_array_operator_index = NULL;

static GDExtensionVariantFromTypeConstructorFunc gd_variant_from_int_constructor = NULL;
static GDExtensionVariantFromTypeConstructorFunc gd_variant_from_bool_constructor = NULL;
static GDExtensionVariantFromTypeConstructorFunc gd_variant_from_pba_constructor = NULL;
static GDExtensionVariantFromTypeConstructorFunc gd_variant_from_pva_constructor = NULL;
static GDExtensionTypeFromVariantConstructorFunc gd_variant_to_int_constructor = NULL;
static GDExtensionPtrConstructor gd_pba_constructor = NULL;
static GDExtensionPtrDestructor gd_pba_destructor = NULL;
static GDExtensionPtrBuiltInMethod gd_pba_resize = NULL;
static GDExtensionPtrConstructor gd_pva_constructor = NULL;
static GDExtensionPtrDestructor gd_pva_destructor = NULL;
static GDExtensionPtrBuiltInMethod gd_pva_resize = NULL;

/* --- SHM / event state (module scope) --- */
static void*  s_map = NULL;
static HANDLE s_hmap = NULL;
static HANDLE s_ev_frame_ready = NULL;
static HANDLE s_ev_input_ack = NULL;
static uint64_t s_last_frame_id = 0;

static void make_sn(void* dest, const char* name) {
    memset(dest, 0, 8);
    if (gd_string_name_new_with_utf8_chars) {
        gd_string_name_new_with_utf8_chars(dest, name);
    }
}

static void make_str(void* dest, const char* text) {
    memset(dest, 0, 8);
    if (gd_string_new_with_utf8_chars) {
        gd_string_new_with_utf8_chars(dest, text);
    }
}

static int s_open_error = 0;

/* Idempotent open: create-or-open the mapping and events. Returns 1 on success. */
static int shm_open(void) {
    if (s_map && s_hmap) return 1; /* already open */

    s_hmap = OpenFileMappingA(FILE_MAP_READ | FILE_MAP_WRITE, FALSE, ACGC_SHM_MAPPING_NAME);
    if (!s_hmap) {
        s_hmap = OpenFileMappingA(FILE_MAP_ALL_ACCESS, FALSE, ACGC_SHM_MAPPING_NAME);
    }
    if (!s_hmap) {
        s_open_error = 1000 + (int)GetLastError();
        return 0;
    }
    s_map = MapViewOfFile(s_hmap, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, ACGC_SHM_TOTAL_SIZE);
    if (!s_map) {
        s_map = MapViewOfFile(s_hmap, FILE_MAP_ALL_ACCESS, 0, 0, ACGC_SHM_TOTAL_SIZE);
    }
    if (!s_map) {
        s_open_error = 2000 + (int)GetLastError();
        CloseHandle(s_hmap);
        s_hmap = NULL;
        return 0;
    }

    ACGCShmHeader* hdr = ACGC_SHM_HEADER(s_map);
    if (hdr->magic != ACGC_SHM_MAGIC) {
        s_open_error = 3000;
        UnmapViewOfFile(s_map); s_map = NULL;
        CloseHandle(s_hmap); s_hmap = NULL;
        return 0;
    }
    if (hdr->version != ACGC_SHM_VERSION) {
        s_open_error = 4000;
        UnmapViewOfFile(s_map); s_map = NULL;
        CloseHandle(s_hmap); s_hmap = NULL;
        return 0;
    }
    hdr->consumer_alive = 1;

    if (!s_ev_frame_ready) {
        s_ev_frame_ready = OpenEventA(EVENT_MODIFY_STATE | SYNCHRONIZE, FALSE, ACGC_SHM_EVENT_FRAME_READY);
        if (!s_ev_frame_ready) s_ev_frame_ready = OpenEventA(EVENT_ALL_ACCESS, FALSE, ACGC_SHM_EVENT_FRAME_READY);
    }
    if (!s_ev_input_ack) {
        s_ev_input_ack = OpenEventA(EVENT_MODIFY_STATE | SYNCHRONIZE, FALSE, ACGC_SHM_EVENT_INPUT_ACK);
        if (!s_ev_input_ack) s_ev_input_ack = OpenEventA(EVENT_ALL_ACCESS, FALSE, ACGC_SHM_EVENT_INPUT_ACK);
    }

    s_open_error = 0;
    return 1;
}

static void shm_close(void) {
    if (s_map) {
        ACGCShmHeader* hdr = ACGC_SHM_HEADER(s_map);
        hdr->consumer_alive = 0;
    }
    if (s_ev_frame_ready) { CloseHandle(s_ev_frame_ready); s_ev_frame_ready = NULL; }
    if (s_ev_input_ack)   { CloseHandle(s_ev_input_ack);   s_ev_input_ack   = NULL; }
    if (s_map)            { UnmapViewOfFile(s_map);        s_map = NULL; }
    if (s_hmap)           { CloseHandle(s_hmap);           s_hmap = NULL; }
}

/* --- Method: open() -> bool --- */
static void cli_open(void *mu, GDExtensionClassInstancePtr inst,
                     const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                     GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst; (void)args; (void)argc;
    if (err) err->error = GDEXTENSION_CALL_OK;
    GDExtensionBool ok = shm_open() ? 1 : 0;
    if (ret && gd_variant_from_bool_constructor) gd_variant_from_bool_constructor(ret, &ok);
}

/* --- Method: poll_frame() -> PackedByteArray --- */
static void cli_poll_frame(void *mu, GDExtensionClassInstancePtr inst,
                           const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                           GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst; (void)args; (void)argc;
    if (err) err->error = GDEXTENSION_CALL_OK;
    if (!ret || !s_map || !gd_variant_from_pba_constructor || !gd_pba_constructor || !gd_pba_destructor) return;

    uint8_t pba[16];
    memset(pba, 0, sizeof(pba));
    gd_pba_constructor(pba, NULL);

    ACGCShmHeader* hdr = ACGC_SHM_HEADER(s_map);
    /* Only deliver a frame once (tear-free double buffer handoff). */
    if (hdr->frame_id != s_last_frame_id) {
        uint32_t rslot = hdr->active_read_slot;
        if (rslot < 2) {
            ACGCShmFrameSlot* slot = ACGC_SHM_FRAME(s_map, rslot);
            uint32_t psize = slot->payload_size;
            if (psize > 0 && psize <= ACGC_SHM_FRAME_SLOT_SIZE && gd_pba_resize && gd_packed_byte_array_operator_index) {
                int64_t target = (int64_t)psize;
                const void* a[1] = { &target };
                int64_t ignored = 0;
                gd_pba_resize(pba, a, &ignored, 1);
                uint8_t* dst = gd_packed_byte_array_operator_index(pba, 0);
                if (dst) memcpy(dst, slot->data, psize);
            }
            s_last_frame_id = hdr->frame_id;
        }
    }

    gd_variant_from_pba_constructor(ret, pba);
    gd_pba_destructor(pba);
}

/* --- Method: send_input(buttons, stick_x, stick_y, substick_x, substick_y, trigger_l, trigger_r) -> void --- */
static void cli_send_input(void *mu, GDExtensionClassInstancePtr inst,
                           const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                           GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst; (void)ret;
    if (err) err->error = GDEXTENSION_CALL_OK;
    if (!s_map) return;

    ACGCShmInputBlock* in = ACGC_SHM_INPUT(s_map);
    int64_t v = 0;
    if (argc >= 1 && args[0] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[0]); in->buttons = (uint16_t)v; }
    if (argc >= 2 && args[1] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[1]); in->stick_x = (int8_t)v; }
    if (argc >= 3 && args[2] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[2]); in->stick_y = (int8_t)v; }
    if (argc >= 4 && args[3] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[3]); in->substick_x = (int8_t)v; }
    if (argc >= 5 && args[4] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[4]); in->substick_y = (int8_t)v; }
    if (argc >= 6 && args[5] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[5]); in->trigger_l = (uint8_t)v; }
    if (argc >= 7 && args[6] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[6]); in->trigger_r = (uint8_t)v; }
    InterlockedIncrement((volatile LONG*)&in->input_seq);
}

/* --- Method: send_rtc_sync(year, month, day, hour, min, sec) -> void --- */
static void cli_send_rtc_sync(void *mu, GDExtensionClassInstancePtr inst,
                              const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                              GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst; (void)ret;
    if (err) err->error = GDEXTENSION_CALL_OK;
    if (!s_map) return;

    ACGCShmInputBlock* in = ACGC_SHM_INPUT(s_map);
    int64_t v = 0;
    if (argc >= 1 && args[0] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[0]); in->rtc_year = (uint32_t)v; }
    if (argc >= 2 && args[1] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[1]); in->rtc_month = (uint8_t)v; }
    if (argc >= 3 && args[2] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[2]); in->rtc_day = (uint8_t)v; }
    if (argc >= 4 && args[3] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[3]); in->rtc_hour = (uint8_t)v; }
    if (argc >= 5 && args[4] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[4]); in->rtc_min = (uint8_t)v; }
    if (argc >= 6 && args[5] && gd_variant_to_int_constructor) { gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[5]); in->rtc_sec = (uint8_t)v; }
    in->rtc_inject = 1;
}

/* --- Method: send_efb_ack(seq: int) -> void --- */
static void cli_send_efb_ack(void *mu, GDExtensionClassInstancePtr inst,
                             const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                             GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst; (void)ret;
    if (err) err->error = GDEXTENSION_CALL_OK;
    if (!s_map) return;
    if (argc >= 1 && args[0] && gd_variant_to_int_constructor) {
        int64_t v = 0;
        gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)args[0]);
        ACGCShmInputBlock* in = ACGC_SHM_INPUT(s_map);
        in->efb_ack = (uint32_t)v;
    }
}

/* --- Method: get_efb_seq() -> int --- */
static void cli_get_efb_seq(void *mu, GDExtensionClassInstancePtr inst,
                            const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                            GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst; (void)args; (void)argc;
    if (err) err->error = GDEXTENSION_CALL_OK;
    int64_t v = 0;
    if (s_map) v = (int64_t)ACGC_SHM_HEADER(s_map)->efb_seq;
    if (ret && gd_variant_from_int_constructor) gd_variant_from_int_constructor(ret, &v);
}

/* --- Method: send_exit_signal() -> void --- */
static void cli_send_exit_signal(void *mu, GDExtensionClassInstancePtr inst,
                                 const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                                 GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst; (void)args; (void)argc; (void)ret;
    if (err) err->error = GDEXTENSION_CALL_OK;
    if (!s_map) return;
    ACGC_SHM_HEADER(s_map)->exit_requested = 1;
    if (s_ev_input_ack) SetEvent(s_ev_input_ack); /* wake the host if it waits on input */
}

/* --- Method: pop_audio_samples(int max_frames = 0) -> PackedVector2Array --- */
static void cli_pop_audio_samples(void *mu, GDExtensionClassInstancePtr inst,
                                  const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                                  GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst;
    if (err) err->error = GDEXTENSION_CALL_OK;
    if (!ret || !s_map || !gd_variant_from_pva_constructor || !gd_pva_constructor || !gd_pva_destructor) return;

    uint8_t pva[16];
    memset(pva, 0, sizeof(pva));
    gd_pva_constructor(pva, NULL);

    ACGCShmAudioRing* ring = ACGC_SHM_AUDIO(s_map);
    int16_t* samples = ACGC_SHM_AUDIO_SAMPLES(s_map);
    uint32_t cap = ring->buffer_samples;
#ifdef _WIN32
    uint32_t head = (uint32_t)InterlockedCompareExchange((volatile LONG*)&ring->head_sample, 0, 0);
    uint32_t tail = (uint32_t)InterlockedCompareExchange((volatile LONG*)&ring->tail_sample, 0, 0);
#else
    uint32_t head = ring->head_sample;
    uint32_t tail = ring->tail_sample;
#endif

    uint32_t avail = (head >= tail) ? (head - tail) : (cap - tail + head);
    uint32_t pair_count = avail / 2; /* interleaved stereo -> Vector2 */

    /* Optional max_frames parameter: clamp to requested frame count */
    if (argc >= 1 && args[0] && gd_variant_to_int_constructor) {
        int64_t max_f = 0;
        gd_variant_to_int_constructor(&max_f, (GDExtensionVariantPtr)args[0]);
        if (max_f > 0 && (uint32_t)max_f < pair_count) {
            pair_count = (uint32_t)max_f;
        }
    }

    if (pair_count > 0 && cap > 0 && gd_pva_resize && gd_packed_vector2_array_operator_index) {
        int64_t target = (int64_t)pair_count;
        const void* a[1] = { &target };
        int64_t ignored = 0;
        gd_pva_resize(pva, a, &ignored, 1);
        float* dst = (float*)gd_packed_vector2_array_operator_index(pva, 0);
        if (dst) {
            for (uint32_t i = 0; i < pair_count; i++) {
                uint32_t idx = (tail + 2 * i) % cap;
                int16_t l = samples[idx];
                int16_t r = samples[(idx + 1) % cap];
                dst[2 * i + 0] = (float)l / 32768.0f;
                dst[2 * i + 1] = (float)r / 32768.0f;
            }
        }
#ifdef _WIN32
        MemoryBarrier();
        InterlockedExchange((volatile LONG*)&ring->tail_sample, (LONG)((tail + pair_count * 2) % cap));
#else
        ring->tail_sample = (tail + pair_count * 2) % cap;
#endif
    }

    gd_variant_from_pva_constructor(ret, pva);
    gd_pva_destructor(pva);
}

/* --- Method: get_audio_cushion_ms() -> int --- */
static void cli_get_audio_cushion_ms(void *mu, GDExtensionClassInstancePtr inst,
                                     const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                                     GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst; (void)args; (void)argc;
    if (err) err->error = GDEXTENSION_CALL_OK;
    int64_t ms = 0;
    if (s_map) {
        ACGCShmAudioRing* ring = ACGC_SHM_AUDIO(s_map);
        uint32_t cap = ring->buffer_samples;
        if (cap > 0) {
#ifdef _WIN32
            uint32_t head = (uint32_t)InterlockedCompareExchange((volatile LONG*)&ring->head_sample, 0, 0);
            uint32_t tail = (uint32_t)InterlockedCompareExchange((volatile LONG*)&ring->tail_sample, 0, 0);
#else
            uint32_t head = ring->head_sample;
            uint32_t tail = ring->tail_sample;
#endif
            uint32_t avail = (head >= tail) ? (head - tail) : (cap - tail + head);
            uint32_t frames = avail / 2;
            ms = (int64_t)(frames * 1000 / 32000);
        }
    }
    if (ret && gd_variant_from_int_constructor) gd_variant_from_int_constructor(ret, &ms);
}

/* --- XInput dynamic loader & gamepad polling --- */
#ifdef _WIN32
#include <xinput.h>

typedef DWORD (WINAPI *PFN_XInputGetState)(DWORD dwUserIndex, XINPUT_STATE* pState);
static PFN_XInputGetState s_pfn_xinput_get_state = NULL;
static int s_xinput_checked = 0;

static void ensure_xinput_loaded(void) {
    if (s_xinput_checked) return;
    s_xinput_checked = 1;
    HMODULE h = LoadLibraryA("xinput1_4.dll");
    if (!h) h = LoadLibraryA("xinput1_3.dll");
    if (!h) h = LoadLibraryA("xinput9_1_0.dll");
    if (h) {
        s_pfn_xinput_get_state = (PFN_XInputGetState)GetProcAddress(h, "XInputGetState");
    }
}
#endif

/* --- Method: poll_xinput() -> PackedByteArray (10 bytes: btn_u16, stick_x_s8, stick_y_s8, sub_x_s8, sub_y_s8, trg_l_u8, trg_r_u8, connected_u8, user_u8) --- */
static void cli_poll_xinput(void *mu, GDExtensionClassInstancePtr inst,
                            const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                            GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst; (void)args; (void)argc;
    if (err) err->error = GDEXTENSION_CALL_OK;
    if (!ret || !gd_variant_from_pba_constructor || !gd_pba_constructor || !gd_pba_destructor) return;

    uint8_t pba[16];
    memset(pba, 0, sizeof(pba));
    gd_pba_constructor(pba, NULL);

    uint8_t buf[10];
    memset(buf, 0, sizeof(buf));

#ifdef _WIN32
    ensure_xinput_loaded();
    if (s_pfn_xinput_get_state) {
        for (DWORD i = 0; i < 4; i++) {
            XINPUT_STATE st;
            memset(&st, 0, sizeof(st));
            if (s_pfn_xinput_get_state(i, &st) == ERROR_SUCCESS) {
                uint16_t buttons = 0;
                int8_t stick_x = 0;
                int8_t stick_y = 0;
                int8_t substick_x = 0;
                int8_t substick_y = 0;
                uint8_t trg_l = 0;
                uint8_t trg_r = 0;

                WORD w = st.Gamepad.wButtons;
                if (w & XINPUT_GAMEPAD_DPAD_UP)        buttons |= 0x0008; /* PAD_BUTTON_UP */
                if (w & XINPUT_GAMEPAD_DPAD_DOWN)      buttons |= 0x0004; /* PAD_BUTTON_DOWN */
                if (w & XINPUT_GAMEPAD_DPAD_LEFT)      buttons |= 0x0001; /* PAD_BUTTON_LEFT */
                if (w & XINPUT_GAMEPAD_DPAD_RIGHT)     buttons |= 0x0002; /* PAD_BUTTON_RIGHT */
                if (w & XINPUT_GAMEPAD_A)               buttons |= 0x0100; /* PAD_BUTTON_A */
                if (w & XINPUT_GAMEPAD_B)               buttons |= 0x0200; /* PAD_BUTTON_B */
                if (w & XINPUT_GAMEPAD_X)               buttons |= 0x0400; /* PAD_BUTTON_X */
                if (w & XINPUT_GAMEPAD_Y)               buttons |= 0x0800; /* PAD_BUTTON_Y */
                if ((w & XINPUT_GAMEPAD_START) || (w & XINPUT_GAMEPAD_BACK)) buttons |= 0x1000; /* PAD_BUTTON_START */
                if (w & XINPUT_GAMEPAD_LEFT_SHOULDER)  { trg_l = 255; buttons |= 0x0040; } /* PAD_TRIGGER_L */
                if (w & XINPUT_GAMEPAD_RIGHT_SHOULDER) buttons |= 0x0010; /* PAD_TRIGGER_Z */

                if (st.Gamepad.bLeftTrigger > 30) {
                    trg_l = st.Gamepad.bLeftTrigger;
                    buttons |= 0x0040; /* PAD_TRIGGER_L */
                }
                if (st.Gamepad.bRightTrigger > 30) {
                    trg_r = st.Gamepad.bRightTrigger;
                    buttons |= 0x0020; /* PAD_TRIGGER_R */
                }

                /* Left Stick (deadzone ~5000, max range -80..80) */
                int lx = st.Gamepad.sThumbLX;
                int ly = st.Gamepad.sThumbLY;
                if (abs(lx) > 5000) stick_x = (int8_t)((int64_t)lx * 80 / 32768);
                if (abs(ly) > 5000) stick_y = (int8_t)((int64_t)ly * 80 / 32768);

                /* Right Stick / C-Stick */
                int rx = st.Gamepad.sThumbRX;
                int ry = st.Gamepad.sThumbRY;
                if (abs(rx) > 5000) substick_x = (int8_t)((int64_t)rx * 80 / 32768);
                if (abs(ry) > 5000) substick_y = (int8_t)((int64_t)ry * 80 / 32768);

                buf[0] = (uint8_t)(buttons & 0xFF);
                buf[1] = (uint8_t)((buttons >> 8) & 0xFF);
                buf[2] = (uint8_t)stick_x;
                buf[3] = (uint8_t)stick_y;
                buf[4] = (uint8_t)substick_x;
                buf[5] = (uint8_t)substick_y;
                buf[6] = trg_l;
                buf[7] = trg_r;
                buf[8] = 1; /* connected */
                buf[9] = (uint8_t)i; /* user index */
                break;
            }
        }
    }
#endif

    if (gd_pba_resize && gd_packed_byte_array_operator_index) {
        int64_t target = sizeof(buf);
        const void* a[1] = { &target };
        int64_t ignored = 0;
        gd_pba_resize(pba, a, &ignored, 1);
        uint8_t* dst = (uint8_t*)gd_packed_byte_array_operator_index(pba, 0);
        if (dst) memcpy(dst, buf, sizeof(buf));
    }

    gd_variant_from_pba_constructor(ret, pba);
    gd_pba_destructor(pba);
}

/* --- Method: is_host_running() -> bool --- */
static void cli_is_host_running(void *mu, GDExtensionClassInstancePtr inst,
                                const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                                GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst; (void)args; (void)argc;
    if (err) err->error = GDEXTENSION_CALL_OK;
    GDExtensionBool alive = 0;
    if (s_map) alive = ACGC_SHM_HEADER(s_map)->producer_alive ? 1 : 0;
    if (ret && gd_variant_from_bool_constructor) gd_variant_from_bool_constructor(ret, &alive);
}

/* --- Method: get_frame_id() -> int --- */
static void cli_get_frame_id(void *mu, GDExtensionClassInstancePtr inst,
                             const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                             GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst; (void)args; (void)argc;
    if (err) err->error = GDEXTENSION_CALL_OK;
    int64_t id = 0;
    if (s_map) id = (int64_t)ACGC_SHM_HEADER(s_map)->frame_id;
    if (ret && gd_variant_from_int_constructor) gd_variant_from_int_constructor(ret, &id);
}

/* --- Game-state getters (read from the SHM state block, for the lighting path) --- */
static int64_t state_int(int field) {
    if (!s_map) return 0;
    ACGCShmStateBlock* st = ACGC_SHM_STATE(s_map);
    switch (field) {
        case 0: return (int64_t)st->hour;
        case 1: return (int64_t)st->minute;
        case 2: return (int64_t)st->weather;
        case 3: return (int64_t)st->season;
        case 4: return (int64_t)st->scene_no;
        case 5: return (int64_t)st->second;
        default: return 0;
    }
}

#define STATE_GETTER(name, field) \
    static void name(void *mu, GDExtensionClassInstancePtr inst, \
                     const GDExtensionConstVariantPtr *args, GDExtensionInt argc, \
                     GDExtensionVariantPtr ret, GDExtensionCallError *err) { \
        (void)mu; (void)inst; (void)args; (void)argc; \
        if (err) err->error = GDEXTENSION_CALL_OK; \
        int64_t v = state_int(field); \
        if (ret && gd_variant_from_int_constructor) gd_variant_from_int_constructor(ret, &v); \
    }

STATE_GETTER(cli_get_hour, 0)
STATE_GETTER(cli_get_minute, 1)
STATE_GETTER(cli_get_weather, 2)
STATE_GETTER(cli_get_season, 3)
STATE_GETTER(cli_get_scene_no, 4)
STATE_GETTER(cli_get_second, 5)

/* --- Method: get_open_error() -> int --- */
static void cli_get_open_error(void *mu, GDExtensionClassInstancePtr inst,
                               const GDExtensionConstVariantPtr *args, GDExtensionInt argc,
                               GDExtensionVariantPtr ret, GDExtensionCallError *err) {
    (void)mu; (void)inst; (void)args; (void)argc;
    if (err) err->error = GDEXTENSION_CALL_OK;
    int64_t v = (int64_t)s_open_error;
    if (ret && gd_variant_from_int_constructor) gd_variant_from_int_constructor(ret, &v);
}

/* --- Instance lifecycle --- */
static GDExtensionObjectPtr cli_create_instance(void *p_class_userdata, GDExtensionBool p_notify_postinitialize) {
    (void)p_class_userdata; (void)p_notify_postinitialize;
    uint8_t parent_sn[8];
    make_sn(parent_sn, "RefCounted");
    GDExtensionObjectPtr obj = gd_classdb_construct_object3(parent_sn);
    if (obj && gd_object_set_instance) {
        uint8_t class_sn[8];
        make_sn(class_sn, "ACGCShmClient");
        gd_object_set_instance(obj, class_sn, (void*)0x1);
    }
    return obj;
}

static void cli_free_instance(void *p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata; (void)p_instance;
}

/* --- Simple (zero-arg) method registration helper --- */
static void register_method_simple(GDExtensionClassLibraryPtr lib, void* class_sn,
                                   const char* name, GDExtensionClassMethodCall call_func,
                                   int has_return, GDExtensionVariantType ret_type,
                                   void* empty_sn, void* empty_str) {
    uint8_t method_sn[8];
    make_sn(method_sn, name);

    GDExtensionPropertyInfo rinfo;
    memset(&rinfo, 0, sizeof(rinfo));
    rinfo.type = ret_type;
    rinfo.name = (GDExtensionStringNamePtr)empty_sn;
    rinfo.class_name = (GDExtensionStringNamePtr)empty_sn;
    rinfo.hint_string = (GDExtensionStringPtr)empty_str;
    rinfo.usage = 6;

    GDExtensionClassMethodInfo minfo;
    memset(&minfo, 0, sizeof(minfo));
    minfo.name = (GDExtensionStringNamePtr)method_sn;
    minfo.call_func = call_func;
    minfo.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
    minfo.has_return_value = has_return ? 1 : 0;
    if (has_return) {
        minfo.return_value_info = &rinfo;
        if (ret_type == GDEXTENSION_VARIANT_TYPE_INT) {
            minfo.return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT64;
        }
    }
    minfo.argument_count = 0;

    if (gd_classdb_register_extension_class_method) {
        gd_classdb_register_extension_class_method(lib, class_sn, &minfo);
    }
}

/* Register a method with N int arguments (for send_input / send_rtc_sync). */
static void register_method_ints(GDExtensionClassLibraryPtr lib, void* class_sn,
                                 const char* name, GDExtensionClassMethodCall call_func,
                                 int argc, const char** arg_names, void* empty_sn, void* empty_str) {
    uint8_t method_sn[8];
    make_sn(method_sn, name);

    GDExtensionPropertyInfo ainfo[8];
    GDExtensionClassMethodArgumentMetadata ameta[8];
    uint8_t asns[8][8];
    for (int i = 0; i < argc && i < 8; i++) {
        make_sn(asns[i], arg_names[i]);
        memset(&ainfo[i], 0, sizeof(GDExtensionPropertyInfo));
        ainfo[i].type = GDEXTENSION_VARIANT_TYPE_INT;
        ainfo[i].name = (GDExtensionStringNamePtr)asns[i];
        ainfo[i].class_name = (GDExtensionStringNamePtr)empty_sn;
        ainfo[i].hint_string = (GDExtensionStringPtr)empty_str;
        ainfo[i].usage = 6;
        ameta[i] = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT64;
    }

    GDExtensionClassMethodInfo minfo;
    memset(&minfo, 0, sizeof(minfo));
    minfo.name = (GDExtensionStringNamePtr)method_sn;
    minfo.call_func = call_func;
    minfo.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
    minfo.has_return_value = 0;
    minfo.argument_count = argc;
    minfo.arguments_info = ainfo;
    minfo.arguments_metadata = ameta;

    if (gd_classdb_register_extension_class_method) {
        gd_classdb_register_extension_class_method(lib, class_sn, &minfo);
    }
}

static uint8_t s_default_max_frames[32];
static GDExtensionVariantPtr s_default_audio_args[1] = { (GDExtensionVariantPtr)s_default_max_frames };

static void register_method_pop_audio_samples(GDExtensionClassLibraryPtr lib, void* class_sn,
                                              void* empty_sn, void* empty_str) {
    uint8_t method_sn[8];
    make_sn(method_sn, "pop_audio_samples");

    GDExtensionPropertyInfo rinfo;
    memset(&rinfo, 0, sizeof(rinfo));
    rinfo.type = GDEXTENSION_VARIANT_TYPE_PACKED_VECTOR2_ARRAY;
    rinfo.name = (GDExtensionStringNamePtr)empty_sn;
    rinfo.class_name = (GDExtensionStringNamePtr)empty_sn;
    rinfo.hint_string = (GDExtensionStringPtr)empty_str;
    rinfo.usage = 6;

    uint8_t asn[8];
    make_sn(asn, "max_frames");
    GDExtensionPropertyInfo ainfo;
    memset(&ainfo, 0, sizeof(ainfo));
    ainfo.type = GDEXTENSION_VARIANT_TYPE_INT;
    ainfo.name = (GDExtensionStringNamePtr)asn;
    ainfo.class_name = (GDExtensionStringNamePtr)empty_sn;
    ainfo.hint_string = (GDExtensionStringPtr)empty_str;
    ainfo.usage = 6;
    GDExtensionClassMethodArgumentMetadata ameta = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT64;

    int64_t def_val = 0;
    if (gd_variant_from_int_constructor) {
        gd_variant_from_int_constructor(s_default_max_frames, &def_val);
    }

    GDExtensionClassMethodInfo minfo;
    memset(&minfo, 0, sizeof(minfo));
    minfo.name = (GDExtensionStringNamePtr)method_sn;
    minfo.call_func = cli_pop_audio_samples;
    minfo.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
    minfo.has_return_value = 1;
    minfo.return_value_info = &rinfo;
    minfo.argument_count = 1;
    minfo.arguments_info = &ainfo;
    minfo.arguments_metadata = &ameta;
    minfo.default_argument_count = 1;
    minfo.default_arguments = s_default_audio_args;

    if (gd_classdb_register_extension_class_method) {
        gd_classdb_register_extension_class_method(lib, class_sn, &minfo);
    }
}

static void initialize_level(void *p_userdata, GDExtensionInitializationLevel p_level) {
    (void)p_userdata;
    if (p_level != GDEXTENSION_INITIALIZATION_SCENE) return;

    uint8_t class_sn[8];
    uint8_t parent_sn[8];
    make_sn(class_sn, "ACGCShmClient");
    make_sn(parent_sn, "RefCounted");

    GDExtensionClassCreationInfo6 cinfo;
    memset(&cinfo, 0, sizeof(cinfo));
    cinfo.is_virtual = 0;
    cinfo.is_abstract = 0;
    cinfo.is_exposed = 1;
    cinfo.is_runtime = 1;
    cinfo.create_instance_func = cli_create_instance;
    cinfo.free_instance_func = cli_free_instance;
    if (gd_classdb_register_extension_class6) {
        gd_classdb_register_extension_class6(gd_library, class_sn, parent_sn, &cinfo);
    }

    uint8_t empty_sn[8];
    uint8_t empty_str[8];
    make_sn(empty_sn, "");
    make_str(empty_str, "");

    register_method_simple(gd_library, class_sn, "open", cli_open, 1, GDEXTENSION_VARIANT_TYPE_BOOL, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "poll_frame", cli_poll_frame, 1, GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "poll_xinput", cli_poll_xinput, 1, GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, empty_sn, empty_str);
    register_method_pop_audio_samples(gd_library, class_sn, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_audio_cushion_ms", cli_get_audio_cushion_ms, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "send_exit_signal", cli_send_exit_signal, 0, GDEXTENSION_VARIANT_TYPE_NIL, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "is_host_running", cli_is_host_running, 1, GDEXTENSION_VARIANT_TYPE_BOOL, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_frame_id", cli_get_frame_id, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_hour", cli_get_hour, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_minute", cli_get_minute, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_second", cli_get_second, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_weather", cli_get_weather, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_season", cli_get_season, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_scene_no", cli_get_scene_no, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_open_error", cli_get_open_error, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_efb_seq", cli_get_efb_seq, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    {
        const char* names[1] = { "seq" };
        register_method_ints(gd_library, class_sn, "send_efb_ack", cli_send_efb_ack, 1, names, empty_sn, empty_str);
    }

    {
        const char* names[7] = { "buttons", "stick_x", "stick_y", "substick_x", "substick_y", "trigger_l", "trigger_r" };
        register_method_ints(gd_library, class_sn, "send_input", cli_send_input, 7, names, empty_sn, empty_str);
    }
    {
        const char* names[6] = { "year", "month", "day", "hour", "min", "sec" };
        register_method_ints(gd_library, class_sn, "send_rtc_sync", cli_send_rtc_sync, 6, names, empty_sn, empty_str);
    }

    fprintf(stderr, "[GDExtension] ACGCShmClient registration finished successfully!\n");
    fflush(stderr);
}

static void deinitialize_level(void *p_userdata, GDExtensionInitializationLevel p_level) {
    (void)p_userdata; (void)p_level;
    if (p_level == GDEXTENSION_INITIALIZATION_SCENE) {
        shm_close();
    }
}

GDE_EXPORT GDExtensionBool acgc_shm_client_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
                                                GDExtensionClassLibraryPtr p_library,
                                                GDExtensionInitialization *r_initialization) {
    if (!p_get_proc_address || !p_library || !r_initialization) return 0;

    gd_get_proc_address = p_get_proc_address;
    gd_library = p_library;

    gd_string_name_new_with_utf8_chars = (GDExtensionInterfaceStringNameNewWithUtf8Chars)p_get_proc_address("string_name_new_with_utf8_chars");
    gd_string_new_with_utf8_chars = (GDExtensionInterfaceStringNewWithUtf8Chars)p_get_proc_address("string_new_with_utf8_chars");
    gd_classdb_register_extension_class6 = (GDExtensionInterfaceClassdbRegisterExtensionClass6)p_get_proc_address("classdb_register_extension_class6");
    gd_classdb_register_extension_class_method = (GDExtensionInterfaceClassdbRegisterExtensionClassMethod)p_get_proc_address("classdb_register_extension_class_method");
    gd_classdb_construct_object3 = (GDExtensionInterfaceClassdbConstructObject3)p_get_proc_address("classdb_construct_object3");
    gd_object_set_instance = (GDExtensionInterfaceObjectSetInstance)p_get_proc_address("object_set_instance");
    gd_get_variant_from_type_constructor = (GDExtensionInterfaceGetVariantFromTypeConstructor)p_get_proc_address("get_variant_from_type_constructor");
    gd_get_variant_to_type_constructor = (GDExtensionInterfaceGetVariantToTypeConstructor)p_get_proc_address("get_variant_to_type_constructor");
    gd_variant_get_ptr_constructor = (GDExtensionInterfaceVariantGetPtrConstructor)p_get_proc_address("variant_get_ptr_constructor");
    gd_variant_get_ptr_destructor = (GDExtensionInterfaceVariantGetPtrDestructor)p_get_proc_address("variant_get_ptr_destructor");
    gd_variant_get_ptr_builtin_method = (GDExtensionInterfaceVariantGetPtrBuiltinMethod)p_get_proc_address("variant_get_ptr_builtin_method");
    gd_packed_byte_array_operator_index = (GDExtensionInterfacePackedByteArrayOperatorIndex)p_get_proc_address("packed_byte_array_operator_index");
    gd_packed_vector2_array_operator_index = (GDExtensionInterfacePackedVector2ArrayOperatorIndex)p_get_proc_address("packed_vector2_array_operator_index");

    if (gd_get_variant_from_type_constructor) {
        gd_variant_from_int_constructor = gd_get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_INT);
        gd_variant_from_bool_constructor = gd_get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_BOOL);
        gd_variant_from_pba_constructor = gd_get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
        gd_variant_from_pva_constructor = gd_get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_PACKED_VECTOR2_ARRAY);
    }
    if (gd_get_variant_to_type_constructor) {
        gd_variant_to_int_constructor = gd_get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_INT);
    }

    if (gd_variant_get_ptr_constructor) {
        gd_pba_constructor = gd_variant_get_ptr_constructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 0);
        gd_pva_constructor = gd_variant_get_ptr_constructor(GDEXTENSION_VARIANT_TYPE_PACKED_VECTOR2_ARRAY, 0);
    }
    if (gd_variant_get_ptr_destructor) {
        gd_pba_destructor = gd_variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
        gd_pva_destructor = gd_variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_PACKED_VECTOR2_ARRAY);
    }
    if (gd_variant_get_ptr_builtin_method) {
        uint8_t sn_resize[8];
        make_sn(sn_resize, "resize");
        gd_pba_resize = gd_variant_get_ptr_builtin_method(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, sn_resize, 848867239);
        gd_pva_resize = gd_variant_get_ptr_builtin_method(GDEXTENSION_VARIANT_TYPE_PACKED_VECTOR2_ARRAY, sn_resize, 848867239);
    }

    r_initialization->initialize = initialize_level;
    r_initialization->deinitialize = deinitialize_level;
    r_initialization->userdata = NULL;
    r_initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;

#ifdef _WIN32
    install_shader_cache_hook();
#endif

    return 1;
}
