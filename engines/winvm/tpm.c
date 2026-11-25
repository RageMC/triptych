// SPDX-License-Identifier: GPL-2.0-or-later
// TPM 2.0 for the winarm board: the TCG PC Client "FIFO" (TIS) register interface, the one QEMU's
// tpm-tis-device exposes on the ARM virt board, in front of libtpms (BSD-3, Stefan Berger/IBM).
//
// Why TIS (FIFO) and not CRB: EDK2's ArmVirtQemu finds the TPM through a DT node with compatible
// "tcg,tpm-tis-mmio" (ArmVirtPkg/Library/PlatformPeiLib) and then probes the interface itself
// (Tpm2GetPtpInterface: CRB, FIFO or TIS). Windows' inbox tpm.sys drives TIS/FIFO from a TPM2 ACPI
// table with start method 6 (memory-mapped I/O) and a MSFT0101 device; that is exactly what QEMU
// publishes for "-device tpm-tis-device" and what Windows 11 on Arm guests (UTM, libvirt) boot with.
// Linux binds tpm_tis to the same MSFT0101 device. No interrupt is wired: every driver polls.
//
// libtpms needs libcrypto. Mac: Homebrew openssl@3 (static libcrypto.a, see scripts/build-libtpms.sh).
// iOS: cross-build OpenSSL 3 static for ios-arm64 and link it (the script lists the options).
//
// Commands run on a worker thread (the first TPM2_CreatePrimary of an RSA EK takes seconds and
// device MMIO runs under the machine's device lock). NVRAM (libtpms' permanent state) is written to
// the state file on every NV commit, through libtpms' storedata callback.
#include "devices_ext.h"
#ifdef WINVM_LIBTPMS
#include <libtpms/tpm_library.h>
#include <libtpms/tpm_error.h>
#include <libtpms/tpm_nvfilename.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TPM_BUF 4096
#define NLOC 5
#define BURST 64

enum { ACC_ESTABLISH = 0x01, ACC_REQUEST = 0x02, ACC_PENDING = 0x04, ACC_SEIZE = 0x08, ACC_SEIZED = 0x10,
       ACC_ACTIVE = 0x20, ACC_VALID = 0x80 };
enum { STS_RETRY = 0x02, STS_EXPECT = 0x08, STS_DATA = 0x10, STS_GO = 0x20, STS_READY = 0x40, STS_VALID = 0x80,
       STS_CANCEL = 0x01000000, STS_RESET_EST = 0x02000000, STS_FAMILY2 = 0x04000000 };
enum { S_IDLE, S_READY, S_RECEPTION, S_EXECUTION, S_COMPLETION };

typedef struct Tpm {
    char *path;
    int state, active;               /* active locality or -1 */
    uint8_t request[NLOC], seized[NLOC];
    uint32_t int_enable, int_status;
    uint8_t int_vector;
    uint8_t cmd[TPM_BUF], rsp[TPM_BUF];
    unsigned char *lbuf; uint32_t lbuf_size; /* libtpms' own response buffer (heap, it may grow it) */
    uint32_t wlen, cmd_len, rlen, roff;
    pthread_t th; pthread_mutex_t mu; pthread_cond_t cv;
    int job, quit;
    atomic_int done;
    unsigned char *saved; uint32_t saved_len; /* last permanent state written to the file */
} Tpm;

static int log_on;
atomic_uint winvm_tpm_commands; /* commands the guest ran (the app shows it; tests check the firmware used the TPM) */
#define TLOG(...) do { if (log_on) fprintf(stderr, "tpm: " __VA_ARGS__); } while (0)

/* Write the permanent state to the state file (atomically: tmp + rename) unless it is unchanged. Takes buf. */
static void save_state(Tpm *t, unsigned char *buf, uint32_t len) {
    if (t->saved && t->saved_len == len && !memcmp(t->saved, buf, len)) { free(buf); return; }
    char tmp[1024];
    snprintf(tmp, sizeof tmp, "%s.tmp", t->path);
    FILE *f = fopen(tmp, "wb");
    int ok = 0;
    if (f) {
        ok = fwrite(buf, 1, len, f) == len;
        ok = fclose(f) == 0 && ok;
        if (ok && rename(tmp, t->path) != 0) ok = 0;
    }
    if (!ok) fprintf(stderr, "winvm: cannot save the TPM state to %s\n", t->path);
    free(t->saved); t->saved = buf; t->saved_len = len;
}

