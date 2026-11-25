// SPDX-License-Identifier: GPL-3.0-or-later
#include "triptych_bridge.h"
#include <sys/socket.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <pthread.h>
#include <resolv.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

// csops is a private-but-stable libsystem call (used by every iOS JIT app).
extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
#define CS_OPS_STATUS 0
#define CS_DEBUGGED 0x10000000

bool tp_process_is_debugged(void) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) return false;
    return (flags & CS_DEBUGGED) != 0;
}

#if TRIPTYCH_HAS_LINUX
extern void real_tty_set_host_fd(int fd);
extern void real_tty_set_host_size(unsigned short cols, unsigned short rows);
extern int tp_linux_cli_main(int argc, char *const argv[]);

static atomic_bool g_started, g_exited;
static atomic_int g_status;
static char *g_argv[6];

// main.c/xX_main_Xx.h call exit() when the guest's PID 1 exits; the build
// renames that call to this, so the guest ends without killing the app.
void tp_linux_guest_exit(int code) {
    atomic_store(&g_status, code);
    atomic_store(&g_exited, true);
    pthread_exit(NULL);
}

static void *linux_thread(void *arg) {
    (void)arg;
    int rc = tp_linux_cli_main(5, g_argv);
    // Returning means startup failed (main returns only on error).
    atomic_store(&g_status, rc);
    atomic_store(&g_exited, true);
    return NULL;
}

int tp_linux_start(const char *rootfs, int *master_fd) {
    if (!rootfs || !master_fd) return -EINVAL;
    if (atomic_exchange(&g_started, true)) return -EBUSY;
    // Use a host pty where available. The iOS device sandbox rejects posix_openpt.
    int m = -1, s = -1;
    bool pty = !getenv("TRIPTYCH_LINUX_NO_PTY");
    if (pty) {
        m = posix_openpt(O_RDWR | O_NOCTTY);
        const char *slave = (m >= 0 && !grantpt(m) && !unlockpt(m)) ? ptsname(m) : NULL;
        if (slave) s = open(slave, O_RDWR | O_NOCTTY);
        if (s < 0) {
            fprintf(stderr, "linux: no pseudo-terminal (%s); using a socket pair for the console\n", strerror(errno ? errno : EIO));
            if (m >= 0) close(m);
            m = -1; pty = false;
        }
    }
    if (pty) {
        struct winsize ws = { .ws_row = 40, .ws_col = 80 };
        ioctl(m, TIOCSWINSZ, &ws);
    } else {
        int sv[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
            int e = errno;
            atomic_store(&g_started, false);
            return -e;
        }
        m = sv[0];
        s = sv[1];
        int no_sigpipe = 1;
        if (setsockopt(m, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) != 0 ||
            setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe)) != 0) {
            int e = errno;
            close(s);
            close(m);
            atomic_store(&g_started, false);
            return -e;
        }
    }
    fprintf(stderr, "linux: console on a %s\n", pty ? "pseudo-terminal" : "socket pair");
    char *root_copy = strdup(rootfs);
    if (!root_copy) { close(s); close(m); atomic_store(&g_started, false); return -ENOMEM; }
    // Give the engine the slave directly. Other engines keep the process's standard streams.
    real_tty_set_host_fd(s);
    // -t: the engine makes a guest tty over a non-terminal host console (the socket pair when there is no pty).
    g_argv[0] = "ish"; g_argv[1] = pty ? "-f" : "-tf"; g_argv[2] = root_copy;
    g_argv[3] = "/bin/sh"; g_argv[4] = "-l"; g_argv[5] = NULL;
    pthread_attr_t a; pthread_attr_init(&a);
    pthread_attr_setstacksize(&a, 8 << 20);
    pthread_t t;
    int rc = pthread_create(&t, &a, linux_thread, NULL);
    pthread_attr_destroy(&a);
    if (rc) {
        real_tty_set_host_fd(-1);
        close(s);
        free(root_copy);
        g_argv[2] = NULL;
        close(m);
        atomic_store(&g_started, false);
        return -rc;
    }
    pthread_detach(t);
    *master_fd = m;
    return 0;
}

