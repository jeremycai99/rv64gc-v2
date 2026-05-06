/* Bare-metal RV64IM CoreMark port */
#include "coremark.h"
#include "../benchmarks/bench_mmio.h"

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

ee_s32 portme_sys1(void) {
    return 0x0;
}

ee_s32 portme_sys2(void) {
    return 0x0;
}

ee_s32 portme_sys3(void) {
    return 0x66;
}

ee_s32 portme_sys4(void) {
    return ITERATIONS;
}

ee_s32 portme_sys5(void) {
    return 0;
}

void start_time(void) {
    rv64gc_bench_begin(RV64GC_BENCH_ID_COREMARK, (unsigned long)ITERATIONS);
    t_start = (CORE_TICKS)read_mcycle();
}

void stop_time(void) {
    t_end = (CORE_TICKS)read_mcycle();
    rv64gc_bench_stop();
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

void rv64gc_coremark_debug(unsigned long index, unsigned long value) {
    rv64gc_bench_write(index, value);
}

void rv64gc_coremark_abort(unsigned long index, unsigned long value) {
    rv64gc_coremark_debug(index, value);
    rv64gc_bench_write(RV64GC_BENCH_REG_FLAGS, RV64GC_BENCH_FLAG_ERROR);
    rv64gc_bench_stop();
    *(volatile unsigned long *)0x80001000UL = 3UL;
    while (1) {
    }
}

void rv64gc_coremark_report(ee_u32 checksum, ee_s32 total_errors) {
    unsigned long flags = 0;

    if (total_errors > 0)
        flags |= RV64GC_BENCH_FLAG_ERROR;
    if (total_errors < 0)
        flags |= RV64GC_BENCH_FLAG_UNVALIDATED;

    rv64gc_bench_write(RV64GC_BENCH_REG_CHECKSUM, (unsigned long)checksum);
    rv64gc_bench_write(RV64GC_BENCH_REG_FLAGS, flags);
}
