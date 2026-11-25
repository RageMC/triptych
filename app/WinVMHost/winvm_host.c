// SPDX-License-Identifier: GPL-2.0-or-later
// Host API of the winarm board (engines/winvm) for the app.
#include "../Triptych/Bridge/winvm_host.h"
#include "winarm.h"
#include "dispatch.h"
#include "sysreg.h"
#include "disk.h"
#include "devices_ext.h"
#include "usb.h"
#include <TargetConditionals.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if TARGET_OS_IPHONE && !defined(WINVM_SIM_SPLIT)
#include "henge-ios-jit.h"
static HengeDualMapping jit;
#endif

static HvMachine m;
static HvCpu cpus[HV_MAX_CPUS];
static WinArm board;
static HvDisk disk = {.fd = -1, .wfd = -1}, iso = {.fd = -1, .wfd = -1};
static FILE *serial;
static atomic_bool kicker_stop;
enum { WINVM_IDLE, WINVM_RUNNING, WINVM_STOPPED, WINVM_STOPPING };
static atomic_int state;
static pthread_t runner;
static bool runner_started, stop_requested;
/* Serialize start and stop. The worker uses api_lock only, so stop can join it. */
static pthread_mutex_t lifecycle = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t api_lock = PTHREAD_MUTEX_INITIALIZER;

static void block_signals(void) {
    sigset_t set; sigfillset(&set);
    sigdelset(&set, SIGSEGV); sigdelset(&set, SIGBUS); sigdelset(&set, SIGILL); sigdelset(&set, SIGTRAP);
    pthread_sigmask(SIG_BLOCK, &set, NULL);
}
static void *secondary(void *arg) { block_signals(); hv_run(arg); return NULL; }

static void *kicker(void *arg) {
    (void)arg;
    while (!atomic_load(&kicker_stop)) {
        usleep(1000);
        hv_machine_kick_all(&m);
    }
    return NULL;
}

static void destroy(void) {
    winvm_usb_destroy();
    winvm_tpm_destroy(&board);
    winarm_destroy(&board);
    if (disk.fd >= 0) hv_disk_flush(&disk);
    hv_disk_close(&disk);
    hv_disk_close(&iso);
    if (serial) { fclose(serial); serial = NULL; }
    hv_machine_free(&m);
    memset(cpus, 0, sizeof cpus);
#if TARGET_OS_IPHONE && !defined(WINVM_SIM_SPLIT)
    henge_ios_jit_release(&jit);
#endif
}

static void *run_thread(void *arg) {
    (void)arg;
    block_signals();
    int reason = HV_HALT_NONE;
    for (;;) {
        pthread_mutex_lock(&api_lock);
        if (stop_requested) {
            pthread_mutex_unlock(&api_lock);
            break;
        }
        if (reason == HV_HALT_RESET) hv_flush_blocks(&m);
        winarm_reset(&board);
        pthread_mutex_unlock(&api_lock);

        atomic_store(&kicker_stop, false);
        pthread_t sec[HV_MAX_CPUS], kick;
        int i = 1;
        for (; i < board.ncpus; i++)
            if (pthread_create(&sec[i], NULL, secondary, &cpus[i]) != 0) break;
        bool kicked = i == board.ncpus && pthread_create(&kick, NULL, kicker, NULL) == 0;
        if (kicked) hv_run(&cpus[0]);
        else fprintf(stderr, "winvm: could not start all CPU threads\n");
        reason = atomic_load(&cpus[0].halted);
        hv_machine_halt(&m, HV_HALT_HOST);
        atomic_store(&kicker_stop, true);
        while (--i > 0) pthread_join(sec[i], NULL);
        if (kicked) pthread_join(kick, NULL);
        if (reason != HV_HALT_RESET || !kicked) break;
    }

    atomic_store(&state, WINVM_STOPPING);
    pthread_mutex_lock(&api_lock);
    destroy();
    atomic_store(&state, WINVM_STOPPED);
    pthread_mutex_unlock(&api_lock);
    return NULL;
}

static void serial_write(void *opaque, uint8_t byte) {
    FILE *log = opaque;
    if (log) fputc(byte, log);
}

static int init_machine(char *err, int errlen) {
#if TARGET_OS_IPHONE && !defined(WINVM_SIM_SPLIT)
    henge_ios_jit_prepare_vm_memory();
    static const size_t sizes[] = {(size_t)512 << 20, (size_t)384 << 20, (size_t)256 << 20};
    for (unsigned i = 0; i < sizeof sizes / sizeof sizes[0]; i++) {
        jit = henge_ios_jit_reserve_top(sizes[i]);
        if (!jit.rw_addr) continue;
        if (hv_machine_init_jit(&m, jit.rx_addr, jit.rw_addr, jit.size) == 0) {
            fprintf(stderr, "winvm: using %zu MiB of the app's JIT region\n", jit.size >> 20);
            return 0;
        }
        hv_machine_free(&m);
        henge_ios_jit_release(&jit);
    }
    snprintf(err, errlen, "no JIT region: turn on JIT (Easel / Setup) before starting the Windows PC, or quit and reopen Triptych with JIT");
#else
#ifdef WINVM_SIM_SPLIT
    /* The Simulator allows Henge's RW alias + RX mapping without a debugger. */
    setenv("HV_JIT_SPLIT", "1", 1);
#endif
    if (hv_machine_init(&m, (size_t)512 << 20) == 0) return 0;
    snprintf(err, errlen, "no executable memory (JIT region)");
#endif
    return -1;
}