void tp_linux_resize(int master_fd, uint16_t cols, uint16_t rows) {
    if (atomic_load(&g_exited)) return;
    struct winsize ws = { .ws_col = cols, .ws_row = rows };
    (void)ioctl(master_fd, TIOCSWINSZ, &ws);
    // Keep the guest tty in sync in both cases. A socket has no host winsize,
    // and the embedded pty driver only reads the host's winsize at tty init.
    real_tty_set_host_size(cols, rows);
}

bool tp_linux_has_exited(int *status) {
    if (status) *status = atomic_load(&g_status);
    return atomic_load(&g_exited);
}
bool tp_linux_available(void) { return true; }

#include "../../../upstreams/linuxrunner/tools/fakefs.h"
#include "../../../upstreams/linuxrunner/deps/zstd/lib/zstd.h"
struct tp_import_ctx { void *cookie; void (*cb)(void *, double); };
static void tp_import_progress(void *cookie, double p, const char *msg, bool *cancel) {
    (void)msg; *cancel = false;
    struct tp_import_ctx *c = cookie;
    if (c->cb && p >= 0) c->cb(c->cookie, p);
}

static bool tp_is_zstd_file(const char *path, off_t *size_out) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return false;
    struct stat st;
    if (size_out) *size_out = (fstat(fd, &st) == 0) ? st.st_size : 0;
    uint8_t buf[4];
    ssize_t n = read(fd, buf, sizeof(buf));
    close(fd);
    if (n != 4) return false;
    uint32_t magic = (uint32_t)buf[0] | ((uint32_t)buf[1] << 8) | ((uint32_t)buf[2] << 16) | ((uint32_t)buf[3] << 24);
    return magic == 0xFD2FB528u || (magic & 0xFFFFFFF0u) == 0x184D2A50u;
}

struct tp_zstd_pipe_ctx {
    int in_fd;
    int out_fd;
    off_t total_bytes;
    struct tp_import_ctx *progress_ctx;
    bool ok;
    char err[256];
};

static bool tp_write_all(int fd, const uint8_t *buf, size_t len) {
    size_t off = 0;
    while (off < len) {
        ssize_t w = write(fd, buf + off, len - off);
        if (w < 0) {
            if (errno == EINTR) continue;
            return false;
        }
        off += (size_t)w;
    }
    return true;
}

static void *tp_zstd_pipe_worker(void *arg) {
    struct tp_zstd_pipe_ctx *ctx = arg;
    size_t in_cap = ZSTD_DStreamInSize();
    size_t out_cap = ZSTD_DStreamOutSize();
    uint8_t *in_buf = malloc(in_cap);
    uint8_t *out_buf = malloc(out_cap);
    ZSTD_DCtx *dctx = ZSTD_createDCtx();
    if (!in_buf || !out_buf || !dctx) {
        snprintf(ctx->err, sizeof(ctx->err), "zstd out of memory");
        goto done;
    }
    bool frame_done = true;
    off_t total_read = 0;
    for (;;) {
        ssize_t r = read(ctx->in_fd, in_buf, in_cap);
        if (r < 0) {
            if (errno == EINTR) continue;
            snprintf(ctx->err, sizeof(ctx->err), "read error: %s", strerror(errno));
            goto done;
        }
        if (r == 0) {
            if (!frame_done) {
                snprintf(ctx->err, sizeof(ctx->err), "truncated zstd stream");
                goto done;
            }
            ctx->ok = true;
            goto done;
        }
        total_read += r;
        if (ctx->total_bytes > 0 && ctx->progress_ctx && ctx->progress_ctx->cb) {
            ctx->progress_ctx->cb(ctx->progress_ctx->cookie, (double)total_read / (double)ctx->total_bytes);
        }
        ZSTD_inBuffer input = { in_buf, (size_t)r, 0 };
        size_t ret = 0;
        ZSTD_outBuffer output;
        do {
            output.dst = out_buf;
            output.size = out_cap;
            output.pos = 0;
            ret = ZSTD_decompressStream(dctx, &output, &input);
            if (ZSTD_isError(ret)) {
                snprintf(ctx->err, sizeof(ctx->err), "zstd decode error: %s", ZSTD_getErrorName(ret));
                goto done;
            }
            frame_done = (ret == 0);
            if (output.pos > 0 && !tp_write_all(ctx->out_fd, out_buf, output.pos)) {
                snprintf(ctx->err, sizeof(ctx->err), "pipe write error: %s", strerror(errno));
                goto done;
            }
        } while (input.pos < input.size || (ret > 0 && output.pos == out_cap));
    }
done:
    close(ctx->out_fd);
    close(ctx->in_fd);
    if (dctx) ZSTD_freeDCtx(dctx);
    free(in_buf);
    free(out_buf);
    return NULL;
}

