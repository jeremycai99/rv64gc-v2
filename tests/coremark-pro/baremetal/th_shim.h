/*
 * th_shim.h — minimal mith th_* compatibility shim for direct-kernel builds.
 *
 * Maps all th_* functions used by sha256.c / ezxml.c to standard C library
 * equivalents from newlib.  No mith harness sources required.
 *
 * Include this BEFORE any CoreMark-PRO header in direct-kernel main files.
 */
#ifndef TH_SHIM_H
#define TH_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <ctype.h>

/* --- Type aliases that mith/th_types.h would normally provide ------------ */
typedef unsigned char   e_u8;
typedef unsigned short  e_u16;
typedef unsigned int    e_u32;
typedef unsigned long   e_u64;
typedef signed char     e_s8;
typedef signed short    e_s16;
typedef signed int      e_s32;
typedef signed long     e_s64;
typedef float           e_f32;
typedef double          e_f64;

/* --- Globals referenced by th_lib.c / mith_lib.c stubs ------------------- */
/* These may be referenced by ezxml or other code pulled in indirectly.      */
extern int pgo_training_run;
extern int verify_output;
extern int reporting_threshold;

/* --- Memory management --------------------------------------------------- */
#define th_malloc(s)       malloc(s)
#define th_free(p)         free(p)
#define th_realloc(p,s)    realloc((p),(s))
#define th_calloc(n,s)     calloc((n),(s))

/* --- String + memory helpers --------------------------------------------- */
#define th_memcpy(d,s,n)   memcpy((d),(s),(n))
#define th_memmove(d,s,n)  memmove((d),(s),(n))
#define th_memset(s,c,n)   memset((s),(c),(n))
#define th_memcmp(s1,s2,n) memcmp((s1),(s2),(n))

#define th_strlen(s)       strlen(s)
#define th_strcpy(d,s)     strcpy((d),(s))
#define th_strncpy(d,s,n)  strncpy((d),(s),(n))
#define th_strcat(d,s)     strcat((d),(s))
#define th_strcmp(s1,s2)   strcmp((s1),(s2))
#define th_strncmp(s1,s2,n) strncmp((s1),(s2),(n))
#define th_strstr(h,n)     strstr((h),(n))
#define th_strchr(s,c)     strchr((s),(c))
#define th_strspn(s,a)     strspn((s),(a))
#define th_strcspn(s,a)    strcspn((s),(a))
#define th_strdup(s)       strdup(s)
#define th_strtol(s,e,b)   strtol((s),(e),(b))
#define th_atoi(s)         atoi(s)

/* --- I/O (all discarded or stubbed) -------------------------------------- */
#define th_printf(...)     ((void)0)
#define th_fprintf(...)    ((void)0)
#define th_sprintf(...)    sprintf(__VA_ARGS__)
#define th_snprintf(...)   snprintf(__VA_ARGS__)

/* th_exit: write tohost and spin */
static inline void th_exit_impl(int code) __attribute__((noreturn));
static inline void th_exit_impl(int code) {
    volatile unsigned long *tohost = (volatile unsigned long *)0x80001000UL;
    if (code == 0) *tohost = 1UL;
    else *tohost = (unsigned long)((code << 1) | 1);
    while (1) {}
}
#define th_exit(code, ...) th_exit_impl(code)

/* --- File I/O stubs (ezxml uses these only in non-FAKE_FILEIO paths) ----- */
/* We compile with FAKE_FILEIO=1 so these paths are not reached in practice, */
/* but ezxml.c still references th_fopen etc. at the call sites we DO use.   */
/* Provide no-op stubs so the linker is satisfied.                            */
typedef void ee_FILE;
#define th_fopen(f,m)      ((ee_FILE*)NULL)
#define th_fclose(f)       0
#define th_fread(b,s,n,f)  0
#define th_fwrite(b,s,n,f) 0
#define th_feof(f)         1
#define th_ferror(f)       1
#define th_fileno(f)       -1
#define th_fflush(f)       0
#define th_fseek(f,o,w)    -1
#define th_ftell(f)        -1L
#define th_fsize(f)        0

/* th_stderr: just use NULL since th_fprintf is discarded */
#define th_stderr          ((ee_FILE*)NULL)
#define th_stdout          ((ee_FILE*)NULL)
#define th_stdin           ((ee_FILE*)NULL)

/* th_file.h often defines FILE_TYPE_DEFINED to suppress stdio FILE */
#define FILE_TYPE_DEFINED  1

#endif /* TH_SHIM_H */
