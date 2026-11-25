// SPDX-License-Identifier: GPL-3.0-or-later
// Guest process interception layer for MacAppsKit:
// - Intercepts fork, vfork, execve, posix_spawn, posix_spawnp, waitpid, system, and popen
//   for both dlopen'd Simulator guests (Mach-O rebinding) and tl_loader guests (tl_runtime_lookup).
// - Dispatches /usr/bin/openssl verification via Security.framework, sw_vers/uname builtins,
//   and bundled Mach-O helpers (wine, wineserver, Python helpers).
#include "MacProcessShim.h"

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/fat.h>
#include <mach-o/fixup-chains.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <zlib.h>

// MARK: - Shared child process table & spawn file actions

#define MAC_MAX_PROCS 256
#define MAC_MAX_FA 64
#define MAC_MAX_FA_OPS 64
#define MAC_MAX_POPEN 64

typedef struct {
    pid_t pid;
    int done;    // 0 running, 1 finished, 2 reaped
    int status;  // waitpid status word
} MacChildProc;

static MacChildProc g_procs[MAC_MAX_PROCS];
static pid_t g_next_pid = 90000;
static pthread_mutex_t g_proc_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_proc_cond = PTHREAD_COND_INITIALIZER;

typedef enum { FA_DUP2, FA_CLOSE, FA_OPEN } FaOpKind;
typedef struct {
    FaOpKind kind;
    int fd1, fd2;
    char *path;
    int oflag;
    mode_t mode;
} FaOp;

typedef struct {
    const void *key;
    FaOp ops[MAC_MAX_FA_OPS];
    int nops;
} FaRecord;

static FaRecord g_fa[MAC_MAX_FA];
static pthread_mutex_t g_fa_lock = PTHREAD_MUTEX_INITIALIZER;

static struct {
    FILE *stream;
    pid_t pid;
} g_popen[MAC_MAX_POPEN];
static pthread_mutex_t g_popen_lock = PTHREAD_MUTEX_INITIALIZER;

static char g_bundle_root[PATH_MAX];
static MacProcessHelperLauncherFn g_helper_launcher;
static MacProcessRuntimeFn g_wine_runtime;
static MacProcessRuntimeFn g_perl_runtime;
static MacProcessExitFallbackFn g_exit_fallback;
static pthread_mutex_t g_shim_lock = PTHREAD_MUTEX_INITIALIZER;

void MacProcessShimSetHelperLauncher(MacProcessHelperLauncherFn launcher) {
    pthread_mutex_lock(&g_shim_lock);
    g_helper_launcher = launcher;
    pthread_mutex_unlock(&g_shim_lock);
}

void MacProcessShimSetWineRuntime(MacProcessRuntimeFn runtime) {
    pthread_mutex_lock(&g_shim_lock);
    g_wine_runtime = runtime;
    pthread_mutex_unlock(&g_shim_lock);
}

void MacProcessShimSetPerlRuntime(MacProcessRuntimeFn runtime) {
    pthread_mutex_lock(&g_shim_lock);
    g_perl_runtime = runtime;
    pthread_mutex_unlock(&g_shim_lock);
}

void MacProcessShimSetExitFallback(MacProcessExitFallbackFn fn) {
    pthread_mutex_lock(&g_shim_lock);
    g_exit_fallback = fn;
    pthread_mutex_unlock(&g_shim_lock);
}

static MacChildProc *proc_alloc(void) {
    pthread_mutex_lock(&g_proc_lock);
    MacChildProc *slot = NULL;
    for (int i = 0; i < MAC_MAX_PROCS; i++) {
        if (g_procs[i].pid == 0 || g_procs[i].done == 2) {
            slot = &g_procs[i];
            break;
        }
    }
    if (slot) {
        slot->pid = g_next_pid++;
        if (g_next_pid > 2000000) g_next_pid = 90000;
        slot->done = 0;
        slot->status = 0;
    }
    pthread_mutex_unlock(&g_proc_lock);
    return slot;
}

static void proc_finish(pid_t pid, int exit_code) {
    pthread_mutex_lock(&g_proc_lock);
    for (int i = 0; i < MAC_MAX_PROCS; i++) {
        if (g_procs[i].pid == pid) {
            g_procs[i].status = W_EXITCODE(exit_code & 0xFF, 0);
            g_procs[i].done = 1;
            pthread_cond_broadcast(&g_proc_cond);
            break;
        }
    }
    pthread_mutex_unlock(&g_proc_lock);
}

static MacChildProc *proc_find_locked(pid_t pid) {
    for (int i = 0; i < MAC_MAX_PROCS; i++) {
        if (g_procs[i].pid == pid && g_procs[i].done != 2) return &g_procs[i];
    }
    return NULL;
}

// MARK: - Builtins (sw_vers, uname, /bin/sh -c, /usr/bin/env)

static void write_str_fd(int fd, const char *s) {
    if (fd < 0 || !s) return;
    size_t left = strlen(s);
    while (left > 0) {
        ssize_t n = write(fd, s, left);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        s += n;
        left -= (size_t)n;
    }
}

static int parse_shell_words(const char *cmd, char *buf, size_t bufsz, char **argv, int max_args) {
    if (!cmd || !*cmd) return 0;
    size_t bi = 0;
    int argc = 0;
    const char *p = cmd;
    while (*p && argc < max_args - 1) {
        while (*p == ' ' || *p == '\t' || *p == '\n') p++;
        if (!*p) break;
        if (bi >= bufsz - 1) break;
        argv[argc++] = buf + bi;
        char quote = 0;
        while (*p) {
            if (!quote && (*p == ' ' || *p == '\t' || *p == '\n')) break;
            if (!quote && (*p == '\'' || *p == '"')) {
                quote = *p++;
                continue;
            }
            if (quote && *p == quote) {
                quote = 0;
                p++;
                continue;
            }
            if (*p == '\\' && quote != '\'' && p[1]) p++;
            if (bi + 1 < bufsz) buf[bi++] = *p;
            p++;
        }
        if (bi < bufsz) buf[bi++] = '\0';
    }
    argv[argc] = NULL;
    return argc;
}

static const char *base_name(const char *p) {
    if (!p) return "";
    const char *s = strrchr(p, '/');
    return s ? s + 1 : p;
}

static int run_sw_vers(int argc, char *const argv[], int out_fd) {
    char version[64] = "15.0", build[64] = "24A335";
    size_t n = sizeof version;
    if (sysctlbyname("kern.osproductversion", version, &n, NULL, 0) != 0 || !version[0]) snprintf(version, sizeof version, "15.0");
    n = sizeof build;
    if (sysctlbyname("kern.osversion", build, &n, NULL, 0) != 0 || !build[0]) snprintf(build, sizeof build, "24A335");

    const char *arg = (argc > 1 && argv[1]) ? argv[1] : "";
    char out[256];
    if (!strcmp(arg, "-productVersion") || !strcmp(arg, "--productVersion")) {
        snprintf(out, sizeof out, "%s\n", version);
    } else if (!strcmp(arg, "-buildVersion") || !strcmp(arg, "--buildVersion")) {
        snprintf(out, sizeof out, "%s\n", build);
    } else if (!strcmp(arg, "-productName") || !strcmp(arg, "--productName")) {
        snprintf(out, sizeof out, "macOS\n");
    } else {
        snprintf(out, sizeof out, "ProductName:\t\tmacOS\nProductVersion:\t\t%s\nBuildVersion:\t\t%s\n", version, build);
    }
    write_str_fd(out_fd, out);
    return 0;
}

static int run_uname(int argc, char *const argv[], int out_fd) {
    char release[64] = "24.0.0", version[256] = "Darwin Kernel Version 24.0.0", host[128] = "localhost";
    size_t n = sizeof release;
    sysctlbyname("kern.osrelease", release, &n, NULL, 0);
    n = sizeof version;
    sysctlbyname("kern.version", version, &n, NULL, 0);
    if (gethostname(host, sizeof host) != 0 || !host[0]) snprintf(host, sizeof host, "localhost");

    bool s = false, nd = false, r = false, v = false, m = false, p = false;
    if (argc <= 1) s = true;
    for (int i = 1; i < argc && argv[i]; i++) {
        const char *a = argv[i];
        if (a[0] != '-') continue;
        for (const char *c = a + 1; *c; c++) {
            switch (*c) {
            case 'a': s = nd = r = v = m = true; break;
            case 's': s = true; break;
            case 'n': nd = true; break;
            case 'r': r = true; break;
            case 'v': v = true; break;
            case 'm': m = true; break;
            case 'p': p = true; break;
            default: break;
            }
        }
    }
    if (!s && !nd && !r && !v && !m && !p) s = true;

    char out[512] = "";
    if (s)  strlcat(out, "Darwin ", sizeof out);
    if (nd) { strlcat(out, host, sizeof out); strlcat(out, " ", sizeof out); }
    if (r)  { strlcat(out, release, sizeof out); strlcat(out, " ", sizeof out); }
    if (v)  { strlcat(out, version, sizeof out); strlcat(out, " ", sizeof out); }
    if (m)  strlcat(out, "arm64 ", sizeof out);
    if (p)  strlcat(out, "arm ", sizeof out);
    size_t len = strlen(out);
    if (len > 0 && out[len - 1] == ' ') out[len - 1] = '\n';
    else strlcat(out, "\n", sizeof out);
    write_str_fd(out_fd, out);
    return 0;
}

