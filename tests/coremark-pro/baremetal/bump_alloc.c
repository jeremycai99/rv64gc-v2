/*
 * bump_alloc.c — trivial bump allocator for bare-metal direct-kernel builds.
 *
 * Overrides newlib malloc/calloc/free/realloc (linked ahead of libc.a).
 * The radix2 direct-kernel main performs 3 long-lived allocations and no
 * frees; newlib's _malloc_r free-list scan degenerates in this bare-metal
 * heap setup (the prior radix2 "2.49 IPC" datapoint was 100% malloc-scan
 * loop, kernel never reached).  A bump allocator removes the harness
 * pathology without touching the benchmark kernel.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#define ARENA_BYTES (8u << 20)   /* 8 MB */
static uint64_t arena[ARENA_BYTES / 8];
static size_t   bump_off;

void *malloc(size_t n)
{
    size_t need = (n + 15u) & ~(size_t)15u;
    if (bump_off + need > sizeof(arena)) return NULL;
    void *p = (char *)arena + bump_off;
    bump_off += need;
    return p;
}

void *calloc(size_t nmemb, size_t size)
{
    size_t n = nmemb * size;
    void *p = malloc(n);
    if (p) memset(p, 0, n);
    return p;
}

void free(void *p) { (void)p; }

void *realloc(void *p, size_t n)
{
    /* grow-only: allocate fresh and copy n bytes (callers in the
       kernel-direct mains only grow). */
    void *q = malloc(n);
    if (q && p) memcpy(q, p, n);
    return q;
}
