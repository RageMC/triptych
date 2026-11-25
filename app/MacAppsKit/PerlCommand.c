// SPDX-License-Identifier: GPL-3.0-or-later
// In-process Perl runtime for MacProcessShim (see PerlCommand.h). Perl is built with ithreads and multiplicity:
// every command gets its own interpreter on its own thread, so a script can run another script (CrossOver's
// `wine` wrapper is one) while it waits for it. A root interpreter that never runs code is created first:
// Perl lets only that one change the app's real environment, so scripts' %ENV stays their own.
// Compiled with Perl's embedding flags (project.yml); they must match libtriptychperl.a's.
#include "PerlCommand.h"
#include "MacProcessShim.h"

#include <EXTERN.h>
#include <perl.h>
#include <XSUB.h>

#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <string.h>

extern void triptych_perl_xs_init(pTHX);

static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static PerlInterpreter *g_root;
static char g_lib[PATH_MAX];
static _Thread_local int t_fds[3] = {-1, -1, -1};

void PerlCommandSetLibraryPath(const char *dir) {
    pthread_mutex_lock(&g_lock);
    if (dir) strlcpy(g_lib, dir, sizeof g_lib);
    else g_lib[0] = 0;
    pthread_mutex_unlock(&g_lock);
}

int PerlCommandErrorFd(void);
int PerlCommandErrorFd(void) {
    return t_fds[2];
}

static void library_path(char *out, size_t size) {
    pthread_mutex_lock(&g_lock);
    strlcpy(out, g_lib, size);
    pthread_mutex_unlock(&g_lock);
    if (*out) return;
    char exe[PATH_MAX];
    uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n) != 0) exe[0] = 0;
    char *slash = strrchr(exe, '/');
    if (slash) *slash = 0;
    snprintf(out, size, "%s/perl-lib", exe);
}

static void perl_init_once(void) {
    int argc = 1;
    char *argv_buf[] = {"perl", NULL};
    char *env_buf[] = {NULL};
    char **argv = argv_buf, **env = env_buf;
    PERL_SYS_INIT3(&argc, &argv, &env);
    g_root = perl_alloc();
    perl_construct(g_root);
    PERL_SET_CONTEXT(NULL);
}

// MARK: - Triptych::Process XS

// (in, out, err): the command's standard FDs, which Triptych::Process makes STDIN/STDOUT/STDERR.
static XSPROTO(XS_std_fds) {
    dXSARGS;
    PERL_UNUSED_VAR(items);
    EXTEND(SP, 3);
    for (int i = 0; i < 3; i++) ST(i) = sv_2mortal(newSViv(t_fds[i]));
    XSRETURN(3);
}

// _spawn(path, [argv], in, out, err): pid of a shim child running with the current %ENV, or undef and $!.
static XSPROTO(XS_spawn) {
    dXSARGS;
    if (items != 5 || !SvROK(ST(1)) || SvTYPE(SvRV(ST(1))) != SVt_PVAV)
        croak_xs_usage(cv, "path, argv, in, out, err");
    const char *path = SvPV_nolen(ST(0));
    AV *av = (AV *)SvRV(ST(1));
    SSize_t argc = av_count(av);
    char **argv = (char **)safecalloc((size_t)argc + 1, sizeof(char *));
    for (SSize_t i = 0; i < argc; i++) {
        SV **e = av_fetch(av, i, 0);
        argv[i] = savepv(e ? SvPV_nolen(*e) : "");
    }
    HV *env = GvHVn(PL_envgv);
    I32 envc = 0;
    hv_iterinit(env);
    while (hv_iternext(env)) envc++;
    char **envp = (char **)safecalloc((size_t)envc + 1, sizeof(char *));
    I32 k = 0;
    HE *he;
    hv_iterinit(env);
    while ((he = hv_iternext(env)) && k < envc) {
        I32 klen;
        const char *key = hv_iterkey(he, &klen);
        STRLEN vlen;
        const char *val = SvPV(hv_iterval(env, he), vlen);
        char *kv = (char *)safemalloc((size_t)klen + vlen + 2);
        memcpy(kv, key, (size_t)klen);
        kv[klen] = '=';
        memcpy(kv + klen + 1, val, vlen);
        kv[klen + 1 + vlen] = 0;
        envp[k++] = kv;
    }
    pid_t pid = 0;
    int err = MacProcessShimSpawn(&pid, path, argv, envp, (int)SvIV(ST(2)), (int)SvIV(ST(3)), (int)SvIV(ST(4)));
    for (SSize_t i = 0; i < argc; i++) Safefree(argv[i]);
    Safefree(argv);
    for (I32 i = 0; i < k; i++) Safefree(envp[i]);
    Safefree(envp);
    if (err) {
        errno = err;
        SETERRNO(err, 0);
        ST(0) = &PL_sv_undef;
    } else {
        ST(0) = sv_2mortal(newSViv(pid));
    }
    XSRETURN(1);
}

