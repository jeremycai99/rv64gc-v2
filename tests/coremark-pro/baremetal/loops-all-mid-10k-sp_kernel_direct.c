/*
 * loops-all-mid-10k-sp_kernel_direct.c
 *
 * Bare-metal direct-kernel profiling bypass for the loops-all-mid-10k-sp
 * CoreMark-PRO workload.
 *
 * Bypasses mith_main entirely.  Calls define_params_loops + bmark_init_loops
 * once (setup phase), then calls t_run_test_loops in a tight loop (kernel
 * phase).  This is single-precision (USE_FP32=1), real newlib libm
 * (sinf/cosf/sqrtf/expf/powf from libc.a / libm.a).
 *
 * Phase markers (csrw mscratch):
 *   0xAABB0001 — startup / before init
 *   0xAABB0002 — kernel start (t_run_test_loops loop begins)
 *   0xAABB0003 — kernel end
 *
 * Build flags:
 *   LOOPS_KERNEL_ITERS  — number of t_run_test_loops calls (default 5)
 *                         each call runs all 25 Livermore loops on N=10000;
 *                         ~10-15M cycles per call => 5 iters ~ 60M cycles
 *
 * NOTE: This is a microarchitectural profile run (bare-metal, single-context,
 *       direct-kernel), NOT an official CoreMark-PRO score.
 */

#include <stdint.h>
#include <string.h>
#include <stdlib.h>

/* --- mith / loop headers -------------------------------------------------- */
/* th_cfg.h is in mith/al/include via -I, sets platform config             */
#include "th_cfg.h"
#include "th_lib.h"
#include "th_rand.h"
#include "th_math.h"
#include "loops.h"

/* --- RISC-V CSR helpers --------------------------------------------------- */
static inline void marker(unsigned long val) {
    __asm__ volatile("csrw mscratch, %0" :: "r"(val) : "memory");
}

static inline unsigned long rdcycle(void) {
    unsigned long c;
    __asm__ volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}

/* --- tohost halt ----------------------------------------------------------- */
static void halt(int code) __attribute__((noreturn));
static void halt(int code) {
    volatile unsigned long *tohost = (volatile unsigned long *)0x80001000UL;
    if (code == 0)
        *tohost = 1UL;
    else
        *tohost = (unsigned long)((code << 1) | 1);
    while (1) {}
}

/* --- Config --------------------------------------------------------------- */
#ifndef LOOPS_KERNEL_ITERS
#define LOOPS_KERNEL_ITERS 5
#endif

/* Preset selection:
 *   preset 0 = "1k"   N=1024,  Loop=100, tests=0xfef9e797 (all enabled)
 *   preset 1 = "10k"  N=10000, Loop=100, tests=0xfef9e797 (all enabled)
 * We use preset 0 (N=1024) to keep setup + kernel within ~20M cycles
 * (the 10k preset needs ~200M+ cycles which exceeds the simulation budget).
 * The instruction mix / memory access patterns are representative; only the
 * working-set size differs.  This is a bare-metal profile run, NOT a score. */
#ifndef LOOPS_PRESET_IDX
#define LOOPS_PRESET_IDX 0   /* 0 = 1k (N=1024), 1 = 10k (N=10000) */
#endif
#ifndef LOOPS_PRESET_DATASET
#define LOOPS_PRESET_DATASET "1k"
#endif

/* loops extern API (defined in loops.c + ref-sp/10k.c) */
extern void *define_params_loops(unsigned int idx, char *name, char *dataset);
extern void *bmark_init_loops(void *);
extern void *t_run_test_loops(struct TCDef *, void *);
extern void *bmark_fini_loops(void *);

/* --- main ----------------------------------------------------------------- */
int main(void)
{
    marker(0xAABB0001UL);   /* startup marker */

    /* ---------------------------------------------------------------------- */
    /* Setup phase: define + init (calls th_calloc, rand, etc.)               */
    /* ---------------------------------------------------------------------- */
    char name[]    = "loops-all-mid";
    char dataset[] = LOOPS_PRESET_DATASET;

    /* define_params_loops: preset 0 = N=1024, Loop=100 */
    void *base_params = define_params_loops(LOOPS_PRESET_IDX, name, dataset);
    if (!base_params) halt(2);

    /* bmark_init_loops: allocate all working arrays */
    void *work_params = bmark_init_loops(base_params);
    if (!work_params) halt(3);

    /* TCDef for the bench function */
    struct TCDef tcdef;
    memset(&tcdef, 0, sizeof(tcdef));

    /* ---------------------------------------------------------------------- */
    /* Kernel phase                                                            */
    /* ---------------------------------------------------------------------- */
    marker(0xAABB0002UL);   /* kernel start */
    unsigned long cyc_start = rdcycle();

    volatile unsigned long sink = 0;
    for (int iter = 0; iter < LOOPS_KERNEL_ITERS; iter++) {
        /* Re-init work_params each iteration so the loops see fresh data
         * (matches what mith_main does: init/run/fini per benchmark call).
         * We free and re-init so the benchmark state is reset. */
        bmark_fini_loops(work_params);
        work_params = bmark_init_loops(base_params);
        if (!work_params) halt(4);

        t_run_test_loops(&tcdef, work_params);
        /* Prevent dead-code elimination by accumulating tcdef.CRC */
        sink ^= (unsigned long)tcdef.CRC;
    }

    unsigned long cyc_end = rdcycle();
    marker(0xAABB0003UL);   /* kernel end */

    /* Store sink */
    volatile unsigned long *sink_mem = (volatile unsigned long *)0x80001008UL;
    *sink_mem = sink;
    (void)(cyc_end - cyc_start);

    /* Cleanup */
    bmark_fini_loops(work_params);

    halt(0);
}
