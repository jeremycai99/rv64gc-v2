/*
 * nnet_kernel_direct.c — bare-metal nnet (neural-net) kernel profiling bypass.
 *
 * Bypasses the mith harness entirely.  Calls the nnet training kernel
 * (DoNNetIteration, via t_run_test_nnet) directly on a fixed in-memory
 * dataset, eliminating all strstr/th_parse_flag/al_main overhead.
 *
 * The nnet workload is a small back-propagation NN that trains on 26 letter
 * patterns.  Each iteration = one DoNNetIteration call = one "learning cycle"
 * (~20-200 forward+back passes over all patterns).  The hot path is:
 *   sigmoid computation:  sum = 1/(1 + exp(-sum))  in do_mid_forward / do_out_forward
 *   weight update:        delta += learn*error*output  in adjust_*_wts
 *
 * FP: uses real libm exp() (double-precision) via th_exp macro -> exp.
 *     DO NOT stub exp() to 0.
 *
 * Phase markers (readable in the sim cycle-count log):
 *   1. Before setup:      csrw mscratch, 0xAABB0001   (startup)
 *   2. Before kernel loop:csrw mscratch, 0xAABB0002   (kernel start)
 *   3. After kernel loop: csrw mscratch, 0xAABB0003   (kernel end)
 *
 * Build configuration:
 *   - NNET_KERNEL_ITERS: number of DoNNetIteration outer iterations (default 500)
 *
 * PROFILE RUN: bare-metal, USE_SINGLE_CONTEXT=1, FAKE_FILEIO=1, USE_FP64=1.
 * NOT an official CoreMark-PRO score.
 */

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>

/* ---- Mith type includes (need to match nnet.c's view) ------------------- */
/* We define the FP precision before including any mith header */
#define USE_FP64        1
#define USE_FP32        0
#define FP_KERNELS_SUPPORT 1
#define USE_MATH_H      1
#define FLOAT_SUPPORT   1
#define COMPILE_OUT_HEAP 1
#define HAVE_MALLOC     1
#define NO_ALIGNED_ALLOC 1
#define HOST_EXAMPLE_CODE 0   /* tells th_al.h we are NOT host; but we provide our own store_dp */
#define USE_SINGLE_CONTEXT 1
#define MAX_CONTEXTS    1
#define HAVE_PTHREAD    0
#define USE_NATIVE_PTHREAD 0
#define FAKE_FILEIO     1
#define HAVE_FILEIO     1
#define EE_SIZEOF_PTR   8
#define EE_SIZEOF_LONG  8
#define EE_SIZEOF_INT   4
#define HAVE_GETPID     0
#define HAVE_DIRENT_H   0
#define HAVE_DIRENT     0
#define HAVE_UNISTD_H   0
#define HAVE_SYS_STAT_H 0
#define USE_EE_STAT     0
#define HAVE_SYS_DIR_H  0
#define HAVE_STRUCT_STAT_ST_BLKSIZE 0
#define HAVE_STRUCT_STAT_ST_BLOCKS  0
#define STUB_STAT       1
#define HAVE_VSSCANF    1
#define HAVE_VFSCANF    0
#define NEED_STD_FILES  1
#define NEED_SEEK_PARAMS 1
#define NEED_MKSTEMP    0

#include "th_cfg.h"
#include "th_lib.h"
#include "th_rand.h"
#include "nnet.h"

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
#ifndef NNET_KERNEL_ITERS
/* preset-1 (n_in=1, loops=9, ~20 passes/loop) costs ~200-400K cycles per call.
 * Use 50 iterations to cover ~15M cycles of compute kernel. */
#define NNET_KERNEL_ITERS 50
#endif

#ifndef NNET_PRESET_IDX
/* 0 = letters dataset (26 patterns, 9 loops, ~350 passes/loop) - expensive
 * 1 = 1letter dataset (1 pattern,  9 loops, ~20  passes/loop) - cheap      */
#define NNET_PRESET_IDX 1
#endif

/* ---- Public nnet API (defined in nnet.c) -------------------------------- */
/* TCDef is defined in th_lib.h */

extern void *define_params_nnet(unsigned int idx, char *name, char *dataset);
extern void *bmark_init_nnet(void *);
extern void *t_run_test_nnet(struct TCDef *, void *);
extern int   bmark_clean_nnet(void *);
extern int   bmark_verify_nnet(void *);
extern void *bmark_fini_nnet(void *);

/* ---- main --------------------------------------------------------------- */
int main(void)
{
    static unsigned long cyc_start, cyc_end;
    static TCDef tcdef;
    static char name[32]    = "nnet";
    static char dataset[32] = "NULL";
    volatile unsigned long sink = 0;

    marker(0xAABB0001UL);   /* startup marker */

    /* --- Setup phase: define + init params (uses PRNG + preset data) ------- */
    /* Use preset NNET_PRESET_IDX.
     * Preset 1 (1letter: n_in=1, loops=9, ~20 passes/loop) costs ~200-400K
     * cycles per call.  50 iterations gives ~15M kernel cycles.
     * Preset 0 (letters: n_in=26, loops=9, ~350 passes/loop) costs ~8-12M
     * cycles per call and is the official full-dataset. */
    void *base_params = define_params_nnet(NNET_PRESET_IDX, name, dataset);
    if (!base_params) halt(1);

    /* bmark_init_nnet copies base_params -> per-run params */
    void *run_params = bmark_init_nnet(base_params);
    if (!run_params) halt(1);

    /* Zero-init the tcdef */
    memset(&tcdef, 0, sizeof(tcdef));

    /* ----- KERNEL PHASE ----- */
    marker(0xAABB0002UL);   /* kernel start */
    cyc_start = rdcycle();

    for (int iter = 0; iter < NNET_KERNEL_ITERS; iter++) {
        /* Reinitialize run_params from base each iteration so the NN
         * always has consistent starting weights (same training problem).
         * This matches what the mith harness does: bmark_init is called
         * per-run to get a fresh copy of the params. */
        void *it_params = bmark_init_nnet(base_params);
        if (!it_params) halt(2);

        t_run_test_nnet(&tcdef, it_params);

        /* Prevent dead-code elimination */
        sink ^= (unsigned long)tcdef.CRC;
        sink ^= (unsigned long)(((nnet_params *)it_params)->iterations);

        bmark_fini_nnet(it_params);
    }

    cyc_end = rdcycle();
    marker(0xAABB0003UL);   /* kernel end */

    /* Store sink to memory */
    volatile unsigned long *sink_mem = (volatile unsigned long *)0x80001008UL;
    *sink_mem = sink;

    /* Cleanup */
    bmark_fini_nnet(run_params);
    bmark_clean_nnet(base_params);

    halt(0);
}
