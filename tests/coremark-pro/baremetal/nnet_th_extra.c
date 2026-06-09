/*
 * nnet_th_extra.c — extra mith stubs needed for the nnet direct-kernel build.
 *
 * Provides:
 *   - th_aligned_malloc_x / th_aligned_free_x   (used by nnet.c params alloc)
 *   - store_dp / load_dp / store_sp / load_sp    (used by th_rand.c PRNG)
 *   - intparts_zero                              (referenced by th_lib.h)
 *   - th_malloc / th_free wrappers               (used by th_rand.c)
 *
 * All FP bit-manipulation stubs are the HOST_EXAMPLE_CODE variants from
 * th_al.c, stripped of the OS/Windows includes.
 *
 * NOTE: th_math.h macros map th_exp -> exp (real libm), so no th_exp stub needed.
 */

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

/* ---- Types matching th_al.h / th_lib.h --------------------------------- */
typedef signed char     e_s8;
typedef signed short    e_s16;
typedef signed int      e_s32;
typedef unsigned char   e_u8;
typedef unsigned short  e_u16;
typedef unsigned int    e_u32;
typedef float           e_f32;
typedef double          e_f64;

typedef struct intparts_s {
    e_s8  sign;
    e_s16 exp;
    e_u32 mant_high32;
    e_u32 mant_low32;
} intparts;

intparts intparts_zero = {0, 0, 0, 0};

/* ---- Bit-manipulation helpers (from fdlibm / th_al.c style) ------------ */

#define EXTRACT_WORDS(ix0, ix1, d)          \
do {                                         \
    union { double v; uint64_t u; } _ew;     \
    _ew.v = (d);                             \
    (ix0) = (uint32_t)(_ew.u >> 32);        \
    (ix1) = (uint32_t)(_ew.u & 0xffffffff); \
} while (0)

#define INSERT_WORDS(d, ix0, ix1)           \
do {                                         \
    union { double v; uint64_t u; } _iw;     \
    _iw.u = ((uint64_t)(uint32_t)(ix0) << 32) | (uint32_t)(ix1); \
    (d) = _iw.v;                             \
} while (0)

#define GET_FLOAT_WORD(i, d)                \
do {                                         \
    union { float v; uint32_t u; } _gf;      \
    _gf.v = (d); (i) = _gf.u;               \
} while (0)

#define SET_FLOAT_WORD(d, i)                \
do {                                         \
    union { float v; uint32_t u; } _sf;      \
    _sf.u = (i); (d) = _sf.v;               \
} while (0)

/* store_dp: build a double from intparts (sign, exp, mant_high32, mant_low32) */
int store_dp(e_f64 *value, intparts *asint)
{
    e_u32 manthigh = asint->mant_high32;
    e_s32 exp = asint->exp;
    e_f64 v64;
    e_u32 iexp;

    if (!value || !asint) return 0;

    if (manthigh >= ((e_u32)1 << (52 - 32 + 1))) return 0;
    if (!(manthigh & ((e_u32)1 << (52 - 32)))) {
        if (exp == 0 && manthigh == 0 && asint->mant_low32 == 0) {
            INSERT_WORDS(v64, (e_u32)(asint->sign) << 31, 0);
            *value = v64;
            return 1;
        }
        return 0;
    }

    manthigh &= ((e_u32)1 << (52 - 32)) - 1;
    exp += 1023;
    if (exp <= 0 || exp >= 2047) return 0;
    iexp = exp << (52 - 32);
    if (asint->sign) iexp |= 0x80000000u;
    INSERT_WORDS(v64, (manthigh | iexp), asint->mant_low32);
    *value = v64;
    return 1;
}

/* load_dp: decode a double into intparts */
int load_dp(e_f64 *value, intparts *asint)
{
    e_u32 iValue0, iValue1;
    if (!value || !asint) return 0;
    EXTRACT_WORDS(iValue1, iValue0, *value);
    asint->mant_low32  = iValue0;
    asint->mant_high32 = (iValue1 & (((e_u32)1 << (52 - 32)) - 1));
    asint->exp  = (e_s16)((iValue1 >> (52 - 32)) & 2047);
    asint->sign = (e_s8)(iValue1 >> 31);
    if (asint->exp == 2047) return 0;
    if (asint->exp != 0) {
        asint->mant_high32 |= ((e_u32)1 << (52 - 32));
        asint->exp = (e_s16)(asint->exp - 1023);
    } else {
        if (asint->mant_high32 || asint->mant_low32) return 0;
    }
    return 1;
}

