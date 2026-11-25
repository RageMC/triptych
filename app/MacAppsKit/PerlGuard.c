// SPDX-License-Identifier: GPL-3.0-or-later
// libperl's process calls inside Triptych (engines/macapps/perl/triptych_perl_guard.h renames them in every
// libperl object). Perl runs on shim command threads in the app's own process, so these must never act on the
// app: no fork or exec (Triptych::Process starts commands through MacProcessShim), exit ends only the command,
// and kill, signal handlers, alarms and sessions stay inside the script.
#include "MacProcessShim.h"

#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

int PerlCommandErrorFd(void);  // PerlCommand.c: the running command's stderr

static void refuse(const char *what, const char *detail) {
    char msg[1200];
    int n = snprintf(msg, sizeof msg, "Triptych Perl: %s%s%s refused (commands run through Triptych::Process)\n",
                     what, detail ? " " : "", detail ? detail : "");
    int fd = PerlCommandErrorFd();
    if (n > 0) (void)!write(fd >= 0 ? fd : STDERR_FILENO, msg, (size_t)n < sizeof msg ? (size_t)n : sizeof msg - 1);
}

pid_t triptych_perl_fork(void) {
    refuse("fork", NULL);
    errno = ENOSYS;
    return -1;
}

int triptych_perl_execv(const char *path, char *const argv[]) {
    (void)argv;
    refuse("exec", path);
    errno = ENOSYS;
    return -1;
}

int triptych_perl_execvp(const char *file, char *const argv[]) {
    return triptych_perl_execv(file, argv);
}

int triptych_perl_execl(const char *path, const char *arg0, ...) {
    (void)arg0;
    return triptych_perl_execv(path, NULL);
}

pid_t triptych_perl_waitpid(pid_t pid, int *status, int options) {
    return MacShim_waitpid(pid, status, options);
}

// Shim children can't be signalled (they are threads); report them as signalled, refuse everything else.
int triptych_perl_kill(pid_t pid, int sig) {
    if (pid > 0 && MacProcessShimIsChild(pid)) return 0;
    if (sig == 0 && pid == getpid()) return 0;
    errno = EPERM;
    return -1;
}

void triptych_perl_exit(int status) {
    MacProcessShimExitCommand(status);
    // Not on a shim command thread (a test calling Perl directly): end only this thread.
    if (!pthread_main_np()) pthread_exit(NULL);
    fprintf(stderr, "Triptych Perl: exit(%d) on the main thread ignored\n", status);
    abort();
}

unsigned int triptych_perl_alarm(unsigned int seconds) {
    (void)seconds;
    return 0;
}

int triptych_perl_setitimer(int which, const struct itimerval *value, struct itimerval *old) {
    (void)which;
    (void)value;
    if (old) memset(old, 0, sizeof *old);
    return 0;
}

// %SIG handlers would be process-wide: keep them unset (the app's handlers stay as they are).
int triptych_perl_sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
    (void)sig;
    (void)act;
    if (old) {
        memset(old, 0, sizeof *old);
        old->sa_handler = SIG_DFL;
    }
    return 0;
}

void (*triptych_perl_signal(int sig, void (*handler)(int)))(int) {
    (void)sig;
    (void)handler;
    return SIG_DFL;
}

pid_t triptych_perl_setsid(void) {
    return getpid();
}

int triptych_perl_setpgid(pid_t pid, pid_t pgid) {
    (void)pid;
    (void)pgid;
    return 0;
}
