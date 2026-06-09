/*
 * loops-all-mid-10k-sp_th_extra.c
 *
 * Extra stubs/globals needed by th_lib.c (from mith/src/th_lib.c) and
 * th_encode.c when building the loops-all-mid-10k-sp direct-kernel ELF.
 *
 * reporting_threshold: defined in mith_lib.c; we provide it here so we
 *   don't have to link all of mith_lib.c.
 * uu_send_buf: called by th_ffilecmp in th_lib.c; stubbed since we never
 *   call file comparison functions.
 * verify_output: used by mith harness; we don't run verify.
 */

#include <stddef.h>
#include <stdint.h>

/* From mith/include/th_lib.h:
 *   extern e_u32 reporting_threshold;
 * Defined in mith_lib.c as TH_INFO (=5). Provide minimal value here. */
typedef unsigned int e_u32;
e_u32 reporting_threshold = 5; /* TH_INFO */

/* verify_output is declared extern in th_lib.h and used by mith.
 * In the direct-kernel build we never call bmark_verify_loops, so it's safe
 * to initialize to 0. */
int verify_output = 0;

/* uu_send_buf is called from th_lib.c:th_ffilecmp() which we never invoke.
 * Stub it out to avoid linking th_encode.c (which pulls in base64 tables). */
int uu_send_buf(const unsigned char *buf, size_t length, const char *fn) {
    (void)buf; (void)length; (void)fn;
    return 0;
}
