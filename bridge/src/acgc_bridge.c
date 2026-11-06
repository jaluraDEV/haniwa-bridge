/* acgc_bridge.c - GDExtension bridge between Godot and ACGC-PC-Port */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include "gdextension_interface.h"
#include "acgc_api.h"

#ifdef _WIN32
#define GDE_EXPORT __declspec(dllexport)
#else
#define GDE_EXPORT
#endif

/* Godot interface functions */
static GDExtensionInterfaceGetProcAddress gd_get_proc_address = NULL;
static GDExtensionClassLibraryPtr gd_library = NULL;

static GDExtensionInterfaceStringNameNewWithUtf8Chars gd_string_name_new_with_utf8_chars = NULL;
static GDExtensionInterfaceStringNewWithUtf8Chars gd_string_new_with_utf8_chars = NULL;
static GDExtensionInterfaceClassdbRegisterExtensionClass6 gd_classdb_register_extension_class6 = NULL;
static GDExtensionInterfaceClassdbRegisterExtensionClassMethod gd_classdb_register_extension_class_method = NULL;
static GDExtensionInterfaceClassdbConstructObject3 gd_classdb_construct_object3 = NULL;
static GDExtensionInterfaceClassdbConstructObject2 gd_classdb_construct_object2 = NULL;
static GDExtensionInterfaceObjectSetInstance gd_object_set_instance = NULL;
static GDExtensionInterfaceGetVariantFromTypeConstructor gd_get_variant_from_type_constructor = NULL;
static GDExtensionVariantFromTypeConstructorFunc gd_variant_from_int_constructor = NULL;
static GDExtensionVariantFromTypeConstructorFunc gd_variant_from_bool_constructor = NULL;
static GDExtensionInterfaceGetVariantToTypeConstructor gd_get_variant_to_type_constructor = NULL;
static GDExtensionTypeFromVariantConstructorFunc gd_variant_to_int_constructor = NULL;
static GDExtensionVariantFromTypeConstructorFunc gd_variant_from_pba_constructor = NULL;
static GDExtensionInterfaceVariantGetPtrConstructor gd_variant_get_ptr_constructor = NULL;
static GDExtensionInterfaceVariantGetPtrDestructor gd_variant_get_ptr_destructor = NULL;
static GDExtensionInterfaceVariantGetPtrBuiltinMethod gd_variant_get_ptr_builtin_method = NULL;
static GDExtensionInterfacePackedByteArrayOperatorIndex gd_packed_byte_array_operator_index = NULL;
static GDExtensionPtrConstructor gd_pba_constructor = NULL;
static GDExtensionPtrDestructor gd_pba_destructor = NULL;
static GDExtensionPtrBuiltInMethod gd_pba_resize = NULL;

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

/* Method ping() -> int (returns 42) */
static void acgc_bridge_ping(void *method_userdata,
                             GDExtensionClassInstancePtr p_instance,
                             const GDExtensionConstVariantPtr *p_args,
                             GDExtensionInt p_argument_count,
                             GDExtensionVariantPtr r_return,
                             GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = 42;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method init_game([year, month, day, hour, min, sec]) -> bool */
static void acgc_bridge_init_game(void *method_userdata,
                                  GDExtensionClassInstancePtr p_instance,
                                  const GDExtensionConstVariantPtr *p_args,
                                  GDExtensionInt p_argument_count,
                                  GDExtensionVariantPtr r_return,
                                  GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;

    ACGCConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.headless = 1;
    cfg.enable_audio = 1;
    cfg.initial_year = 2002;
    cfg.initial_month = 9;
    cfg.initial_day = 15;
    cfg.initial_hour = 12;
    cfg.initial_min = 0;
    cfg.initial_sec = 0;
    cfg.scene_override = -1;

    if (p_argument_count >= 1 && p_args && p_args[0] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[0]);
        if (v > 0) cfg.initial_year = (uint16_t)v;
    }
    if (p_argument_count >= 2 && p_args && p_args[1] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[1]);
        if (v > 0) cfg.initial_month = (uint8_t)v;
    }
    if (p_argument_count >= 3 && p_args && p_args[2] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[2]);
        if (v > 0) cfg.initial_day = (uint8_t)v;
    }
    if (p_argument_count >= 4 && p_args && p_args[3] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[3]);
        if (v >= 0) cfg.initial_hour = (uint8_t)v;
    }
    if (p_argument_count >= 5 && p_args && p_args[4] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[4]);
        if (v >= 0) cfg.initial_min = (uint8_t)v;
    }
    if (p_argument_count >= 6 && p_args && p_args[5] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[5]);
        if (v >= 0) cfg.initial_sec = (uint8_t)v;
    }
    if (p_argument_count >= 7 && p_args && p_args[6] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[6]);
        cfg.use_fixed_addresses = (int)v;
    }
    if (p_argument_count >= 8 && p_args && p_args[7] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[7]);
        cfg.scene_override = (int)v;
    }

    int ok = acgc_init(&cfg);

    if (r_return && gd_variant_from_bool_constructor) {
        GDExtensionBool val = ok ? 1 : 0;
        gd_variant_from_bool_constructor(r_return, &val);
    }
}