static int gzip_stream(int src_fd, int dst_fd, bool decompress, int err_fd) {
    uint8_t buf[16384];
    if (decompress) {
        int dfd = dup(src_fd);
        if (dfd < 0) return 1;
        gzFile gz = gzdopen(dfd, "rb");
        if (!gz) { close(dfd); return 1; }
        for (;;) {
            int n = gzread(gz, buf, sizeof buf);
            if (n < 0) {
                int zerr = Z_OK;
                const char *msg = gzerror(gz, &zerr);
                write_str_fd(err_fd, msg ? msg : "gzip: read error\n");
                gzclose(gz);
                return 1;
            }
            if (n == 0) break;
            size_t off = 0;
            while (off < (size_t)n) {
                ssize_t w = write(dst_fd, buf + off, (size_t)n - off);
                if (w < 0) {
                    if (errno == EINTR) continue;
                    gzclose(gz);
                    return 1;
                }
                off += (size_t)w;
            }
        }
        gzclose(gz);
        return 0;
    }

    int dfd = dup(dst_fd);
    if (dfd < 0) return 1;
    gzFile gz = gzdopen(dfd, "wb");
    if (!gz) { close(dfd); return 1; }
    for (;;) {
        ssize_t n = read(src_fd, buf, sizeof buf);
        if (n < 0) {
            if (errno == EINTR) continue;
            gzclose(gz);
            return 1;
        }
        if (n == 0) break;
        if (gzwrite(gz, buf, (unsigned)n) != n) {
            gzclose(gz);
            return 1;
        }
    }
    gzclose(gz);
    return 0;
}

static int run_gzip(int argc, char *const argv[], int in_fd, int out_fd, int err_fd) {
    const char *prog = argc > 0 ? base_name(argv[0]) : "gzip";
    bool decompress = !strcmp(prog, "gunzip") || !strcmp(prog, "zcat");
    bool to_stdout = !strcmp(prog, "zcat");
    bool keep = false;
    const char *files[64];
    int nfiles = 0;

    for (int i = 1; i < argc && argv[i]; i++) {
        const char *a = argv[i];
        if (!strcmp(a, "--")) {
            for (int j = i + 1; j < argc && argv[j] && nfiles < 64; j++) files[nfiles++] = argv[j];
            break;
        }
        if (!strcmp(a, "--decompress") || !strcmp(a, "--uncompress")) { decompress = true; continue; }
        if (!strcmp(a, "--stdout") || !strcmp(a, "--to-stdout")) { to_stdout = true; continue; }
        if (!strcmp(a, "--keep")) { keep = true; continue; }
        if (a[0] == '-' && a[1] != '\0') {
            for (const char *c = a + 1; *c; c++) {
                if (*c == 'd') decompress = true;
                else if (*c == 'c') to_stdout = true;
                else if (*c == 'k') keep = true;
            }
            continue;
        }
        if (nfiles < 64) files[nfiles++] = a;
    }

    if (nfiles == 0) return gzip_stream(in_fd, out_fd, decompress, err_fd);

    int rc = 0;
    for (int i = 0; i < nfiles; i++) {
        const char *f = files[i];
        if (!strcmp(f, "-")) {
            if (gzip_stream(in_fd, out_fd, decompress, err_fd) != 0) rc = 1;
            continue;
        }
        int sfd = open(f, O_RDONLY);
        if (sfd < 0) {
            write_str_fd(err_fd, "gzip: cannot open input file\n");
            rc = 1;
            continue;
        }
        if (to_stdout) {
            if (gzip_stream(sfd, out_fd, decompress, err_fd) != 0) rc = 1;
            close(sfd);
            continue;
        }
        char dst[PATH_MAX];
        size_t flen = strlen(f);
        if (decompress) {
            if (flen > 3 && !strcmp(f + flen - 3, ".gz")) {
                snprintf(dst, sizeof dst, "%.*s", (int)(flen - 3), f);
            } else if (flen > 4 && !strcmp(f + flen - 4, ".tgz")) {
                snprintf(dst, sizeof dst, "%.*s.tar", (int)(flen - 4), f);
            } else {
                close(sfd);
                rc = 1;
                continue;
            }
        } else {
            snprintf(dst, sizeof dst, "%s.gz", f);
        }
        int dfd = open(dst, O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (dfd < 0) {
            close(sfd);
            rc = 1;
            continue;
        }
        int g = gzip_stream(sfd, dfd, decompress, err_fd);
        close(sfd);
        close(dfd);
        if (g != 0) {
            unlink(dst);
            rc = 1;
        } else if (!keep) {
            unlink(f);
        }
    }
    return rc;
}

static bool is_builtin_name(const char *name) {
    static const char *const kBuiltins[] = {
        "openssl", "sw_vers", "uname", "gzip", "gunzip", "zcat", "which", "true", "false", "sh", "env", NULL
    };
    for (int i = 0; kBuiltins[i]; i++) {
        if (!strcmp(name, kBuiltins[i])) return true;
    }
    return false;
}

static int resolve_bundled_helper(const char *path, char *resolved, size_t rsz);

static int run_which(int argc, char *const argv[], int out_fd) {
    int rc = (argc > 1) ? 0 : 1;
    for (int i = 1; i < argc && argv[i]; i++) {
        if (argv[i][0] == '-') continue;
        const char *name = base_name(argv[i]);
        char line[PATH_MAX];
        if (is_builtin_name(name)) {
            snprintf(line, sizeof line, "/usr/bin/%s\n", name);
            write_str_fd(out_fd, line);
        } else if (resolve_bundled_helper(argv[i], line, sizeof line - 2) != ENOENT) {
            strlcat(line, "\n", sizeof line);
            write_str_fd(out_fd, line);
        } else {
            rc = 1;
        }
    }
    return rc;
}

// MARK: - Bundled helper resolution & dispatch

static int helper_format(const char *path, bool pane) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return ENOENT;
    uint8_t buf[64];
    ssize_t n = read(fd, buf, sizeof buf);
    close(fd);
    static const char perl[] = "#!/usr/bin/perl";
    if (n >= (ssize_t)sizeof perl && !memcmp(buf, perl, sizeof perl - 1) &&
        buf[sizeof perl - 1] && strchr(" \t\r\n", buf[sizeof perl - 1])) {
        return ENOTSUP;
    }
    if (n < 8) return ENOENT;
    uint32_t m = 0;
    memcpy(&m, buf, 4);
    if (m == MH_MAGIC_64) {
        const struct mach_header_64 *mh = (const void *)buf;
        if ((size_t)n < sizeof(*mh)) return ENOENT;
        return mh->cputype == CPU_TYPE_ARM64 || (pane && mh->cputype == CPU_TYPE_X86_64) ? 0 : ENOENT;
    }
    uint32_t bm = __builtin_bswap32(m);
    if (bm == FAT_MAGIC || bm == FAT_MAGIC_64) {
        uint32_t nfat = __builtin_bswap32(*(const uint32_t *)(buf + 4));
        return nfat > 0 && nfat <= 16 ? 0 : ENOENT;
    }
    return ENOENT;
}

static bool is_blocked_helper_name(const char *name) {
    static const char *const blocked[] = {
        "Sparkle", "Updater", "Autoupdate", "Installer", "ShipIt", "Downloader", "crashpad", NULL
    };
    for (int i = 0; blocked[i]; i++) {
        if (strstr(name, blocked[i])) return true;
    }
    return false;
}