static void persist(Tpm *t) {
    unsigned char *buf = NULL; uint32_t len = 0;
    if (TPMLIB_GetState(TPMLIB_STATE_PERMANENT, &buf, &len) == TPM_SUCCESS) save_state(t, buf, len);
}

/* libtpms' NVRAM callbacks. Without them libtpms falls back to a file named "NVChip" in the current directory
   for every NV load and commit (tpm2/NVMem.c _plat__NVEnable_NVChipFile): that asserts when the directory is not
   writable (an iOS app's cwd is "/") and otherwise leaves stray NVChip files around. With them, the board's state
   file is the only storage: loaded through TPMLIB_SetState/loaddata, written on every NV commit through storedata. */
static Tpm *cb_tpm; /* libtpms is one TPM per process */
static TPM_RESULT nv_init(void) { return TPM_SUCCESS; }
static TPM_RESULT nv_load(unsigned char **data, uint32_t *length, uint32_t n, const char *name) {
    (void)n;
    if (!cb_tpm || strcmp(name, TPM_PERMANENT_ALL_NAME) || !cb_tpm->saved) return TPM_RETRY; /* nothing yet: manufacture */
    if (!(*data = malloc(cb_tpm->saved_len))) return TPM_FAIL;                             /* libtpms frees it */
    memcpy(*data, cb_tpm->saved, cb_tpm->saved_len); *length = cb_tpm->saved_len;
    return TPM_SUCCESS;
}
static TPM_RESULT nv_store(const unsigned char *data, uint32_t length, uint32_t n, const char *name) {
    (void)n;
    if (!cb_tpm || strcmp(name, TPM_PERMANENT_ALL_NAME)) return TPM_SUCCESS; /* TPM 2 only commits permall */
    unsigned char *copy = malloc(length);
    if (!copy) return TPM_FAIL;
    memcpy(copy, data, length);
    save_state(cb_tpm, copy, length);
    return TPM_SUCCESS;
}
static TPM_RESULT nv_delete(uint32_t n, const char *name, TPM_BOOL must_exist) { (void)n; (void)name; (void)must_exist; return TPM_SUCCESS; }

static int tpm_power_on(Tpm *t) { /* libtpms is one TPM per process: (re)initialise it from t->saved */
    static struct libtpms_callbacks cbs = {.sizeOfStruct = sizeof cbs, .tpm_nvram_init = nv_init,
        .tpm_nvram_loaddata = nv_load, .tpm_nvram_storedata = nv_store, .tpm_nvram_deletename = nv_delete};
    cb_tpm = t;
    if (TPMLIB_RegisterCallbacks(&cbs) != TPM_SUCCESS) return -1;
    if (TPMLIB_ChooseTPMVersion(TPMLIB_TPM_VERSION_2) != TPM_SUCCESS) return -1;
    if (t->saved && TPMLIB_SetState(TPMLIB_STATE_PERMANENT, t->saved, t->saved_len) != TPM_SUCCESS) {
        fprintf(stderr, "winvm: the TPM state in %s is not usable\n", t->path);
        return -1;
    }
    if (TPMLIB_MainInit() != TPM_SUCCESS) return -1;
    persist(t); /* first run: the freshly manufactured state */
    return 0;
}

