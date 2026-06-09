/*
 * Bare-metal newlib syscall stubs for CoreMark-PRO on rv64gc-v2.
 *
 * newlib calls these when malloc/printf/etc need OS services.
 * We provide: _sbrk (bump allocator), _write (discard to stdout/stderr),
 * and no-op stubs for everything else.
 */

#include <sys/types.h>
#include <sys/stat.h>
#include <errno.h>

/* Heap boundaries from link.ld */
extern char __heap_start[];
extern char __heap_end[];

/* _sbrk: bump allocator */
void *_sbrk(ptrdiff_t incr) {
    static char *heap_ptr = 0;
    char *prev;

    if (heap_ptr == 0)
        heap_ptr = __heap_start;

    prev = heap_ptr;
    if (heap_ptr + incr > __heap_end) {
        errno = ENOMEM;
        return (void *)-1;
    }
    heap_ptr += incr;
    return (void *)prev;
}

/* _write: discard all output (no UART) */
int _write(int fd, const char *buf, int len) {
    (void)fd; (void)buf;
    return len;
}

/* _read: not supported */
int _read(int fd, char *buf, int len) {
    (void)fd; (void)buf; (void)len;
    return -1;
}

/* _close */
int _close(int fd) {
    (void)fd;
    return -1;
}

/* _fstat: minimal stub */
int _fstat(int fd, struct stat *st) {
    (void)fd;
    st->st_mode = S_IFCHR;
    return 0;
}

/* _lseek */
off_t _lseek(int fd, off_t offset, int whence) {
    (void)fd; (void)offset; (void)whence;
    return -1;
}

/* _isatty */
int _isatty(int fd) {
    (void)fd;
    return 1;
}

/* _exit */
void _exit(int status) {
    volatile unsigned long *tohost = (volatile unsigned long *)0x80001000UL;
    if (status == 0)
        *tohost = 1UL;
    else
        *tohost = (unsigned long)((status << 1) | 1);
    while (1) {}
}

/* _kill / _getpid */
int _kill(int pid, int sig) {
    (void)pid; (void)sig;
    return -1;
}

int _getpid(void) {
    return 1;
}

/* _open / _openat */
int _open(const char *path, int flags, ...) {
    (void)path; (void)flags;
    return -1;
}
