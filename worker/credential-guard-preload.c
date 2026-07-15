#define _GNU_SOURCE

#include <stdlib.h>
#include <sys/prctl.h>
#include <unistd.h>

__attribute__((constructor)) static void protect_process_environment(void) {
    if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) == -1) {
        _exit(70);
    }
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1) {
        _exit(70);
    }
}
