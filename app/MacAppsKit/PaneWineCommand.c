// SPDX-License-Identifier: GPL-3.0-or-later
// Pane's per-command Wine API (see PaneWineCommand.h). CrossOver's Perl `wine` wrapper prepares the bottle and
// execs the native loader (`wine <program> args...`) or wineserver (`wineserver -k|-w|-p`); MacProcessShim
// routes both here. Commands for all bottles are serialized: Madeira runs one Wine session at a time.
#include "PaneWineCommand.h"
#include "MacProcessShim.h"

#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PANE_ARGS_MAX 8192

static pthread_mutex_t g_session_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_config_lock = PTHREAD_MUTEX_INITIALIZER;
static PaneWineRunnerFn g_runner;
static PaneWineStopFn g_stop;
static int g_overridden;
static PaneWineLoaderFn g_loader;

void PaneWineCommandSetLoader(PaneWineLoaderFn loader) {
    pthread_mutex_lock(&g_config_lock);
    g_loader = loader;
    pthread_mutex_unlock(&g_config_lock);
}

void PaneWineCommandSetRunner(PaneWineRunnerFn runner, PaneWineStopFn stop) {
    pthread_mutex_lock(&g_config_lock);
    g_runner = runner;
    g_stop = stop;
    g_overridden = runner != NULL || stop != NULL;
    pthread_mutex_unlock(&g_config_lock);
}

void PaneWineCommandInstall(void) { MacProcessShimSetWineRuntime(PaneWineCommandRun); }

/// Finds Madeira's entry points in the loaded MadeiraRuntime.framework. When it is not loaded yet, the app's loader
/// (MadeiraRuntime.load: releases Pane's reserved address space, then dlopens) loads it first.
static void resolve_runtime(PaneWineRunnerFn *runner, PaneWineStopFn *stop) {
    pthread_mutex_lock(&g_config_lock);
    *runner = g_runner;
    *stop = g_stop;
    int overridden = g_overridden;
    PaneWineLoaderFn loader = g_loader;
    pthread_mutex_unlock(&g_config_lock);
    if (overridden) return;
    if (loader) (void)loader();
    static const char suffix[] = "/MadeiraRuntime.framework/MadeiraRuntime";
    for (uint32_t i = 0, n = _dyld_image_count(); i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        size_t len = name ? strlen(name) : 0;
        if (len < sizeof suffix - 1 || strcmp(name + len - (sizeof suffix - 1), suffix) != 0) continue;
        void *h = dlopen(name, RTLD_NOLOAD | RTLD_LAZY | RTLD_LOCAL);
        if (!h) return;
        *runner = (PaneWineRunnerFn)dlsym(h, "madeira_embed_run_command");
        *stop = (PaneWineStopFn)dlsym(h, "madeira_embed_stop_prefix");
        dlclose(h);   // balanced with the NOLOAD reference; the framework is never unloaded
        return;
    }
}

static const char *env_lookup(char *const envp[], const char *key) {
    size_t klen = strlen(key);
    for (int i = 0; envp && envp[i]; i++)
        if (strncmp(envp[i], key, klen) == 0 && envp[i][klen] == '=') return envp[i] + klen + 1;
    return NULL;
}