/* Method get_arena_hash() -> int */
static void acgc_bridge_get_arena_hash(void *method_userdata,
                                       GDExtensionClassInstancePtr p_instance,
                                       const GDExtensionConstVariantPtr *p_args,
                                       GDExtensionInt p_argument_count,
                                       GDExtensionVariantPtr r_return,
                                       GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    uint64_t hash = acgc_get_arena_hash();
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)hash;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method tick(buttons, stick_x, stick_y, substick_x, substick_y, trigger_l, trigger_r) -> int */
static void acgc_bridge_tick(void *method_userdata,
                             GDExtensionClassInstancePtr p_instance,
                             const GDExtensionConstVariantPtr *p_args,
                             GDExtensionInt p_argument_count,
                             GDExtensionVariantPtr r_return,
                             GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;

    ACGCPadInput pad;
    memset(&pad, 0, sizeof(pad));

    if (p_argument_count > 0 && p_args && p_args[0] && gd_variant_to_int_constructor) {
        int64_t v = 0;
        gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[0]);
        pad.buttons = (uint16_t)v;
    }
    if (p_argument_count > 1 && p_args && p_args[1] && gd_variant_to_int_constructor) {
        int64_t v = 0;
        gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[1]);
        pad.stick_x = (int8_t)v;
    }
    if (p_argument_count > 2 && p_args && p_args[2] && gd_variant_to_int_constructor) {
        int64_t v = 0;
        gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[2]);
        pad.stick_y = (int8_t)v;
    }
    if (p_argument_count > 3 && p_args && p_args[3] && gd_variant_to_int_constructor) {
        int64_t v = 0;
        gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[3]);
        pad.substick_x = (int8_t)v;
    }
    if (p_argument_count > 4 && p_args && p_args[4] && gd_variant_to_int_constructor) {
        int64_t v = 0;
        gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[4]);
        pad.substick_y = (int8_t)v;
    }
    if (p_argument_count > 5 && p_args && p_args[5] && gd_variant_to_int_constructor) {
        int64_t v = 0;
        gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[5]);
        pad.trigger_l = (uint8_t)v;
    }
    if (p_argument_count > 6 && p_args && p_args[6] && gd_variant_to_int_constructor) {
        int64_t v = 0;
        gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[6]);
        pad.trigger_r = (uint8_t)v;
    }

    int active = acgc_tick(&pad);
    (void)active;

    if (r_return && gd_variant_from_int_constructor) {
        extern uint32_t pc_frame_counter;
        int64_t val = (int64_t)pc_frame_counter;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method dump_arena(index: int) -> bool */
static void acgc_bridge_dump_arena(void *method_userdata,
                                   GDExtensionClassInstancePtr p_instance,
                                   const GDExtensionConstVariantPtr *p_args,
                                   GDExtensionInt p_argument_count,
                                   GDExtensionVariantPtr r_return,
                                   GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    int idx = 0;
    if (p_argument_count > 0 && p_args && p_args[0] && gd_variant_to_int_constructor) {
        int64_t v = 0;
        gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[0]);
        idx = (int)v;
    }
    char path[64];
    snprintf(path, sizeof(path), "arena_run%d.bin", idx);
    int ok = acgc_dump_arena(path);
    if (r_return && gd_variant_from_bool_constructor) {
        GDExtensionBool val = ok ? 1 : 0;
        gd_variant_from_bool_constructor(r_return, &val);
    }
}

/* Method shutdown_game() -> void */
static void acgc_bridge_shutdown_game(void *method_userdata,
                                      GDExtensionClassInstancePtr p_instance,
                                      const GDExtensionConstVariantPtr *p_args,
                                      GDExtensionInt p_argument_count,
                                      GDExtensionVariantPtr r_return,
                                      GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count; (void)r_return;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    acgc_shutdown();
}