// 0 is a native helper, ENOTSUP is a Perl script, and EXDEV signals
// a CrossOver Wine executable that belongs to Pane.
static int resolve_helper_candidate(const char *path, const char *bundle_root,
                                    char *resolved, size_t rsz) {
    bool pane = false;
    char canonical[PATH_MAX];
    if (*bundle_root && realpath(path, canonical)) {
        size_t len = strlen(bundle_root);
        if (!strncmp(canonical, bundle_root, len)) {
            const char *relative = canonical + len;
            static const char bin[] = "/Contents/SharedSupport/CrossOver/bin/";
            if (!strncmp(relative, bin, sizeof bin - 1)) {
                const char *name = relative + sizeof bin - 1;
                if (!strcmp(name, "wine") || !strcmp(name, "wineserver") ||
                    !strcmp(name, "wineserver-arm64") || !strcmp(name, "wineserver-x86")) {
                    pane = true;
                }
            } else if (!strcmp(relative,
                       "/Contents/SharedSupport/CrossOver/lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine") ||
                       !strcmp(relative, "/Contents/SharedSupport/CrossOver/lib/wine/x86_64-unix/wine")) {
                pane = true;
            }
        }
    }
    int result = helper_format(path, pane);
    if (result == 0 && pane) result = EXDEV;
    if (result != ENOENT && strlcpy(resolved, path, rsz) >= rsz) return ENOENT;
    return result;
}

static int resolve_bundled_helper(const char *path, char *resolved, size_t rsz) {
    if (!path || !*path) return ENOENT;
    char bundle_root[PATH_MAX];
    pthread_mutex_lock(&g_shim_lock);
    strlcpy(bundle_root, g_bundle_root, sizeof bundle_root);
    pthread_mutex_unlock(&g_shim_lock);
    struct stat st;
    if (strchr(path, '/') && stat(path, &st) == 0 && S_ISREG(st.st_mode)) {
        if (is_blocked_helper_name(base_name(path))) return ENOENT;
        return resolve_helper_candidate(path, bundle_root, resolved, rsz);
    }
    // Explicit paths never fall back to a different executable with the same name.
    if (strchr(path, '/') || !bundle_root[0]) return ENOENT;
    const char *name = base_name(path);
    if (is_blocked_helper_name(name)) return ENOENT;

    const char *candidates[8];
    char buf[8][PATH_MAX];
    int nc = 0;
    snprintf(buf[nc], PATH_MAX, "%s/Contents/MacOS/%s", bundle_root, name);
    candidates[nc] = buf[nc]; nc++;
    snprintf(buf[nc], PATH_MAX, "%s/Contents/SharedSupport/CrossOver/bin/%s", bundle_root, name);
    candidates[nc] = buf[nc]; nc++;
    snprintf(buf[nc], PATH_MAX, "%s/Contents/SharedSupport/CrossOver/bin/%s-arm64", bundle_root, name);
    candidates[nc] = buf[nc]; nc++;
    if (!strcmp(name, "wine")) {
        snprintf(buf[nc], PATH_MAX, "%s/Contents/SharedSupport/CrossOver/lib/wine/aarch64-unix/wine.app/Contents/MacOS/wine", bundle_root);
        candidates[nc] = buf[nc]; nc++;
    }
    if (!strncmp(name, "python", 6)) {
        snprintf(buf[nc], PATH_MAX, "%s/Contents/Frameworks/Python.framework/Versions/Current/bin/%s", bundle_root, name);
        candidates[nc] = buf[nc]; nc++;
        snprintf(buf[nc], PATH_MAX, "%s/Contents/Frameworks/Python.framework/Versions/Current/Resources/Python.app/Contents/MacOS/Python", bundle_root);
        candidates[nc] = buf[nc]; nc++;
    }
    for (int i = 0; i < nc; i++) {
        if (stat(candidates[i], &st) != 0 || !S_ISREG(st.st_mode)) continue;
        int result = resolve_helper_candidate(candidates[i], bundle_root, resolved, rsz);
        if (result == ENOENT) continue;
        // A wrapper needs its interpreter and setup. Do not silently select
        // a native helper with the same name when the wrapper is present.
        return result;
    }
    return ENOENT;
}

typedef enum {
    CMD_UNSUPPORTED = 0,
    CMD_PERL_SCRIPT,
    CMD_PANE_WINE,
    CMD_OPENSSL,
    CMD_SW_VERS,
    CMD_UNAME,
    CMD_GZIP,
    CMD_WHICH,
    CMD_TRUE,
    CMD_FALSE,
    CMD_HELPER,
} CmdKind;

typedef struct {
    pid_t pid;
    CmdKind kind;
    MacProcessRuntimeFn runtime;
    char path[PATH_MAX];
    int argc;
    char **argv;
    char **envp;
    int in_fd;
    int out_fd;
    int err_fd;
} ChildTask;

static char **dup_strv(char *const v[], int *count_out) {
    int n = 0;
    while (v && v[n]) n++;
    char **out = calloc((size_t)n + 1, sizeof(char *));
    if (!out) return NULL;
    for (int i = 0; i < n; i++) out[i] = strdup(v[i]);
    if (count_out) *count_out = n;
    return out;
}

static void free_strv(char **v) {
    if (!v) return;
    for (int i = 0; v[i]; i++) free(v[i]);
    free(v);
}

static CmdKind classify_command(const char *path, char *const argv[], char *resolved_path, size_t rsz,
                                char sh_buf[2][4096], char *sh_argv[2][128],
                                int *out_argc, char *const **out_argv) {
    int argc = 0;
    while (argv && argv[argc]) argc++;

    const char *base = base_name(path);
    // Unwrap /bin/sh -c "..." or /usr/bin/env cmd ... iteratively (up to 4 nesting levels, e.g. popen -> /bin/sh -c '...').
    for (int depth = 0; depth < 4; depth++) {
        if ((!strcmp(base, "sh") || !strcmp(base, "bash") || !strcmp(base, "zsh")) && argc >= 3 && !strcmp(argv[1], "-c")) {
            int slot = depth & 1;
            int n = parse_shell_words(argv[2], sh_buf[slot], 4096, sh_argv[slot], 128);
            if (n <= 0) break;
            path = sh_argv[slot][0];
            base = base_name(path);
            argc = n;
            argv = sh_argv[slot];
        } else if (!strcmp(base, "env") && argc >= 2) {
            int skip = 1;
            while (skip < argc && strchr(argv[skip], '=')) skip++;
            if (skip >= argc) break;
            path = argv[skip];
            base = base_name(path);
            argc = argc - skip;
            argv = argv + skip;
        } else {
            break;
        }
    }
    *out_argc = argc;
    *out_argv = argv;

    if (!strcmp(base, "openssl")) {
        snprintf(resolved_path, rsz, "%s", path);
        return CMD_OPENSSL;
    }
    if (!strcmp(base, "sw_vers")) {
        snprintf(resolved_path, rsz, "%s", path);
        return CMD_SW_VERS;
    }
    if (!strcmp(base, "uname")) {
        snprintf(resolved_path, rsz, "%s", path);
        return CMD_UNAME;
    }
    if (!strcmp(base, "gzip") || !strcmp(base, "gunzip") || !strcmp(base, "zcat")) {
        snprintf(resolved_path, rsz, "%s", path);
        return CMD_GZIP;
    }
    if (!strcmp(base, "which")) {
        snprintf(resolved_path, rsz, "%s", path);
        return CMD_WHICH;
    }
    if (!strcmp(base, "true")) {
        snprintf(resolved_path, rsz, "%s", path);
        return CMD_TRUE;
    }
    if (!strcmp(base, "false")) {
        snprintf(resolved_path, rsz, "%s", path);
        return CMD_FALSE;
    }
    int result = resolve_bundled_helper(path, resolved_path, rsz);
    if (result == 0) return CMD_HELPER;
    if (result == ENOTSUP) return CMD_PERL_SCRIPT;
    if (result == EXDEV) return CMD_PANE_WINE;
    return CMD_UNSUPPORTED;
}

static int run_task_body(ChildTask *t) {
    switch (t->kind) {
    case CMD_OPENSSL:
        return MacOpenSSLRun(t->argc, (const char *const *)t->argv, t->in_fd, t->out_fd, t->err_fd);
    case CMD_SW_VERS:
        return run_sw_vers(t->argc, t->argv, t->out_fd);
    case CMD_UNAME:
        return run_uname(t->argc, t->argv, t->out_fd);
    case CMD_GZIP:
        return run_gzip(t->argc, t->argv, t->in_fd, t->out_fd, t->err_fd);
    case CMD_WHICH:
        return run_which(t->argc, t->argv, t->out_fd);
    case CMD_TRUE:
        return 0;
    case CMD_FALSE:
        return 1;
    case CMD_PERL_SCRIPT:
    case CMD_PANE_WINE:
        return t->runtime(t->path, t->argv, t->envp, t->in_fd, t->out_fd, t->err_fd);
    case CMD_HELPER: {
        pthread_mutex_lock(&g_shim_lock);
        MacProcessHelperLauncherFn fn = g_helper_launcher;
        pthread_mutex_unlock(&g_shim_lock);
        if (!fn) {
            fprintf(stderr, "MacProcessShim: no helper launcher for %s\n", t->path);
            return 127;
        }
        int status = 127;
        if (fn(t->path, t->argv, t->envp, &status) != 0) return 127;
        return status;
    }
    default:
        return 127;
    }
}

