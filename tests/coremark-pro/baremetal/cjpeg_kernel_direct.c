/*
 * cjpeg_kernel_direct.c — bare-metal JPEG encode kernel profiling bypass.
 *
 * Completely bypasses mith harness (no mith_main, no th_parse_flag,
 * no strstr storms).  Calls cjpeg_main() directly on the embedded
 * Rose256.bmp (35050 bytes, 256x256 24-bit BMP) in a tight loop.
 *
 * The Rose256 BMP is the "preset" dataset used by the cjpeg-rose7-preset
 * workload in CoreMark-PRO.  It is embedded as a C array from
 * benchmarks/consumer_v2/cjpeg/data/Rose256_bmp.c.
 *
 * Phase markers:
 *   csrw mscratch, 0xAABB0001  — startup (before first compress)
 *   csrw mscratch, 0xAABB0002  — kernel start (loop begins)
 *   csrw mscratch, 0xAABB0003  — kernel end
 *
 * Build flags:
 *   CJPEG_KERNEL_ITERS  (default 20) — how many jpeg_compress passes
 *
 * Note: each iteration compresses Rose256 (256x256 RGB BMP → JPEG at q75).
 * One pass ≈ several million cycles.  20 passes is a good profile window.
 *
 * NOT an official CoreMark-PRO score. Bare-metal, single-context,
 * direct-kernel profile for uarch design-space exploration.
 */

#include <stdint.h>
#include <string.h>
#include <stdlib.h>

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
#ifndef CJPEG_KERNEL_ITERS
#define CJPEG_KERNEL_ITERS 20
#endif

/* Rose256_bmp_length is 35050 bytes (256x256 24-bit BMP) */
#define ROSE256_SIZE 35050UL
/* Output JPEG upper bound: for 256x256 q75, ~10KB is typical */
#define JPEG_OUT_SIZE 20000UL

/* ---- Rose256 BMP embedded data ----------------------------------------- */
/* Forward decl — defined in Rose256_bmp.c */
typedef unsigned char e_u8;
extern e_u8 Rose256_bmp[];
enum { Rose256_bmp_length = 35050UL };

/* ---- cjpeg_main API ------------------------------------------------------ */
/* cjpparam_t (from algo.h) — replicated here to avoid pulling in all algo.h deps */
typedef struct {
    unsigned int idx;
    int          do_uuencode;
    char         inFilename[80];
    unsigned long output_file_size;
    char        *default_out_name;
    char        *default_in_name;
    unsigned short cjpeg_CRC;
    e_u8        *inFile_p;
    int          inFile_idx;
    int          inFile_size;
    e_u8        *outFile_p;
    int          outFile_idx;
    int          outFile_size;
    int          outFile_crcsize;
    unsigned int override_idx;
    int          use_c_buffer;
} cjpparam_t;

/* cjpeg_main declaration */
int cjpeg_main(char **output_fname, cjpparam_t *params);

/* ---- main --------------------------------------------------------------- */
int main(void)
{
    marker(0xAABB0001UL);  /* startup marker */

    /* Allocate output buffer once (reused each iteration) */
    e_u8 *out_buf = (e_u8 *)malloc(JPEG_OUT_SIZE);
    if (!out_buf) halt(1);

    /* Build params — point directly at the embedded BMP data.
     * Each cjpeg_main() call resets inFile_idx/outFile_idx, so the
     * same in-memory BMP and output buffer can be reused.
     */
    cjpparam_t params;
    memset(&params, 0, sizeof(params));
    params.idx             = 0;
    params.do_uuencode     = 0;
    params.use_c_buffer    = 1;          /* signal: data supplied by C array */
    params.inFile_p        = Rose256_bmp;
    params.inFile_size     = (int)ROSE256_SIZE;
    params.inFile_idx      = 0;
    params.outFile_p       = out_buf;
    params.outFile_size    = (int)JPEG_OUT_SIZE;
    params.outFile_crcsize = 5900;
    params.outFile_idx     = 0;
    params.default_out_name = "Rose256.jpg";
    params.default_in_name  = "Rose256.bmp";

    /* Warm-up: one pass outside the counted window to prime caches */
    char *outname_dummy = NULL;
    cjpeg_main(&outname_dummy, &params);
    /* Reset indices for the kernel loop */
    params.inFile_idx  = 0;
    params.outFile_idx = 0;

    /* ----- KERNEL PHASE ----- */
    marker(0xAABB0002UL);  /* kernel start */

    volatile unsigned int sink = 0;
    unsigned long cyc_start = rdcycle();

    for (int iter = 0; iter < CJPEG_KERNEL_ITERS; iter++) {
        params.inFile_idx  = 0;
        params.outFile_idx = 0;
        char *outname = NULL;
        cjpeg_main(&outname, &params);
        /* accumulate output byte to prevent DCE */
        sink ^= (unsigned int)out_buf[0] ^ (unsigned int)out_buf[params.outFile_idx - 1];
    }

    unsigned long cyc_end = rdcycle();
    marker(0xAABB0003UL);  /* kernel end */

    /* Keep sink live */
    volatile unsigned int *sink_mem = (volatile unsigned int *)0x80001008UL;
    *sink_mem = sink;

    (void)cyc_start; (void)cyc_end;
    free(out_buf);

    halt(0);
}