/* Method get_frame_count() -> int */
static void acgc_bridge_get_frame_count(void *method_userdata,
                                        GDExtensionClassInstancePtr p_instance,
                                        const GDExtensionConstVariantPtr *p_args,
                                        GDExtensionInt p_argument_count,
                                        GDExtensionVariantPtr r_return,
                                        GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    if (r_return && gd_variant_from_int_constructor) {
        extern uint32_t pc_frame_counter;
        int64_t val = (int64_t)pc_frame_counter;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method get_hour() -> int */
static void acgc_bridge_get_hour(void *method_userdata,
                                 GDExtensionClassInstancePtr p_instance,
                                 const GDExtensionConstVariantPtr *p_args,
                                 GDExtensionInt p_argument_count,
                                 GDExtensionVariantPtr r_return,
                                 GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    ACGCState state;
    acgc_get_state(&state);
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)state.hour;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method get_minute() -> int */
static void acgc_bridge_get_minute(void *method_userdata,
                                   GDExtensionClassInstancePtr p_instance,
                                   const GDExtensionConstVariantPtr *p_args,
                                   GDExtensionInt p_argument_count,
                                   GDExtensionVariantPtr r_return,
                                   GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    ACGCState state;
    acgc_get_state(&state);
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)state.minute;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method get_second() -> int */
static void acgc_bridge_get_second(void *method_userdata,
                                   GDExtensionClassInstancePtr p_instance,
                                   const GDExtensionConstVariantPtr *p_args,
                                   GDExtensionInt p_argument_count,
                                   GDExtensionVariantPtr r_return,
                                   GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    ACGCState state;
    acgc_get_state(&state);
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)state.second;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method get_season() -> int */
static void acgc_bridge_get_season(void *method_userdata,
                                   GDExtensionClassInstancePtr p_instance,
                                   const GDExtensionConstVariantPtr *p_args,
                                   GDExtensionInt p_argument_count,
                                   GDExtensionVariantPtr r_return,
                                   GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    ACGCState state;
    acgc_get_state(&state);
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)state.season;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method get_weather() -> int */
static void acgc_bridge_get_weather(void *method_userdata,
                                    GDExtensionClassInstancePtr p_instance,
                                    const GDExtensionConstVariantPtr *p_args,
                                    GDExtensionInt p_argument_count,
                                    GDExtensionVariantPtr r_return,
                                    GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    ACGCState state;
    acgc_get_state(&state);
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)state.weather;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method get_now_sec() -> int */
static void acgc_bridge_get_now_sec(void *method_userdata,
                                    GDExtensionClassInstancePtr p_instance,
                                    const GDExtensionConstVariantPtr *p_args,
                                    GDExtensionInt p_argument_count,
                                    GDExtensionVariantPtr r_return,
                                    GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    ACGCState state;
    acgc_get_state(&state);
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)state.now_sec;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method is_game_running() -> bool */
static void acgc_bridge_is_game_running(void *method_userdata,
                                        GDExtensionClassInstancePtr p_instance,
                                        const GDExtensionConstVariantPtr *p_args,
                                        GDExtensionInt p_argument_count,
                                        GDExtensionVariantPtr r_return,
                                        GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    ACGCState state;
    acgc_get_state(&state);
    if (r_return && gd_variant_from_bool_constructor) {
        GDExtensionBool val = state.is_running ? 1 : 0;
        gd_variant_from_bool_constructor(r_return, &val);
    }
}

/* Method get_scene_no() -> int */
static void acgc_bridge_get_scene_no(void *method_userdata,
                                     GDExtensionClassInstancePtr p_instance,
                                     const GDExtensionConstVariantPtr *p_args,
                                     GDExtensionInt p_argument_count,
                                     GDExtensionVariantPtr r_return,
                                     GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    int s = acgc_get_scene_no();
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)s;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method get_scene_mode() -> int */
static void acgc_bridge_get_scene_mode(void *method_userdata,
                                       GDExtensionClassInstancePtr p_instance,
                                       const GDExtensionConstVariantPtr *p_args,
                                       GDExtensionInt p_argument_count,
                                       GDExtensionVariantPtr r_return,
                                       GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    int s = acgc_get_scene_mode();
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)s;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method get_rng_seed() -> int */
static void acgc_bridge_get_rng_seed(void *method_userdata,
                                     GDExtensionClassInstancePtr p_instance,
                                     const GDExtensionConstVariantPtr *p_args,
                                     GDExtensionInt p_argument_count,
                                     GDExtensionVariantPtr r_return,
                                     GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    uint32_t s = acgc_get_rng_seed();
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)s;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method get_actor_count() -> int */
static void acgc_bridge_get_actor_count(void *method_userdata,
                                        GDExtensionClassInstancePtr p_instance,
                                        const GDExtensionConstVariantPtr *p_args,
                                        GDExtensionInt p_argument_count,
                                        GDExtensionVariantPtr r_return,
                                        GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    int cnt = acgc_get_actor_count();
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)cnt;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method poke_arena_byte(offset: int, val: int) -> void */
static void acgc_bridge_poke_arena_byte(void *method_userdata,
                                        GDExtensionClassInstancePtr p_instance,
                                        const GDExtensionConstVariantPtr *p_args,
                                        GDExtensionInt p_argument_count,
                                        GDExtensionVariantPtr r_return,
                                        GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)r_return;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    uint32_t offset = 0;
    uint8_t val = 0;
    if (p_argument_count >= 1 && p_args && p_args[0] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[0]);
        offset = (uint32_t)v;
    }
    if (p_argument_count >= 2 && p_args && p_args[1] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[1]);
        val = (uint8_t)v;
    }
    acgc_poke_arena_byte(offset, val);
}

/* Method peek_arena_byte(offset: int) -> int */
static void acgc_bridge_peek_arena_byte(void *method_userdata,
                                        GDExtensionClassInstancePtr p_instance,
                                        const GDExtensionConstVariantPtr *p_args,
                                        GDExtensionInt p_argument_count,
                                        GDExtensionVariantPtr r_return,
                                        GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    uint32_t offset = 0;
    if (p_argument_count >= 1 && p_args && p_args[0] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[0]);
        offset = (uint32_t)v;
    }
    uint8_t val = acgc_peek_arena_byte(offset);
    if (r_return && gd_variant_from_int_constructor) {
        int64_t r = val;
        gd_variant_from_int_constructor(r_return, &r);
    }
}