int tp_linux_import(const char *archive, const char *fsdir, void *cookie,
                    void (*progress)(void *, double), char *errbuf, int errlen) {
    struct tp_import_ctx ctx = { cookie, progress };
    struct fakefsify_error err = {0};
    struct progress p = { &ctx, tp_import_progress };
    off_t total_bytes = 0;
    if (tp_is_zstd_file(archive, &total_bytes)) {
        int in_fd = open(archive, O_RDONLY);
        if (in_fd < 0) {
            snprintf(errbuf, errlen, "%s", strerror(errno));
            return -1;
        }
        int fds[2];
        if (pipe(fds) != 0) {
            int e = errno;
            close(in_fd);
            snprintf(errbuf, errlen, "%s", strerror(e));
            return -1;
        }
        fcntl(fds[1], F_SETNOSIGPIPE, 1);
        struct tp_zstd_pipe_ctx zctx = {
            .in_fd = in_fd,
            .out_fd = fds[1],
            .total_bytes = total_bytes,
            .progress_ctx = &ctx,
            .ok = false,
            .err = {0},
        };
        pthread_t thr;
        int prc = pthread_create(&thr, NULL, tp_zstd_pipe_worker, &zctx);
        if (prc != 0) {
            close(in_fd);
            close(fds[0]);
            close(fds[1]);
            snprintf(errbuf, errlen, "%s", strerror(prc));
            return -1;
        }
        bool ok = fakefs_import_fd(fds[0], fsdir, &err, p);
        close(fds[0]);
        pthread_join(thr, NULL);
        if (ok && zctx.ok) return 0;
        if (!ok) {
            snprintf(errbuf, errlen, "%s (type %d, code %d, line %d)", err.message ? err.message : "import failed", (int)err.type, err.code, err.line);
            free(err.message);
        } else {
            snprintf(errbuf, errlen, "%s", zctx.err[0] ? zctx.err : "zstd import failed");
        }
        return -1;
    }
    if (fakefs_import(archive, fsdir, &err, p)) return 0;
    snprintf(errbuf, errlen, "%s (type %d, code %d, line %d)", err.message ? err.message : "import failed", (int)err.type, err.code, err.line);
    free(err.message);
    return -1;
}

int tp_write_host_resolv_conf(const char *path) {
    if (!path || !path[0]) return -1;
    FILE *fp = fopen(path, "w");
    if (!fp) return -1;
    struct __res_state res;
    memset(&res, 0, sizeof(res));
    int wrote = 0;
    if (res_ninit(&res) == 0) {
        union res_sockaddr_union servers[10];
        int count = res_getservers(&res, servers, 10);
        for (int i = 0; i < count && wrote < 3; i++) {
            const struct sockaddr *sa = (const struct sockaddr *)&servers[i];
            if ((sa->sa_family != AF_INET && sa->sa_family != AF_INET6)) continue;
            socklen_t salen = sa->sa_family == AF_INET ? (socklen_t)sizeof(struct sockaddr_in) : (socklen_t)sizeof(struct sockaddr_in6);
            char host[NI_MAXHOST];
            if (getnameinfo(sa, salen, host, sizeof(host), NULL, 0, NI_NUMERICHOST) != 0) continue;
            // Skip loopback stub addresses (guest lacks host's local DNS daemon) and scoped link-local addresses.
            if (strncmp(host, "127.", 4) == 0 || strcmp(host, "::1") == 0 || strchr(host, '%') != NULL) continue;
            fprintf(fp, "nameserver %s\n", host);
            wrote++;
        }
        res_ndestroy(&res);
    }
    if (wrote == 0) {
        fputs("nameserver 1.1.1.1\nnameserver 8.8.8.8\n", fp);
    }
    return fclose(fp) == 0 ? 0 : -1;
}
#else
int tp_linux_import(const char *archive, const char *fsdir, void *cookie,
                    void (*progress)(void *, double), char *errbuf, int errlen) {
    (void)archive; (void)fsdir; (void)cookie; (void)progress; snprintf(errbuf, errlen, "Linux engine not built"); return -1;
}
int tp_linux_start(const char *rootfs, int *master_fd) { (void)rootfs; (void)master_fd; return -ENOSYS; }
void tp_linux_resize(int master_fd, uint16_t cols, uint16_t rows) { (void)master_fd; (void)cols; (void)rows; }
bool tp_linux_has_exited(int *status) { if (status) *status = 0; return false; }
bool tp_linux_available(void) { return false; }
int tp_write_host_resolv_conf(const char *path) { (void)path; return -1; }
#endif

