// SPDX-License-Identifier: GPL-3.0-or-later
#import "x86pc_host.h"
#import "triptych_bridge.h"
#include <dlfcn.h>
#include <errno.h>
#include <getopt.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>

static int g_hmp_port, g_qmp_port;

static void *g_qemu_handle = NULL;      // whichever QEMU framework was dlopen'ed first in this process
static X86PCBuild g_qemu_build;
static int (*g_qemu_main_loop)(void);
static void (*g_qemu_init)(int, char **);
static void (*g_qemu_cleanup)(int);
static int g_argc;
static char **g_argv;
static volatile bool g_running = false;
static pthread_t g_thread;
static volatile bool g_joinable = false;     // g_thread is started and not yet joined

// Triptych display backend entry points (engines/x86pc/patches), resolved from the QEMU framework with dlsym.
static size_t (*g_t_copy)(void *, size_t, int *, int *, int *, uint64_t *);
static int (*g_t_key_usb)(int, int);
static void (*g_t_pointer_abs)(int, int, int, int, unsigned);
static void (*g_t_shutdown)(void);

static NSString *framework_name(X86PCBuild build) {
    return build == X86PCBuildTCTI ? @"qemu-x86_64-softmmu-tcti" : @"qemu-x86_64-softmmu";
}

static NSString *framework_binary(NSString *name) {
    return [[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:
             [NSString stringWithFormat:@"%@.framework", name]] stringByAppendingPathComponent:name];
}

static void set_error(char *err, size_t errlen, NSString *msg) {
    if (err && errlen) strlcpy(err, msg.UTF8String, errlen);
}

X86PCBuild x86pc_host_build_for_process(void) {
#if TARGET_OS_SIMULATOR
    return X86PCBuildJIT;
#else
    return tp_process_is_debugged() ? X86PCBuildJIT : X86PCBuildTCTI;
#endif
}

X86PCBuild x86pc_host_build_jit(void) { return X86PCBuildJIT; }
X86PCBuild x86pc_host_build_tcti(void) { return X86PCBuildTCTI; }

bool x86pc_host_build_bundled(X86PCBuild build) {
    return [NSFileManager.defaultManager fileExistsAtPath:framework_binary(framework_name(build))];
}

/* qemu-img's shared library exports main(), so it runs in-process with its own argv. */
struct qimg_job { int argc; char **argv; int status; void *handle; };

static void *qimg_thread(void *p) {
    struct qimg_job *j = p;
    int (*qmain)(int, char **) = dlsym(j->handle, "main");
    // qemu-img's entry point normally starts in a new process with a clean getopt cursor.
    optind = 1;
    optreset = 1;
    j->status = qmain ? qmain(j->argc, j->argv) : -1;
    return NULL;
}

int x86pc_host_create_qcow2(const char *path, uint64_t bytes, char *err, size_t errlen) {
    NSString *bin = framework_binary(@"qemu-img");
    void *h = dlopen(bin.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!h) { set_error(err, errlen, [NSString stringWithFormat:@"qemu-img framework missing: %s", dlerror()]); return -1; }
    NSString *size = [NSString stringWithFormat:@"%llu", (unsigned long long)bytes];
    NSArray<NSString *> *a = @[@"qemu-img", @"create", @"-f", @"qcow2", [NSString stringWithUTF8String:path], size];
    char **argv = calloc(a.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < a.count; i++) argv[i] = strdup(a[i].UTF8String);
    struct qimg_job job = { (int)a.count, argv, -1, h };
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 8 << 20);
    pthread_t t;
    if (pthread_create(&t, &at, qimg_thread, &job) != 0) { set_error(err, errlen, @"cannot start qemu-img"); return -1; }
    pthread_join(t, NULL);
    for (NSUInteger i = 0; i < a.count; i++) free(argv[i]);
    free(argv);
    if (job.status != 0) set_error(err, errlen, [NSString stringWithFormat:@"qemu-img create failed (%d)", job.status]);
    return job.status;
}

static void *qemu_thread(void *unused) {
    (void)unused;
    g_qemu_init(g_argc, g_argv);              // returns with the BQL held, which qemu_main_loop expects
    int status = g_qemu_main_loop();
    g_qemu_cleanup(status);
    g_running = false;
    NSLog(@"x86pc: qemu exited %d", status);
    return NULL;
}

int x86pc_host_start(NSArray<NSString *> *args, X86PCBuild build, char *err, size_t errlen) {
    if (g_running) { set_error(err, errlen, @"A PC is already running; quit Triptych to start another."); return -1; }
    if (!g_qemu_handle) {
        NSString *bin = framework_binary(framework_name(build));
        g_qemu_handle = dlopen(bin.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!g_qemu_handle) { set_error(err, errlen, [NSString stringWithFormat:@"QEMU framework: %s", dlerror()]); return -1; }
        g_qemu_build = build;
        g_qemu_init = dlsym(g_qemu_handle, "qemu_init");
        g_qemu_main_loop = dlsym(g_qemu_handle, "qemu_main_loop");
        g_qemu_cleanup = dlsym(g_qemu_handle, "qemu_cleanup");
        g_t_copy = dlsym(g_qemu_handle, "triptych_display_copy");
        g_t_key_usb = dlsym(g_qemu_handle, "triptych_input_key_usb");
        g_t_pointer_abs = dlsym(g_qemu_handle, "triptych_input_pointer_abs");
        g_t_shutdown = dlsym(g_qemu_handle, "triptych_display_shutdown");
        if (!g_qemu_init || !g_qemu_main_loop || !g_qemu_cleanup) {
            set_error(err, errlen, @"QEMU framework lacks qemu_init / qemu_main_loop / qemu_cleanup");
            return -1;
        }
        if (!g_t_copy || !g_t_key_usb || !g_t_pointer_abs || !g_t_shutdown) {
            set_error(err, errlen, @"This QEMU framework has no Triptych display backend; rebuild it with scripts/build-x86pc.sh.");
            return -1;
        }
    } else if (g_qemu_build != build) {
        set_error(err, errlen, @"Another QEMU build is already loaded in this process; relaunch Triptych.");
        return -1;
    }
    g_argc = (int)args.count;
    g_argv = calloc(g_argc + 1, sizeof(char *));
    for (int i = 0; i < g_argc; i++) g_argv[i] = strdup(args[i].UTF8String);
    NSLog(@"x86pc: %@", [args componentsJoinedByString:@" "]);
    g_running = true;
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at, 8 << 20);
    if (pthread_create(&g_thread, &at, qemu_thread, NULL) != 0) { g_running = false; set_error(err, errlen, @"cannot start the QEMU thread"); return -1; }
    g_joinable = true;
    return 0;
}