/* Method poke_actor_byte(offset: int, val: int) -> void */
static void acgc_bridge_poke_actor_byte(void *method_userdata,
                                        GDExtensionClassInstancePtr p_instance,
                                        const GDExtensionConstVariantPtr *p_args,
                                        GDExtensionInt p_argument_count,
                                        GDExtensionVariantPtr r_return,
                                        GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)r_return;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    uint32_t offset = 0;
    uint8_t val = 0;
    if (p_argument_count >= 1 && p_args && p_args[0] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[0]);
        offset = (uint32_t)v;
    }
    if (p_argument_count >= 2 && p_args && p_args[1] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[1]);
        val = (uint8_t)v;
    }
    acgc_poke_actor_byte(offset, val);
}

/* Method peek_actor_byte(offset: int) -> int */
static void acgc_bridge_peek_actor_byte(void *method_userdata,
                                        GDExtensionClassInstancePtr p_instance,
                                        const GDExtensionConstVariantPtr *p_args,
                                        GDExtensionInt p_argument_count,
                                        GDExtensionVariantPtr r_return,
                                        GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    uint32_t offset = 0;
    if (p_argument_count >= 1 && p_args && p_args[0] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[0]);
        offset = (uint32_t)v;
    }
    uint8_t val = acgc_peek_actor_byte(offset);
    if (r_return && gd_variant_from_int_constructor) {
        int64_t r = val;
        gd_variant_from_int_constructor(r_return, &r);
    }
}

/* Method poke_rng_seed(seed: int) -> void */
static void acgc_bridge_poke_rng_seed(void *method_userdata,
                                      GDExtensionClassInstancePtr p_instance,
                                      const GDExtensionConstVariantPtr *p_args,
                                      GDExtensionInt p_argument_count,
                                      GDExtensionVariantPtr r_return,
                                      GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)r_return;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    uint32_t seed = 0;
    if (p_argument_count >= 1 && p_args && p_args[0] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[0]);
        seed = (uint32_t)v;
    }
    acgc_poke_rng_seed(seed);
}

/* Legacy helper: run_ticks(ticks: int) -> int */
extern int pc_run_headless(int ticks);
static void acgc_bridge_run_ticks(void *method_userdata,
                                  GDExtensionClassInstancePtr p_instance,
                                  const GDExtensionConstVariantPtr *p_args,
                                  GDExtensionInt p_argument_count,
                                  GDExtensionVariantPtr r_return,
                                  GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance;
    int64_t ticks = 60;
    if (p_argument_count > 0 && p_args && p_args[0] && gd_variant_to_int_constructor) {
        gd_variant_to_int_constructor(&ticks, (GDExtensionVariantPtr)p_args[0]);
    }
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    int result = pc_run_headless((int)ticks);
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = result;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method get_frame_packet() -> PackedByteArray */
static void acgc_bridge_get_frame_packet(void *method_userdata,
                                         GDExtensionClassInstancePtr p_instance,
                                         const GDExtensionConstVariantPtr *p_args,
                                         GDExtensionInt p_argument_count,
                                         GDExtensionVariantPtr r_return,
                                         GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;

    if (!r_return || !gd_variant_from_pba_constructor || !gd_pba_constructor || !gd_pba_destructor) {
        return;
    }

    size_t size = 0;
    const void* data = acgc_get_frame_packet(&size);

    uint8_t pba_storage[16];
    memset(pba_storage, 0, sizeof(pba_storage));
    gd_pba_constructor(pba_storage, NULL);

    if (data && size > 0 && size <= 16 * 1024 * 1024 && gd_pba_resize && gd_packed_byte_array_operator_index) {
        int64_t target_size = (int64_t)size;
        const void* args[1] = { &target_size };
        int64_t ret = 0;
        gd_pba_resize(pba_storage, args, &ret, 1);
        uint8_t* dst = gd_packed_byte_array_operator_index(pba_storage, 0);
        if (dst) {
            memcpy(dst, data, size);
        } else {
            fprintf(stderr, "[Bridge ERROR] dst is NULL! size=%zu target_size=%lld ret=%lld\n", size, (long long)target_size, (long long)ret);
        }
    } else if (size > 16 * 1024 * 1024) {
        fprintf(stderr, "[Bridge ERROR] Refusing to allocate runaway packet: %zu bytes\n", size);
    }

    gd_variant_from_pba_constructor(r_return, pba_storage);
    gd_pba_destructor(pba_storage);
}

/* Method get_frame_packet_size() -> int */
static void acgc_bridge_get_frame_packet_size(void *method_userdata,
                                              GDExtensionClassInstancePtr p_instance,
                                              const GDExtensionConstVariantPtr *p_args,
                                              GDExtensionInt p_argument_count,
                                              GDExtensionVariantPtr r_return,
                                              GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    size_t size = 0;
    acgc_get_frame_packet(&size);
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)size;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method get_frame_packet_ptr() -> int */
static void acgc_bridge_get_frame_packet_ptr(void *method_userdata,
                                             GDExtensionClassInstancePtr p_instance,
                                             const GDExtensionConstVariantPtr *p_args,
                                             GDExtensionInt p_argument_count,
                                             GDExtensionVariantPtr r_return,
                                             GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    size_t size = 0;
    const void* ptr = acgc_get_frame_packet(&size);
    if (r_return && gd_variant_from_int_constructor) {
        int64_t val = (int64_t)(uintptr_t)ptr;
        gd_variant_from_int_constructor(r_return, &val);
    }
}

/* Method has_frame_packet() -> bool */
static void acgc_bridge_has_frame_packet(void *method_userdata,
                                         GDExtensionClassInstancePtr p_instance,
                                         const GDExtensionConstVariantPtr *p_args,
                                         GDExtensionInt p_argument_count,
                                         GDExtensionVariantPtr r_return,
                                         GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    int has = acgc_has_frame_packet();
    if (r_return && gd_variant_from_bool_constructor) {
        GDExtensionBool val = has ? 1 : 0;
        gd_variant_from_bool_constructor(r_return, &val);
    }
}

/* Method set_scene(scene_id: int) -> void */
static void acgc_bridge_set_scene(void *method_userdata,
                                  GDExtensionClassInstancePtr p_instance,
                                  const GDExtensionConstVariantPtr *p_args,
                                  GDExtensionInt p_argument_count,
                                  GDExtensionVariantPtr r_return,
                                  GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)r_return;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    int sc = -1;
    if (p_argument_count >= 1 && p_args && p_args[0] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[0]);
        sc = (int)v;
    }
    acgc_set_scene(sc);
}

