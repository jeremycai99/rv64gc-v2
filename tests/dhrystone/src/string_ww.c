/* string_ww.c — word-wide (SWAR) string routines for the Dhrystone
 * word-wide variant.  Same vendor-libc-class methodology as the parser
 * string_opt.c: A76-class cores score Dhrystone with word-wide libc.
 * Fast path requires same 8B alignment of src/dst (true for Dhrystone's
 * global string arrays); falls back to byte loops otherwise. */
#include <stddef.h>
#include <stdint.h>
#define ONES  0x0101010101010101ULL
#define HIGHS 0x8080808080808080ULL
#define HASZERO(x) (((x) - ONES) & ~(x) & HIGHS)

char *strcpy(char *dst, const char *src) {
    char *d = dst;
    if ((((uintptr_t)d ^ (uintptr_t)src) & 7) == 0) {
        while (((uintptr_t)src & 7) && (*d++ = *src++) != '\0') ;
        if (((uintptr_t)src & 7) == 0 && (d == dst || d[-1] != '\0')) {
            uint64_t *dw = (uint64_t *)d;
            const uint64_t *sw = (const uint64_t *)src;
            uint64_t w;
            while (!HASZERO(w = *sw)) { *dw++ = w; sw++; }
            d = (char *)dw; src = (const char *)sw;
            while ((*d++ = *src++) != '\0') ;
        }
        return dst;
    }
    while ((*d++ = *src++) != '\0') ;
    return dst;
}

int strcmp(const char *s1, const char *s2) {
    if ((((uintptr_t)s1 ^ (uintptr_t)s2) & 7) == 0) {
        while (((uintptr_t)s1 & 7)) {
            if (*s1 == '\0' || *s1 != *s2)
                return *(unsigned char *)s1 - *(unsigned char *)s2;
            s1++; s2++;
        }
        const uint64_t *w1 = (const uint64_t *)s1, *w2 = (const uint64_t *)s2;
        while (*w1 == *w2 && !HASZERO(*w1)) { w1++; w2++; }
        s1 = (const char *)w1; s2 = (const char *)w2;
    }
    while (*s1 && (*s1 == *s2)) { s1++; s2++; }
    return *(unsigned char *)s1 - *(unsigned char *)s2;
}

void *memcpy(void *dst, const void *src, unsigned long n) {
    char *d = dst; const char *s = src;
    if ((((uintptr_t)d ^ (uintptr_t)s) & 7) == 0) {
        while (((uintptr_t)s & 7) && n) { *d++ = *s++; n--; }
        uint64_t *dw = (uint64_t *)d; const uint64_t *sw = (const uint64_t *)s;
        while (n >= 8) { *dw++ = *sw++; n -= 8; }
        d = (char *)dw; s = (const char *)sw;
    }
    while (n--) *d++ = *s++;
    return dst;
}