static void *worker(void *arg) {
    Tpm *t = arg;
    pthread_mutex_lock(&t->mu);
    for (;;) {
        while (!t->job && !t->quit) pthread_cond_wait(&t->cv, &t->mu);
        if (t->quit) break;
        pthread_mutex_unlock(&t->mu);
        /* libtpms owns its response buffer: it realloc()s it up to TPM_BUFFER_MAX, so it must be heap memory. */
        uint32_t rl = 0;
        TPM_RESULT r = TPMLIB_Process(&t->lbuf, &rl, &t->lbuf_size, t->cmd, t->cmd_len);
        if (r == TPM_SUCCESS && rl >= 10 && rl <= TPM_BUF) memcpy(t->rsp, t->lbuf, rl);
        else { /* TPM_RC_FAILURE: a well-formed error response */
            static const uint8_t fail[10] = {0x80, 0x01, 0, 0, 0, 10, 0, 0, 1, 0x01};
            memcpy(t->rsp, fail, 10); rl = 10;
        }
        t->rlen = rl;
        atomic_fetch_add(&winvm_tpm_commands, 1);
        TLOG("cmd %02x%02x%02x%02x%02x%02x%02x%02x%02x%02x (%u bytes) -> rc %02x%02x%02x%02x (%u bytes)\n",
             t->cmd[0], t->cmd[1], t->cmd[2], t->cmd[3], t->cmd[4], t->cmd[5], t->cmd[6], t->cmd[7], t->cmd[8], t->cmd[9],
             t->cmd_len, t->rsp[6], t->rsp[7], t->rsp[8], t->rsp[9], rl);
        pthread_mutex_lock(&t->mu);
        t->job = 0;
        atomic_store(&t->done, 1);
    }
    pthread_mutex_unlock(&t->mu);
    return NULL;
}

static void wait_idle(Tpm *t) { while (t->state == S_EXECUTION && !atomic_load(&t->done)) usleep(1000); }

/* Called with the device lock held, before every register access. */
static void tpm_sync(Tpm *t) {
    if (t->state == S_EXECUTION && atomic_load(&t->done)) { t->state = S_COMPLETION; t->roff = 0; }
}

static uint32_t sts_value(Tpm *t) {
    tpm_sync(t);
    uint32_t s = STS_FAMILY2 | STS_VALID;
    uint32_t burst = BURST;
    switch (t->state) {
    case S_READY: s |= STS_READY; break;
    case S_RECEPTION: if (t->wlen < 10 || t->wlen < t->cmd_len) s |= STS_EXPECT; break;
    case S_COMPLETION: if (t->roff < t->rlen) s |= STS_DATA; break;
    case S_EXECUTION: s &= ~STS_VALID; break;
    default: break;
    }
    return s | burst << 8;
}

static void abort_cmd(Tpm *t) { wait_idle(t); t->state = S_IDLE; t->wlen = t->cmd_len = t->rlen = t->roff = 0; }

static void grant(Tpm *t) { /* hand the TPM to the highest locality that asked */
    for (int l = NLOC - 1; l >= 0; l--)
        if (t->request[l]) { t->request[l] = 0; t->active = l; abort_cmd(t); return; }
}

static uint32_t access_value(Tpm *t, int l) {
    uint32_t a = ACC_VALID | ACC_ESTABLISH;
    if (t->active == l) a |= ACC_ACTIVE;
    if (t->seized[l]) a |= ACC_SEIZED;
    for (int o = 0; o < NLOC; o++) if (o != l && t->request[o]) a |= ACC_PENDING;
    return a;
}

static uint32_t reg_read32(Tpm *t, int l, uint32_t off) { /* aligned register word */
    switch (off) {
    case 0x00: return access_value(t, l);
    case 0x08: return t->int_enable;
    case 0x0c: return t->int_vector;
    case 0x10: return t->int_status;
    case 0x14: return 0x30000697;           /* PTP 1.3 for TPM 2.0, 64-byte transfers, level-low irq capable */
    case 0x18: return t->active == l ? sts_value(t) : 0xffffffffu;
    case 0x30: return (1u << 8) | (3u << 11) | (1u << 13); /* FIFO interface; 5 localities; 64-byte xfers; CapFIFO */
    case 0xf00: return 0x00011014;          /* DID 1, VID 0x1014 (QEMU's identity) */
    case 0xf04: return 1;                   /* RID */
    default: return 0;
    }
}

