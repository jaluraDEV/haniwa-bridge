/* pc_os.c - Dolphin OS replacement: arena, timers, threads, message queues */
#include "pc_platform.h"
#include "libc64/qrand.h"

#include <time.h>

int g_pc_use_fixed_addresses = 0;

/* Layout matching OSArena and OSMemBlock from libc64/__osMalloc.h */
typedef struct PCMemBlock_s {
    s16 magic;
    s16 free;
    s32 size;
    struct PCMemBlock_s* next;
    struct PCMemBlock_s* prev;
} PCMemBlock;

typedef struct PCArena_s {
    PCMemBlock* head;
    u8* base;
    u8 unused[0x20];
    u8 _28;
    u8 initialized;
    u8 flags;
} PCArena;

extern PCArena zelda_arena;

/* --- Memory arena --- */
static u8* arena_memory = NULL;
static u8* arena_lo = NULL;
static u8* arena_hi = NULL;

extern void __osMallocInit(void* arena, u8* base, s32 size);
extern void* __osMalloc(void* arena, u32 size);
extern void __osFree(void* arena, void* ptr);

/* Deterministic game heap within GameCube arena memory */
static PCArena s_pc_game_arena;
static int s_pc_game_arena_initialized = 0;

void pc_game_arena_init(void) {
    if (!s_pc_game_arena_initialized && arena_memory) {
        u8* base = arena_memory + 0x040000;
        s32 size = 0x800000; /* 8 MB dedicated for game state (s_game, hyral, gamealloc) */
        __osMallocInit(&s_pc_game_arena, base, size);
        s_pc_game_arena.flags |= 1; /* OSArena_FLAG_CLEAR_MEM_ON_ALLOC */
        s_pc_game_arena_initialized = 1;
    }
}

void* pc_game_malloc(size_t size) {
    if (!s_pc_game_arena_initialized) pc_game_arena_init();
    void* ptr = NULL;
    if (s_pc_game_arena_initialized) {
        ptr = __osMalloc(&s_pc_game_arena, (u32)size);
    }
    if (!ptr) {
        ptr = malloc(size);
    }
    if (ptr) {
        memset(ptr, 0, size);
    }
    return ptr;
}

void pc_game_free(void* ptr) {
    if (!ptr) return;
    uintptr_t uptr = (uintptr_t)ptr;
    uintptr_t a_start = (uintptr_t)arena_memory;
    if (a_start && uptr >= a_start && uptr < a_start + PC_MAIN_MEMORY_SIZE) {
        __osFree(&s_pc_game_arena, ptr);
    } else {
        free(ptr);
    }
}

void* OSGetArenaLo(void) { return arena_lo; }
void* OSGetArenaHi(void) { return arena_hi; }
void  OSSetArenaLo(void* lo) { arena_lo = (u8*)lo; }
void  OSSetArenaHi(void* hi) { arena_hi = (u8*)hi; }
u8*   pc_get_arena_memory(void) { return arena_memory; }

/* --- Time/clock --- */
u32 pc_OSBusClock  = GC_BUS_CLOCK;
u32 pc_OSCoreClock = GC_CORE_CLOCK;

static u64 time_base_start = 0;
static s64 gc_epoch_offset_ticks = 0; /* Ticks from GC epoch to program start */
int g_pc_system_rtc = 0; /* Opt-in by the standalone host; replay clocks stay deterministic. */
static s64 s_library_time_ticks = 0;  /* Deterministic injected tick clock */

/* GC epoch: Jan 1, 2000 (946684800 seconds after Unix epoch) */
#define GC_UNIX_EPOCH_DIFF 946684800LL

void pc_time_set_initial(u16 year, u8 month, u8 day, u8 hour, u8 min, u8 sec) {
    if (year == 0) year = 2002;
    if (month == 0 || month > 12) month = 9;
    if (day == 0 || day > 31) day = 15;
    if (hour > 23) hour = 12;
    if (min > 59) min = 0;
    if (sec > 59) sec = 0;

    struct tm tm_val;
    memset(&tm_val, 0, sizeof(tm_val));
    tm_val.tm_year = year - 1900;
    tm_val.tm_mon  = month - 1;
    tm_val.tm_mday = day;
    tm_val.tm_hour = hour;
    tm_val.tm_min  = min;
    tm_val.tm_sec  = sec;
    tm_val.tm_isdst = -1;

    time_t t = mktime(&tm_val);
    s64 gc_secs = (s64)(t - GC_UNIX_EPOCH_DIFF);
    s_library_time_ticks = gc_secs * (s64)GC_TIMER_CLOCK;
}

