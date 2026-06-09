/*
 * zip_kernel_direct.c — bare-metal zlib compress/decompress kernel profiling bypass.
 *
 * Completely bypasses mith harness (no mith_main, no th_parse_flag,
 * no strstr storms).  Builds a ~1 MB XML-like buffer in memory and calls
 * compress() / uncompress() from zlib-1.2.8 in a tight loop.
 *
 * Phase markers (readable in sim cycle-count log):
 *   csrw mscratch, 0xAABB0001  — startup (before buffer generation)
 *   csrw mscratch, 0xAABB0002  — kernel start (compress loop begins)
 *   csrw mscratch, 0xAABB0003  — kernel end (after loop)
 *
 * Build flags:
 *   ZIP_KERNEL_ITERS  (default 5) — number of compress+uncompress rounds
 *   ZIP_BUF_SIZE      (default 1048113) — uncompressed input size (matches dataset 0)
 *
 * Default dataset 0 from zip_darkmark.c:
 *   {NULL, 13560, NULL, 1048113, 0x34f8, 0, 8989, 0, NULL, 0, 0, 0, 0, 0x1764}
 *   seed=8989, buf_type=0 (XML-style records), unz_buf_len=1048113
 *
 * Note: this is a bare-metal PROFILE run, NOT an official CoreMark-PRO score.
 */

#include <stdint.h>
#include <string.h>
#include <stdlib.h>   /* malloc / free from newlib */
#include <stdio.h>    /* sprintf */

/* zlib public API */
#include "zlib.h"

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
#ifndef ZIP_KERNEL_ITERS
#define ZIP_KERNEL_ITERS 5
#endif
#ifndef ZIP_BUF_SIZE
#define ZIP_BUF_SIZE 1048113   /* dataset 0 unz_buf_len */
#endif

/* ---- Simple LCG random (mirrors mith rand_init seed=8989, limit=0xff) --- */
/* We just want to fill the buffer with plausible XML-like text;
 * exact match to mith's prng is not needed for profiling. */
static unsigned int lcg_state = 8989U;
static unsigned int lcg_next_val(void) {
    lcg_state = lcg_state * 1664525U + 1013904223U;
    return lcg_state & 0xFFu;   /* 0..255 range like mith random_u8 */
}
static unsigned int lcg_u32(void) {
    unsigned int v = 0;
    v |= lcg_next_val();
    v |= lcg_next_val() << 8;
    v |= lcg_next_val() << 16;
    v |= lcg_next_val() << 24;
    return v;
}

/* ---- String tables matching zip_darkmark.c gen_parse_buf() -------------- */
static const char *cnames[] = { "EEMBC", "SAGESOFT", "INTEL",
                                 "Lockheed Martin", "ST", "RENESAS" };
static const char *pnames[] = { "Shay", "Markus", "Pierre",
                                 "Vader", "Skeet", "Boron" };

static const char *xml_start =
    "<?xml version='1.0'?>\n<html>\n  <body scene='test'>\n";
static const char *xml_end =
    "  </body>\n</html>\n<footer>(c) EEMBC</footer>\n";

/*
 * gen_xml_buf: fill `buf` (size bytes) with XML records.
 * Returns actual bytes written (without NUL terminator).
 * Mirrors the default buf_type=0 path in zip_darkmark.c.
 */
static size_t gen_xml_buf(char *buf, size_t size)
{
    size_t pos = 0;
    size_t start_len = strlen(xml_start);
    size_t end_len   = strlen(xml_end);

    if (size < start_len + end_len + 1)
        return 0;

    memcpy(buf + pos, xml_start, start_len);
    pos += start_len;
    size -= start_len;

    char entry[128];
    /* Keep filling until we'd overshoot the end footer */
    while (size > (end_len + 100)) {
        const char *company = cnames[lcg_u32() % 6];
        const char *name    = pnames[lcg_u32() % 6];
        unsigned int id     = (lcg_u32() & 0xFFFu) + 1;
        int elen = sprintf(entry,
            "<p company='%s'><b>%s</b><data>%u</data></p>\n",
            company, name, id);
        if (elen <= 0 || (size_t)elen + end_len + 4 >= size)
            break;
        memcpy(buf + pos, entry, elen);
        pos += elen;
        size -= elen;
    }

    memcpy(buf + pos, xml_end, end_len);
    pos += end_len;
    buf[pos] = '\0';
    return pos;
}

/* ---- main --------------------------------------------------------------- */
int main(void)
{
    marker(0xAABB0001UL);   /* startup marker */

    /* ---- Allocate buffers ---- */
    size_t unz_len = (size_t)ZIP_BUF_SIZE;
    unsigned char *unz_buf = (unsigned char *)malloc(unz_len + 1);
    if (!unz_buf) halt(1);

    /* Compressed output buffer: compressBound() = unz_len + ~1% + 12 */
    uLong bound = compressBound((uLong)unz_len);
    unsigned char *zip_buf = (unsigned char *)malloc((size_t)bound);
    if (!zip_buf) halt(2);

    /* Decompressed round-trip buffer */
    unsigned char *rt_buf = (unsigned char *)malloc(unz_len + 1);
    if (!rt_buf) halt(3);

    /* ---- Fill input buffer with XML-like data ---- */
    size_t actual_len = gen_xml_buf((char *)unz_buf, unz_len);
    if (actual_len == 0) halt(4);
    /* Pad remainder with a benign pattern */
    for (size_t i = actual_len; i < unz_len; i++)
        unz_buf[i] = (unsigned char)('A' + (i % 26));

    /* Sink to prevent DCE */
    volatile uLong g_zip_len = 0;
    volatile uLong g_unz_len = 0;

    /* ----- KERNEL PHASE ----- */
    marker(0xAABB0002UL);   /* kernel start — perf counters sample here */
    unsigned long cyc_start = rdcycle();

    for (int iter = 0; iter < ZIP_KERNEL_ITERS; iter++) {
        /* === COMPRESS === */
        uLong zip_len = bound;
        int err = compress(zip_buf, &zip_len, unz_buf, (uLong)unz_len);
        if (err != Z_OK) halt(10 + err);

        g_zip_len ^= zip_len;   /* prevent DCE */

        /* === DECOMPRESS (round-trip) === */
        uLong rt_len = (uLong)(unz_len + 1);
        err = uncompress(rt_buf, &rt_len, zip_buf, zip_len);
        if (err != Z_OK) halt(20 + err);

        g_unz_len ^= rt_len;   /* prevent DCE */
    }

    unsigned long cyc_end = rdcycle();
    marker(0xAABB0003UL);   /* kernel end */

    /* Store sinks to tohost+8 so compiler keeps them */
    volatile uLong *sink_mem = (volatile uLong *)0x80001008UL;
    *sink_mem = g_zip_len ^ g_unz_len ^ (uLong)(cyc_end - cyc_start);

    free(rt_buf);
    free(zip_buf);
    free(unz_buf);

    halt(0);
}
