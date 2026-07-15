#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <unistd.h>

#define TOKEN_MAX 8192

static void wipe(void *buffer, size_t length) {
    volatile unsigned char *cursor = buffer;
    while (length-- > 0) {
        *cursor++ = 0;
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fputs("usage: credential-guard PROGRAM [ARG...] < token\n", stderr);
        return 64;
    }

    if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0) == -1) {
        fprintf(stderr, "credential-guard: PR_SET_DUMPABLE failed: %s\n", strerror(errno));
        return 70;
    }

    char token[TOKEN_MAX + 1];
    size_t length = 0;
    while (length < TOKEN_MAX) {
        ssize_t count = read(STDIN_FILENO, token + length, TOKEN_MAX - length);
        if (count == 0) {
            break;
        }
        if (count < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr, "credential-guard: token read failed: %s\n", strerror(errno));
            wipe(token, sizeof(token));
            return 70;
        }
        length += (size_t)count;
    }

    if (length == TOKEN_MAX) {
        char extra;
        ssize_t count;
        do {
            count = read(STDIN_FILENO, &extra, 1);
        } while (count < 0 && errno == EINTR);
        if (count > 0) {
            fputs("credential-guard: token exceeds maximum length\n", stderr);
            wipe(token, sizeof(token));
            return 70;
        }
    }

    while (length > 0 && (token[length - 1] == '\n' || token[length - 1] == '\r')) {
        length--;
    }
    if (length == 0 || memchr(token, '\0', length) != NULL) {
        fputs("credential-guard: token is empty or invalid\n", stderr);
        wipe(token, sizeof(token));
        return 70;
    }
    token[length] = '\0';

    unsetenv("GITHUB_TOKEN");
    unsetenv("GH_TOKEN");
    unsetenv("COPILOT_PAT");
    if (setenv("COPILOT_GITHUB_TOKEN", token, 1) == -1) {
        fprintf(stderr, "credential-guard: setenv failed: %s\n", strerror(errno));
        wipe(token, sizeof(token));
        return 70;
    }
    wipe(token, sizeof(token));

    if (setenv("LD_PRELOAD", "/usr/local/lib/libcredential-guard.so", 1) == -1) {
        fprintf(stderr, "credential-guard: LD_PRELOAD setup failed: %s\n", strerror(errno));
        return 70;
    }

    int null_fd = open("/dev/null", O_RDONLY);
    if (null_fd == -1 || dup2(null_fd, STDIN_FILENO) == -1) {
        fprintf(stderr, "credential-guard: stdin reset failed: %s\n", strerror(errno));
        if (null_fd != -1) {
            close(null_fd);
        }
        return 70;
    }
    if (null_fd != STDIN_FILENO) {
        close(null_fd);
    }

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) == -1) {
        fprintf(stderr, "credential-guard: PR_SET_NO_NEW_PRIVS failed: %s\n", strerror(errno));
        return 70;
    }

    execvp(argv[1], &argv[1]);
    fprintf(stderr, "credential-guard: execvp failed: %s\n", strerror(errno));
    return 71;
}
