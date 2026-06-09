/*
 * al_port.c — bare-metal adaptation layer for rv64gc-v2 CoreMark-PRO port.
 *
 * Replaces mith/al/src/th_al.c for the bare-metal target.
 * Key things we override:
 *   - al_signal_start/finished/now: use rdcycle CSR
 *   - al_ticks_per_sec: return a fixed assumed clock (cycles, not seconds)
 *   - al_write_con / al_printf: discard (no UART)
 *   - al_exit: write tohost and halt
 *   - redirect_std_files: no-op
 *   - store_dp/load_dp/store_sp/load_sp: implement from fp_shape.h logic
 *     (needed for FP kernel SNR verification)
 */

#include "th_cfg.h"
#include <stdarg.h>
#include <string.h>
#include <stdio.h>
#define FILE_TYPE_DEFINED
#include "th_file.h"
#include "th_types.h"
#include "th_lib.h"
#include "th_al.h"
#include "al_smp.h"

/* ---- Timing (rdcycle) --------------------------------------------------- */

static unsigned long read_mcycle(void) {
    unsigned long c;
    __asm__ volatile("csrr %0, mcycle" : "=r"(c));
    return c;
}

static unsigned long g_start_cycle = 0;

void al_signal_start(void) {
    g_start_cycle = read_mcycle();
}

size_t al_signal_finished(void) {
    unsigned long now = read_mcycle();
    return (size_t)(now - g_start_cycle);
}

size_t al_signal_now(void) {
    unsigned long now = read_mcycle();
    return (size_t)(now - g_start_cycle);
}

/* Report cycles (1 "tick" per cycle; caller treats this as arbitrary units) */
size_t al_ticks_per_sec(void) {
    return 100000000UL; /* assume 100 MHz nominal (value is informational only) */
}

size_t al_tick_granularity(void) {
    return 1;
}

/* ---- Console output (discard) ------------------------------------------- */

#if USE_TH_PRINTF
int al_write_con(const char *tx_buf, size_t byte_count) {
    (void)tx_buf; (void)byte_count;
    return 0;
}
#endif

int al_printf(const char *fmt, va_list args) {
    (void)fmt; (void)args;
    return 0;
}

int al_sprintf(char *str, const char *fmt, va_list args) {
    return vsprintf(str, fmt, args);
}

void al_report_results(void) {}

/* ---- System ---------------------------------------------------------------- */

void al_hardware_reset(int ev) {
    (void)ev;
}

void al_exit(int exit_code) {
    volatile unsigned long *tohost = (volatile unsigned long *)0x80001000UL;
    if (exit_code == 0)
        *tohost = 1UL;
    else
        *tohost = (unsigned long)((exit_code << 1) | 1);
    while (1) {}
}

char *al_getenv(const char *key) {
    (void)key;
    return NULL;
}

/* ---- al_main ------------------------------------------------------------- */
/* redirect_std_files is defined in th_lib.c (maps to stdin/stdout/stderr)   */

void al_main(int argc, char *argv[]) {
    extern void redirect_std_files(void);
    (void)argc; (void)argv;
    redirect_std_files();
}

/* ---- File I/O (stubs — FAKE_FILEIO=1 handles the real bodies) ------------ */

int al_vsscanf(const char *str, const char *format, va_list ap) {
    /* simple up-to-7-arg wrapper using sscanf */
#define VSSF_MAX 7
    void *arg[VSSF_MAX];
    int numargs = 0, i;
    const char *p = format;
    while (*p) {
        if (p[0] == '%') {
            if (p[1] == '*' || p[1] == '%') p++;
            else numargs++;
        }
        p++;
    }
    if (numargs > VSSF_MAX) return 0;
    for (i = 0; i < numargs; i++) arg[i] = va_arg(ap, void *);
    switch (numargs) {
        case 0: return sscanf(str, format);
        case 1: return sscanf(str, format, arg[0]);
        case 2: return sscanf(str, format, arg[0], arg[1]);
        case 3: return sscanf(str, format, arg[0], arg[1], arg[2]);
        case 4: return sscanf(str, format, arg[0], arg[1], arg[2], arg[3]);
        case 5: return sscanf(str, format, arg[0], arg[1], arg[2], arg[3], arg[4]);
        case 6: return sscanf(str, format, arg[0], arg[1], arg[2], arg[3], arg[4], arg[5]);
        case 7: return sscanf(str, format, arg[0], arg[1], arg[2], arg[3], arg[4], arg[5], arg[6]);
        default: return 0;
    }
}