static uint8_t fifo_get(Tpm *t) {
    tpm_sync(t);
    if (t->state != S_COMPLETION || t->roff >= t->rlen) return 0xff;
    return t->rsp[t->roff++];
}

static void fifo_put(Tpm *t, uint8_t b) {
    tpm_sync(t);
    if (t->state == S_READY) { t->state = S_RECEPTION; t->wlen = t->cmd_len = 0; }
    if (t->state != S_RECEPTION) return;
    if (t->wlen < TPM_BUF) t->cmd[t->wlen++] = b; else return;
    if (t->wlen == 10) {
        t->cmd_len = (uint32_t)t->cmd[2] << 24 | (uint32_t)t->cmd[3] << 16 | (uint32_t)t->cmd[4] << 8 | t->cmd[5];
        if (t->cmd_len < 10 || t->cmd_len > TPM_BUF) t->cmd_len = 10; /* nonsense size: run the header, the TPM rejects it */
    }
}

static void go(Tpm *t) {
    if (t->state != S_RECEPTION || t->wlen < 10 || t->wlen < t->cmd_len) return;
    t->state = S_EXECUTION;
    pthread_mutex_lock(&t->mu);
    atomic_store(&t->done, 0);
    t->job = 1;
    pthread_cond_signal(&t->cv);
    pthread_mutex_unlock(&t->mu);
}

static void sts_write(Tpm *t, uint32_t v) {
    tpm_sync(t);
    if (v & STS_CANCEL) { TPMLIB_CancelCommand(); }
    if (v & STS_READY) {
        if (t->state == S_EXECUTION) { /* the command cannot be taken back; drop its answer */
            wait_idle(t); tpm_sync(t);
        }
        t->state = S_READY; t->wlen = t->cmd_len = t->rlen = t->roff = 0;
    } else if (v & STS_GO) go(t);
    else if ((v & STS_RETRY) && t->state == S_COMPLETION) t->roff = 0;
}

static void access_write(Tpm *t, int l, uint8_t v) {
    if (v & ACC_SEIZED) t->seized[l] = 0;
    if (v & ACC_ACTIVE) { /* relinquish */
        if (t->active == l) { t->active = -1; abort_cmd(t); grant(t); }
        t->request[l] = 0;
    }
    if (v & ACC_REQUEST) {
        if (t->active < 0) { t->active = l; abort_cmd(t); }
        else if (t->active != l) t->request[l] = 1;
    }
    if (v & ACC_SEIZE) {
        if (t->active >= 0 && l > t->active) { t->seized[t->active] = 1; t->request[t->active] = 0; t->active = l; abort_cmd(t); }
    }
}

/* TPM_DATA_FIFO (0x24) and the PTP's TPM_XDATA_FIFO (0x80..0xbf, for transfers of up to 64 bytes): both are
   the same byte stream (PTP 1.3 section 6.3.2; QEMU's tpm_tis handles both ranges the same way). */
static int is_fifo(uint32_t r) { return (r >= 0x24 && r < 0x28) || (r >= 0x80 && r < 0xc0); }

static uint64_t tpm_read(void *o, uint64_t off, unsigned size) {
    Tpm *t = o;
    int l = (int)(off >> 12); uint32_t r = (uint32_t)(off & 0xfff);
    if (l >= NLOC) return ~0ull;
    if (is_fifo(r)) { /* DATA_FIFO or XDATA_FIFO */
        if (t->active != l) return ~0ull >> (64 - 8 * size);
        uint64_t v = 0; /* up to 8 bytes per access */
        for (unsigned i = 0; i < size; i++) v |= (uint64_t)fifo_get(t) << (8 * i);
        return v;
    }
    if (r >= 0xc0 && r < 0xf00) return 0;
    uint32_t w = reg_read32(t, l, r & ~3u) >> (8 * (r & 3));
    return size >= 4 ? w : w & ((1u << (8 * size)) - 1);
}