// Native Simulator helpers run on a worker thread. Their exit status belongs
// to the virtual child, and exiting it must release the same FDs as a return.
typedef struct {
    ChildTask *task;
    int status;
} ChildCompletion;

static _Thread_local ChildCompletion *g_helper_completion;

static void finish_child(void *opaque) {
    ChildCompletion *completion = opaque;
    ChildTask *t = completion->task;
    if (t->in_fd >= 0) close(t->in_fd);
    if (t->out_fd >= 0) close(t->out_fd);
    if (t->err_fd >= 0) close(t->err_fd);
    proc_finish(t->pid, completion->status);
    free_strv(t->argv);
    free_strv(t->envp);
    free(t);
}

static void *child_worker(void *opaque) {
    ChildTask *t = opaque;
    ChildCompletion completion = {t, 127};
    pthread_cleanup_push(finish_child, &completion);
    if (t->kind == CMD_HELPER || t->runtime) g_helper_completion = &completion;
    completion.status = run_task_body(t);
    g_helper_completion = NULL;
    pthread_cleanup_pop(1);
    return NULL;
}

static void exit_helper_thread(int status) {
    if (!g_helper_completion) return;
    g_helper_completion->status = status;
    g_helper_completion = NULL;
    pthread_exit(NULL);
}

static ChildTask *current_child_task(void) {
    return g_helper_completion ? g_helper_completion->task : NULL;
}

static void inherited_standard_fds(int fds[3]) {
    ChildTask *current = current_child_task();
    fds[0] = current ? current->in_fd : STDIN_FILENO;
    fds[1] = current ? current->out_fd : STDOUT_FILENO;
    fds[2] = current ? current->err_fd : STDERR_FILENO;
}

static int dup_cloexec(int fd) {
    if (fd < 0) return -1;
    int d = dup(fd);
    if (d >= 0) fcntl(d, F_SETFD, FD_CLOEXEC);
    return d;
}

static int launch_command_async(pid_t *pid_out, const char *path, char *const argv[], char *const envp[],
                                int in_fd, int out_fd, int err_fd) {
    char resolved[PATH_MAX];
    char sh_buf[2][4096];
    char *sh_argv[2][128];
    int eff_argc = 0;
    char *const *eff_argv = NULL;
    CmdKind kind = classify_command(path, argv, resolved, sizeof resolved,
                                    sh_buf, sh_argv, &eff_argc, &eff_argv);
    MacProcessRuntimeFn runtime = NULL;
    if (kind == CMD_PERL_SCRIPT || kind == CMD_PANE_WINE) {
        pthread_mutex_lock(&g_shim_lock);
        runtime = kind == CMD_PERL_SCRIPT ? g_perl_runtime : g_wine_runtime;
        pthread_mutex_unlock(&g_shim_lock);
        if (!runtime) {
            fprintf(stderr, "MacProcessShim: %s runtime unavailable for %s\n",
                    kind == CMD_PERL_SCRIPT ? "Perl" : "Pane Wine", base_name(resolved));
            return ENOTSUP;
        }
    }
    if (kind == CMD_UNSUPPORTED) {
        fprintf(stderr, "MacProcessShim: unsupported process %s\n", path ? path : "(null)");
        return ENOENT;
    }

    MacChildProc *proc = proc_alloc();
    if (!proc) return EAGAIN;

    ChildTask *t = calloc(1, sizeof *t);
    if (!t) {
        proc_finish(proc->pid, 127);
        return ENOMEM;
    }
    t->pid = proc->pid;
    t->kind = kind;
    t->runtime = runtime;
    snprintf(t->path, sizeof t->path, "%s", resolved);
    t->argv = dup_strv(eff_argv, &t->argc);
    extern char **environ;
    ChildTask *current = current_child_task();
    t->envp = dup_strv(envp ? envp : (current ? current->envp : environ), NULL);
    t->in_fd = (in_fd >= 0) ? dup_cloexec(in_fd) : -1;
    t->out_fd = (out_fd >= 0) ? dup_cloexec(out_fd) : -1;
    t->err_fd = (err_fd >= 0) ? dup_cloexec(err_fd) : -1;

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    if (kind == CMD_HELPER || runtime) pthread_attr_setstacksize(&attr, 16u << 20);
    pthread_t thr;
    int prc = pthread_create(&thr, &attr, child_worker, t);
    pthread_attr_destroy(&attr);
    if (prc != 0) {
        if (t->in_fd >= 0) close(t->in_fd);
        if (t->out_fd >= 0) close(t->out_fd);
        if (t->err_fd >= 0) close(t->err_fd);
        free_strv(t->argv);
        free_strv(t->envp);
        free(t);
        proc_finish(proc->pid, 127);
        return prc;
    }
    if (pid_out) *pid_out = proc->pid;
    return 0;
}

int MacProcessShimSpawn(pid_t *pid, const char *path, char *const argv[], char *const envp[],
                        int inFd, int outFd, int errFd) {
    if (!path || !argv || !argv[0]) return EINVAL;
    return launch_command_async(pid, path, argv, envp, inFd, outFd, errFd);
}

void MacProcessShimExitCommand(int status) {
    exit_helper_thread(status & 0xFF);
}

int MacProcessShimIsChild(pid_t pid) {
    if (pid <= 0) return 0;
    pthread_mutex_lock(&g_proc_lock);
    MacChildProc *p = proc_find_locked(pid);
    int live = p && p->done != 2;
    pthread_mutex_unlock(&g_proc_lock);
    return live;
}

// MARK: - posix_spawn & file actions

static FaRecord *fa_find_locked(const void *key, bool create) {
    if (!key) return NULL;
    FaRecord *empty = NULL;
    for (int i = 0; i < MAC_MAX_FA; i++) {
        if (g_fa[i].key == key) return &g_fa[i];
        if (!g_fa[i].key && !empty) empty = &g_fa[i];
    }
    if (create && empty) {
        memset(empty, 0, sizeof *empty);
        empty->key = key;
        return empty;
    }
    return NULL;
}

int MacShim_posix_spawn_file_actions_init(posix_spawn_file_actions_t *file_actions) {
    int rc = posix_spawn_file_actions_init(file_actions);
    if (rc == 0 && file_actions) {
        pthread_mutex_lock(&g_fa_lock);
        FaRecord *r = fa_find_locked(*file_actions, true);
        if (r) r->nops = 0;
        pthread_mutex_unlock(&g_fa_lock);
    }
    return rc;
}

int MacShim_posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *file_actions) {
    if (file_actions) {
        pthread_mutex_lock(&g_fa_lock);
        FaRecord *r = fa_find_locked(*file_actions, false);
        if (r) {
            for (int i = 0; i < r->nops; i++) free(r->ops[i].path);
            r->nops = 0;
            r->key = NULL;
        }
        pthread_mutex_unlock(&g_fa_lock);
    }
    return posix_spawn_file_actions_destroy(file_actions);
}

static void fa_record_op(posix_spawn_file_actions_t *file_actions, void *old_key, FaOp op) {
    if (!file_actions) return;
    void *new_key = *file_actions;
    pthread_mutex_lock(&g_fa_lock);
    FaRecord *r = old_key ? fa_find_locked(old_key, false) : NULL;
    if (!r) r = fa_find_locked(new_key, true);
    if (r) {
        // Darwin's posix_spawn_file_actions_add* reallocs *file_actions when growing beyond 2 ops.
        r->key = new_key;
        if (r->nops < MAC_MAX_FA_OPS) r->ops[r->nops++] = op;
        else free(op.path);
    } else {
        free(op.path);
    }
    pthread_mutex_unlock(&g_fa_lock);
}

int MacShim_posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *file_actions, int fildes, int newfildes) {
    void *old_key = file_actions ? *file_actions : NULL;
    int rc = posix_spawn_file_actions_adddup2(file_actions, fildes, newfildes);
    if (rc == 0) fa_record_op(file_actions, old_key, (FaOp){.kind = FA_DUP2, .fd1 = fildes, .fd2 = newfildes});
    return rc;
}

int MacShim_posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *file_actions, int fildes) {
    void *old_key = file_actions ? *file_actions : NULL;
    int rc = posix_spawn_file_actions_addclose(file_actions, fildes);
    if (rc == 0) fa_record_op(file_actions, old_key, (FaOp){.kind = FA_CLOSE, .fd1 = fildes});
    return rc;
}

