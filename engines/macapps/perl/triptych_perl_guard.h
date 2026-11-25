/* SPDX-License-Identifier: GPL-3.0-or-later
 * Force-included (-include) into every libperl and core XS object built for iOS by scripts/build-perl-ios.sh.
 * Perl runs inside Triptych (app/MacAppsKit/PerlCommand.c), so its process calls must never act on the app:
 * fork and exec fail (Triptych::Process runs commands through MacProcessShim instead), waitpid reaches the
 * shim's virtual children, exit ends only the command's thread, and signals, alarms and kill stay local.
 * The system headers are included first so their declarations (some carry __asm labels) keep their names;
 * the macros below only rename the call sites. The functions are defined in PerlCommand.c. */
#ifndef TRIPTYCH_PERL_GUARD_H
#define TRIPTYCH_PERL_GUARD_H

#include <signal.h>
#include <stdlib.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

pid_t triptych_perl_fork(void);
int triptych_perl_execv(const char *path, char *const argv[]);
int triptych_perl_execvp(const char *file, char *const argv[]);
int triptych_perl_execl(const char *path, const char *arg0, ...);
pid_t triptych_perl_waitpid(pid_t pid, int *status, int options);
int triptych_perl_kill(pid_t pid, int sig);
void triptych_perl_exit(int status) __attribute__((noreturn));
unsigned int triptych_perl_alarm(unsigned int seconds);
int triptych_perl_setitimer(int which, const struct itimerval *value, struct itimerval *old);
int triptych_perl_sigaction(int sig, const struct sigaction *act, struct sigaction *old);
void (*triptych_perl_signal(int sig, void (*handler)(int)))(int);
pid_t triptych_perl_setsid(void);
int triptych_perl_setpgid(pid_t pid, pid_t pgid);

#define fork() triptych_perl_fork()
#define execv(p, a) triptych_perl_execv(p, a)
#define execvp(f, a) triptych_perl_execvp(f, a)
#define execl(...) triptych_perl_execl(__VA_ARGS__)
#define waitpid(p, s, o) triptych_perl_waitpid(p, s, o)
#define kill(p, s) triptych_perl_kill(p, s)
#define exit(s) triptych_perl_exit(s)
#define _exit(s) triptych_perl_exit(s)
#define alarm(s) triptych_perl_alarm(s)
#define setitimer(w, v, o) triptych_perl_setitimer(w, v, o)
#define sigaction(s, a, o) triptych_perl_sigaction(s, a, o)
#define signal(s, h) triptych_perl_signal(s, h)
#define setsid() triptych_perl_setsid()
#define setpgid(p, g) triptych_perl_setpgid(p, g)

#endif