void pc_time_step_tick(void) {
    /* Each 60 Hz tick advances hardware time by exactly (GC_TIMER_CLOCK / 60) */
    s_library_time_ticks += (s64)(GC_TIMER_CLOCK / 60);
}

u64 pc_get_arena_hash(void) {
    if (!arena_memory) return 0;
    const u64 FNV_OFFSET_BASIS = 0xcbf29ce484222325ULL;
    const u64 FNV_PRIME = 0x100000001b3ULL;
    u64 hash = FNV_OFFSET_BASIS;

    uintptr_t arena_start = (uintptr_t)arena_memory;
    uintptr_t arena_end   = arena_start + PC_MAIN_MEMORY_SIZE;
    uintptr_t img_start   = (uintptr_t)pc_image_base;
    uintptr_t img_end     = (uintptr_t)pc_image_end;

    /* Query host thread stack bounds on x86 Windows via TEB FS:[0x04]/[0x08] */
    uintptr_t stack_base = 0, stack_limit = 0;
#if defined(_WIN32) && (defined(__i386__) || defined(_M_IX86))
    __asm__("movl %%fs:0x04, %0" : "=r"(stack_base));
    __asm__("movl %%fs:0x08, %0" : "=r"(stack_limit));
#endif

    /* 1. Hash GameCube 24MB main memory arena (up to top 64KB stack cutoff) */
    const u32* ptr = (const u32*)arena_memory;
    size_t count = (PC_MAIN_MEMORY_SIZE - 0x10000) / sizeof(u32);
    for (size_t i = 0; i < count; i++) {
        u32 val = ptr[i];
        uintptr_t uval = (uintptr_t)val;
        if (uval >= arena_start && uval < arena_end) {
            uintptr_t rel = uval - arena_start;
            if (rel < 0x00840000 || rel >= (PC_MAIN_MEMORY_SIZE - 0x20000)) {
                val = (u32)rel;
            }
        } else if (img_start && uval >= img_start && uval < img_end) {
            val = (u32)(uval - img_start);
        } else if (stack_limit && uval >= stack_limit && uval <= stack_base) {
            val = 0; /* Exclude transient host stack addresses */
        } else if ((uval >= 0x00A00000 && uval < 0x60000000) || uval >= 0x70000000) {
            if ((uval & 3) == 0 && (uval < 0x3E000000 || uval > 0x48000000)) {
                val = 0;
            }
        }
        hash ^= (u64)val;
        hash *= FNV_PRIME;
    }

    /* 2. Hash zelda_arena (the active GameCube actor/field heap) */
    if (zelda_arena.initialized && zelda_arena.head != NULL) {
        uintptr_t zelda_base = (uintptr_t)zelda_arena.base;
        PCMemBlock* block = zelda_arena.head;
        while (block != NULL) {
            if (block->magic == (s16)0x7373 && !block->free && block->size > 0) {
                uintptr_t block_data = (uintptr_t)block + 0x30; /* sizeof(OSMemBlock) is 0x30 */
                size_t words = (size_t)block->size / sizeof(u32);
                const u32* dptr = (const u32*)block_data;
                for (size_t j = 0; j < words; j++) {
                    u32 val = dptr[j];
                    uintptr_t uval = (uintptr_t)val;
                    if ((uval & 1) == 0 && zelda_base) {
                        uintptr_t rel = uval - zelda_base;
                        if (rel < 0x00040000 || (rel >= 0x01700000 && rel < 0x01800000)) {
                            val = (u32)rel;
                        }
                    }
                    if ((uval & 3) == 0 && arena_start && uval >= arena_start && uval < arena_end) {
                        uintptr_t rel = uval - arena_start;
                        if (rel < 0x00080000) {
                            val = (u32)rel;
                        }
                    }
                    if (img_start && uval >= img_start && uval < img_end) {
                        val = (u32)(uval - img_start);
                    } else if (stack_limit && uval >= stack_limit && uval <= stack_base) {
                        val = 0;
                    }
                    hash ^= (u64)val;
                    hash *= FNV_PRIME;
                }
            }
            block = block->next;
        }
    }

    /* 3. Hash RNG seed (__qrand_idum) */
    hash ^= (u64)qrand_get_seed();
    hash *= FNV_PRIME;

    return hash;
}