static int create(const WinArmConfig *cfg, const char *nvme, const char *isopath,
                  const char *tpm, const char *serial_path, char *err, int errlen) {
    /* Known EDK2 CD-boot bug (docs/STATUS.md). WINVM_TLBI_BLOCK=1 turns the optimization back on. */
    if (!getenv("WINVM_TLBI_BLOCK")) setenv("HV_NO_TLBI_BLOCK", "1", 0);
    if (init_machine(err, errlen) != 0 || winarm_create(&board, &m, cpus, cfg, err, errlen) != 0) return -1;
    if (serial_path) {
        serial = fopen(serial_path, "w");
        if (serial) setvbuf(serial, NULL, _IOLBF, 0);
        else perror("winvm: opening serial log");
    }
    board.uart->output = serial_write;
    board.uart->output_opaque = serial;
    if (nvme && (hv_disk_open(&disk, nvme, 0, 0) != 0 || !winvm_nvme_create(&board, &disk, 0))) {
        snprintf(err, errlen, "cannot attach the disk"); return -1;
    }
    if (!winvm_usb_create(&board)) { snprintf(err, errlen, "cannot create the USB controller"); return -1; }
    if (isopath && (hv_disk_open(&iso, isopath, 0, 1) != 0 || !winvm_usb_storage_create(&board, &iso, 1))) {
        snprintf(err, errlen, "cannot attach the ISO"); return -1;
    }
    if (tpm && !winvm_tpm_create(&board, tpm)) { snprintf(err, errlen, "cannot start the TPM"); return -1; }
    static const uint8_t mac[6] = {0x52, 0x54, 0x00, 0x12, 0x34, 0x56};
    winvm_usb_net_create(&board, mac); /* Optional NAT for Windows' USB NCM driver. */
    if (winarm_finalize(&board) != 0) { snprintf(err, errlen, "cannot build the ACPI tables"); return -1; }
    if (isopath && nvme) usb_autoboot_cd(&disk);
    return 0;
}

int winvm_host_start(const char *code, const char *vars, int ram_mb, int ncpus,
                     uint32_t width, uint32_t height, const char *nvme, const char *isopath,
                     const char *tpm, const char *serial_path, char *err, int errlen) {
    pthread_mutex_lock(&lifecycle);
    if (atomic_load(&state) == WINVM_RUNNING) {
        snprintf(err, errlen, "the Windows PC is still running");
        pthread_mutex_unlock(&lifecycle);
        return -1;
    }
    if (runner_started) {
        pthread_join(runner, NULL);
        runner_started = false;
    }

    pthread_mutex_lock(&api_lock);
    WinArmConfig cfg = {.ncpus = ncpus, .ram_mb = (uint64_t)ram_mb, .code_path = code, .vars_path = vars,
                        .display_width = width, .display_height = height};
    int result = create(&cfg, nvme, isopath, tpm, serial_path, err, errlen);
    if (result == 0) {
        stop_requested = false;
        runner_started = pthread_create(&runner, NULL, run_thread, NULL) == 0;
        if (!runner_started) {
            snprintf(err, errlen, "cannot start the Windows PC thread");
            result = -1;
        }
    }
    if (result == 0) atomic_store(&state, WINVM_RUNNING);
    else destroy();
    pthread_mutex_unlock(&api_lock);
    pthread_mutex_unlock(&lifecycle);
    return result;
}

void winvm_host_stop(void) {
    pthread_mutex_lock(&lifecycle);
    pthread_mutex_lock(&api_lock);
    if (atomic_load(&state) == WINVM_RUNNING) {
        stop_requested = true;
        atomic_store(&state, WINVM_STOPPING);
        hv_machine_halt(&m, HV_HALT_HOST);
    }
    pthread_mutex_unlock(&api_lock);
    if (runner_started) {
        pthread_join(runner, NULL);
        runner_started = false;
    }
    pthread_mutex_unlock(&lifecycle);
}

int winvm_host_state(void) { return atomic_load(&state); }

int winvm_host_has_tpm(void) {
#ifdef WINVM_LIBTPMS
    return 1;
#else
    return 0;
#endif
}

unsigned winvm_host_tpm_commands(void) { return winvm_tpm_command_count(); }
unsigned winvm_host_iso_read_mb(void) { return (unsigned)(usb_storage_bytes_read() >> 20); }

void winvm_host_read_fb(WinvmFrameReader read, void *opaque) {
    if (atomic_load(&state) != WINVM_RUNNING) return;
    pthread_mutex_lock(&api_lock);
    if (atomic_load(&state) == WINVM_RUNNING) {
        hv_dev_lock(&m);
        uint32_t w = board.fb.width, h = board.fb.height, stride = board.fb.stride;
        if (board.fb.addr && w && h && (uint64_t)w * 4 <= stride) {
            const uint8_t *p = hv_phys_ptr(&m, board.fb.addr, (uint64_t)stride * h);
            if (p) read(opaque, p, w, h, stride);
        }
        hv_dev_unlock(&m);
    }
    pthread_mutex_unlock(&api_lock);
}

void winvm_host_key(int hid_usage, int down) {
    pthread_mutex_lock(&api_lock);
    if (atomic_load(&state) == WINVM_RUNNING && !stop_requested) usb_key((uint8_t)hid_usage, down);
    pthread_mutex_unlock(&api_lock);
}

void winvm_host_tablet(int x, int y, int buttons, int wheel) {
    pthread_mutex_lock(&api_lock);
    if (atomic_load(&state) == WINVM_RUNNING && !stop_requested) usb_tablet(x, y, buttons, wheel);
    pthread_mutex_unlock(&api_lock);
}