int MacShim_posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *file_actions, int fildes, const char *path, int oflag, mode_t mode) {
    void *old_key = file_actions ? *file_actions : NULL;
    int rc = posix_spawn_file_actions_addopen(file_actions, fildes, path, oflag, mode);
    if (rc == 0) {
        fa_record_op(file_actions, old_key,
                     (FaOp){.kind = FA_OPEN, .fd1 = fildes, .path = path ? strdup(path) : NULL, .oflag = oflag, .mode = mode});
    }
    return rc;
}

int MacShim_posix_spawn(pid_t *pid,
                        const char *path,
                        const posix_spawn_file_actions_t *file_actions,
                        const posix_spawnattr_t *attrp,
                        char *const argv[],
                        char *const envp[]) {
    if (attrp) {
        short flags;
        int err = posix_spawnattr_getflags(attrp, &flags);
        if (err) return err;
        // A worker thread cannot replace the host process. In particular,
        // Wine requests SETEXEC to restart itself with a different page size.
        if (flags & POSIX_SPAWN_SETEXEC) return ENOTSUP;
    }
    int std_fds[3];
    inherited_standard_fds(std_fds);
    int opened[16];
    int nopened = 0;

    if (file_actions && *file_actions) {
        pthread_mutex_lock(&g_fa_lock);
        FaRecord *r = fa_find_locked(*file_actions, false);
        if (r) {
            for (int i = 0; i < r->nops; i++) {
                FaOp *op = &r->ops[i];
                if (op->kind == FA_DUP2) {
                    int src = (op->fd1 >= 0 && op->fd1 < 3) ? std_fds[op->fd1] : op->fd1;
                    if (op->fd2 >= 0 && op->fd2 < 3) std_fds[op->fd2] = src;
                } else if (op->kind == FA_CLOSE) {
                    if (op->fd1 >= 0 && op->fd1 < 3) std_fds[op->fd1] = -1;
                } else if (op->kind == FA_OPEN && op->path) {
                    int fd = open(op->path, op->oflag, op->mode);
                    if (fd >= 0) {
                        if (nopened < 16) opened[nopened++] = fd;
                        if (op->fd1 >= 0 && op->fd1 < 3) std_fds[op->fd1] = fd;
                    }
                }
            }
        }
        pthread_mutex_unlock(&g_fa_lock);
    }

    int err = launch_command_async(pid, path, argv, envp, std_fds[0], std_fds[1], std_fds[2]);
    for (int i = 0; i < nopened; i++) close(opened[i]);
    return err;
}

int MacShim_posix_spawnp(pid_t *pid,
                         const char *file,
                         const posix_spawn_file_actions_t *file_actions,
                         const posix_spawnattr_t *attrp,
                         char *const argv[],
                         char *const envp[]) {
    return MacShim_posix_spawn(pid, file, file_actions, attrp, argv, envp);
}

// MARK: - Virtual fork + dup2/close/execve/_exit

#define MAC_FORK_STACK_SAVE 16384

typedef struct {
    uint64_t x[11]; // x19..x29
    uint64_t lr;    // x30
    uint64_t sp;
    uint64_t d[8];  // d8..d15
} MacForkRegs;

typedef struct {
    int active;
    pid_t pid;
    int std_fds[3];
    int closed_std[3];
    int duped_temp[16];
    int nduped;
    char *cwd;
    MacForkRegs regs;
    size_t stack_len;
    uint8_t stack_buf[MAC_FORK_STACK_SAVE];
} MacForkCtx;

static _Thread_local MacForkCtx g_fork_ctx;

void mac_fork_begin(const MacForkRegs *regs) {
    MacForkCtx *c = &g_fork_ctx;
    memset(c, 0, sizeof *c);
    c->active = 1;
    c->pid = 0; // assigned at execve/_exit
    inherited_standard_fds(c->std_fds);
    c->regs = *regs;

    uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(pthread_self());
    size_t avail = (top > (uintptr_t)regs->sp) ? (size_t)(top - (uintptr_t)regs->sp) : 0;
    if (avail > MAC_FORK_STACK_SAVE) avail = MAC_FORK_STACK_SAVE;
    avail &= ~(size_t)7;
    c->stack_len = avail;
    if (avail) memcpy(c->stack_buf, (const void *)(uintptr_t)regs->sp, avail);
}

extern void mac_fork_resume_asm(const MacForkRegs *regs, void *dst_sp, const void *src_buf, size_t len, pid_t ret_pid) __attribute__((noreturn));

__asm__(
    ".text\n"
    ".p2align 2\n"
    ".globl _MacShim_fork\n"
    ".globl _MacShim_vfork\n"
    "_MacShim_fork:\n"
    "_MacShim_vfork:\n"
    "  mov x9, sp\n"
    "  sub sp, sp, #176\n"
    "  stp x19, x20, [sp, #0]\n"
    "  stp x21, x22, [sp, #16]\n"
    "  stp x23, x24, [sp, #32]\n"
    "  stp x25, x26, [sp, #48]\n"
    "  stp x27, x28, [sp, #64]\n"
    "  stp x29, x30, [sp, #80]\n"
    "  str x9, [sp, #96]\n"
    "  stp d8, d9, [sp, #104]\n"
    "  stp d10, d11, [sp, #120]\n"
    "  stp d12, d13, [sp, #136]\n"
    "  stp d14, d15, [sp, #152]\n"
    "  mov x0, sp\n"
    "  bl _mac_fork_begin\n"
    "  ldp d8, d9, [sp, #104]\n"
    "  ldp d10, d11, [sp, #120]\n"
    "  ldp d12, d13, [sp, #136]\n"
    "  ldp d14, d15, [sp, #152]\n"
    "  ldp x19, x20, [sp, #0]\n"
    "  ldp x21, x22, [sp, #16]\n"
    "  ldp x23, x24, [sp, #32]\n"
    "  ldp x25, x26, [sp, #48]\n"
    "  ldp x27, x28, [sp, #64]\n"
    "  ldp x29, x30, [sp, #80]\n"
    "  add sp, sp, #176\n"
    "  mov x0, #0\n"
    "  ret\n"
    ".p2align 2\n"
    ".globl _mac_fork_resume_asm\n"
    "_mac_fork_resume_asm:\n"
    "  cbz x3, 2f\n"
    "1:\n"
    "  ldr x9, [x2], #8\n"
    "  str x9, [x1], #8\n"
    "  subs x3, x3, #8\n"
    "  b.hi 1b\n"
    "2:\n"
    "  ldp d8, d9, [x0, #104]\n"
    "  ldp d10, d11, [x0, #120]\n"
    "  ldp d12, d13, [x0, #136]\n"
    "  ldp d14, d15, [x0, #152]\n"
    "  ldp x19, x20, [x0, #0]\n"
    "  ldp x21, x22, [x0, #16]\n"
    "  ldp x23, x24, [x0, #32]\n"
    "  ldp x25, x26, [x0, #48]\n"
    "  ldp x27, x28, [x0, #64]\n"
    "  ldp x29, x30, [x0, #80]\n"
    "  ldr x9, [x0, #96]\n"
    "  mov sp, x9\n"
    "  mov w0, w4\n"
    "  ret\n"
);

static int resolve_virtual_fd(int fd) {
    MacForkCtx *c = &g_fork_ctx;
    if (!c->active) return fd;
    if (fd >= 0 && fd < 3) return c->closed_std[fd] ? -1 : c->std_fds[fd];
    return fd;
}

int MacShim_close(int fd) {
    MacForkCtx *c = &g_fork_ctx;
    if (!c->active) return close(fd);
    if (fd >= 0 && fd < 3) c->closed_std[fd] = 1;
    // Never close parent FDs while inside virtual child setup.
    return 0;
}

int MacShim_dup(int fd) {
    MacForkCtx *c = &g_fork_ctx;
    if (!c->active) return dup(fd);
    return resolve_virtual_fd(fd);
}

int MacShim_dup2(int oldfd, int newfd) {
    MacForkCtx *c = &g_fork_ctx;
    if (!c->active) return dup2(oldfd, newfd);
    int real_old = resolve_virtual_fd(oldfd);
    if (real_old < 0) { errno = EBADF; return -1; }
    if (newfd >= 0 && newfd < 3) {
        c->std_fds[newfd] = real_old;
        c->closed_std[newfd] = 0;
        return newfd;
    }
    int d = dup2(real_old, newfd);
    if (d >= 0 && c->nduped < 16) c->duped_temp[c->nduped++] = d;
    return d;
}