void pc_poke_arena_byte(size_t offset, u8 val) {
    if (!arena_memory || offset >= (PC_MAIN_MEMORY_SIZE - 0x10000)) return;
    arena_memory[offset] = val;
}

u8 pc_peek_arena_byte(size_t offset) {
    if (!arena_memory || offset >= (PC_MAIN_MEMORY_SIZE - 0x10000)) return 0;
    return arena_memory[offset];
}

void pc_poke_actor_byte(size_t offset, u8 val) {
    if (!zelda_arena.initialized || !zelda_arena.head) return;
    PCMemBlock* block = zelda_arena.head;
    while (block != NULL) {
        if (block->magic == (s16)0x7373 && !block->free && block->size > 0) {
            u8* data = (u8*)block + 0x30;
            if (offset < (size_t)block->size) {
                data[offset] = val;
                return;
            }
        }
        block = block->next;
    }
}

u8 pc_peek_actor_byte(size_t offset) {
    if (!zelda_arena.initialized || !zelda_arena.head) return 0;
    PCMemBlock* block = zelda_arena.head;
    while (block != NULL) {
        if (block->magic == (s16)0x7373 && !block->free && block->size > 0) {
            u8* data = (u8*)block + 0x30;
            if (offset < (size_t)block->size) {
                return data[offset];
            }
        }
        block = block->next;
    }
    return 0;
}

void pc_poke_rng_seed(u32 seed) {
    qrand_set_seed(seed);
}

#include <direct.h>

int pc_dump_state_breakdown(const char* dir_prefix, int run_id) {
    char dir[256];
    snprintf(dir, sizeof(dir), "%s_run%d", dir_prefix, run_id);
    _mkdir(dir);

    /* 1. Dump MEM1 */
    char path[512];
    snprintf(path, sizeof(path), "%s/mem1.bin", dir);
    FILE* f = fopen(path, "wb");
    if (f && arena_memory) {
        size_t count = (PC_MAIN_MEMORY_SIZE - 0x10000);
        fwrite(arena_memory, 1, count, f);
        fclose(f);
    }

    /* 2. Dump manifest with hashes of MEM1, RNG, and each zelda_arena block */
    snprintf(path, sizeof(path), "%s/manifest.json", dir);
    FILE* mf = fopen(path, "w");
    if (!mf) return 0;

    fprintf(mf, "{\n");
    fprintf(mf, "  \"run_id\": %d,\n", run_id);
    fprintf(mf, "  \"rng_seed\": %u,\n", qrand_get_seed());
    fprintf(mf, "  \"arena_memory_base\": \"%p\",\n", arena_memory);
    fprintf(mf, "  \"zelda_arena_base\": \"%p\",\n", zelda_arena.initialized ? zelda_arena.base : NULL);
    fprintf(mf, "  \"blocks\": [\n");

    if (zelda_arena.initialized && zelda_arena.head) {
        PCMemBlock* block = zelda_arena.head;
        int idx = 0;
        int first = 1;
        while (block != NULL) {
            if (block->magic == (s16)0x7373 && !block->free && block->size > 0) {
                char block_file[64];
                snprintf(block_file, sizeof(block_file), "block_%03d_sz%d.bin", idx, block->size);
                snprintf(path, sizeof(path), "%s/%s", dir, block_file);
                FILE* bf = fopen(path, "wb");
                if (bf) {
                    fwrite((u8*)block + 0x30, 1, block->size, bf);
                    fclose(bf);
                }

                /* Compute block hash */
                const u64 FNV_OFFSET_BASIS = 0xcbf29ce484222325ULL;
                const u64 FNV_PRIME = 0x100000001b3ULL;
                u64 b_hash = FNV_OFFSET_BASIS;
                size_t words = (size_t)block->size / sizeof(u32);
                const u32* dptr = (const u32*)((u8*)block + 0x30);
                for (size_t j = 0; j < words; j++) {
                    b_hash ^= (u64)dptr[j];
                    b_hash *= FNV_PRIME;
                }

                if (!first) fprintf(mf, ",\n");
                first = 0;
                fprintf(mf, "    {\"idx\": %d, \"addr\": \"%p\", \"size\": %d, \"raw_hash\": \"%016llx\", \"file\": \"%s\"}",
                        idx, (u8*)block + 0x30, block->size, (unsigned long long)b_hash, block_file);
                idx++;
            }
            block = block->next;
        }
    }

    fprintf(mf, "\n  ]\n}\n");
    fclose(mf);
    return 1;
}

