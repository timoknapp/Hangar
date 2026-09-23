/* Fixed privilege-drop entry point. Installed root-owned, NOT setuid; only the
 * publisher may invoke it via sudo. No caller-selected identity or executable.
 * All authority is removed before any shell, repository code or CLI starts. */
#define _GNU_SOURCE
#include <errno.h>
#include <grp.h>
#include <linux/capability.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/syscall.h>
#include <unistd.h>

static void die(const char *phase) {
    fprintf(stderr, "agent-launch: %s: %s\n", phase, strerror(errno));
    exit(125);
}

int main(int argc, char **argv) {
    if (argc < 3 || (strcmp(argv[1], "command") && strcmp(argv[1], "copilot")) ||
        (!strcmp(argv[1], "command") && argc != 3)) {
        fputs("usage: agent-launch command TEXT | copilot ARG...\n", stderr);
        return 125;
    }
    if (geteuid() != 0) { errno = EPERM; die("requires publisher sudo"); }
    struct passwd *pw = getpwnam("squad-agent");
    if (!pw || pw->pw_uid == 0 || pw->pw_gid == 0) { errno = EINVAL; die("coding identity"); }
    uid_t uid = pw->pw_uid;
    gid_t gid = pw->pw_gid;
    char *cwd = getcwd(NULL, 0);
    if (!cwd) die("working directory");
    if (clearenv()) die("clearenv");
    /* Do not inherit publisher sockets, files, or agent configuration. stdin is
     * reserved for the existing credential-guard pipe (command mode gets /dev/null). */
    if (close_range(3, ~0U, 0)) die("close_range");
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0)) die("no-new-privileges");
    if (prctl(PR_CAP_AMBIENT, PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0)) die("ambient capabilities");
    /* Dropping the bounding set requires CAP_SETPCAP, so do this BEFORE setuid.
     * Discover the kernel's capability range rather than assuming header age. */
    int cap;
    for (cap = 0; ; cap++) {
        int present = prctl(PR_CAPBSET_READ, cap, 0, 0, 0);
        if (present < 0 && errno == EINVAL) break;
        if (present < 0 || prctl(PR_CAPBSET_DROP, cap, 0, 0, 0)) die("bounding capabilities");
    }
    if (setgroups(0, NULL) || setresgid(gid, gid, gid) || setresuid(uid, uid, uid)) die("identity drop");
    struct __user_cap_header_struct header = { .version = _LINUX_CAPABILITY_VERSION_3, .pid = 0 };
    struct __user_cap_data_struct caps[2] = {{0}, {0}};
    if (syscall(SYS_capset, &header, caps)) die("clear capabilities");
    if (syscall(SYS_capget, &header, caps)) die("read capabilities");
    if (caps[0].effective || caps[0].permitted || caps[0].inheritable ||
        caps[1].effective || caps[1].permitted || caps[1].inheritable ||
        getuid() != uid || geteuid() != uid || getgid() != gid || getegid() != gid ||
        getgroups(0, NULL) != 0 || prctl(PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0) != 1) {
        errno = EPERM; die("verify isolation");
    }
    for (int i = 0; i < cap; i++) {
        if (prctl(PR_CAPBSET_READ, i, 0, 0, 0) != 0) { errno = EPERM; die("verify bounding set"); }
    }
    /* An inherited cwd is itself a directory capability. Require absolute
     * traversal to still succeed after dropping all authority. */
    if (chdir(cwd)) die("unprivileged working directory");
    free(cwd);
    if (prctl(PR_SET_DUMPABLE, 0, 0, 0, 0)) die("dumpability");
    const char *env[][2] = {
        {"HOME", "/home/squad-agent"}, {"USER", "squad-agent"}, {"LOGNAME", "squad-agent"},
        {"PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"},
        {"LANG", "C.UTF-8"}, {"LC_ALL", "C.UTF-8"}, {"CI", "true"},
        {"NO_COLOR", "1"}, {"NPM_CONFIG_CACHE", "/home/squad-agent/.npm"},
        /* Prompt mode otherwise abandons still-running background agents after
         * 600s and exits "successfully" without their work. The publisher's
         * task-deadline timeout remains the authoritative upper bound. */
        {"COPILOT_TASK_WAIT_TIMEOUT_SECONDS", "86400"}
    };
    for (size_t i = 0; i < sizeof(env) / sizeof(env[0]); i++) {
        if (setenv(env[i][0], env[i][1], 1)) die("environment");
    }
    if (!strcmp(argv[1], "command")) {
        if (!freopen("/dev/null", "r", stdin)) die("command stdin");
        fputs("HANGAR_AGENT_STARTED\n", stderr);
        fflush(stderr);
        execl("/usr/bin/bash", "bash", "--noprofile", "--norc", "-c", argv[2], (char *)NULL);
    } else {
        /* Preserve token-on-stdin and the non-dumpable preload guard. */
        argv[1] = "/usr/local/bin/credential-guard";
        char **args = calloc((size_t)argc + 1, sizeof(char *));
        if (!args) die("arguments");
        args[0] = argv[1];
        args[1] = "copilot";
        /* credential-guard resolves the CLI only through our fixed system PATH. */
        for (int i = 2; i < argc; i++) args[i] = argv[i];
        execv(args[0], args);
    }
    die("exec");
}