static void tpm_write(void *o, uint64_t off, uint64_t val, unsigned size) {
    Tpm *t = o;
    int l = (int)(off >> 12); uint32_t r = (uint32_t)(off & 0xfff);
    if (l >= NLOC) return;
    if (is_fifo(r)) {
        if (t->active != l) return;
        for (unsigned i = 0; i < size; i++) fifo_put(t, (uint8_t)(val >> (8 * i)));
        return;
    }
    uint32_t v = (uint32_t)val << (8 * (r & 3));
    switch (r & ~3u) {
    case 0x00: if ((r & 3) == 0) access_write(t, l, (uint8_t)val); break;
    case 0x08: t->int_enable = v; break;
    case 0x0c: t->int_vector = (uint8_t)val; break;
    case 0x10: t->int_status &= ~v; break;
    case 0x18: if (t->active == l) sts_write(t, v); break;
    default: break;
    }
}

static void tpm_reset(void *o) {
    Tpm *t = o;
    wait_idle(t);
    TPMLIB_Terminate();
    t->state = S_IDLE; t->active = -1;
    memset(t->request, 0, sizeof t->request); memset(t->seized, 0, sizeof t->seized);
    t->int_enable = t->int_status = t->int_vector = 0;
    t->wlen = t->cmd_len = t->rlen = t->roff = 0;
    if (tpm_power_on(t) != 0) fprintf(stderr, "winvm: the TPM failed to restart\n");
}

unsigned winvm_tpm_command_count(void) { return atomic_load(&winvm_tpm_commands); }

static void free_tpm(Tpm *t) {
    pthread_cond_destroy(&t->cv);
    pthread_mutex_destroy(&t->mu);
    free(t->saved);
    free(t->lbuf);
    free(t->path);
    free(t);
}

void winvm_tpm_destroy(WinArm *b) {
    Tpm *t = b->tpm;
    if (!t) return;
    wait_idle(t);
    pthread_mutex_lock(&t->mu);
    t->quit = 1;
    pthread_cond_signal(&t->cv);
    pthread_mutex_unlock(&t->mu);
    pthread_join(t->th, NULL);
    TPMLIB_Terminate();
    cb_tpm = NULL;
    free_tpm(t);
    b->tpm = NULL;
    b->tpm_reset = NULL;
    atomic_store(&winvm_tpm_commands, 0);
}

void *winvm_tpm_create(WinArm *b, const char *state_path) {
    Tpm *t = calloc(1, sizeof *t);
    if (!t) return NULL;
    log_on = getenv("WINVM_TPM_LOG") != NULL;
    t->path = strdup(state_path);
    if (!t->path) { free(t); return NULL; }
    t->active = -1;
    pthread_mutex_init(&t->mu, NULL); pthread_cond_init(&t->cv, NULL);
    FILE *f = fopen(state_path, "rb"); /* a missing file is a new TPM */
    if (f) {
        fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
        if (n > 0) {
            t->saved = malloc((size_t)n);
            if (t->saved && fread(t->saved, 1, (size_t)n, f) == (size_t)n) t->saved_len = (uint32_t)n;
            else { free(t->saved); t->saved = NULL; }
        }
        fclose(f);
    }
    if (tpm_power_on(t) != 0 || pthread_create(&t->th, NULL, worker, t) != 0) {
        TPMLIB_Terminate();
        cb_tpm = NULL;
        free_tpm(t);
        return NULL;
    }
    hv_machine_add_mmio(b->m, WA_TPM, WA_TPM_SIZE, t, tpm_read, tpm_write, "tpm");
    b->tpm = t; b->tpm_reset = tpm_reset;
    fprintf(stderr, "winvm: TPM 2.0 at %#llx (libtpms %u.%u.%u), state %s (%s)\n", (unsigned long long)WA_TPM,
            TPMLIB_GetVersion() >> 16 & 0xff, TPMLIB_GetVersion() >> 8 & 0xff, TPMLIB_GetVersion() & 0xff, state_path,
            TPMLIB_WasManufactured() ? "new TPM" : "state restored");
    return t;
}
#endif
