/* Bare-metal RV64IM CoreMark port */
#include "coremark.h"

#ifdef GEM5_M5OPS
#include <gem5/m5ops.h>
#endif

volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

ee_u32 default_num_contexts = 1;

static CORE_TICKS t_start, t_end;

static unsigned long read_mcycle(void) {
    unsigned long c;
    __asm__ volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}

void portable_init(core_portable *p, int *argc, char *argv[]) {
    (void)p; (void)argc; (void)argv;
}

void portable_fini(core_portable *p) {
    (void)p;
}

void start_time(void) {
    t_start = (CORE_TICKS)read_mcycle();
}

void stop_time(void) {
    t_end = (CORE_TICKS)read_mcycle();
}

CORE_TICKS get_time(void) {
    return t_end - t_start;
}

secs_ret time_in_secs(CORE_TICKS ticks) {
    return (secs_ret)ticks;
}

/* Stub ee_printf — no UART, just discard */
int ee_printf(const char *fmt, ...) {
    (void)fmt;
    return 0;
}

void gem5_roi_begin(void) {
#ifdef GEM5_M5OPS
    m5_reset_stats(0, 0);
    m5_work_begin(0, 0);
#endif
}

void gem5_roi_end(void) {
#ifdef GEM5_M5OPS
    m5_work_end(0, 0);
    m5_dump_reset_stats(0, 0);
#endif
}

void gem5_bench_exit(void) {
#ifdef GEM5_M5OPS
    m5_exit(0);
#endif
}