int al_vfscanf(ee_FILE *stream, const char *format, va_list ap) {
    (void)stream; (void)format; (void)ap;
    return 0;
}

int al_filecmp(const char *f1, const char *f2) {
    return f1 == f2;
}

size_t al_fsize(const char *filename) {
    (void)filename;
    return 0;
}

void *al_fcreate(const char *filename, const char *mode, char *data, size_t size) {
    (void)filename; (void)mode; (void)data; (void)size;
    return NULL;
}

/* al_unlink is defined in al_file.c (FAKE_FILEIO path) */

/* ---- FP kernel support (store/load dp/sp from intparts) ----------------- */
/* These are needed for FP SNR verification. Copied from th_al.c HOST path  */

#if FP_KERNELS_SUPPORT

#include "fp_shape.h"

int store_dp(e_f64 *value, intparts *asint) {
    e_f64 v64;
    e_u32 iexp;
    e_s32 exp = asint->exp;
    e_u32 manthigh = asint->mant_high32;

    if (manthigh >= ((e_u32)1 << (52-32 + 1)))
        return 0;
    if (!(manthigh & ((e_u32)1 << (52-32)))) {
        if (exp == 0 && asint->mant_low32 == 0 && manthigh == 0) {
            INSERT_WORDS(v64, (e_u32)(asint->sign) << 31, 0);
            *value = v64;
            return 1;
        }
        return 0;
    }
    manthigh &= ((e_u32)1 << (52-32)) - 1;
    exp += 1023;
    if (exp <= 0 || exp >= 2047) return 0;
    iexp = exp << (52-32);
    if (asint->sign) iexp |= 0x80000000;
    INSERT_WORDS(v64, (manthigh | iexp), asint->mant_low32);
    *value = v64;
    return 1;
}

int load_dp(e_f64 *value, intparts *asint) {
    e_u32 iValue0, iValue1;
    if (!value || !asint) return 0;
    EXTRACT_WORDS(iValue1, iValue0, *value);
    asint->mant_low32 = iValue0;
    asint->mant_high32 = (iValue1 & (((e_u32)1 << (52-32)) - 1));
    asint->exp = ((iValue1 >> (52-32)) & 2047);
    asint->sign = iValue1 >> 31;
    if (asint->exp == 2047) return 0;
    if (asint->exp != 0) {
        asint->mant_high32 |= ((e_u32)1 << (52-32));
        asint->exp -= 1023;
    } else {
        if (asint->mant_high32 || asint->mant_low32) return 0;
    }
    return 1;
}

int store_sp(e_f32 *value, intparts *asint) {
    e_u32 iValue;
    e_f32 v32;
    e_u32 iexp;
    e_s32 exp = asint->exp;
    e_u32 mant = asint->mant_low32;

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
    iexp = exp << 23;
    if (asint->sign) iexp |= 0x80000000;
    iValue = mant | iexp;
    SET_FLOAT_WORD(v32, iValue);
    *value = v32;
    return 1;
}

int load_sp(e_f32 *value, intparts *asint) {
    e_u32 iValue;
    if (!value || !asint) return 0;
    GET_FLOAT_WORD(iValue, *value);
    asint->mant_high32 = 0;
    asint->mant_low32 = (iValue & (((e_u32)1 << 23) - 1));
    asint->exp = ((iValue >> 23) & 255);
    if (asint->exp == 255) return 0;
    if (asint->exp != 0) {
        asint->mant_low32 |= ((e_u32)1 << 23);
        asint->exp -= 127;
    } else {
        if (asint->mant_low32) return 0;
    }
    asint->sign = iValue >> 31;
    return 1;
}

#endif /* FP_KERNELS_SUPPORT */
