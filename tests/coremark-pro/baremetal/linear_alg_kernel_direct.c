/*
 * linear_alg_kernel_direct.c — bare-metal Linpack (single-precision 100x100) kernel profiling.
 *
 * Bypasses mith harness dispatch (no mith_main, no th_parse_flag, no strstr storms).
 * Calls run_linpack (via t_run_test_linpack) directly on a pre-initialized dataset in a tight loop.
 *
 * Workload: linear_alg-mid-100x100-sp
 *   - 100x100 single-precision LU factorization + back-substitution (LINPACK)
 *   - Uses real newlib libm (fabsf, etc.) — NOT stubbed
 *   - Dataset index 4: n=100, ntimes=10, seed=73686179 (same as workload XML param 4)
 *
 * Phase markers (readable in the sim cycle-count log):
 *   1. Before setup:        csrw mscratch, 0xAABB0001   (startup marker)
 *   2. Before kernel loop:  csrw mscratch, 0xAABB0002   (kernel start)
 *   3. After kernel loop:   csrw mscratch, 0xAABB0003   (kernel end)
 *
 * Config:
 *   LINEAR_ALG_KERNEL_ITERS: number of t_run_test_linpack calls (default 50)
 *     Each call: run_single_linpack(10+0)*2 = 10+11 outer iters on 100x100 matrix
 *     ~2-5M cycles per outer iter on this core => ~1-3B cycles total for 50 iters
 *     Start with 5 iters (~100-300M cycles) and scale up.
 *
 * Build: uses full mith sources for th_rand/th_bignum/th_al (store_sp etc.)
 * This is the ONLY file with main(); do NOT also compile the workload wrapper
 * (linear_alg-mid-100x100-sp.c).
 *
 * Note: These are PROFILE runs (bare-metal, single-context, direct-kernel),
 * NOT official CoreMark-PRO scores.
 */

/* Pull in the mith types + config */
#include "th_cfg.h"
#include "th_types.h"
#include "th_lib.h"
#include "th_rand.h"
#include "th_math.h"
#include "linpack.h"

/* ---- RISC-V CSR helpers ------------------------------------------------- */
static inline void marker(unsigned long val) {
    __asm__ volatile("csrw mscratch, %0" :: "r"(val) : "memory");
}

static inline unsigned long rdcycle(void) {
    unsigned long c;
    __asm__ volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}

/* ---- tohost halt --------------------------------------------------------- */
static void halt(int code) __attribute__((noreturn));
static void halt(int code) {
    volatile unsigned long *tohost = (volatile unsigned long *)0x80001000UL;
    if (code == 0)
        *tohost = 1UL;
    else
        *tohost = (unsigned long)((code << 1) | 1);
    while (1) {}
}

/* ---- Config ------------------------------------------------------------- */
#ifndef LINEAR_ALG_KERNEL_ITERS
#define LINEAR_ALG_KERNEL_ITERS 5
#endif

/* TCDef is required by t_run_test_linpack but we only care about the kernel run */
extern void *t_run_test_linpack(struct TCDef *, void *);
extern void *bmark_init_linpack(void *);
extern void *bmark_fini_linpack(void *);
extern void *define_params_linpack(unsigned int, char *, char *);
extern int   bmark_clean_linpack(void *);

/* ---- main --------------------------------------------------------------- */
int main(void)
{
    marker(0xAABB0001UL);   /* startup marker */

    /* Initialize preset table (reads inputs_f32.c data into presets_linpack[]) */
    init_presets_linpack();

    /* Define params: index=4 → n=100, ntimes=10, seed=73686179, lda=101 */
    char name[32] = "linear_alg-mid";
    char dataset[32] = "100x100";
    linpack_params *base_params = (linpack_params *)define_params_linpack(4, name, dataset);
    if (!base_params) halt(1);

    /* Allocate per-run working buffers (a, b, ipvt) */
    linpack_params *run_params = (linpack_params *)bmark_init_linpack(base_params);
    if (!run_params) halt(2);

    /* Minimal TCDef: only CRC field used by t_run_test_linpack */
    TCDef tcdef;
    __builtin_memset(&tcdef, 0, sizeof(tcdef));

    /* Sink to prevent DCE */
    volatile unsigned long g_sink = 0;

    /* ----- KERNEL PHASE ----- */
    marker(0xAABB0002UL);   /* kernel start — perf counters sample here */
    unsigned long cyc_start = rdcycle();

    for (int iter = 0; iter < LINEAR_ALG_KERNEL_ITERS; iter++) {
        /* t_run_test_linpack: calls rand_init + run_linpack + rand_fini */
        t_run_test_linpack(&tcdef, run_params);
        /* prevent dead-code elimination */
        g_sink ^= (unsigned long)(tcdef.CRC) ^ iter;
    }

    unsigned long cyc_end = rdcycle();
    marker(0xAABB0003UL);   /* kernel end */

    /* Store sink to memory */
    volatile unsigned long *sink_mem = (volatile unsigned long *)0x80001008UL;
    *sink_mem = g_sink;

    /* Cleanup */
    bmark_fini_linpack(run_params);
    bmark_clean_linpack(base_params);

    /* Signal PASS */
    halt(0);
}