/* Method change_scene(scene_id: int) -> void */
static void acgc_bridge_change_scene(void *method_userdata,
                                     GDExtensionClassInstancePtr p_instance,
                                     const GDExtensionConstVariantPtr *p_args,
                                     GDExtensionInt p_argument_count,
                                     GDExtensionVariantPtr r_return,
                                     GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)r_return;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    int sc = -1;
    if (p_argument_count >= 1 && p_args && p_args[0] && gd_variant_to_int_constructor) {
        int64_t v = 0; gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[0]);
        sc = (int)v;
    }
    acgc_change_scene(sc);
}

static GDExtensionObjectPtr acgc_bridge_create_instance(void *p_class_userdata, GDExtensionBool p_notify_postinitialize) {
    (void)p_class_userdata;
    (void)p_notify_postinitialize;
    uint8_t parent_sn[8];
    make_sn(parent_sn, "RefCounted");
    GDExtensionObjectPtr obj = NULL;
    if (gd_classdb_construct_object3) {
        obj = gd_classdb_construct_object3(parent_sn);
    } else if (gd_classdb_construct_object2) {
        obj = gd_classdb_construct_object2(parent_sn);
    }
    if (obj && gd_object_set_instance) {
        uint8_t class_sn[8];
        make_sn(class_sn, "ACGCBridge");
        gd_object_set_instance(obj, class_sn, (void*)0x1);
    }
    return obj;
}

static void acgc_bridge_free_instance(void *p_class_userdata, GDExtensionClassInstancePtr p_instance) {
    (void)p_class_userdata;
    (void)p_instance;
}

/* Method registration helper */
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

static void acgc_bridge_dump_state_breakdown(void *method_userdata,
                                            GDExtensionClassInstancePtr p_instance,
                                            const GDExtensionConstVariantPtr *p_args,
                                            GDExtensionInt p_argument_count,
                                            GDExtensionVariantPtr r_return,
                                            GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    int run_id = 0;
    if (p_argument_count > 0 && p_args && p_args[0] && gd_variant_to_int_constructor) {
        int64_t v = 0;
        gd_variant_to_int_constructor(&v, (GDExtensionVariantPtr)p_args[0]);
        run_id = (int)v;
    }
    int ok = acgc_dump_state_breakdown("dump", run_id);
    if (r_return && gd_variant_from_bool_constructor) {
        GDExtensionBool val = ok ? 1 : 0;
        gd_variant_from_bool_constructor(r_return, &val);
    }
}

extern int pc_audio_get_underruns(void);
extern int pc_audio_get_dropped_samples(void);
extern int pc_audio_get_buffer_fill(void);

static void acgc_bridge_get_audio_underruns(void *method_userdata,
                                            GDExtensionClassInstancePtr p_instance,
                                            const GDExtensionConstVariantPtr *p_args,
                                            GDExtensionInt p_argument_count,
                                            GDExtensionVariantPtr r_return,
                                            GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    int64_t val = (int64_t)pc_audio_get_underruns();
    if (r_return && gd_variant_from_int_constructor) {
        gd_variant_from_int_constructor(r_return, &val);
    }
}