s64 osGetTime(void) {
#ifdef _WIN32
    if (g_pc_system_rtc) {
        /* GC calendars represent local civil time, not UTC. Read Windows on
         * every call so suspend, offline time and DST are not frame-counted. */
        SYSTEMTIME now;
        int calendar[10] = {0};
        extern s64 OSCalendarTimeToTicks(void* td_ptr);
        GetLocalTime(&now);
        calendar[0] = now.wSecond;
        calendar[1] = now.wMinute;
        calendar[2] = now.wHour;
        calendar[3] = now.wDay;
        calendar[4] = now.wMonth - 1;
        calendar[5] = now.wYear;
        calendar[8] = now.wMilliseconds;
        return OSCalendarTimeToTicks(calendar);
    }
#endif
    extern int g_pc_as_library;
    if (g_pc_as_library) {
        return s_library_time_ticks;
    }
    u64 now = SDL_GetPerformanceCounter();
    u64 freq = SDL_GetPerformanceFrequency();
    s64 elapsed = (s64)((now - time_base_start) * (u64)GC_TIMER_CLOCK / freq);
    return gc_epoch_offset_ticks + elapsed;
}

s64 OSGetTime(void) { return osGetTime(); }

/* same as OSGetTime on PC (no time_adjust needed) */
s64 __OSGetSystemTime(void) { return OSGetTime(); }

u32 osGetCount(void) {
    return (u32)osGetTime();
}

u32 OSGetTick(void) { return osGetCount(); }

/* --- Calendar time (ported from OSTime.c) --- */
#define OS_TIMER_CLOCK          GC_TIMER_CLOCK
#define OSSecondsToTicks(sec)   ((s64)(sec) * (s64)OS_TIMER_CLOCK)
#define OSTicksToSeconds(ticks) ((s64)(ticks) / (s64)OS_TIMER_CLOCK)
#define OSMillisecondsToTicks(msec) ((s64)(msec) * (s64)(OS_TIMER_CLOCK / 1000))
#define OSTicksToMilliseconds(ticks) ((s64)(ticks) / (s64)(OS_TIMER_CLOCK / 1000))
#define OSMicrosecondsToTicks(usec) (((s64)(usec) * (s64)(OS_TIMER_CLOCK / 125000)) / 8)
#define OSTicksToMicroseconds(ticks) (((s64)(ticks) * 8) / (s64)(OS_TIMER_CLOCK / 125000))

#define MONTH_MAX    12
#define WEEK_DAY_MAX 7
#define YEAR_DAY_MAX 365
#define USEC_MAX     1000
#define MSEC_MAX     1000
#define SECS_IN_MIN  60
#define SECS_IN_HOUR (60 * 60)
#define SECS_IN_DAY  (60 * 60 * 24)
#define SECS_IN_YEAR (SECS_IN_DAY * 365)
/* Days from March 1, year 0 (proleptic Gregorian) to Jan 1, 2000 (GC epoch).
 * = 2000*365 + floor(2000/4) - floor(2000/100) + floor(2000/400) = 730485 */
#define BIAS         0xB2575