#if TRIPTYCH_HAS_MACOS
#include "henge-vm.h"
bool tp_macos_available(void) { return true; }
int tp_macos_selftest(const char *dir, char *msg, int msglen) {
    char path[1024];
    snprintf(path, sizeof path, "%s/selftest-aux.img", dir);
    unlink(path);
    int rc = henge_make_aux(path);
    struct stat st;
    long size = (stat(path, &st) == 0) ? (long)st.st_size : -1;
    snprintf(msg, msglen, "henge_make_aux=%d size=%ld debugged=%d", rc, size, tp_process_is_debugged());
    return (rc == 0 && size > 0) ? 0 : -1;
}
#include "henge-ios-jit.h"
#include "henge-tl.h"
HengeDualMapping *henge_ios_jit_get_mapping(void);
int tp_macos_run_program(const char *path, const char *out_path, char *msg, int msglen) {
    henge_ios_jit_install_trap_handler();
    bool mapjit = henge_ios_jit_mapjit_works();
    HengeDualMapping *m = henge_ios_jit_get_mapping();
    if (!m || !m->rx_addr) {
        if (!henge_ios_jit_prewarm_self((size_t)512 << 20)) {
            snprintf(msg, msglen, "no executable memory (mapjit=%d, debugged=%d)", mapjit, tp_process_is_debugged());
            return -1;
        }
    }
    const char *route = henge_ios_jit_self_route();
    char err[512] = "";
    int rc = henge_tl_run(path, out_path, err, sizeof err);
    snprintf(msg, msglen, "jit route=%s mapjit=%d rc=%d %s", route ? route : "debugger", mapjit, rc, err);
    return rc;
}
#else
int tp_macos_run_program(const char *path, const char *out_path, char *msg, int msglen) {
    (void)path; (void)out_path; snprintf(msg, msglen, "not built"); return -1;
}
bool tp_macos_available(void) { return false; }
int tp_macos_selftest(const char *dir, char *msg, int msglen) { (void)dir; snprintf(msg, msglen, "not built"); return -1; }
#endif

// ---- Windows engine: hold Madeira's fixed address range from launch ----
// Madeira's madeira_early_va_claim (JITAllocator.c) reserves 0x140000000 (128 MB window + up to 1 GB pool for
// FEX's code cache) in a constructor, i.e. before main in Madeira's own app. Here MadeiraRuntime is dlopened
// later, when other mappings may have landed there, so Triptych reserves the same range (same sizes, same
// no-overwrite rule) at launch and releases it just before the dlopen.
#include <mach/mach.h>
static vm_address_t g_hold_base, g_hold_size;

__attribute__((constructor(101))) static void tp_hold_madeira_va(void) {
    const vm_address_t win = 0x140000000ul, winsz = 0x8000000ul;
    vm_address_t a = win;
    if (vm_allocate(mach_task_self(), &a, winsz, VM_FLAGS_FIXED) != KERN_SUCCESS || a != win) return;
    vm_size_t pool = 0;
    for (vm_size_t sz = 1024ul << 20; sz >= (256ul << 20); sz -= (16ul << 20)) {
        vm_address_t p = win + winsz;
        if (vm_allocate(mach_task_self(), &p, sz, VM_FLAGS_FIXED) == KERN_SUCCESS && p == win + winsz) { pool = sz; break; }
    }
    vm_protect(mach_task_self(), win, winsz + pool, 0, VM_PROT_NONE);
    g_hold_base = win; g_hold_size = winsz + pool;
}

void tp_release_madeira_va(void) {
    if (!g_hold_size) return;
    vm_deallocate(mach_task_self(), g_hold_base, g_hold_size);
    g_hold_size = 0;
}
