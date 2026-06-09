/*
 * radix2-big-64k_kernel_direct.c — bare-metal 64K-point FFT kernel profiling.
 *
 * Completely bypasses the mith harness and th_rand data-generation machinery.
 * Generates a 65536-point complex (interleaved) double-precision input vector
 * using a deterministic LCG + bit-cast (same statistical character as
 * fromint_f64_vector with seed 6710900), pre-computes twiddle factors with
 * REAL libm sin(), then calls the FFT kernel in a tight loop.
 *
 * FP note: USE_FP64=1, twiddles computed with real sin() from newlib libm.
 *
 * Phase markers:
 *   csrw mscratch, 0xAABB0001  — startup (input + twiddle setup)
 *   csrw mscratch, 0xAABB0002  — kernel start
 *   csrw mscratch, 0xAABB0003  — kernel end
 *
 * Build flags:
 *   RADIX2_KERNEL_ITERS  (default 3)  — iterations of the 64K FFT
 *   RADIX2_N             (default 65536)
 *
 * With 3 iterations this is ~150-200 M FP-heavy instructions plus setup,
 * targeting ~10-20M kernel cycles at the expected IPC.
 */

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>   /* malloc/free from newlib */
#include <string.h>   /* memcpy */
#include <math.h>     /* sin — REAL libm */

typedef double   e_fp;
typedef double   e_f64;
typedef float    e_f32;
typedef unsigned int e_u32;
typedef signed int   e_s32;

#define FPCONST(_x) (_x)
#define RESTRICT restrict

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
#ifndef RADIX2_KERNEL_ITERS
#define RADIX2_KERNEL_ITERS 3
#endif
#ifndef RADIX2_N
#define RADIX2_N 65536
#endif

/* ---- int_log2 ------------------------------------------------------------ */
static int int_log2(int n)
{
    int k = 1, log = 0;
    for (; k < n; k *= 2, log++);
    if (n != (1 << log)) halt(10);
    return log;
}

/* ---- calculate_twiddles — direction=-1, uses REAL sin() ------------------ */
static e_fp *calculate_twiddles(int size, int direction)
{
    int n = 0, a;
    e_fp *twp;
    int bit = 0, logn, dual = 1;

    if (size == 1) return NULL;
    logn = int_log2(size / 2);

    for (bit = 0; bit < logn; bit++, dual *= 2)
        for (a = 1; a < dual; a++)
            n++;
    twp = (e_fp *)malloc(sizeof(e_fp) * 2 * n);
    if (!twp) halt(11);

    n = 0; bit = 0; dual = 1;
    for (bit = 0; bit < logn; bit++, dual *= 2) {
        e_fp w_real = FPCONST(1.0);
        e_fp w_imag = FPCONST(0.0);
        /* theta = 2 * direction * PI / (2 * dual) */
        e_fp theta = FPCONST(2.0) * direction * FPCONST(3.1415926535897932) /
                     (FPCONST(2.0) * (e_fp)dual);
        e_fp s  = sin(theta);           /* REAL libm sin */
        e_fp t  = sin(theta * FPCONST(0.5));
        e_fp s2 = FPCONST(2.0) * t * t;

        for (a = 1; a < dual; a++) {
            e_fp tmp_real = w_real - s * w_imag - s2 * w_real;
            e_fp tmp_imag = w_imag + s * w_real - s2 * w_imag;
            w_real = tmp_real;
            w_imag = tmp_imag;
            twp[n++] = w_real;
            twp[n++] = w_imag;
        }
    }
    return twp;
}

/* ---- FFT_bitreverse ------------------------------------------------------ */
static void FFT_bitreverse(int N, e_fp *RESTRICT data)
{
    int n   = N / 2;
    int nm1 = n - 1;
    int i   = 0, j = 0;
    for (; i < nm1; i++) {
        int ii = i << 1, jj = j << 1;
        int k  = n >> 1;
        if (i < j) {
            e_fp tr = data[ii],     ti = data[ii + 1];
            data[ii]     = data[jj];     data[ii + 1] = data[jj + 1];
            data[jj]     = tr;           data[jj + 1] = ti;
        }
        while (k <= j) { j -= k; k >>= 1; }
        j += k;
    }
}