static const char *base_name(const char *path) {
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

static void say(int fd, const char *fmt, const char *a, const char *b) {
    char buf[PATH_MAX * 2];
    int n = snprintf(buf, sizeof buf, fmt, a ? a : "", b ? b : "");
    if (n > 0) (void)!write(fd >= 0 ? fd : STDERR_FILENO, buf, (size_t)n < sizeof buf ? (size_t)n : sizeof buf - 1);
}

int PaneWineCommandTranslateProgram(const char *prefix, const char *program, char *out, unsigned long outSize) {
    if (!program || !out || outSize == 0) return -1;
    int n;
    if (program[0] == '/') {
        char drive_c[PATH_MAX];
        size_t dlen = 0;
        if (prefix && prefix[0]) {
            size_t plen = strlen(prefix);
            while (plen > 1 && prefix[plen - 1] == '/') plen--;
            n = snprintf(drive_c, sizeof drive_c, "%.*s/drive_c/", (int)plen, prefix);
            if (n > 0 && (size_t)n < sizeof drive_c) dlen = (size_t)n;
        }
        const char *rest;
        if (dlen && strncmp(program, drive_c, dlen) == 0) {
            rest = program + dlen;
            n = snprintf(out, outSize, "C:\\%s", rest);
        } else {
            n = snprintf(out, outSize, "Z:%s", program);
        }
        if (n < 0 || (unsigned long)n >= outSize) return -1;
        for (char *p = out; *p; p++) if (*p == '/') *p = '\\';
        return 0;
    }
    int windows_path = strchr(program, '\\') != NULL || (program[0] && program[1] == ':');
    size_t len = strlen(program);
    int has_ext = len > 4 && program[len - 4] == '.';
    n = snprintf(out, outSize, (windows_path || has_ext) ? "%s" : "%s.exe", program);
    return (n < 0 || (unsigned long)n >= outSize) ? -1 : 0;
}

int PaneWineCommandQuoteArgs(char *const argv[], char *out, unsigned long outSize) {
    if (!out || outSize == 0) return -1;
    size_t o = 0;
    out[0] = 0;
#define PUT(c) do { if (o + 1 >= outSize) return -1; out[o++] = (c); } while (0)
    for (int i = 0; argv && argv[i]; i++) {
        const char *a = argv[i];
        if (i) PUT(' ');
        int quote = a[0] == 0 || strpbrk(a, " \t\n\v\"") != NULL;
        if (!quote) {
            for (; *a; a++) PUT(*a);
            continue;
        }
        PUT('"');
        for (;; a++) {
            unsigned slashes = 0;
            while (*a == '\\') { slashes++; a++; }
            if (*a == 0) { for (unsigned k = 0; k < slashes * 2; k++) PUT('\\'); break; }
            if (*a == '"') { for (unsigned k = 0; k < slashes * 2 + 1; k++) PUT('\\'); PUT('"'); continue; }
            for (unsigned k = 0; k < slashes; k++) PUT('\\');
            PUT(*a);
        }
        PUT('"');
    }
#undef PUT
    out[o] = 0;
    return 0;
}

static int run_wineserver(const char *prefix, char *const argv[], int outFd, int errFd, PaneWineStopFn stop) {
    int status = 0;
    for (int i = 1; argv && argv[i]; i++) {
        const char *a = argv[i];
        if (strcmp(a, "--version") == 0 || strcmp(a, "-v") == 0) {
            say(outFd, "Wine (Pane in-process wineserver)\n", NULL, NULL);
        } else if (strcmp(a, "-w") == 0 || strcmp(a, "--wait") == 0) {
            // Commands run synchronously under the session lock: once it is free, nothing runs.
            pthread_mutex_lock(&g_session_lock);
            pthread_mutex_unlock(&g_session_lock);
        } else if (strncmp(a, "-k", 2) == 0 || strncmp(a, "--kill", 6) == 0) {
            int rc = stop ? stop(prefix) : 0;
            if (rc < 0) { say(errFd, "wineserver: could not stop the session for %s: %s\n", prefix, strerror(-rc)); status = 1; }
        } else if (strncmp(a, "-p", 2) == 0 || strncmp(a, "--persistent", 12) == 0 ||
                   strncmp(a, "-d", 2) == 0 || strncmp(a, "--debug", 7) == 0 ||
                   strcmp(a, "-f") == 0 || strcmp(a, "--foreground") == 0) {
            // The in-process server lives as long as Pane's session; persistence and debug levels are Madeira's.
        } else {
            say(errFd, "wineserver: unsupported option %s\n", a, NULL);
            status = 1;
        }
    }
    return status;
}

int PaneWineCommandRun(const char *path, char *const argv[], char *const envp[], int inFd, int outFd, int errFd) {
    const char *prefix = env_lookup(envp, "WINEPREFIX");
    const char *tool = base_name(path ? path : (argv && argv[0] ? argv[0] : "wine"));
    // One line per command in the app's log (MacApps/<app>.log while a Mac app runs).
    fprintf(stderr, "PaneWineCommand: %s %s (bottle %s)\n", tool, argv && argv[0] && argv[1] ? argv[1] : "",
            prefix ? prefix : "none");
    if (!prefix || prefix[0] != '/') {
        say(errFd, "%s: Pane runs Wine only for a bottle (an absolute WINEPREFIX is required)\n", tool, NULL);
        return 1;
    }
    PaneWineRunnerFn runner;
    PaneWineStopFn stop;
    resolve_runtime(&runner, &stop);
    if (strncmp(tool, "wineserver", 10) == 0) return run_wineserver(prefix, argv, outFd, errFd, stop);

    if (!argv || !argv[0] || !argv[1]) {
        say(errFd, "Usage: %s PROGRAM [ARGUMENTS...]\n", tool, NULL);
        return 1;
    }
    char exe[PATH_MAX];
    char args[PANE_ARGS_MAX];
    if (PaneWineCommandTranslateProgram(prefix, argv[1], exe, sizeof exe) != 0 ||
        PaneWineCommandQuoteArgs(argv + 2, args, sizeof args) != 0) {
        say(errFd, "%s: command line too long for %s\n", tool, argv[1]);
        return 1;
    }
    if (!runner) {
        say(errFd, "%s: Pane's Wine runtime is not loaded; cannot run %s\n", tool, exe);
        return 126;
    }
    pthread_mutex_lock(&g_session_lock);
    int rc = runner(prefix, exe, args, envp, inFd, outFd, errFd);
    pthread_mutex_unlock(&g_session_lock);
    if (rc == -EBUSY) {
        say(errFd, "%s: Pane is running another bottle or Windows session; quit and reopen Triptych to run %s\n", tool, exe);
        return 126;
    }
    if (rc < 0) {
        char what[PATH_MAX + 128];
        snprintf(what, sizeof what, "%s: %s", exe, strerror(-rc));
        say(errFd, "%s: Pane could not start %s\n", tool, what);
        return 126;
    }
    return rc & 0xFF;
}
