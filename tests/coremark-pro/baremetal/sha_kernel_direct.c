/*
 * sha_kernel_direct.c — bare-metal SHA-256 kernel profiling bypass.
 *
 * Completely bypasses mith harness (no mith_main, no th_parse_flag,
 * no strstr storms).  Calls sha2() directly on a fixed 1 MB buffer.
 *
 * Phase markers (readable in the sim cycle-count log):
 *   1. Before setup loop:   csrw mscratch, 0xAABB0001   (startup marker)
 *   2. Before kernel loop:  csrw mscratch, 0xAABB0002   (kernel start)
 *   3. After kernel loop:   csrw mscratch, 0xAABB0003   (kernel end)
 *
 * Build configuration:
 *   - SHA_KERNEL_ITERS: number of sha2() calls (default 200 = ~10-20M cyc)
 *   - SHA_BUF_SIZE: input bytes (default 1048576 = 1 MB)
 *
 * The TB prints "mcycle=N minstret=M" every 10K cycles; watch for the
 * IPC to stabilize after the AABB0002 marker => that is the kernel phase.
 */

#include <stdint.h>
#include <string.h>
#include <stdlib.h>   /* malloc / free from newlib */

/* SHA-256 public API (from sha256.c / sha256.h) */
typedef unsigned char  e_u8;
typedef unsigned int   e_u32;
void sha2(e_u8 *data, e_u32 length, e_u8 *digest);

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
#ifndef SHA_KERNEL_ITERS
#define SHA_KERNEL_ITERS 200
#endif
#ifndef SHA_BUF_SIZE
#define SHA_BUF_SIZE 1048576   /* 1 MB */
#endif

/* ---- main --------------------------------------------------------------- */
int main(void)
{
    static e_u8 digest[32];
    static unsigned long cyc_start, cyc_end;

    marker(0xAABB0001UL);   /* startup marker */

    /* Allocate input buffer and fill with a deterministic pattern. */
    e_u8 *buf = (e_u8 *)malloc(SHA_BUF_SIZE);
    if (!buf) halt(1);

    /* Simple fill — avoids strlen/strstr overhead; pattern doesn't affect
     * SHA branch behaviour since SHA operates on fixed 512-bit blocks. */
    for (int i = 0; i < SHA_BUF_SIZE; i++)
        buf[i] = (e_u8)(i ^ (i >> 8) ^ 0xA5);

    /* ----- KERNEL PHASE ----- */
    marker(0xAABB0002UL);   /* kernel start — perf counters sample here */
    cyc_start = rdcycle();

    volatile e_u32 sink = 0;
    for (int iter = 0; iter < SHA_KERNEL_ITERS; iter++) {
        sha2(buf, (e_u32)SHA_BUF_SIZE, digest);
        /* prevent dead-code elimination */
        sink ^= (e_u32)digest[0] ^ (e_u32)digest[31];
    }

    cyc_end = rdcycle();
    marker(0xAABB0003UL);   /* kernel end */

    /* Store sink to memory so the compiler can't eliminate it */
    volatile e_u32 *sink_mem = (volatile e_u32 *)0x80001008UL;
    *sink_mem = sink;

    free(buf);

    /* Signal PASS — the TB will print final IPC at this point */
    halt(0);
}
