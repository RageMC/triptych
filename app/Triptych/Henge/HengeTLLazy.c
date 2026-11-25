// SPDX-License-Identifier: GPL-2.0-or-later
// Henge's translation layer (libhengetl + henge-tl.c + henge-tl-app.m) lives in Frameworks/HengeTL.framework and is
// loaded on first use, not linked into Triptych: it brings its own AppKit (NSWindow, NSView, ...), and Objective-C
// class names are process-wide. Linked in, those classes would shadow the Mac apps page's AppKit shim
// (engines/macapps/host/shim) for every name-based lookup (nib loading, PyObjC, NSClassFromString). These are the
// functions of henge-tl.h, each forwarding to the framework.
#include "henge-tl.h"
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

extern _Atomic int henge_tl_ran; // henge-vm.c

static void *gHandle;
static char gLoadError[512];

static void load_once(void) {
    char exe[PATH_MAX];
    uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n) != 0) { snprintf(gLoadError, sizeof gLoadError, "no executable path"); return; }
    char *slash = strrchr(exe, '/');
    if (slash) *slash = 0;
    char path[PATH_MAX];
    // One AppKit per process: once the Mac apps page's shim is in, Henge's would be shadowed (and the other way round).
    snprintf(path, sizeof path, "%s/Frameworks/libShim_AppKit.dylib", exe);
    void *shim = dlopen(path, RTLD_NOW | RTLD_NOLOAD);
    if (shim) {
        dlclose(shim);
        snprintf(gLoadError, sizeof gLoadError,
                 "An app from the Mac apps page ran in this session. Quit and reopen Triptych to use built-in Mac apps.");
        return;
    }
    snprintf(path, sizeof path, "%s/Frameworks/HengeTL.framework/HengeTL", exe);
    gHandle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!gHandle) {
        fprintf(stderr, "Could not load the Gesso translation layer: %s\n", dlerror() ?: "dlopen failed");
        snprintf(gLoadError, sizeof gLoadError, "The built-in Mac program loader is unavailable.");
    }
}

static void *sym(const char *name) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, load_once);
    void *p = gHandle ? dlsym(gHandle, name) : NULL;
    if (!p) fprintf(stderr, "HengeTLLazy: %s unavailable: %s\n", name, gLoadError[0] ? gLoadError : "symbol missing");
    return p;
}

int henge_tl_lazy_loaded(void) { return gHandle != NULL; }

static int fail(char *err, size_t errlen) {
    if (err && errlen) snprintf(err, errlen, "%s", gLoadError[0] ? gLoadError : "Triptych's translation layer is missing");
    return -1;
}

#define FWD(ret, name, params, args, fallback)                    \
    ret name params {                                             \
        static ret (*fn) params;                                  \
        if (!fn) fn = (ret (*) params)sym(#name);                 \
        if (!fn) { fallback; }                                    \
        return fn args;                                           \
    }
#define FWDV(name, params, args)                                  \
    void name params {                                            \
        static void (*fn) params;                                 \
        if (!fn) fn = (void (*) params)sym(#name);                \
        if (fn) fn args;                                          \
    }

FWD(int, henge_tl_import_dmg, (const char *dmg, const char *dir, char *err, size_t errlen), (dmg, dir, err, errlen), return fail(err, errlen))
FWD(int, henge_tl_info, (const char *path, HengeTlInfo *info, char *err, size_t errlen), (path, info, err, errlen), return fail(err, errlen))
FWD(int, henge_tl_run, (const char *path, const char *out_path, char *err, size_t errlen), (path, out_path, err, errlen), return fail(err, errlen))
// Asked often (to grey out the Mac): answered without loading the framework.
int henge_tl_used(void) { return atomic_load(&henge_tl_ran); }
int henge_tl_ran_program(void) {
    if (!gHandle) return 0;
    static int (*fn)(void);
    if (!fn) fn = (int (*)(void))dlsym(gHandle, "henge_tl_ran_program");
    return fn ? fn() : 0;
}
FWDV(henge_tl_app_set_screen, (double width, double height, double scale), (width, height, scale))
FWDV(henge_tl_app_on_change, (void (*callback)(void)), (callback))
FWD(int, henge_tl_app_load, (const char *app_path, char *err, size_t errlen), (app_path, err, errlen), return fail(err, errlen))
FWD(int, henge_tl_app_run, (void), (), return -1)
FWDV(henge_tl_app_run_soon, (void (*finished)(int)), (finished))
FWD(int, henge_tl_app_window_count, (void), (), return 0)
FWD(void *, henge_tl_app_window_layer, (int index), (index), return NULL)
FWD(int, henge_tl_app_window_frame, (int index, double *x, double *y, double *w, double *h), (index, x, y, w, h), return -1)
FWD(double, henge_tl_app_screen_height, (void), (), return 0)
FWDV(henge_tl_app_mouse, (int type, double x, double y, int clicks, unsigned long flags), (type, x, y, clicks, flags))
FWDV(henge_tl_app_scroll, (double x, double y, double dx, double dy, int phase), (x, y, dx, dy, phase))
FWDV(henge_tl_app_key, (int down, unsigned short keycode, const char *chars, unsigned long flags), (down, keycode, chars, flags))
FWD(const void *, henge_tl_app_main_menu, (void), (), return NULL)
FWDV(henge_tl_app_menu_choose, (const int *path, int depth), (path, depth))
