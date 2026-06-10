/*
 * parser_kernel_direct.c — bare-metal XML parser kernel profiling bypass.
 *
 * Completely bypasses mith harness (no mith_main, no th_parse_flag,
 * no strstr storms).  Generates a 125 KB XML buffer once using the same
 * gen_parse_buf logic from parser.c (simplified), then calls
 * ezxml_parse_str() + traverse + ezxml_free() in a tight loop.
 *
 * Phase markers:
 *   csrw mscratch, 0xAABB0001  — startup (before buffer gen)
 *   csrw mscratch, 0xAABB0002  — kernel start
 *   csrw mscratch, 0xAABB0003  — kernel end
 *
 * Build flags:
 *   PARSER_KERNEL_ITERS  (default 30)
 *   PARSER_BUF_SIZE      (default 125000)
 *
 * With 30 iterations at ~125 KB XML each, this is ~30-60M instructions
 * (mostly ezxml pointer chasing => many indirect branches => ITTAGE target).
 * Adjust PARSER_KERNEL_ITERS down if runtime too long (each ~1.5M cyc).
 */

#include <stdint.h>
#include <string.h>
#include <stdlib.h>   /* malloc / free from newlib */
#include <stdio.h>    /* sprintf */

/* ezxml public API */
#include "ezxml.h"

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
#ifndef PARSER_KERNEL_ITERS
#define PARSER_KERNEL_ITERS 30
#endif
#ifndef PARSER_BUF_SIZE
#define PARSER_BUF_SIZE 125000
#endif

/* ---- Simple LCG (no mith rand, no malloc for state) --------------------- */
static unsigned int lcg_state = 12345678U;
static unsigned int lcg_next(void) {
    lcg_state = lcg_state * 1664525U + 1013904223U;
    return lcg_state;
}

/* ---- Generate XML buffer (same structure as parser.c default dataset 0) - */
static const char *xml_start =
    "<?xml version='1.0'?>\n<html>\n  <body scene='test'>\n";
static const char *xml_end =
    "  </body>\n</html>\n<footer>(c) EEMBC</footer>\n";

static const char *cnames[] = { "EEMBC", "SAGESOFT", "INTEL",
                                 "Lockheed Martin", "ST", "RENESAS" };
static const char *pnames[] = { "Shay", "Markus", "Pierre",
                                 "Vader", "Skeet", "Boron" };

/*
 * Build a self-contained XML buffer in `buf` (caller-allocated, `cap` bytes).
 * Returns actual bytes written (not counting NUL terminator).
 */
static size_t build_xml(char *buf, size_t cap)
{
    size_t pos = 0;
    size_t start_len = strlen(xml_start);
    size_t end_len   = strlen(xml_end);

    if (cap < start_len + end_len + 1)
        return 0;

    memcpy(buf + pos, xml_start, start_len);
    pos += start_len;

    char entry[128];
    while (pos + end_len + 80 < cap) {
        const char *company = cnames[lcg_next() % 6];
        const char *name    = pnames[lcg_next() % 6];
        unsigned int id     = (lcg_next() & 0xFFF) + 1;
        int elen = sprintf(entry,
            "    <p company='%s'><b>%s</b><data>%u</data></p>\n",
            company, name, id);
        if (elen <= 0 || pos + (size_t)elen + end_len >= cap)
            break;
        memcpy(buf + pos, entry, elen);
        pos += elen;
    }

    memcpy(buf + pos, xml_end, end_len);
    pos += end_len;
    buf[pos] = '\0';
    return pos;
}

/* ---- Traverse the parsed XML tree (same as t_run_test_parser) ----------- */
static volatile unsigned int g_sink = 0;

static void traverse_tree(ezxml_t top)
{
    ezxml_t body   = ezxml_child(top, "body");
    if (!body) return;

    unsigned int acc = 0;
    for (ezxml_t person = ezxml_child(body, "p"); person; person = person->next) {
        const char *company = ezxml_attr(person, "company");
        ezxml_t tag = ezxml_child(person, "b");
        if (!tag) continue;
        const char *name = tag->txt;
        tag = ezxml_child(person, "data");
        if (!tag) continue;
        int data = 0;
        const char *dp = tag->txt;
        while (*dp >= '0' && *dp <= '9')
            data = data * 10 + (*dp++ - '0');

        /* Accumulate something to prevent DCE */
        acc ^= (unsigned int)(company[0]) ^ (unsigned int)(name[0]) ^
               (unsigned int)data;
        (void)acc;
    }
    g_sink ^= acc;
}

/* ---- main --------------------------------------------------------------- */
int main(void)
{
    marker(0xAABB0001UL);   /* startup marker */

    /* Allocate a persistent XML template buffer.
     * We generate it once and reuse for every parse iteration.
     * Each ezxml_parse_str() call gets a fresh copy because ezxml
     * modifies the buffer in-place during parsing. */
    size_t buf_size = (size_t)PARSER_BUF_SIZE;
    char *xml_template = (char *)malloc(buf_size + 1);
    if (!xml_template) halt(1);

    size_t xml_len = build_xml(xml_template, buf_size);
    if (xml_len == 0) halt(2);

    /* Working copy: ezxml modifies buffer in-place, so we copy each iter */
    char *xml_work = (char *)malloc(xml_len + 1);
    if (!xml_work) halt(3);

    /* ----- KERNEL PHASE ----- */
    marker(0xAABB0002UL);   /* kernel start */

    for (int iter = 0; iter < PARSER_KERNEL_ITERS; iter++) {
        /* Restore working copy for each parse (ezxml modifies in-place) */
        memcpy(xml_work, xml_template, xml_len + 1);

        /* Parse — this is the hot kernel */
        ezxml_t top = ezxml_parse_str(xml_work, xml_len);
        if (top) {
#ifndef PARSER_SKIP_TRAVERSE
            traverse_tree(top);   /* phase-isolation A/B: -DPARSER_SKIP_TRAVERSE drops this */
#else
            (void)traverse_tree;
#endif
            ezxml_free(top);
        }
    }

    marker(0xAABB0003UL);   /* kernel end */

    /* Keep sink live */
    volatile unsigned int *sink_mem = (volatile unsigned int *)0x80001008UL;
    *sink_mem = g_sink;

    free(xml_work);
    free(xml_template);

    halt(0);
}