/* ---- FFT_transform_internal (twiddle-table path) ------------------------- */
static void FFT_transform_internal(int N, e_fp *RESTRICT data, e_fp *twp_base)
{
    int n = N / 2;
    int logn = int_log2(n);
    int dual = 1, bit;
    e_fp *twp = twp_base;

    if (n == 1) return;

    FFT_bitreverse(N, data);

    for (bit = 0; bit < logn; bit++, dual *= 2) {
        int a, b;

        /* a=0 butterfly: w=1+0j — no multiply */
        for (b = 0; b < n; b += 2 * dual) {
            int i = 2 * b, j = 2 * (b + dual);
            e_fp wr = data[j], wi = data[j + 1];
            data[j]     = data[i]     - wr;
            data[j + 1] = data[i + 1] - wi;
            data[i]    += wr;
            data[i + 1]+= wi;
        }

        /* a=1..(dual-1): twiddle-table multiply */
        for (a = 1; a < dual; a++) {
            e_fp w_real = *twp++;
            e_fp w_imag = *twp++;
            for (b = 0; b < n; b += 2 * dual) {
                int i = 2 * (b + a), j = 2 * (b + a + dual);
                e_fp z1r = data[j],  z1i = data[j + 1];
                e_fp wr  = w_real * z1r - w_imag * z1i;
                e_fp wi  = w_real * z1i + w_imag * z1r;
                data[j]     = data[i]     - wr;
                data[j + 1] = data[i + 1] - wi;
                data[i]    += wr;
                data[i + 1]+= wi;
            }
        }
    }
}

/* ---- Deterministic FP input generator (avoids th_rand / th_al deps) ------ */
/*
 * Generates N doubles with a mix of signs, magnitudes, and exponents
 * similar to the EEMBC "precise_random" vectors.  Uses a simple Xorshift32
 * PRNG seeded from seed, then bit-casts to double with constrained exponent.
 * The exact values don't affect the FFT instruction mix — what matters is
 * that no value is 0, NaN, or Inf.
 */
static void gen_fp_vector(e_fp *v, int N, unsigned int seed)
{
    unsigned int s = seed;
    for (int i = 0; i < N; i++) {
        /* Xorshift32 */
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        unsigned int hi = s;
        s ^= s << 13; s ^= s >> 17; s ^= s << 5;
        unsigned int lo = s;

        /* Build a valid IEEE-754 double:
         * - sign  = hi[31]
         * - exp   = biased exponent in range [961..1086] => value ~1e-18..1e18
         * - mant  = hi[19:0] : lo[31:0]
         * This avoids denormals, NaN, Inf.                               */
        unsigned int sign_exp = (hi & 0x80000000u) |
                                (((hi & 0x7f) + 961u) << 20) |
                                (hi & 0x000fffffu);
        unsigned long long bits = ((unsigned long long)sign_exp << 32) |
                                  (unsigned long long)lo;
        double d;
        memcpy(&d, &bits, sizeof(d));
        v[i] = d;
    }
}

/* ---- main --------------------------------------------------------------- */
int main(void)
{
    marker(0xAABB0001UL);   /* startup marker */

    const int N = RADIX2_N;

    /* Allocate and generate the source input (N doubles = interleaved complex) */
    e_fp *orig_data = (e_fp *)malloc(sizeof(e_fp) * N);
    if (!orig_data) halt(1);
    gen_fp_vector(orig_data, N, 6710900U);

    /* Allocate working buffer for in-place FFT */
    e_fp *work_data = (e_fp *)malloc(sizeof(e_fp) * N);
    if (!work_data) halt(2);

    /* Pre-compute twiddle factors with REAL libm sin() */
    e_fp *twp_base = calculate_twiddles(N, -1);
    if (!twp_base) halt(3);

    /* ----- KERNEL PHASE ----- */
    marker(0xAABB0002UL);   /* kernel start */

    volatile e_fp sink = FPCONST(0.0);
    for (int iter = 0; iter < RADIX2_KERNEL_ITERS; iter++) {
        /* Restore input: FFT is in-place */
        memcpy(work_data, orig_data, sizeof(e_fp) * N);

        /* THE HOT KERNEL: 64K-point complex FFT, DP, twiddle-table path */
        FFT_transform_internal(N, work_data, twp_base);

        /* Prevent DCE: keep one output element live */
        sink += work_data[0] + work_data[1];
    }

    marker(0xAABB0003UL);   /* kernel end */

    /* Keep sink live */
    volatile e_fp *sink_mem = (volatile e_fp *)0x80001010UL;
    *sink_mem = sink;

    halt(0);
}