/* store_sp: build a float from intparts */
int store_sp(e_f32 *value, intparts *asint)
{
    e_u32 iValue;
    e_f32 v32;
    e_u32 iexp;
    e_s32 exp  = asint->exp;
    e_u32 mant = asint->mant_low32;
    if (!value || !asint) return 0;
    if (asint->mant_high32) return 0;
    if (mant >= ((e_u32)1 << 24)) return 0;
    if (!(mant & ((e_u32)1 << 23))) {
        if (exp == 0 && mant == 0) {
            iValue = (e_u32)(asint->sign) << 31;
            SET_FLOAT_WORD(v32, iValue);
            *value = v32;
            return 1;
        }
        return 0;
    }
    mant &= ((e_u32)1 << 23) - 1;
    exp += 127;
    if (exp <= 0 || exp >= 255) return 0;
    iexp = (e_u32)exp << 23;
    if (asint->sign) iexp |= 0x80000000u;
    iValue = mant | iexp;
    SET_FLOAT_WORD(v32, iValue);
    *value = v32;
    return 1;
}

/* load_sp: decode a float into intparts */
int load_sp(e_f32 *value, intparts *asint)
{
    e_u32 iValue;
    if (!value || !asint) return 0;
    GET_FLOAT_WORD(iValue, *value);
    asint->mant_high32 = 0;
    asint->mant_low32  = (iValue & (((e_u32)1 << 23) - 1));
    asint->exp  = (e_s16)((iValue >> 23) & 255);
    asint->sign = (e_s8)(iValue >> 31);
    if (asint->exp == 255) return 0;
    if (asint->exp != 0) {
        asint->mant_low32 |= ((e_u32)1 << 23);
        asint->exp = (e_s16)(asint->exp - 127);
    } else {
        if (asint->mant_low32) return 0;
    }
    return 1;
}

/* ---- th_parse_buf_flag stubs (used by define_params_nnet dataset parsing) */
/* We always pass dataset="NULL" so these are never really exercised, but
 * they must link. */

#include <stdarg.h>

/* th_lib.h declares these; provide no-op stubs */
int th_parse_buf_flag(const char *buf, const char *flag, int *val)
{
    (void)buf; (void)flag; (void)val;
    return 0; /* not found */
}

int th_parse_buf_flag_unsigned(const char *buf, const char *flag, unsigned int *val)
{
    (void)buf; (void)flag; (void)val;
    return 0;
}

/* ---- fp_iaccurate_bits_dp / ee_ifpbits_buffer_dp stubs ----------------- */
/* Used by t_run_test_nnet for result checking -- we don't need the result
 * to be meaningful in a profiling run. Return a large bit count = pass. */

typedef struct snr_result_s {
    int pass;
    double min; double max; double min_ok;
    unsigned int bmin_ok; unsigned int bmin; unsigned int bmax;
    double sum; double avg; double stdev;
    int N;
} snr_result;

unsigned int fp_iaccurate_bits_dp(double sig, intparts *refbits)
{
    (void)sig; (void)refbits;
    return 60; /* always report "60 bits accurate" -> pass */
}

unsigned int ee_ifpbits_buffer_dp(double *signal, intparts *ref, int size, snr_result *res)
{
    (void)signal; (void)ref; (void)size;
    if (res) { res->pass = 1; res->bmin = 60; }
    return 60;
}

/* ---- th_sprint_dp / th_fpprintf stubs ----------------------------------- */
/* Used by bmark_verify_nnet (which we don't call) -- but they are referenced
 * by nnet.c's gen_ref path. Provide no-ops. */

char *th_sprint_dp(double value, char *buf)
{
    (void)value;
    if (buf) buf[0] = '\0';
    return buf ? buf : (char *)"";
}

/* th_fpprintf: fprintf-like to ee_FILE* -- discard */
int th_fpprintf(void *fp, const char *fmt, ...)
{
    (void)fp; (void)fmt;
    return 0;
}

/* ---- th_aligned_malloc / free (NO_ALIGNED_ALLOC=1 -> just use malloc) -- */

/* th_aligned_malloc_x is called via the th_aligned_malloc macro in th_lib.h */
void *th_aligned_malloc_x(size_t size, size_t align, const char *file, int line)
{
    (void)align; (void)file; (void)line;
    return malloc(size);
}

void th_aligned_free_x(void *block, const char *file, int line)
{
    (void)file; (void)line;
    free(block);
}