int MacShim_chdir(const char *path) {
    MacForkCtx *c = &g_fork_ctx;
    if (!c->active) return chdir(path);
    free(c->cwd);
    c->cwd = path ? strdup(path) : NULL;
    return 0;
}

void MacShim__exit(int status) {
    MacForkCtx *c = &g_fork_ctx;
    if (!c->active) {
        pthread_mutex_lock(&g_shim_lock);
        MacProcessExitFallbackFn fn = g_exit_fallback;
        pthread_mutex_unlock(&g_shim_lock);
        if (fn) fn(status, __builtin_return_address(0));
        exit_helper_thread(status);
        _exit(status);
    }
    MacChildProc *proc = proc_alloc();
    pid_t pid = proc ? proc->pid : -1;
    if (proc) proc_finish(pid, status);
    for (int i = 0; i < c->nduped; i++) close(c->duped_temp[i]);
    free(c->cwd);
    c->cwd = NULL;
    c->active = 0;
    mac_fork_resume_asm(&c->regs, (void *)(uintptr_t)c->regs.sp, c->stack_buf, c->stack_len, pid);
}

int MacShim_execve(const char *path, char *const argv[], char *const envp[]) {
    MacForkCtx *c = &g_fork_ctx;
    int std_fds[3];
    inherited_standard_fds(std_fds);
    if (c->active) {
        for (int i = 0; i < 3; i++) {
            std_fds[i] = c->closed_std[i] ? -1 : c->std_fds[i];
        }
    }

    pid_t pid = 0;
    int err = launch_command_async(&pid, path, argv, envp, std_fds[0], std_fds[1], std_fds[2]);
    if (err != 0) {
        errno = err;
        return -1;
    }

    if (c->active) {
        for (int i = 0; i < c->nduped; i++) close(c->duped_temp[i]);
        free(c->cwd);
        c->cwd = NULL;
        c->active = 0;
        mac_fork_resume_asm(&c->regs, (void *)(uintptr_t)c->regs.sp, c->stack_buf, c->stack_len, pid);
    }

    int st = 0;
    MacShim_waitpid(pid, &st, 0);
    int status = WIFEXITED(st) ? WEXITSTATUS(st) : 127;
    exit_helper_thread(status);
    _exit(status);
}

int MacShim_execv(const char *path, char *const argv[]) {
    return MacShim_execve(path, argv, NULL);
}

int MacShim_execvp(const char *file, char *const argv[]) {
    return MacShim_execve(file, argv, NULL);
}

static int MacShim_execl(const char *path, const char *arg0, ...) {
    char *argv[64] = {(char *)arg0};
    va_list ap;
    va_start(ap, arg0);
    for (int i = 1; i < 63 && argv[i - 1]; i++) argv[i] = va_arg(ap, char *);
    va_end(ap);
    return MacShim_execve(path, argv, NULL);
}

static int MacShim_execle(const char *path, const char *arg0, ...) {
    char *argv[64] = {(char *)arg0};
    va_list ap;
    va_start(ap, arg0);
    int i = 1;
    for (; i < 63 && argv[i - 1]; i++) argv[i] = va_arg(ap, char *);
    char **envp = argv[i - 1] ? NULL : va_arg(ap, char **);
    va_end(ap);
    return MacShim_execve(path, argv, envp);
}

// MARK: - waitpid / wait / wait4 / waitid

pid_t MacShim_waitpid(pid_t pid, int *stat_loc, int options) {
    pthread_mutex_lock(&g_proc_lock);
    for (;;) {
        int any = 0;
        for (int i = 0; i < MAC_MAX_PROCS; i++) {
            MacChildProc *p = &g_procs[i];
            if (p->pid == 0 || p->done == 2) continue;
            if (pid > 0 && p->pid != pid) continue;
            any++;
            if (p->done == 1) {
                p->done = 2;
                pid_t ret = p->pid;
                if (stat_loc) *stat_loc = p->status;
                pthread_mutex_unlock(&g_proc_lock);
                return ret;
            }
        }
        if (!any) {
            pthread_mutex_unlock(&g_proc_lock);
            if (pid > 0 && pid < 90000) return waitpid(pid, stat_loc, options);
            errno = ECHILD;
            return -1;
        }
        if (options & WNOHANG) {
            pthread_mutex_unlock(&g_proc_lock);
            return 0;
        }
        pthread_cond_wait(&g_proc_cond, &g_proc_lock);
    }
}

static pid_t MacShim_wait(int *stat_loc) {
    return MacShim_waitpid(-1, stat_loc, 0);
}

static pid_t MacShim_wait4(pid_t pid, int *stat_loc, int options, struct rusage *rusage) {
    (void)rusage;
    return MacShim_waitpid(pid, stat_loc, options);
}

static int MacShim_waitid(idtype_t idtype, id_t id, siginfo_t *infop, int options) {
    if (idtype != P_PID) return waitid(idtype, id, infop, options);
    pthread_mutex_lock(&g_proc_lock);
    MacChildProc *p = proc_find_locked((pid_t)id);
    if (!p) {
        pthread_mutex_unlock(&g_proc_lock);
        return waitid(idtype, id, infop, options);
    }
    while (p->done == 0 && !(options & WNOHANG)) {
        pthread_cond_wait(&g_proc_cond, &g_proc_lock);
    }
    if (infop) memset(infop, 0, sizeof *infop);
    if (p->done == 1) {
        if (infop) {
            infop->si_signo = SIGCHLD;
            infop->si_code = CLD_EXITED;
            infop->si_pid = p->pid;
            infop->si_status = WEXITSTATUS(p->status);
        }
        if (!(options & WNOWAIT)) p->done = 2;
    }
    pthread_mutex_unlock(&g_proc_lock);
    return 0;
}

// MARK: - system / popen / pclose

int MacShim_system(const char *command) {
    if (!command) return 1;
    char *argv[] = {"/bin/sh", "-c", (char *)command, NULL};
    pid_t pid = 0;
    int std_fds[3];
    inherited_standard_fds(std_fds);
    int err = launch_command_async(&pid, "/bin/sh", argv, NULL, std_fds[0], std_fds[1], std_fds[2]);
    if (err != 0) {
        errno = err;
        return W_EXITCODE(127, 0);
    }
    int st = 0;
    MacShim_waitpid(pid, &st, 0);
    return st;
}

FILE *MacShim_popen(const char *command, const char *mode) {
    if (!command || !mode || (mode[0] != 'r' && mode[0] != 'w')) {
        errno = EINVAL;
        return NULL;
    }
    int fds[2];
    if (pipe(fds) != 0) return NULL;
    bool reading = (mode[0] == 'r');
    int std_fds[3];
    inherited_standard_fds(std_fds);
    int in_fd = reading ? std_fds[0] : fds[0];
    int out_fd = reading ? fds[1] : std_fds[1];
    char *argv[] = {"/bin/sh", "-c", (char *)command, NULL};
    pid_t pid = 0;
    int err = launch_command_async(&pid, "/bin/sh", argv, NULL, in_fd, out_fd, std_fds[2]);
    if (reading) close(fds[1]);
    else close(fds[0]);
    if (err != 0) {
        close(reading ? fds[0] : fds[1]);
        errno = err;
        return NULL;
    }
    FILE *stream = fdopen(reading ? fds[0] : fds[1], reading ? "r" : "w");
    if (!stream) {
        close(reading ? fds[0] : fds[1]);
        MacShim_waitpid(pid, NULL, 0);
        return NULL;
    }
    pthread_mutex_lock(&g_popen_lock);
    for (int i = 0; i < MAC_MAX_POPEN; i++) {
        if (!g_popen[i].stream) {
            g_popen[i].stream = stream;
            g_popen[i].pid = pid;
            break;
        }
    }
    pthread_mutex_unlock(&g_popen_lock);
    return stream;
}

int MacShim_pclose(FILE *stream) {
    if (!stream) { errno = EBADF; return -1; }
    pid_t pid = 0;
    pthread_mutex_lock(&g_popen_lock);
    for (int i = 0; i < MAC_MAX_POPEN; i++) {
        if (g_popen[i].stream == stream) {
            pid = g_popen[i].pid;
            g_popen[i].stream = NULL;
            g_popen[i].pid = 0;
            break;
        }
    }
    pthread_mutex_unlock(&g_popen_lock);
    if (!pid) return pclose(stream);
    fclose(stream);
    int st = 0;
    if (MacShim_waitpid(pid, &st, 0) < 0) return -1;
    return st;
}

// MARK: - Symbol Lookup Table (tl_loader + Mach-O rebind)

typedef struct {
    const char *name;
    void *fn;
} MacShimEntry;