// _exec_exit(status): the end of an emulated exec: leave without END blocks, like a replaced process.
static XSPROTO(XS_exec_exit) {
    dXSARGS;
    if (items != 1) croak_xs_usage(cv, "status");
    int status = (int)SvIV(ST(0));
    if (PL_endav) av_clear(PL_endav);
    my_exit((U32)(status & 0xFF));
    XSRETURN_EMPTY;
}

static void command_xs_init(pTHX) {
    triptych_perl_xs_init(aTHX);
    newXS("Triptych::Process::_std_fds", XS_std_fds, __FILE__);
    newXS("Triptych::Process::_spawn", XS_spawn, __FILE__);
    newXS("Triptych::Process::_exec_exit", XS_exec_exit, __FILE__);
}

// MARK: - Interpreter per command

static int run_perl(char **pargv, int pargc, char *const envp[], int inFd, int outFd, int errFd) {
    pthread_once(&g_once, perl_init_once);
    int saved[3] = {t_fds[0], t_fds[1], t_fds[2]};
    t_fds[0] = inFd;
    t_fds[1] = outFd;
    t_fds[2] = errFd;
    extern char **environ;
    PerlInterpreter *my_perl = perl_alloc();
    PERL_SET_CONTEXT(my_perl);
    perl_construct(my_perl);
    PL_perl_destruct_level = 1;
    PL_exit_flags |= PERL_EXIT_DESTRUCT_END;
    int parsed = perl_parse(my_perl, command_xs_init, pargc, pargv, (char **)(envp ? envp : environ));
    if (parsed == 0) perl_run(my_perl);
    int status = perl_destruct(my_perl);
    perl_free(my_perl);
    PERL_SET_CONTEXT(NULL);
    t_fds[0] = saved[0];
    t_fds[1] = saved[1];
    t_fds[2] = saved[2];
    if (parsed != 0 && (status & 0xFF) == 0) return 255;
    return status & 0xFF;
}

static int run_with_args(const char *first, const char *second, char *const rest[], char *const envp[],
                         int inFd, int outFd, int errFd) {
    char lib[PATH_MAX], inc[PATH_MAX + 2];
    library_path(lib, sizeof lib);
    snprintf(inc, sizeof inc, "-I%s", lib);
    int n = 0;
    while (rest && rest[n]) n++;
    char **pargv = calloc((size_t)n + 6, sizeof(char *));
    if (!pargv) return 127;
    int k = 0;
    pargv[k++] = "perl";
    pargv[k++] = inc;
    pargv[k++] = "-MTriptych::Process";
    pargv[k++] = (char *)first;
    if (second) pargv[k++] = (char *)second;
    for (int i = 0; i < n; i++) pargv[k++] = rest[i];
    int status = run_perl(pargv, k, envp, inFd, outFd, errFd);
    free(pargv);
    return status;
}

int PerlCommandRun(const char *path, char *const argv[], char *const envp[], int inFd, int outFd, int errFd) {
    if (!path) return 127;
    fprintf(stderr, "PerlCommand: %s%s%s\n", path, argv && argv[0] && argv[1] ? " " : "",
            argv && argv[0] && argv[1] ? argv[1] : "");
    return run_with_args(path, NULL, argv && argv[0] ? argv + 1 : NULL, envp, inFd, outFd, errFd);
}

int PerlCommandEval(const char *code, char *const args[], char *const envp[], int inFd, int outFd, int errFd) {
    if (!code) return 127;
    return run_with_args("-e", code, args, envp, inFd, outFd, errFd);
}

void PerlCommandInstall(void) {
    MacProcessShimSetPerlRuntime(PerlCommandRun);
}
