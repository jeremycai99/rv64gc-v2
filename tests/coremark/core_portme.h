/* Bare-metal RV64IM CoreMark port — based on barebones */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#define HAS_FLOAT 0
#define HAS_TIME_H 0
#define USE_CLOCK 0
#define HAS_STDIO 0
#define HAS_PRINTF 0

#ifndef COMPILER_VERSION
#define COMPILER_VERSION "GCC"
#endif
#ifndef COMPILER_FLAGS
#define COMPILER_FLAGS "-O2 -march=rv64im"
#endif
#ifndef MEM_LOCATION
#define MEM_LOCATION "STACK"
#endif

#ifndef MEM_METHOD
#define MEM_METHOD MEM_STACK
#endif

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed int     ee_s32;
typedef double         ee_f32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_u32;
typedef unsigned long  ee_ptr_int;  /* 64-bit pointers on RV64 */
typedef unsigned long  ee_size_t;
#define NULL ((void *)0)

#define align_mem(x) (void *)(8 + (((ee_ptr_int)(x)-1) & ~7))

#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;

#define SEED_METHOD SEED_VOLATILE
#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0

#define MAIN_HAS_NOARGC 1
#define MAIN_HAS_NORETURN 0

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S {
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

#if !defined(PROFILE_RUN) && !defined(PERFORMANCE_RUN) && !defined(VALIDATION_RUN)
#define PERFORMANCE_RUN 1
#endif

int ee_printf(const char *fmt, ...);

void gem5_roi_begin(void);
void gem5_roi_end(void);
void gem5_bench_exit(void);

#endif