static const MacShimEntry g_shim_table[] = {
    {"_fork", (void *)MacShim_fork},
    {"_vfork", (void *)MacShim_vfork},
    {"_execve", (void *)MacShim_execve},
    {"_execv", (void *)MacShim_execv},
    {"_execvp", (void *)MacShim_execvp},
    {"_execl", (void *)MacShim_execl},
    {"_execlp", (void *)MacShim_execl},
    {"_execle", (void *)MacShim_execle},
    {"_posix_spawn", (void *)MacShim_posix_spawn},
    {"_posix_spawnp", (void *)MacShim_posix_spawnp},
    {"_posix_spawn_file_actions_init", (void *)MacShim_posix_spawn_file_actions_init},
    {"_posix_spawn_file_actions_destroy", (void *)MacShim_posix_spawn_file_actions_destroy},
    {"_posix_spawn_file_actions_adddup2", (void *)MacShim_posix_spawn_file_actions_adddup2},
    {"_posix_spawn_file_actions_addclose", (void *)MacShim_posix_spawn_file_actions_addclose},
    {"_posix_spawn_file_actions_addopen", (void *)MacShim_posix_spawn_file_actions_addopen},
    {"_waitpid", (void *)MacShim_waitpid},
    {"_wait", (void *)MacShim_wait},
    {"_wait4", (void *)MacShim_wait4},
    {"_waitid", (void *)MacShim_waitid},
    {"_system", (void *)MacShim_system},
    {"_popen", (void *)MacShim_popen},
    {"_pclose", (void *)MacShim_pclose},
    {"_close", (void *)MacShim_close},
    {"_dup", (void *)MacShim_dup},
    {"_dup2", (void *)MacShim_dup2},
    {"_chdir", (void *)MacShim_chdir},
    {"__exit", (void *)MacShim__exit},
    {"__Exit", (void *)MacShim__exit},
};

void *MacProcessShimLookup(const char *symbol) {
    if (!symbol) return NULL;
    for (size_t i = 0; i < sizeof g_shim_table / sizeof *g_shim_table; i++) {
        if (!strcmp(symbol, g_shim_table[i].name)) return g_shim_table[i].fn;
    }
    return NULL;
}

// MARK: - Mach-O Rebinding for dlopen'd Simulator guests

static void MacShim_dyld_exit(int status) {
    if (g_fork_ctx.active) MacShim__exit(status);
    exit_helper_thread(status);
    exit(status);
}

static void *lookup_dyld_symbol(const char *symbol) {
    // tl_loader supplies its own exit handling. Only dyld-loaded guests use this hook.
    if (!strcmp(symbol, "_exit")) return (void *)MacShim_dyld_exit;
    return MacProcessShimLookup(symbol);
}

static void patch_pointer_slot(void **slot, void *replacement) {
    if (!slot || !replacement) return;
    if (*slot == replacement) return;
    vm_address_t page = (vm_address_t)slot & ~(vm_address_t)0x3FFF;
    vm_size_t psz = 0x4000;
    vm_prot_t old_prot = VM_PROT_READ | VM_PROT_WRITE;
    struct vm_region_submap_info_64 info;
    vm_address_t raddr = page;
    vm_size_t rsize = 0;
    natural_t depth = 0;
    mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
    if (vm_region_recurse_64(mach_task_self(), &raddr, &rsize, &depth, (vm_region_recurse_info_t)&info, &count) == KERN_SUCCESS) {
        old_prot = info.protection;
    }
    if (!(old_prot & VM_PROT_WRITE)) {
        if (vm_protect(mach_task_self(), page, psz, FALSE, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) return;
    }
    *slot = replacement;
    if (!(old_prot & VM_PROT_WRITE)) {
        vm_protect(mach_task_self(), page, psz, FALSE, old_prot);
    }
}

static uint64_t read_uleb(const uint8_t **pp, const uint8_t *end) {
    uint64_t v = 0;
    int shift = 0;
    const uint8_t *p = *pp;
    while (p < end) {
        uint8_t b = *p++;
        if (shift < 64) v |= (uint64_t)(b & 0x7F) << shift;
        shift += 7;
        if (!(b & 0x80)) break;
    }
    *pp = p;
    return v;
}

static int64_t read_sleb(const uint8_t **pp, const uint8_t *end) {
    int64_t v = 0;
    int shift = 0;
    uint8_t b = 0;
    const uint8_t *p = *pp;
    while (p < end) {
        b = *p++;
        v |= (int64_t)(b & 0x7F) << shift;
        shift += 7;
        if (!(b & 0x80)) break;
    }
    if (shift < 64 && (b & 0x40)) v |= -((int64_t)1 << shift);
    *pp = p;
    return v;
}

static const struct segment_command_64 *seg_by_index(const struct mach_header_64 *mh, int index) {
    const uint8_t *p = (const uint8_t *)(mh + 1);
    int k = 0;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const void *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            if (k == index) return (const struct segment_command_64 *)lc;
            k++;
        }
        p += lc->cmdsize;
    }
    return NULL;
}

static void rebind_dyld_info_stream(const struct mach_header_64 *mh, intptr_t slide,
                                    const uint8_t *p, const uint8_t *end, bool lazy) {
    int seg = -1;
    uint64_t off = 0;
    const char *sym = "";
    while (p < end) {
        uint8_t b = *p++, op = b & BIND_OPCODE_MASK, imm = b & BIND_IMMEDIATE_MASK;
        uint64_t count = 0, skip = 0;
        switch (op) {
        case BIND_OPCODE_DONE: if (!lazy) return; break;
        case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM: break;
        case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB: read_uleb(&p, end); break;
        case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM: break;
        case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM:
            sym = (const char *)p;
            p += strlen(sym) + 1;
            break;
        case BIND_OPCODE_SET_TYPE_IMM: break;
        case BIND_OPCODE_SET_ADDEND_SLEB: read_sleb(&p, end); break;
        case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: seg = imm; off = read_uleb(&p, end); break;
        case BIND_OPCODE_ADD_ADDR_ULEB: off += read_uleb(&p, end); break;
        case BIND_OPCODE_DO_BIND: count = 1; skip = 0; goto bind_it;
        case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB: count = 1; skip = read_uleb(&p, end); goto bind_it;
        case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED: count = 1; skip = imm * 8ull; goto bind_it;
        case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB:
            count = read_uleb(&p, end); skip = read_uleb(&p, end);
        bind_it: {
            void *rep = lookup_dyld_symbol(sym);
            const struct segment_command_64 *sc = seg >= 0 ? seg_by_index(mh, seg) : NULL;
            for (uint64_t i = 0; i < count; i++) {
                if (rep && sc) {
                    void **slot = (void **)(uintptr_t)(sc->vmaddr + slide + off);
                    patch_pointer_slot(slot, rep);
                }
                off += 8 + skip;
            }
            break;
        }
        default: return;
        }
    }
}

static const uint8_t *find_arm64_slice_in_file(const uint8_t *map, size_t len, size_t *slice_len) {
    if (len < sizeof(struct mach_header_64)) return NULL;
    uint32_t magic = *(const uint32_t *)map;
    if (magic == MH_MAGIC_64) { *slice_len = len; return map; }
    if (magic == FAT_CIGAM || magic == FAT_MAGIC || magic == FAT_CIGAM_64 || magic == FAT_MAGIC_64) {
        bool swap = (magic == FAT_CIGAM || magic == FAT_CIGAM_64);
        bool wide = (magic == FAT_CIGAM_64 || magic == FAT_MAGIC_64);
        const struct fat_header *fh = (const void *)map;
        uint32_t n = swap ? OSSwapInt32(fh->nfat_arch) : fh->nfat_arch;
        for (uint32_t i = 0; i < n; i++) {
            uint32_t cpu = 0, sub = 0;
            uint64_t off = 0, sz = 0;
            if (wide) {
                const struct fat_arch_64 *a = (const void *)(map + sizeof(*fh) + i * sizeof(*a));
                cpu = swap ? OSSwapInt32(a->cputype) : a->cputype;
                sub = swap ? OSSwapInt32(a->cpusubtype) : a->cpusubtype;
                off = swap ? OSSwapInt64(a->offset) : a->offset;
                sz  = swap ? OSSwapInt64(a->size) : a->size;
            } else {
                const struct fat_arch *a = (const void *)(map + sizeof(*fh) + i * sizeof(*a));
                cpu = swap ? OSSwapInt32(a->cputype) : a->cputype;
                sub = swap ? OSSwapInt32(a->cpusubtype) : a->cpusubtype;
                off = swap ? OSSwapInt32(a->offset) : a->offset;
                sz  = swap ? OSSwapInt32(a->size) : a->size;
            }
            if (cpu == CPU_TYPE_ARM64 && (sub & ~CPU_SUBTYPE_MASK) <= CPU_SUBTYPE_ARM64_V8 && off + sz <= len) {
                *slice_len = (size_t)sz;
                return map + off;
            }
        }
    }
    return NULL;
}