void x86pc_host_stop(void) {
    if (g_running && g_t_shutdown) g_t_shutdown();          // unregisters the display listener, then qemu_system_shutdown_request
    if (g_joinable) {
        g_joinable = false;
        pthread_join(g_thread, NULL);                        // qemu_thread returns after qemu_cleanup; QEMU never calls exit()
    }
}

bool x86pc_host_is_running(void) { return g_running; }

/* A free loopback port: bind to port 0, read the port back, release it. QEMU binds it a moment later. */
static int free_local_port(void) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) return 0;
    struct sockaddr_in a = { .sin_family = AF_INET };
    inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
    socklen_t len = sizeof a;
    int port = 0;
    if (bind(s, (struct sockaddr *)&a, sizeof a) == 0 && getsockname(s, (struct sockaddr *)&a, &len) == 0)
        port = ntohs(a.sin_port);
    close(s);
    return port;
}

int x86pc_host_hmp_port(void) {
    if (!g_hmp_port) g_hmp_port = free_local_port();
    return g_hmp_port;
}

int x86pc_host_qmp_port(void) {
    if (!g_qmp_port) {
        do { g_qmp_port = free_local_port(); } while (g_qmp_port == x86pc_host_hmp_port());
    }
    return g_qmp_port;
}

static volatile uint64_t g_fb_generation;
uint64_t x86pc_host_fb_generation(void) { return g_fb_generation; }

const uint8_t *x86pc_host_fb(uint32_t *w, uint32_t *h, uint32_t *stride) {
    static uint8_t *buf; static size_t cap; static uint64_t seq; static int fw, fh, fs; static bool have;
    if (!g_t_copy || !g_running) return NULL;
    int nw = 0, nh = 0, ns = 0;
    size_t need = g_t_copy(buf, cap, &nw, &nh, &ns, &seq);
    if (need > cap) {                                        // frame grew (resolution switch): resize and pull again
        free(buf); buf = malloc(need); cap = buf ? need : 0;
        if (!buf) return NULL;
        need = g_t_copy(buf, cap, &nw, &nh, &ns, &seq);
    }
    if (need > 0 && need <= cap) { fw = nw; fh = nh; fs = ns; have = true; g_fb_generation++; }
    if (!have) return NULL;
    *w = (uint32_t)fw; *h = (uint32_t)fh; *stride = (uint32_t)fs;
    return buf;
}

void x86pc_host_tablet(int x, int y, int buttons, int wheel) {
    (void)wheel;
    if (g_running && g_t_pointer_abs) g_t_pointer_abs(x, y, 32767, 32767, (unsigned)buttons);
}

void x86pc_host_key(int hid_usage, int down) {
    if (g_running && g_t_key_usb) g_t_key_usb(hid_usage, down);
}

/* Opens a TCP connection to the local QEMU monitor, retrying while QEMU is still starting its listeners. */
static int connect_local(int port) {
    for (int attempt = 0; attempt < 15 && g_running; attempt++) {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) return -1;
        struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(port) };
        inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
        struct timeval tv = { .tv_sec = 2 };
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        if (connect(s, (struct sockaddr *)&a, sizeof a) == 0) return s;
        close(s);
        usleep(200000);
    }
    return -1;
}

bool x86pc_host_hmp(const char *command) {
    int s = connect_local(x86pc_host_hmp_port());
    if (s < 0) return false;
    char buf[1024];
    recv(s, buf, sizeof buf, 0);                       // banner and "(qemu)" prompt
    NSString *line = [NSString stringWithFormat:@"%s\n", command];
    send(s, line.UTF8String, strlen(line.UTF8String), 0);
    usleep(150000);                                    // screendump and sendkey finish inside the monitor
    recv(s, buf, sizeof buf, 0);
    close(s);
    return true;
}

bool x86pc_host_qmp_quit(void) {
    int s = connect_local(x86pc_host_qmp_port());
    if (s < 0) return false;
    char buf[1024];
    recv(s, buf, sizeof buf, 0);                       // greeting
    const char *caps = "{\"execute\":\"qmp_capabilities\"}\n";
    send(s, caps, strlen(caps), 0);
    recv(s, buf, sizeof buf, 0);
    const char *quit = "{\"execute\":\"quit\"}\n";
    send(s, quit, strlen(quit), 0);
    recv(s, buf, sizeof buf, 0);
    close(s);
    return true;
}