static void acgc_bridge_get_audio_dropped_samples(void *method_userdata,
                                            GDExtensionClassInstancePtr p_instance,
                                            const GDExtensionConstVariantPtr *p_args,
                                            GDExtensionInt p_argument_count,
                                            GDExtensionVariantPtr r_return,
                                            GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    int64_t val = (int64_t)pc_audio_get_dropped_samples();
    if (r_return && gd_variant_from_int_constructor) {
        gd_variant_from_int_constructor(r_return, &val);
    }
}

static void acgc_bridge_get_audio_fill(void *method_userdata,
                                       GDExtensionClassInstancePtr p_instance,
                                       const GDExtensionConstVariantPtr *p_args,
                                       GDExtensionInt p_argument_count,
                                       GDExtensionVariantPtr r_return,
                                       GDExtensionCallError *r_error) {
    (void)method_userdata; (void)p_instance; (void)p_args; (void)p_argument_count;
    if (r_error) r_error->error = GDEXTENSION_CALL_OK;
    int64_t val = (int64_t)pc_audio_get_buffer_fill();
    if (r_return && gd_variant_from_int_constructor) {
        gd_variant_from_int_constructor(r_return, &val);
    }
}

static void initialize_level(void *p_userdata, GDExtensionInitializationLevel p_level) {
    (void)p_userdata;
    if (p_level != GDEXTENSION_INITIALIZATION_SCENE) {
        return;
    }

    uint8_t class_sn[8];
    uint8_t parent_sn[8];
    make_sn(class_sn, "ACGCBridge");
    make_sn(parent_sn, "RefCounted");

    GDExtensionClassCreationInfo6 cinfo;
    memset(&cinfo, 0, sizeof(cinfo));
    cinfo.is_virtual = 0;
    cinfo.is_abstract = 0;
    cinfo.is_exposed = 1;
    cinfo.is_runtime = 1;
    cinfo.create_instance_func = acgc_bridge_create_instance;
    cinfo.free_instance_func = acgc_bridge_free_instance;

    if (gd_classdb_register_extension_class6) {
        gd_classdb_register_extension_class6(gd_library, class_sn, parent_sn, &cinfo);
    }

    uint8_t empty_sn[8];
    uint8_t empty_str[8];
    make_sn(empty_sn, "");
    make_str(empty_str, "");

    /* Register simple methods */
    register_method_simple(gd_library, class_sn, "ping", acgc_bridge_ping, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "init_game", acgc_bridge_init_game, 1, GDEXTENSION_VARIANT_TYPE_BOOL, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "shutdown_game", acgc_bridge_shutdown_game, 0, GDEXTENSION_VARIANT_TYPE_NIL, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_frame_count", acgc_bridge_get_frame_count, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_hour", acgc_bridge_get_hour, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_minute", acgc_bridge_get_minute, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_second", acgc_bridge_get_second, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_season", acgc_bridge_get_season, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_weather", acgc_bridge_get_weather, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_now_sec", acgc_bridge_get_now_sec, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_arena_hash", acgc_bridge_get_arena_hash, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "dump_arena", acgc_bridge_dump_arena, 1, GDEXTENSION_VARIANT_TYPE_BOOL, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "is_game_running", acgc_bridge_is_game_running, 1, GDEXTENSION_VARIANT_TYPE_BOOL, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_scene_no", acgc_bridge_get_scene_no, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_scene_mode", acgc_bridge_get_scene_mode, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_rng_seed", acgc_bridge_get_rng_seed, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_actor_count", acgc_bridge_get_actor_count, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "poke_arena_byte", acgc_bridge_poke_arena_byte, 0, GDEXTENSION_VARIANT_TYPE_NIL, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "peek_arena_byte", acgc_bridge_peek_arena_byte, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "poke_actor_byte", acgc_bridge_poke_actor_byte, 0, GDEXTENSION_VARIANT_TYPE_NIL, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "peek_actor_byte", acgc_bridge_peek_actor_byte, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "poke_rng_seed", acgc_bridge_poke_rng_seed, 0, GDEXTENSION_VARIANT_TYPE_NIL, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "dump_state_breakdown", acgc_bridge_dump_state_breakdown, 1, GDEXTENSION_VARIANT_TYPE_BOOL, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_frame_packet", acgc_bridge_get_frame_packet, 1, GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_frame_packet_size", acgc_bridge_get_frame_packet_size, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_frame_packet_ptr", acgc_bridge_get_frame_packet_ptr, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "has_frame_packet", acgc_bridge_has_frame_packet, 1, GDEXTENSION_VARIANT_TYPE_BOOL, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_audio_underruns", acgc_bridge_get_audio_underruns, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_audio_dropped_samples", acgc_bridge_get_audio_dropped_samples, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);
    register_method_simple(gd_library, class_sn, "get_audio_fill", acgc_bridge_get_audio_fill, 1, GDEXTENSION_VARIANT_TYPE_INT, empty_sn, empty_str);

    /* Method set_scene(scene_id: int) -> void */
    {
        uint8_t method_sn[8];
        make_sn(method_sn, "set_scene");
        uint8_t arg_sn[8];
        make_sn(arg_sn, "scene_id");

        GDExtensionPropertyInfo ainfo;
        memset(&ainfo, 0, sizeof(ainfo));
        ainfo.type = GDEXTENSION_VARIANT_TYPE_INT;
        ainfo.name = (GDExtensionStringNamePtr)arg_sn;
        ainfo.class_name = (GDExtensionStringNamePtr)empty_sn;
        ainfo.hint_string = (GDExtensionStringPtr)empty_str;
        ainfo.usage = 6;

        GDExtensionClassMethodArgumentMetadata ameta = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT64;

        GDExtensionClassMethodInfo minfo;
        memset(&minfo, 0, sizeof(minfo));
        minfo.name = (GDExtensionStringNamePtr)method_sn;
        minfo.call_func = acgc_bridge_set_scene;
        minfo.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
        minfo.has_return_value = 0;
        minfo.argument_count = 1;
        minfo.arguments_info = &ainfo;
        minfo.arguments_metadata = &ameta;

        if (gd_classdb_register_extension_class_method) {
            gd_classdb_register_extension_class_method(gd_library, class_sn, &minfo);
        }
    }

    /* Method change_scene(scene_id: int) -> void */
    {
        uint8_t method_sn[8];
        make_sn(method_sn, "change_scene");
        uint8_t arg_sn[8];
        make_sn(arg_sn, "scene_id");

        GDExtensionPropertyInfo ainfo;
        memset(&ainfo, 0, sizeof(ainfo));
        ainfo.type = GDEXTENSION_VARIANT_TYPE_INT;
        ainfo.name = (GDExtensionStringNamePtr)arg_sn;
        ainfo.class_name = (GDExtensionStringNamePtr)empty_sn;
        ainfo.hint_string = (GDExtensionStringPtr)empty_str;
        ainfo.usage = 6;

        GDExtensionClassMethodArgumentMetadata ameta = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT64;

        GDExtensionClassMethodInfo minfo;
        memset(&minfo, 0, sizeof(minfo));
        minfo.name = (GDExtensionStringNamePtr)method_sn;
        minfo.call_func = acgc_bridge_change_scene;
        minfo.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
        minfo.has_return_value = 0;
        minfo.argument_count = 1;
        minfo.arguments_info = &ainfo;
        minfo.arguments_metadata = &ameta;

        if (gd_classdb_register_extension_class_method) {
            gd_classdb_register_extension_class_method(gd_library, class_sn, &minfo);
        }
    }

    /* Legacy run_ticks */
    {
        uint8_t method_sn[8];
        make_sn(method_sn, "run_ticks");
        uint8_t arg_sn[8];
        make_sn(arg_sn, "ticks");

        GDExtensionPropertyInfo rinfo;
        memset(&rinfo, 0, sizeof(rinfo));
        rinfo.type = GDEXTENSION_VARIANT_TYPE_INT;
        rinfo.name = (GDExtensionStringNamePtr)empty_sn;
        rinfo.class_name = (GDExtensionStringNamePtr)empty_sn;
        rinfo.hint_string = (GDExtensionStringPtr)empty_str;
        rinfo.usage = 6;

        GDExtensionPropertyInfo ainfo;
        memset(&ainfo, 0, sizeof(ainfo));
        ainfo.type = GDEXTENSION_VARIANT_TYPE_INT;
        ainfo.name = (GDExtensionStringNamePtr)arg_sn;
        ainfo.class_name = (GDExtensionStringNamePtr)empty_sn;
        ainfo.hint_string = (GDExtensionStringPtr)empty_str;
        ainfo.usage = 6;

        GDExtensionClassMethodArgumentMetadata ameta = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT64;

        GDExtensionClassMethodInfo minfo;
        memset(&minfo, 0, sizeof(minfo));
        minfo.name = (GDExtensionStringNamePtr)method_sn;
        minfo.call_func = acgc_bridge_run_ticks;
        minfo.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
        minfo.has_return_value = 1;
        minfo.return_value_info = &rinfo;
        minfo.return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT64;
        minfo.argument_count = 1;
        minfo.arguments_info = &ainfo;
        minfo.arguments_metadata = &ameta;

        if (gd_classdb_register_extension_class_method) {
            gd_classdb_register_extension_class_method(gd_library, class_sn, &minfo);
        }
    }

    /* Register tick(buttons, stick_x, stick_y, substick_x, substick_y, trigger_l, trigger_r) -> int */
    {
        uint8_t method_sn[8];
        make_sn(method_sn, "tick");

        GDExtensionPropertyInfo rinfo;
        memset(&rinfo, 0, sizeof(rinfo));
        rinfo.type = GDEXTENSION_VARIANT_TYPE_INT;
        rinfo.name = (GDExtensionStringNamePtr)empty_sn;
        rinfo.class_name = (GDExtensionStringNamePtr)empty_sn;
        rinfo.hint_string = (GDExtensionStringPtr)empty_str;
        rinfo.usage = 6;

        GDExtensionPropertyInfo ainfo[7];
        GDExtensionClassMethodArgumentMetadata ameta[7];
        const char* anames[7] = { "buttons", "stick_x", "stick_y", "substick_x", "substick_y", "trigger_l", "trigger_r" };
        uint8_t asns[7][8];

        for (int i = 0; i < 7; i++) {
            make_sn(asns[i], anames[i]);
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
        minfo.call_func = acgc_bridge_tick;
        minfo.method_flags = GDEXTENSION_METHOD_FLAG_NORMAL;
        minfo.has_return_value = 1;
        minfo.return_value_info = &rinfo;
        minfo.return_value_metadata = GDEXTENSION_METHOD_ARGUMENT_METADATA_INT_IS_INT64;
        minfo.argument_count = 7;
        minfo.arguments_info = ainfo;
        minfo.arguments_metadata = ameta;

        if (gd_classdb_register_extension_class_method) {
            gd_classdb_register_extension_class_method(gd_library, class_sn, &minfo);
        }
    }

    fprintf(stderr, "[GDExtension] ACGCBridge registration finished successfully!\n");
    fflush(stderr);
}

static void deinitialize_level(void *p_userdata, GDExtensionInitializationLevel p_level) {
    (void)p_userdata;
    (void)p_level;
}

GDE_EXPORT GDExtensionBool acgc_bridge_init(GDExtensionInterfaceGetProcAddress p_get_proc_address,
                                            GDExtensionClassLibraryPtr p_library,
                                            GDExtensionInitialization *r_initialization) {
    if (!p_get_proc_address || !p_library || !r_initialization) {
        return 0;
    }

    gd_get_proc_address = p_get_proc_address;
    gd_library = p_library;

    gd_string_name_new_with_utf8_chars = (GDExtensionInterfaceStringNameNewWithUtf8Chars)p_get_proc_address("string_name_new_with_utf8_chars");
    gd_string_new_with_utf8_chars = (GDExtensionInterfaceStringNewWithUtf8Chars)p_get_proc_address("string_new_with_utf8_chars");
    gd_classdb_register_extension_class6 = (GDExtensionInterfaceClassdbRegisterExtensionClass6)p_get_proc_address("classdb_register_extension_class6");
    gd_classdb_register_extension_class_method = (GDExtensionInterfaceClassdbRegisterExtensionClassMethod)p_get_proc_address("classdb_register_extension_class_method");
    gd_classdb_construct_object3 = (GDExtensionInterfaceClassdbConstructObject3)p_get_proc_address("classdb_construct_object3");
    gd_classdb_construct_object2 = (GDExtensionInterfaceClassdbConstructObject2)p_get_proc_address("classdb_construct_object2");
    gd_object_set_instance = (GDExtensionInterfaceObjectSetInstance)p_get_proc_address("object_set_instance");
    gd_get_variant_from_type_constructor = (GDExtensionInterfaceGetVariantFromTypeConstructor)p_get_proc_address("get_variant_from_type_constructor");
    gd_get_variant_to_type_constructor = (GDExtensionInterfaceGetVariantToTypeConstructor)p_get_proc_address("get_variant_to_type_constructor");

    if (gd_get_variant_from_type_constructor) {
        gd_variant_from_int_constructor = gd_get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_INT);
        gd_variant_from_bool_constructor = gd_get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_BOOL);
        gd_variant_from_pba_constructor = gd_get_variant_from_type_constructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
    }
    if (gd_get_variant_to_type_constructor) {
        gd_variant_to_int_constructor = gd_get_variant_to_type_constructor(GDEXTENSION_VARIANT_TYPE_INT);
    }

    gd_variant_get_ptr_constructor = (GDExtensionInterfaceVariantGetPtrConstructor)p_get_proc_address("variant_get_ptr_constructor");
    gd_variant_get_ptr_destructor = (GDExtensionInterfaceVariantGetPtrDestructor)p_get_proc_address("variant_get_ptr_destructor");
    gd_variant_get_ptr_builtin_method = (GDExtensionInterfaceVariantGetPtrBuiltinMethod)p_get_proc_address("variant_get_ptr_builtin_method");
    gd_packed_byte_array_operator_index = (GDExtensionInterfacePackedByteArrayOperatorIndex)p_get_proc_address("packed_byte_array_operator_index");

    if (gd_variant_get_ptr_constructor) {
        gd_pba_constructor = gd_variant_get_ptr_constructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, 0);
    }
    if (gd_variant_get_ptr_destructor) {
        gd_pba_destructor = gd_variant_get_ptr_destructor(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY);
    }
    if (gd_variant_get_ptr_builtin_method) {
        uint8_t sn_resize[8];
        make_sn(sn_resize, "resize");
        gd_pba_resize = gd_variant_get_ptr_builtin_method(GDEXTENSION_VARIANT_TYPE_PACKED_BYTE_ARRAY, sn_resize, 848867239);
    }

    r_initialization->initialize = initialize_level;
    r_initialization->deinitialize = deinitialize_level;
    r_initialization->userdata = NULL;
    r_initialization->minimum_initialization_level = GDEXTENSION_INITIALIZATION_SCENE;

    return 1;
}
