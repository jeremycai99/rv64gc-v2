/*
 * th_stubs.c — minimal mith shim for direct-kernel builds.
 *
 * Provides the subset of th_* symbols that sha256.c and ezxml.c depend on,
 * implemented as thin wrappers around newlib.  No mith harness required.
 *
 * Symbols provided:
 *   th_malloc / th_malloc_x    (newlib malloc)
 *   th_free / th_free_x        (newlib free)
 *   th_realloc                 (newlib realloc)
 *   th_calloc                  (newlib calloc)
 *   th_memcpy / th_memmove     (newlib memcpy/memmove)
 *   th_memset                  (newlib memset)
 *   th_strlen / th_strcpy / th_strncpy / th_strcat / th_strcmp / th_strncmp
 *   th_strstr / th_strchr / th_strspn / th_strcspn / th_strdup / th_strtol
 *   th_atoi / th_sprintf / th_snprintf
 *   th_exit                    (writes tohost + spins)
 *   th_printf / th_fprintf     (discarded)
 *   pgo_training_run / verify_output / reporting_threshold (global ints)
 *   th_stdin / th_stdout / th_stderr (NULL ee_FILE* pointers)
 *   redirect_std_files         (no-op)
 *
 * NOT provided (not needed by sha256.c / ezxml.c kernel paths):
 *   th_rand, md5, th_bignum, th_math, mith_lib, mith_workload, al_smp
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdarg.h>

/* ---- Global state expected by mith headers ------------------------------- */
int pgo_training_run = 0;
int verify_output    = 0;
int reporting_threshold = 0;

/* These are used in some mith inlines for th_malloc tracking */
size_t th_malloc_total = 0;
size_t th_malloc_max   = 0;

/* ---- FILE type stub ------------------------------------------------------- */
/* ezxml.c / th_lib.h reference ee_FILE. We expose only NULL pointers. */
void *th_stdin  = NULL;
void *th_stdout = NULL;
void *th_stderr = NULL;

/* ---- Memory management --------------------------------------------------- */
void *th_malloc_x(size_t size, const char *file, int line) {
    (void)file; (void)line;
    return malloc(size);
}
void th_free_x(void *blk, const char *file, int line) {
    (void)file; (void)line;
    free(blk);
}
/* th_realloc has both a plain and an _x variant in th_lib.h */
void *th_realloc_x(void *ptr, size_t size, const char *file, int line) {
    (void)file; (void)line;
    return realloc(ptr, size);
}
void *th_realloc(void *ptr, size_t size) { return realloc(ptr, size); }
void *th_calloc(size_t n, size_t size)   { return calloc(n, size); }
/* th_strdup has an _x variant too */
char *th_strdup_x(const char *s, const char *file, int line) {
    (void)file; (void)line;
    return strdup(s);
}

/* ---- Memory helpers ------------------------------------------------------ */
void *th_memcpy(void *d, const void *s, size_t n)  { return memcpy(d, s, n); }
void *th_memmove(void *d, const void *s, size_t n) { return memmove(d, s, n); }
void *th_memset(void *s, int c, size_t n)          { return memset(s, c, n); }
int   th_memcmp(const void *s1, const void *s2, size_t n) { return memcmp(s1, s2, n); }

/* ---- String helpers ------------------------------------------------------ */
size_t th_strlen(const char *s)                      { return strlen(s); }
char  *th_strcpy(char *d, const char *s)             { return strcpy(d, s); }
char  *th_strncpy(char *d, const char *s, size_t n)  { return strncpy(d, s, n); }
char  *th_strcat(char *d, const char *s)             { return strcat(d, s); }
int    th_strcmp(const char *s1, const char *s2)     { return strcmp(s1, s2); }
int    th_strncmp(const char *s1, const char *s2, size_t n) { return strncmp(s1, s2, n); }
char  *th_strstr(const char *h, const char *n)       { return (char*)strstr(h, n); }
char  *th_strchr(const char *s, int c)               { return (char*)strchr(s, c); }
size_t th_strspn(const char *s, const char *a)       { return strspn(s, a); }
size_t th_strcspn(const char *s, const char *a)      { return strcspn(s, a); }
char  *th_strdup(const char *s)                      { return strdup(s); }
long   th_strtol(const char *s, char **e, int b)     { return strtol(s, e, b); }
int    th_atoi(const char *s)                        { return atoi(s); }