static int YearDays_os[MONTH_MAX]
    = { 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
static int LeapYearDays_os[MONTH_MAX]
    = { 0, 31, 60, 91, 121, 152, 182, 213, 244, 274, 305, 335 };

static int IsLeapYear(int year) {
    return (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
}

static int GetYearDays(int year, int mon) {
    int* md = IsLeapYear(year) ? LeapYearDays_os : YearDays_os;
    return md[mon];
}

static int GetLeapDays(int year) {
    if (year < 1) return 0;
    return (year + 3) / 4 - (year - 1) / 100 + (year - 1) / 400;
}

static void GetDates(int days, void* td_ptr) {
    int* td = (int*)td_ptr;
    int year, n, month;
    int* md;

    td[6] = (days + 6) % WEEK_DAY_MAX;  /* wday */

    for (year = days / YEAR_DAY_MAX;
         days < (n = year * YEAR_DAY_MAX + GetLeapDays(year)); year--)
        ;

    days -= n;
    td[5] = year;   /* year */
    td[7] = days;   /* yday */

    md = IsLeapYear(year) ? LeapYearDays_os : YearDays_os;
    for (month = MONTH_MAX; days < md[--month]; )
        ;
    td[4] = month;               /* mon */
    td[3] = days - md[month] + 1; /* mday */
}

void OSTicksToCalendarTime(s64 ticks, void* td_ptr) {
    int* td = (int*)td_ptr;
    int days, secs;
    s64 d;

    d = ticks % OSSecondsToTicks(1);
    if (d < 0) {
        d += OSSecondsToTicks(1);
    }

    td[9] = (int)(OSTicksToMicroseconds(d) % USEC_MAX); /* usec */
    td[8] = (int)(OSTicksToMilliseconds(d) % MSEC_MAX); /* msec */

    ticks -= d;

    days = (int)(OSTicksToSeconds(ticks) / SECS_IN_DAY) + BIAS;
    secs = (int)(OSTicksToSeconds(ticks) % SECS_IN_DAY);
    if (secs < 0) {
        days -= 1;
        secs += SECS_IN_DAY;
    }

    GetDates(days, td);
    td[2] = secs / 60 / 60;  /* hour */
    td[1] = secs / 60 % 60;  /* min */
    td[0] = secs % 60;       /* sec */
}

s64 OSCalendarTimeToTicks(void* td_ptr) {
    int* td = (int*)td_ptr;
    s64 secs;
    int ov_mon, mon, year;

    ov_mon = td[4] / MONTH_MAX;  /* mon / 12 */
    mon = td[4] - (ov_mon * MONTH_MAX);

    if (mon < 0) {
        mon += MONTH_MAX;
        ov_mon--;
    }

    year = td[5] + ov_mon;  /* year + overflow months as years */

    secs = (s64)SECS_IN_YEAR * year +
           (s64)SECS_IN_DAY * (GetLeapDays(year) + GetYearDays(year, mon) + td[3] - 1) +
           (s64)SECS_IN_HOUR * td[2] +
           (s64)SECS_IN_MIN * td[1] +
           td[0] -
           (s64)0xEB1E1BF80ULL;

    return OSSecondsToTicks(secs) + OSMillisecondsToTicks((s64)td[8]) +
           OSMicrosecondsToTicks((s64)td[9]);
}

void OSGetSaveRegion(void** start, void** end) {
    *start = NULL;
    *end = NULL;
}

/* --- Threads (single-threaded, all no-ops) --- */
#include <dolphin/os/OSThread.h>

static OSThread main_thread;
static OSThread* current_thread = &main_thread;

/* N64 libultra message queue wrappers → Dolphin OS */
void OSInitMessageQueue(void* queue, void** msgArray, int msgCount);
BOOL OSSendMessage(void* queue, void* msg, int flags);
BOOL OSReceiveMessage(void* queue, void** msgPtr, int flags);

void osCreateMesgQueue(void* mq, void* buf, int count) {
    OSInitMessageQueue(mq, (void**)buf, count);
}

int osSendMesg(void* mq, void* msg, int flags) {
    return OSSendMessage(mq, msg, flags) ? 0 : -1;
}

int osRecvMesg(void* mq, void** msg, int flags) {
    return OSReceiveMessage(mq, msg, flags) ? 0 : -1;
}

static void (*pending_thread_entry)(void*) = NULL;
static void* pending_thread_arg = NULL;

void osCreateThread2(void* thread, int id, void (*entry)(void*), void* arg,
                     void* stack, int stack_size, int priority) {
    (void)thread; (void)id; (void)stack; (void)stack_size; (void)priority;
    pending_thread_entry = entry;
    pending_thread_arg = arg;
}

void osStartThread(void* thread) {
    /* don't actually start threads — single-threaded mode */
    (void)thread;
    pending_thread_entry = NULL;
    pending_thread_arg = NULL;
}

void osSetThreadPri(void* thread, int pri) { (void)thread; (void)pri; }
OSThread* OSGetCurrentThread(void) { return current_thread; }
u32 OSGetStackPointer(void) { return main_thread.stackBase ? (u32)(uintptr_t)main_thread.stackBase : (u32)(uintptr_t)&arena_memory; }

/* --- Interrupts --- */
BOOL OSDisableInterrupts(void) { return 0; }
BOOL OSEnableInterrupts(void) { return 0; }
BOOL OSRestoreInterrupts(BOOL level) { return level; }

/* --- Cache (no-ops on PC) --- */
void DCFlushRange(void* addr, u32 len) { (void)addr; (void)len; }
void DCTouchRange(void* addr, u32 len) { (void)addr; (void)len; }
void DCStoreRange(void* addr, u32 len) { (void)addr; (void)len; }
void DCInvalidateRange(void* addr, u32 len) { (void)addr; (void)len; }
void DCFlushRangeNoSync(void* addr, u32 len) { (void)addr; (void)len; }
void DCStoreRangeNoSync(void* addr, u32 len) { (void)addr; (void)len; }
void DCZeroRange(void* addr, u32 len) { memset(addr, 0, len); }
void ICFlashInvalidate(void) {}
void ICInvalidateRange(void* addr, u32 len) { (void)addr; (void)len; }
void LCEnable(void) {}
void LCDisable(void) {}

/* --- Init --- */
void OSInit(void) {
    if (!arena_memory) {
#ifdef _WIN32
        int use_fixed = g_pc_use_fixed_addresses;
        const char* env_fixed = getenv("ACGC_FIXED_ADDRESSES");
        if (env_fixed && atoi(env_fixed) != 0) {
            use_fixed = 1;
        }

        if (use_fixed) {
            /* Try preferred fixed addresses to guarantee identical pointer values across runs */
            static const uintptr_t preferred_bases[] = {
                0x30000000, 0x40000000, 0x50000000, 0x20000000, 0x10000000, 0
            };
            for (int i = 0; preferred_bases[i] != 0; i++) {
                arena_memory = (u8*)VirtualAlloc((void*)preferred_bases[i], PC_MAIN_MEMORY_SIZE, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
                if (arena_memory) {
                    fprintf(stderr, "[PC OS] arena_memory allocated at fixed address %p\n", arena_memory);
                    break;
                }
            }
        }
        if (!arena_memory) {
            arena_memory = (u8*)VirtualAlloc(NULL, PC_MAIN_MEMORY_SIZE, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
            fprintf(stderr, "[PC OS] arena_memory allocated at dynamic address %p (fixed_opt=%d)\n", arena_memory, use_fixed);
        }
#else
        arena_memory = (u8*)malloc(PC_MAIN_MEMORY_SIZE);
#endif
        if (!arena_memory) {
            fprintf(stderr, "Failed to allocate main memory arena\n");
            exit(1);
        }
        memset(arena_memory, 0, PC_MAIN_MEMORY_SIZE);

        /* GC system info at phys addr 0; offset 0x28 = mem size for JKRHeap */
        *(u32*)(arena_memory + 0x28) = PC_MAIN_MEMORY_SIZE;

        memset(&main_thread, 0, sizeof(main_thread));
        main_thread.stackBase = (u8*)(arena_memory + PC_MAIN_MEMORY_SIZE - 0x1000);
        main_thread.stackEnd  = (u32*)(arena_memory + PC_MAIN_MEMORY_SIZE);
        arena_lo = arena_memory + 0x3100;
        arena_hi = arena_memory + PC_MAIN_MEMORY_SIZE - 0x1000;
    }
    time_base_start = SDL_GetPerformanceCounter();
    /* compute ticks from GC epoch (Jan 1, 2000) to now, with timezone */
    {
        time_t unix_now = time(NULL);

        struct tm* gmt = gmtime(&unix_now);
        if (!gmt) { gc_epoch_offset_ticks = 0; return; }
        struct tm utc_tm = *gmt;
        utc_tm.tm_isdst = -1; /* let mktime determine DST */
        time_t utc_as_local = mktime(&utc_tm);
        s64 tz_offset_secs = (s64)difftime(unix_now, utc_as_local);

        if (g_pc_time_override >= 0 || g_pc_date_month > 0) {
            /* --time H[:M[:S]] / --date M/D[/Y] overrides */
            struct tm* lt = localtime(&unix_now);
            if (lt) {
                struct tm ovr = *lt;
                if (g_pc_date_month > 0) {
                    ovr.tm_mon = g_pc_date_month - 1;
                    ovr.tm_mday = g_pc_date_day;
                    if (g_pc_date_year > 0) ovr.tm_year = g_pc_date_year - 1900;
                }
                if (g_pc_time_override >= 0) ovr.tm_hour = g_pc_time_override;
                if (g_pc_min_override >= 0) ovr.tm_min = g_pc_min_override;
                if (g_pc_sec_override >= 0) ovr.tm_sec = g_pc_sec_override;
                ovr.tm_isdst = -1;
                time_t ovr_time = mktime(&ovr);
                if (ovr_time != (time_t)-1) unix_now = ovr_time;
            }
        }

        s64 gc_secs = (s64)(unix_now - GC_UNIX_EPOCH_DIFF) + tz_offset_secs;
        gc_epoch_offset_ticks = gc_secs * (s64)GC_TIMER_CLOCK;
    }
}

void OSInitAlarm(void) { }

void __osInitialize_common(void) { }
void __OSPSInit(void) {}
void __OSFPRInit(void) {}
void __OSCacheInit(void) {}

u32 OSGetConsoleType(void) { return 0x10000004; /* OS_CONSOLE_DEVHW1 */ }

void OSPanic(const char* file, int line, const char* msg, ...) {
    va_list args;
    fprintf(stderr, "OSPanic at %s:%d: ", file, line);
    va_start(args, msg);
    vfprintf(stderr, msg, args);
    va_end(args);
    fprintf(stderr, "\n");
}

void OSReport(const char* fmt, ...) {
    if (!g_pc_verbose) return;
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);
    fflush(stdout);
}

void OSVReport(const char* fmt, va_list list) {
    if (!g_pc_verbose) return;
    vprintf(fmt, list);
}

void OSReportDisable(void) {}

/* --- Alarms --- */
typedef struct OSAlarm { u8 _pad[64]; } OSAlarm;
void OSSetAlarm(OSAlarm* alarm, s64 tick, void (*callback)(OSAlarm*, void*)) {
    (void)alarm; (void)tick; (void)callback;
}
void OSSetPeriodicAlarm(OSAlarm* alarm, s64 start, s64 period, void (*callback)(OSAlarm*, void*)) {
    (void)alarm; (void)start; (void)period; (void)callback;
}
void OSCancelAlarm(OSAlarm* alarm) { (void)alarm; }
void OSCreateAlarm(OSAlarm* alarm) { memset(alarm, 0, sizeof(OSAlarm)); }

/* --- Reset --- */
BOOL OSGetResetSwitchState(void) { return FALSE; }
void OSResetSystem(int reset, u32 resetCode, BOOL forceMenu) {
    g_pc_running = 0;
}
u32 OSGetResetCode(void) { return 0; }
void OSChangeBootMode(u32 mode) { (void)mode; }

int __osResetSwitchPressed = 0;

/* --- Address translation (physical addr → arena_memory offset) --- */
void* OSPhysicalToCached(u32 paddr) { return (void*)(arena_memory + paddr); }
void* OSPhysicalToUncached(u32 paddr) { return (void*)(arena_memory + paddr); }
u32 OSCachedToPhysical(void* caddr) { return (u32)((u8*)caddr - arena_memory); }
u32 OSUncachedToPhysical(void* ucaddr) { return (u32)((u8*)ucaddr - arena_memory); }
void* OSCachedToUncached(void* caddr) { return caddr; }
void* OSUncachedToCached(void* ucaddr) { return ucaddr; }

s32 osAppNMIBuffer[64] = {0};

/* --- Misc --- */
void osShutdownStart(int type) {
    g_pc_running = 0;
}

int osShutdown = 0;

void ReconfigBATs(void) {}

void OSSetStringTable(void* table) { (void)table; }

typedef struct OSSramEx { u8 data[64]; } OSSramEx;
OSSramEx* __OSLockSramEx(void) {
    static OSSramEx sramex = {0};
    return &sramex;
}
void __OSUnlockSramEx(BOOL commit) { (void)commit; }

void msleep(int ms) { SDL_Delay(ms); }

typedef struct OSMutex { int lock; } OSMutex;
void OSInitMutex(OSMutex* mutex) { mutex->lock = 0; }
void OSLockMutex(OSMutex* mutex) { mutex->lock = 1; }
void OSUnlockMutex(OSMutex* mutex) { mutex->lock = 0; }
BOOL OSTryLockMutex(OSMutex* mutex) {
    if (mutex->lock) return FALSE;
    mutex->lock = 1;
    return TRUE;
}

/* --- Message queue --- */
/* matches OSMessageQueue from dolphin/os/OSMessage.h */
typedef struct {
    u8  _threadQueues[16]; /* queueSend + queueReceive - unused on PC */
    void** msgArray;       /* _10 */
    int msgCount;          /* _14 */
    int firstIndex;        /* _18 */
    int usedCount;         /* _1C */
} OSMessageQueue_PC;

void OSInitMessageQueue(void* queue, void** msgArray, int msgCount) {
    OSMessageQueue_PC* mq = (OSMessageQueue_PC*)queue;
    memset(mq->_threadQueues, 0, 16);
    mq->msgArray = msgArray;
    mq->msgCount = msgCount;
    mq->firstIndex = 0;
    mq->usedCount = 0;
}

BOOL OSSendMessage(void* queue, void* msg, int flags) {
    OSMessageQueue_PC* mq = (OSMessageQueue_PC*)queue;
    if (mq->usedCount >= mq->msgCount) {
        /* full */
        return FALSE;
    }
    int idx = (mq->firstIndex + mq->usedCount) % mq->msgCount;
    mq->msgArray[idx] = msg;
    mq->usedCount++;
    return TRUE;
}

BOOL OSReceiveMessage(void* queue, void** msgPtr, int flags) {
    OSMessageQueue_PC* mq = (OSMessageQueue_PC*)queue;
    if (mq->usedCount == 0) {
        return FALSE;
    }
    if (msgPtr) {
        *msgPtr = mq->msgArray[mq->firstIndex];
    }
    mq->firstIndex = (mq->firstIndex + 1) % mq->msgCount;
    mq->usedCount--;
    return TRUE;
}

BOOL OSJamMessage(void* queue, void* msg, int flags) {
    OSMessageQueue_PC* mq = (OSMessageQueue_PC*)queue;
    if (mq->usedCount >= mq->msgCount) {
        return FALSE;
    }
    mq->firstIndex = (mq->firstIndex - 1 + mq->msgCount) % mq->msgCount;
    mq->msgArray[mq->firstIndex] = msg;
    mq->usedCount++;
    return TRUE;
}

/* --- Heap --- */
volatile int __OSCurrHeap = -1;

void* OSInitAlloc(void* arenaStart, void* arenaEnd, int maxHeaps) {
    /* skip past heap descriptors */
    uintptr_t arraySize = (uintptr_t)maxHeaps * 24;
    uintptr_t newStart = ((uintptr_t)arenaStart + arraySize + 0x1F) & ~(uintptr_t)0x1F;
    return (void*)newStart;
}

void* OSAllocFromHeap(int heap, u32 size) { return malloc(size); }
void OSFreeToHeap(int heap, void* ptr) { free(ptr); }
int OSCreateHeap(void* lo, void* hi) { return 0; }
int OSSetCurrentHeap(int heap) { return 0; }

void OSClearContext(OSContext* ctx) { memset(ctx, 0, sizeof(OSContext)); }

void* __OSSetExceptionHandler(u8 type, void* handler) {
    (void)type; (void)handler;
    return NULL;
}

u32 OSGetPhysicalMemSize(void) { return PC_MAIN_MEMORY_SIZE; }
