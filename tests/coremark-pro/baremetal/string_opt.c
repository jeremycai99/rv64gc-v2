/*
 * string_opt.c — optimized string-scan routines for the bare-metal CoreMark-PRO
 * builds (rv64).
 *
 * Replaces newlib's byte-at-a-time O(n*m) strcspn/strspn and byte-at-a-time
 * strchr with word-at-a-time (SWAR) / bitmap implementations, the same
 * algorithm class shipped by musl and vendor libcs.  Linked as an object
 * ahead of libc.a, so these definitions override the archive members.
 * This is a LIBRARY replacement (fair-methodology fix) — no benchmark source
 * is modified.
 *
 * The XML parser kernel (ezxml) spends ~all of its parse phase in
 * strcspn/strspn over a 125 KB buffer; newlib's nested-loop versions cost
 * ~10-15 instructions/byte.  SWAR brings the common small-reject-set case to
 * ~1.5-2 instructions/byte.
 */

#include <stddef.h>
#include <stdint.h>

#define ONES  0x0101010101010101ULL
#define HIGHS 0x8080808080808080ULL
/* True if any byte of x is zero (classic SWAR zero-byte detector). */
#define HASZERO(x) (((x) - ONES) & ~(x) & HIGHS)

/* Broadcast a byte across a 64-bit word. */
static inline uint64_t bcast(unsigned char c) { return ONES * (uint64_t)c; }

/* 256-bit membership bitmap for arbitrary char sets. */
typedef struct { uint64_t w[4]; } byteset_t;

static inline void byteset_build(byteset_t *bs, const char *set)
{
    bs->w[0] = bs->w[1] = bs->w[2] = bs->w[3] = 0;
    for (const unsigned char *p = (const unsigned char *)set; *p; p++)
        bs->w[*p >> 6] |= 1ULL << (*p & 63);
}

static inline int byteset_has(const byteset_t *bs, unsigned char c)
{
    return (int)((bs->w[c >> 6] >> (c & 63)) & 1);
}

size_t strcspn(const char *s, const char *reject)
{
    const char *a = s;

    if (!reject[0])
        { while (*s) s++; return (size_t)(s - a); }

    if (!reject[1]) {
        /* Single reject char: SWAR scan for '\0' or c. */
        uint64_t k = bcast((unsigned char)reject[0]);
        while ((uintptr_t)s & 7) {
            if (!*s || *(const unsigned char *)s == (unsigned char)reject[0])
                return (size_t)(s - a);
            s++;
        }
        const uint64_t *w = (const uint64_t *)s;
        for (;;) {
            uint64_t x = *w;
            if (HASZERO(x) || HASZERO(x ^ k)) break;
            w++;
        }
        s = (const char *)w;
        while (*s && *(const unsigned char *)s != (unsigned char)reject[0]) s++;
        return (size_t)(s - a);
    }

    if (!reject[2]) {
        /* Two reject chars (the ezxml content scan: '<' '%'): SWAR. */
        uint64_t k1 = bcast((unsigned char)reject[0]);
        uint64_t k2 = bcast((unsigned char)reject[1]);
        while ((uintptr_t)s & 7) {
            unsigned char c = *(const unsigned char *)s;
            if (!c || c == (unsigned char)reject[0] ||
                       c == (unsigned char)reject[1])
                return (size_t)(s - a);
            s++;
        }
        const uint64_t *w = (const uint64_t *)s;
        for (;;) {
            uint64_t x = *w;
            if (HASZERO(x) || HASZERO(x ^ k1) || HASZERO(x ^ k2)) break;
            w++;
        }
        s = (const char *)w;
        for (;;) {
            unsigned char c = *(const unsigned char *)s;
            if (!c || c == (unsigned char)reject[0] ||
                       c == (unsigned char)reject[1])
                return (size_t)(s - a);
            s++;
        }
    }

    /* General case: 256-bit bitmap, O(n + m). */
    {
        byteset_t bs;
        byteset_build(&bs, reject);
        while (*s && !byteset_has(&bs, *(const unsigned char *)s)) s++;
        return (size_t)(s - a);
    }
}

size_t strspn(const char *s, const char *accept)
{
    const char *a = s;

    if (!accept[0]) return 0;

    if (!accept[1]) {
        /* Single accept char: SWAR "all bytes equal c" run scan. */
        uint64_t k = bcast((unsigned char)accept[0]);
        while ((uintptr_t)s & 7) {
            if (*(const unsigned char *)s != (unsigned char)accept[0])
                return (size_t)(s - a);
            s++;
        }
        const uint64_t *w = (const uint64_t *)s;
        while (!HASZERO(*w ^ k)) w++;   /* stops when any byte != c (or 0) */
        s = (const char *)w;
        while (*(const unsigned char *)s == (unsigned char)accept[0]) s++;
        return (size_t)(s - a);
    }

    /* General case: 256-bit bitmap (covers EZXML_WS " \t\r\n"), O(n + m). */
    {
        byteset_t bs;
        byteset_build(&bs, accept);
        while (*s && byteset_has(&bs, *(const unsigned char *)s)) s++;
        return (size_t)(s - a);
    }
}

char *strchr(const char *s, int c_in)
{
    unsigned char c = (unsigned char)c_in;

    if (!c) {
        while (*s) s++;
        return (char *)s;
    }

    while ((uintptr_t)s & 7) {
        if (*(const unsigned char *)s == c) return (char *)s;
        if (!*s) return NULL;
        s++;
    }
    {
        uint64_t k = bcast(c);
        const uint64_t *w = (const uint64_t *)s;
        for (;;) {
            uint64_t x = *w;
            if (HASZERO(x) || HASZERO(x ^ k)) break;
            w++;
        }
        s = (const char *)w;
    }
    for (;; s++) {
        if (*(const unsigned char *)s == c) return (char *)s;
        if (!*s) return NULL;
    }
}