/* ---- Formatted output (discarded for bare-metal) ------------------------- */
int th_printf(const char *fmt, ...) { (void)fmt; return 0; }
int th_fprintf(void *fp, const char *fmt, ...) { (void)fp; (void)fmt; return 0; }
int th_sprintf(char *str, const char *fmt, ...) {
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = vsprintf(str, fmt, ap);
    va_end(ap);
    return r;
}
int th_snprintf(char *str, size_t n, const char *fmt, ...) {
    va_list ap;
    int r;
    va_start(ap, fmt);
    r = vsnprintf(str, n, fmt, ap);
    va_end(ap);
    return r;
}

/* ---- th_exit ------------------------------------------------------------- */
void th_exit(int exit_code, const char *fmt, ...) __attribute__((noreturn));
void th_exit(int exit_code, const char *fmt, ...) {
    (void)fmt;
    volatile unsigned long *tohost = (volatile unsigned long *)0x80001000UL;
    if (exit_code == 0) *tohost = 1UL;
    else *tohost = (unsigned long)((exit_code << 1) | 1);
    while (1) {}
}

/* ---- File I/O stubs (never called in FAKE_FILEIO paths) ----------------- */
/* ezxml.c references these symbols; stubs prevent linker errors. */
typedef void ee_FILE;
int    th_fclose(ee_FILE *fp)                          { (void)fp; return -1; }
int    th_ferror(ee_FILE *fp)                          { (void)fp; return 1; }
int    th_feof(ee_FILE *fp)                            { (void)fp; return 1; }
int    th_fileno(ee_FILE *fp)                          { (void)fp; return -1; }
int    th_fflush(ee_FILE *fp)                          { (void)fp; return -1; }
size_t th_fread(void *b, size_t s, size_t n, ee_FILE *fp)
                                                       { (void)b; (void)s; (void)n; (void)fp; return 0; }
size_t th_fwrite(const void *b, size_t s, size_t n, ee_FILE *fp)
                                                       { (void)b; (void)s; (void)n; (void)fp; return 0; }
int    th_fseek(ee_FILE *fp, long off, int w)          { (void)fp; (void)off; (void)w; return -1; }
long   th_ftell(ee_FILE *fp)                           { (void)fp; return -1L; }
ee_FILE *th_fopen(const char *f, const char *m)        { (void)f; (void)m; return NULL; }
int    th_putc(int c, ee_FILE *fp)                     { (void)c; (void)fp; return -1; }
int    th_getc(ee_FILE *fp)                            { (void)fp; return -1; }
char  *th_fgets(char *s, int n, ee_FILE *fp)           { (void)s; (void)n; (void)fp; return NULL; }
int    th_fputs(const char *s, ee_FILE *fp)            { (void)s; (void)fp; return -1; }
size_t th_fsize(const char *f)                         { (void)f; return 0; }
int    th_unlink(const char *f)                        { (void)f; return -1; }
int    th_filecmp(const char *f1, const char *f2)      { return f1 == f2; }

/* Misc th_lib.c exports that may be referenced */
void redirect_std_files(void) {}
char *th_getenv(const char *k) { (void)k; return NULL; }
int  th_timer_available(void) { return 0; }
int  th_timer_is_intrusive(void) { return 0; }

/* crcbuffer — used by t_run_test_parser for result accumulation */
unsigned short th_crcbuffer(const void *inbuf, size_t size, unsigned short inputCRC) {
    const unsigned char *p = (const unsigned char *)inbuf;
    unsigned int crc = inputCRC;
    for (size_t i = 0; i < size; i++) {
        crc ^= (unsigned int)p[i];
        for (int j = 0; j < 8; j++)
            crc = (crc & 1) ? (crc >> 1) ^ 0x8408u : (crc >> 1);
    }
    return (unsigned short)crc;
}

/* Calc_crc32 — used by t_run_test_parser */
unsigned short Calc_crc32(unsigned int data, unsigned short crc) {
    unsigned int x = data;
    crc ^= (unsigned short)(x & 0xFFFF);
    for (int i = 0; i < 16; i++)
        crc = (crc & 1) ? (crc >> 1) ^ 0x8408u : (crc >> 1);
    crc ^= (unsigned short)((x >> 16) & 0xFFFF);
    for (int i = 0; i < 16; i++)
        crc = (crc & 1) ? (crc >> 1) ^ 0x8408u : (crc >> 1);
    return crc;
}
