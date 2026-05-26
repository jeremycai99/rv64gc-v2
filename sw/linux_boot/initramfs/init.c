#define _GNU_SOURCE

#include <fcntl.h>
#include <sys/stat.h>
#include <sys/sysmacros.h>
#include <unistd.h>

int main(void) {
    static const char msg[] = "\nBOOT OK\n";
    int console_fd;

    (void)mkdir("/dev", 0755);
    (void)mknod("/dev/console", S_IFCHR | 0600, makedev(5, 1));

    console_fd = open("/dev/console", O_WRONLY | O_NOCTTY);
    if (console_fd >= 0) {
        (void)write(console_fd, msg, sizeof(msg) - 1);
    } else {
        (void)write(STDOUT_FILENO, msg, sizeof(msg) - 1);
    }

    for (;;) {
        __asm__ volatile("" ::: "memory");
    }

    return 0;
}
