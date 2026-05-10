#define _GNU_SOURCE

#include <unistd.h>

int main(void) {
    static const char msg[] = "\nBOOT OK\n";
    (void)write(STDOUT_FILENO, msg, sizeof(msg) - 1);

    for (;;) {
        __asm__ volatile("" ::: "memory");
    }

    return 0;
}