static void rebind_chained_from_file(const struct mach_header_64 *mh, intptr_t slide,
                                     const struct linkedit_data_command *chained) {
    Dl_info info = {0};
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    int fd = open(info.dli_fname, O_RDONLY);
    if (fd < 0) return;
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size <= 0) { close(fd); return; }
    uint8_t *fmap = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (fmap == MAP_FAILED) return;

    size_t slen = 0;
    const uint8_t *slice = find_arm64_slice_in_file(fmap, (size_t)st.st_size, &slen);
    if (!slice || chained->dataoff + chained->datasize > slen) {
        munmap(fmap, (size_t)st.st_size);
        return;
    }

    const uint8_t *data = slice + chained->dataoff;
    const struct dyld_chained_fixups_header *h = (const void *)data;
    if (h->fixups_version != 0 || h->symbols_format != 0 || !h->imports_count) {
        munmap(fmap, (size_t)st.st_size);
        return;
    }
    const char *syms = (const char *)data + h->symbols_offset;
    const uint8_t *imp = data + h->imports_offset;
    void **targets = calloc(h->imports_count, sizeof(void *));
    bool any = false;
    if (targets) {
        for (uint32_t i = 0; i < h->imports_count; i++) {
            uint32_t name_off = 0;
            if (h->imports_format == DYLD_CHAINED_IMPORT) {
                name_off = ((const struct dyld_chained_import *)(imp + 4 * i))->name_offset;
            } else if (h->imports_format == DYLD_CHAINED_IMPORT_ADDEND) {
                name_off = ((const struct dyld_chained_import_addend *)(imp + 8 * i))->name_offset;
            } else if (h->imports_format == DYLD_CHAINED_IMPORT_ADDEND64) {
                name_off = ((const struct dyld_chained_import_addend64 *)(imp + 16 * i))->name_offset;
            } else break;
            void *rep = lookup_dyld_symbol(syms + name_off);
            if (rep) { targets[i] = rep; any = true; }
        }
    }
    if (any) {
        const struct dyld_chained_starts_in_image *starts = (const void *)(data + h->starts_offset);
        for (uint32_t s = 0; s < starts->seg_count; s++) {
            if (!starts->seg_info_offset[s]) continue;
            const struct dyld_chained_starts_in_segment *seg =
                (const void *)((const uint8_t *)starts + starts->seg_info_offset[s]);
            if (seg->pointer_format != DYLD_CHAINED_PTR_64 && seg->pointer_format != DYLD_CHAINED_PTR_64_OFFSET) continue;
            const struct segment_command_64 *sc = seg_by_index(mh, (int)s);
            if (!sc) continue;
            for (uint32_t pg = 0; pg < seg->page_count; pg++) {
                uint16_t off = seg->page_start[pg];
                if (off == DYLD_CHAINED_PTR_START_NONE) continue;
                uint64_t page_rel = (uint64_t)pg * seg->page_size + off;
                const uint8_t *floc = slice + seg->segment_offset + page_rel;
                for (;;) {
                    uint64_t raw = 0;
                    memcpy(&raw, floc, 8);
                    if (raw >> 63) {
                        uint32_t ordinal = raw & 0xFFFFFF;
                        if (ordinal < h->imports_count && targets[ordinal]) {
                            void **mem_slot = (void **)(uintptr_t)(sc->vmaddr + slide + page_rel);
                            patch_pointer_slot(mem_slot, targets[ordinal]);
                        }
                    }
                    uint64_t next = (raw >> 51) & 0xFFF;
                    if (!next) break;
                    page_rel += next * 4;
                    floc += next * 4;
                }
            }
        }
    }
    free(targets);
    munmap(fmap, (size_t)st.st_size);
}

static void rebind_dysymtab(const struct mach_header_64 *mh, intptr_t slide,
                            const struct segment_command_64 *linkedit,
                            const struct symtab_command *symtab,
                            const struct dysymtab_command *dysymtab) {
    if (!linkedit || !symtab || !dysymtab) return;
    uintptr_t base = (uintptr_t)linkedit->vmaddr + (uintptr_t)slide - linkedit->fileoff;
    const struct nlist_64 *syms = (const void *)(base + symtab->symoff);
    const char *strs = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const void *)(base + dysymtab->indirectsymoff);

    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const void *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const void *)lc;
            const struct section_64 *secs = (const void *)(sc + 1);
            for (uint32_t j = 0; j < sc->nsects; j++) {
                uint32_t type = secs[j].flags & SECTION_TYPE;
                if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
                uint32_t nptrs = (uint32_t)(secs[j].size / sizeof(void *));
                void **ptrs = (void **)(uintptr_t)(secs[j].addr + slide);
                for (uint32_t k = 0; k < nptrs; k++) {
                    uint32_t symidx = indirect[secs[j].reserved1 + k];
                    if (symidx == INDIRECT_SYMBOL_ABS || symidx == INDIRECT_SYMBOL_LOCAL ||
                        symidx == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS) || symidx >= symtab->nsyms) continue;
                    const char *name = strs + syms[symidx].n_un.n_strx;
                    void *rep = lookup_dyld_symbol(name);
                    if (rep) patch_pointer_slot(&ptrs[k], rep);
                }
            }
        }
        p += lc->cmdsize;
    }
}

void MacProcessShimRebindImage(const void *mh_ptr, intptr_t slide) {
    const struct mach_header_64 *mh = (const struct mach_header_64 *)mh_ptr;
    if (!mh || mh->magic != MH_MAGIC_64) return;

    const struct segment_command_64 *linkedit = NULL;
    const struct dyld_info_command *dyldinfo = NULL;
    const struct linkedit_data_command *chained = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;

    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const void *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sc = (const void *)lc;
            if (!strcmp(sc->segname, "__LINKEDIT")) linkedit = sc;
        } else if (lc->cmd == LC_DYLD_INFO || lc->cmd == LC_DYLD_INFO_ONLY) {
            dyldinfo = (const void *)lc;
        } else if (lc->cmd == LC_DYLD_CHAINED_FIXUPS) {
            chained = (const void *)lc;
        } else if (lc->cmd == LC_SYMTAB) {
            symtab = (const void *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab = (const void *)lc;
        }
        p += lc->cmdsize;
    }

    if (chained) {
        rebind_chained_from_file(mh, slide, chained);
        return;
    }
    if (dyldinfo && linkedit) {
        uintptr_t base = (uintptr_t)linkedit->vmaddr + (uintptr_t)slide - linkedit->fileoff;
        if (dyldinfo->bind_size) {
            const uint8_t *s = (const uint8_t *)(base + dyldinfo->bind_off);
            rebind_dyld_info_stream(mh, slide, s, s + dyldinfo->bind_size, false);
        }
        if (dyldinfo->lazy_bind_size) {
            const uint8_t *s = (const uint8_t *)(base + dyldinfo->lazy_bind_off);
            rebind_dyld_info_stream(mh, slide, s, s + dyldinfo->lazy_bind_size, true);
        }
    }
    if (symtab && dysymtab && linkedit) {
        rebind_dysymtab(mh, slide, linkedit, symtab, dysymtab);
    }
}

static void on_dyld_add_image(const struct mach_header *mh, intptr_t slide) {
    pthread_mutex_lock(&g_shim_lock);
    char root[PATH_MAX];
    snprintf(root, sizeof root, "%s", g_bundle_root);
    pthread_mutex_unlock(&g_shim_lock);
    if (!root[0]) return;

    Dl_info info = {0};
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    char real[PATH_MAX];
    const char *path = realpath(info.dli_fname, real) ? real : info.dli_fname;
    size_t rlen = strlen(root);
    if (strncmp(path, root, rlen) == 0 && (path[rlen] == '/' || path[rlen] == '\0')) {
        MacProcessShimRebindImage(mh, slide);
    }
}

static void register_dyld_callback(void) {
    _dyld_register_func_for_add_image(on_dyld_add_image);
}

void MacProcessShimInstallForBundle(const char *appBundlePath) {
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    if (appBundlePath && *appBundlePath) {
        char real[PATH_MAX];
        const char *rp = realpath(appBundlePath, real) ? real : appBundlePath;
        pthread_mutex_lock(&g_shim_lock);
        snprintf(g_bundle_root, sizeof g_bundle_root, "%s", rp);
        pthread_mutex_unlock(&g_shim_lock);
    }
    pthread_once(&once, register_dyld_callback);
}
