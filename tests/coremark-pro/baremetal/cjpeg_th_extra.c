/*
 * cjpeg_th_extra.c — cjpeg-specific th_* stubs for bare-metal profiling.
 *
 * These stubs are needed by the libjpeg consumer benchmark sources
 * (jutils.c, filedata.c, bmark_lite.c) but are NOT in the shared
 * th_stubs.c.  Isolated here to avoid conflicts with other agents.
 *
 * Stubs provided:
 *   Calc_crc8           — 8-bit CRC used by bmark_verify_cjpeg (not called)
 *   th_sscanf           — thin wrapper around sscanf (needed by bmark_lite.c)
 *   th_stat             — always returns -1 (file path not used; BMP is embedded)
 *   th_clearerr         — no-op
 *   th_ungetc           — no-op
 *   th_send_buf_as_file — no-op (verify_output=0 so never called)
 *   th_parse_buf_flag   — returns 0 (no command-line to parse)
 *   th_parse_buf_flag_unsigned — returns 0
 *   th_get_buf_flag     — returns 0
 *   th_vfprintf         — discards output
 *   th_fscanf           — stub (returns 0)
 *   th_fdopen           — returns NULL
 *   th_freopen          — returns NULL
 *   th_tmpfile          — returns NULL
 *   th_mktemp           — returns NULL
 *   th_fcreate          — returns NULL
 *   th_lstat            — returns -1
 *   th_fstat            — returns -1
 *   th_rename           — returns -1
 *   th_getcwd           — returns NULL
 *   th_getwd            — returns NULL
 *   th_chdir            — returns -1
 *   th_malloc_total / th_malloc_max not re-declared here (already in th_stubs.c)
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>

typedef unsigned char  e_u8;
typedef unsigned short e_u16;
typedef int            e_s32;
typedef unsigned int   e_u32;
typedef void           ee_FILE;

/* ---- Calc_crc8 (used in bmark_verify_cjpeg, not called in our path) ----- */
e_u16 Calc_crc8(e_u8 data, e_u16 crc) {
    unsigned int x = (unsigned int)data ^ (unsigned int)(crc & 0xFF);
    for (int i = 0; i < 8; i++)
        x = (x & 1) ? (x >> 1) ^ 0xA001u : (x >> 1);
    return (e_u16)((crc >> 8) ^ (x & 0xFF));
}

/* ---- th_sscanf (called by parse_dataset_cjpeg but we bypass that) ------- */
int th_sscanf(const char *str, const char *fmt, ...) {
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = vsscanf(str, fmt, ap);
    va_end(ap);
    return r;
}

/* ---- th_stat (jutils.c getFilesize_cjpeg; not called when BMP embedded) - */
int th_stat(const char *path, void *buf) {
    (void)path; (void)buf;
    return -1;  /* file not found; but we don't load files anyway */
}
int th_lstat(const char *path, void *buf) {
    (void)path; (void)buf;
    return -1;
}
int th_fstat(int fd, void *buf) {
    (void)fd; (void)buf;
    return -1;
}

/* ---- File I/O extras ----------------------------------------------------- */
void th_clearerr(ee_FILE *fp) { (void)fp; }
int  th_ungetc(int c, ee_FILE *fp) { (void)c; (void)fp; return -1; }
int  th_rename(const char *a, const char *b) { (void)a; (void)b; return -1; }
char *th_getcwd(char *buf, size_t sz) { (void)buf; (void)sz; return NULL; }
char *th_getwd(char *buf) { (void)buf; return NULL; }
int  th_chdir(const char *p) { (void)p; return -1; }
ee_FILE *th_fdopen(int fd, const char *m) { (void)fd; (void)m; return NULL; }
ee_FILE *th_freopen(const char *f, const char *m, ee_FILE *fp) {
    (void)f; (void)m; (void)fp; return NULL;
}
ee_FILE *th_tmpfile(void) { return NULL; }
char    *th_mktemp(char *t) { (void)t; return NULL; }
ee_FILE *th_fcreate(const char *f, const char *m, char *d, size_t s) {
    (void)f; (void)m; (void)d; (void)s; return NULL;
}
int th_vfprintf(ee_FILE *fp, const char *fmt, va_list ap) {
    (void)fp; (void)fmt; (void)ap; return 0;
}
int th_fscanf(ee_FILE *fp, const char *fmt, ...) {
    (void)fp; (void)fmt; return 0;
}
int th_vfscanf(ee_FILE *fp, const char *fmt, va_list ap) {
    (void)fp; (void)fmt; (void)ap; return 0;
}

/* ---- th_send_buf_as_file (verify_output=0 so never called) -------------- */
int th_send_buf_as_file(const unsigned char *buf, size_t length, const char *fn) {
    (void)buf; (void)length; (void)fn;
    return 0;
}

/* ---- Buffer flag parsers (not called in our direct path) ---------------- */
int th_parse_buf_flag(char *buf, char *flag, e_s32 *val) {
    (void)buf; (void)flag; (void)val;
    return 0;
}
int th_parse_buf_flag_unsigned(char *buf, char *flag, e_u32 *val) {
    (void)buf; (void)flag; (void)val;
    return 0;
}
int th_get_buf_flag(char *buf, char *flag, char **val) {
    (void)buf; (void)flag; (void)val;
    return 0;
}
int th_parse_buf_flag_word(char *buf, char *flag, char *val[]) {
    (void)buf; (void)flag; (void)val;
    return 0;
}

/* ---- th_malloc_x / th_free_x already in th_stubs.c; only extras here --- */
/* th_malloc_total / th_malloc_max referenced in alloc.h macros via th_stubs.c */

/* ---- th_send_* extras that may be pulled in by th_lib references --------- */
int th_printf_utf8(const char *fmt, ...) { (void)fmt; return 0; }
