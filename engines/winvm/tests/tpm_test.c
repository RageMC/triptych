// SPDX-License-Identifier: GPL-2.0-or-later
// TPM 2.0 test: drives tpm.c through its TIS/FIFO MMIO registers the way a guest driver does, against the real
// libtpms + libcrypto build. Runs on the Mac (make -C engines/winvm test) and inside the iOS Simulator
// (scripts/test-tpm-ios.sh), so the iOS cross-build of OpenSSL/libtpms is exercised too.
// Covers: locality request, FIFO and XDATA_FIFO transfers, 1/4/8-byte accesses, Startup, GetRandom, SHA-256
// (known answer), ECC P-256 and RSA-2048 primary keys, NV define/write/read, state persistence across a restart,
// and that the state file is the only storage (libtpms' NVRAM callbacks; no "NVChip" file in the current directory).
#define WINVM_LIBTPMS 1
#include "../tpm.c"
#include <assert.h>
#include <sys/stat.h>

static void *mmio_opaque;
static uint64_t (*mmio_read)(void *, uint64_t, unsigned);
static void (*mmio_write)(void *, uint64_t, uint64_t, unsigned);
int hv_machine_add_mmio(HvMachine *m, uint64_t pa, uint64_t size, void *opaque, uint64_t (*rd)(void *, uint64_t, unsigned),
                        void (*wr)(void *, uint64_t, uint64_t, unsigned), const char *name) {
    (void)m; (void)pa; (void)size; (void)name;
    mmio_opaque = opaque; mmio_read = rd; mmio_write = wr;
    return 0;
}

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

static uint32_t rd(uint32_t off, unsigned sz) { return (uint32_t)mmio_read(mmio_opaque, off, sz); }
static uint64_t rd64(uint32_t off) { return mmio_read(mmio_opaque, off, 8); }
static void wr(uint32_t off, uint64_t v, unsigned sz) { mmio_write(mmio_opaque, off, v, sz); }

/* Command builder */
typedef struct { uint8_t b[TPM_BUF]; uint32_t n; } Buf;
static void u8(Buf *c, uint8_t v) { c->b[c->n++] = v; }
static void u16(Buf *c, uint16_t v) { u8(c, v >> 8); u8(c, (uint8_t)v); }
static void u32(Buf *c, uint32_t v) { u16(c, v >> 16); u16(c, (uint16_t)v); }
static void hdr(Buf *c, uint16_t tag, uint32_t cc) { c->n = 0; u16(c, tag); u32(c, 0); u32(c, cc); }
static void pw_session(Buf *c) { u32(c, 9); u32(c, 0x40000009); u16(c, 0); u8(c, 0); u16(c, 0); }
static void fin(Buf *c) { c->b[2] = c->n >> 24; c->b[3] = c->n >> 16; c->b[4] = c->n >> 8; c->b[5] = (uint8_t)c->n; }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }

enum { MODE_BYTE, MODE_WORD, MODE_XDATA }; /* how the FIFO is fed and drained */

/* One command through locality 0: READY, write, GO, wait, read. Returns the response code; rsp gets the bytes. */
static uint32_t run(Buf *c, Buf *rsp, int mode) {
    fin(c);
    wr(0x18, STS_READY, 4);
    uint32_t s = rd(0x18, 4);
    CHECK(s & STS_READY, "STS not ready (%#x)", s);
    uint32_t fifo = mode == MODE_XDATA ? 0x80 : 0x24;
    for (uint32_t i = 0; i < c->n;) {
        uint32_t burst = rd(0x18, 4) >> 8 & 0xffff;
        CHECK(burst > 0, "burst count 0");
        if (mode == MODE_BYTE || c->n - i < 4) { wr(fifo, c->b[i], 1); i++; }
        else if (mode == MODE_XDATA && c->n - i >= 8) {
            uint64_t v = 0; for (int k = 0; k < 8; k++) v |= (uint64_t)c->b[i + k] << (8 * k);
            wr(fifo, v, 8); i += 8;
        } else { wr(fifo, (uint32_t)c->b[i] | c->b[i + 1] << 8 | c->b[i + 2] << 16 | (uint32_t)c->b[i + 3] << 24, 4); i += 4; }
        s = rd(0x18, 4);
        if (i < c->n) CHECK(s & STS_EXPECT, "STS lost Expect at byte %u (%#x)", i, s);
    }
    CHECK(!(rd(0x18, 4) & STS_EXPECT), "STS still expects data after %u bytes", c->n);
    wr(0x18, STS_GO, 4);
    for (int ms = 0; ms < 120000; ms++) { /* RSA-2048 key generation can take seconds */
        s = rd(0x18, 4);
        if ((s & STS_VALID) && (s & STS_DATA)) break;
        usleep(1000);
    }
    CHECK((s & STS_VALID) && (s & STS_DATA), "no response (STS %#x)", s);
    rsp->n = 0;
    while (rsp->n < 10) rsp->b[rsp->n++] = (uint8_t)rd(fifo, 1);
    uint32_t len = be32(rsp->b + 2);
    CHECK(len >= 10 && len <= TPM_BUF, "bad response size %u", len);
    while (rsp->n < len) {
        if (mode == MODE_XDATA && len - rsp->n >= 8) { uint64_t v = rd64(fifo); for (int k = 0; k < 8; k++) rsp->b[rsp->n++] = (uint8_t)(v >> (8 * k)); }
        else if (mode == MODE_WORD && len - rsp->n >= 4) { uint32_t v = rd(fifo, 4); for (int k = 0; k < 4; k++) rsp->b[rsp->n++] = (uint8_t)(v >> (8 * k)); }
        else rsp->b[rsp->n++] = (uint8_t)rd(fifo, 1);
    }
    s = rd(0x18, 4);
    CHECK(!(s & STS_DATA), "STS still has data after the response (%#x)", s);
    CHECK(rd(fifo, 1) == 0xff, "FIFO read past the response is not 0xff");
    return be32(rsp->b + 6);
}

static void startup(Buf *c, Buf *r, uint16_t su, int mode) {
    hdr(c, 0x8001, 0x144); u16(c, su);
    uint32_t rc = run(c, r, mode);
    CHECK(rc == 0, "TPM2_Startup(%u) rc %#x", su, rc);
}

static void create_primary(Buf *c, Buf *r, int rsa, int mode) {
    hdr(c, 0x8002, 0x131); u32(c, 0x4000000B); pw_session(c);
    u16(c, 4); u16(c, 0); u16(c, 0);                  /* inSensitive */
    u16(c, 26); u16(c, rsa ? 0x0001 : 0x0023); u16(c, 0x000B); u32(c, 0x00030072); u16(c, 0);
    u16(c, 0x0006); u16(c, 128); u16(c, 0x0043);     /* AES-128-CFB */
    u16(c, 0x0010);                                   /* scheme NULL */
    if (rsa) { u16(c, 2048); u32(c, 0); u16(c, 0); } /* keyBits, exponent, unique */
    else { u16(c, 0x0003); u16(c, 0x0010); u16(c, 0); u16(c, 0); } /* P-256, kdf NULL, unique x, y */
    u16(c, 0); u32(c, 0);                             /* outsideInfo, creationPCR */
    uint32_t rc = run(c, r, mode);
    CHECK(rc == 0, "CreatePrimary(%s) rc %#x", rsa ? "RSA-2048" : "ECC P-256", rc);
    if (rc == 0) {
        uint32_t h = be32(r->b + 10);
        CHECK((h >> 24) == 0x80, "transient handle %#x", h);
        hdr(c, 0x8001, 0x165); u32(c, h);             /* FlushContext */
        CHECK(run(c, r, mode) == 0, "FlushContext");
    }
}

#define NVI 0x01500001
static uint32_t nv_read_public(Buf *c, Buf *r) { hdr(c, 0x8001, 0x169); u32(c, NVI); return run(c, r, MODE_WORD); }

int main(int argc, char **argv) {
    char dir[1024], path[1100], cwd[1100];
    if (!realpath(argc > 1 ? argv[1] : (getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp"), dir)) { perror("realpath"); return 1; }
    snprintf(path, sizeof path, "%s/tpm_test_state.bin", dir);
    unlink(path);
    /* Run in an empty directory: the state file must be the TPM's only storage (no libtpms "NVChip" fallback). */
    snprintf(cwd, sizeof cwd, "%s/tpm_test_cwd", dir);
    mkdir(cwd, 0755); unlink("NVChip");
    if (chdir(cwd) != 0) { perror("chdir"); return 1; }
    unlink("NVChip");
    WinArm b; memset(&b, 0, sizeof b);
    Buf c, r;

    Tpm *t = winvm_tpm_create(&b, path);
    CHECK(t && mmio_read && b.tpm == t, "winvm_tpm_create failed");
    if (!t) return 1;
    CHECK(TPMLIB_WasManufactured(), "a missing state file must give a new TPM");
    struct stat st; CHECK(stat(path, &st) == 0 && st.st_size > 0, "state file not written at manufacture");

    /* Registers before any locality is active */
    CHECK(rd(0x00, 1) == (ACC_VALID | ACC_ESTABLISH), "ACCESS %#x", rd(0x00, 1));
    CHECK(rd(0x18, 4) == 0xffffffffu, "STS readable without the locality");
    CHECK(rd(0xf00, 4) == 0x00011014, "DID/VID %#x", rd(0xf00, 4));
    CHECK((rd(0x30, 4) & 0xf) == 0, "INTERFACE_ID must say FIFO (got %#x)", rd(0x30, 4));
    wr(0x00, ACC_REQUEST, 1);
    CHECK(rd(0x00, 1) & ACC_ACTIVE, "locality 0 not granted");
    wr(0x1000, ACC_REQUEST, 1);                        /* locality 1 asks: pending for 0, not active */
    CHECK(rd(0x00, 1) & ACC_PENDING, "locality 1 request not pending");
    CHECK(!(rd(0x1000, 1) & ACC_ACTIVE), "locality 1 active while 0 holds the TPM");
    wr(0x1000, ACC_ACTIVE, 1);                         /* 1 withdraws its request */
    CHECK(!(rd(0x00, 1) & ACC_PENDING), "withdrawn request still pending");

    startup(&c, &r, 0, MODE_BYTE);

    hdr(&c, 0x8001, 0x17B); u16(&c, 32);               /* GetRandom(32), via XDATA_FIFO with 8-byte accesses */
    CHECK(run(&c, &r, MODE_XDATA) == 0, "GetRandom");
    CHECK(be16(r.b + 10) == 32, "GetRandom returned %u bytes", be16(r.b + 10));
    int nz = 0; for (int i = 0; i < 32; i++) nz |= r.b[12 + i];
    CHECK(nz, "GetRandom returned zeros");

    hdr(&c, 0x8001, 0x17D); u16(&c, 3); u8(&c, 'a'); u8(&c, 'b'); u8(&c, 'c'); u16(&c, 0x000B); u32(&c, 0x40000007);
    CHECK(run(&c, &r, MODE_WORD) == 0, "Hash");
    static const uint8_t abc[32] = {0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
                                    0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad};
    CHECK(be16(r.b + 10) == 32 && !memcmp(r.b + 12, abc, 32), "SHA-256(\"abc\") is wrong");

    create_primary(&c, &r, 0, MODE_WORD);
    create_primary(&c, &r, 1, MODE_XDATA);

    CHECK(nv_read_public(&c, &r) == 0x18B, "NV index exists before it was defined (rc %#x)", be32(r.b + 6));
    hdr(&c, 0x8002, 0x12A); u32(&c, 0x40000001); pw_session(&c);
    u16(&c, 0); u16(&c, 14); u32(&c, NVI); u16(&c, 0x000B); u32(&c, 0x02060006); u16(&c, 0); u16(&c, 8);
    CHECK(run(&c, &r, MODE_WORD) == 0, "NV_DefineSpace rc %#x", be32(r.b + 6));
    hdr(&c, 0x8002, 0x137); u32(&c, NVI); u32(&c, NVI); pw_session(&c);
    u16(&c, 8); for (int i = 0; i < 8; i++) u8(&c, (uint8_t)("triptych"[i])); u16(&c, 0);
    CHECK(run(&c, &r, MODE_WORD) == 0, "NV_Write rc %#x", be32(r.b + 6));

    /* Restart: tear down libtpms the way a board reset does, then a new TPM from the state file only. */
    TPMLIB_Terminate();
    pthread_mutex_lock(&t->mu); t->quit = 1; pthread_cond_signal(&t->cv); pthread_mutex_unlock(&t->mu);
    usleep(20000);
    memset(&b, 0, sizeof b); mmio_read = NULL;
    t = winvm_tpm_create(&b, path);
    CHECK(t && mmio_read, "TPM did not restart from %s", path);
    if (!t) return 1;
    CHECK(!TPMLIB_WasManufactured(), "restart manufactured a new TPM instead of restoring the state");
    wr(0x00, ACC_REQUEST, 1);
    startup(&c, &r, 0, MODE_WORD);
    CHECK(nv_read_public(&c, &r) == 0, "NV index lost across the restart (rc %#x)", be32(r.b + 6));
    hdr(&c, 0x8002, 0x14E); u32(&c, NVI); u32(&c, NVI); pw_session(&c); u16(&c, 8); u16(&c, 0);
    CHECK(run(&c, &r, MODE_BYTE) == 0, "NV_Read rc %#x", be32(r.b + 6));
    CHECK(be16(r.b + 14) == 8 && !memcmp(r.b + 16, "triptych", 8), "NV data lost across the restart");

    /* Board reset path (tpm_reset): the TPM must come back and accept Startup again. */
    b.tpm_reset(b.tpm);
    wr(0x00, ACC_REQUEST, 1);
    startup(&c, &r, 0, MODE_XDATA);

    CHECK(access("NVChip", F_OK) != 0, "libtpms wrote an NVChip file in the current directory");
    unlink("NVChip"); chdir(dir); rmdir(cwd);
    unlink(path);
    char tmp[1200]; snprintf(tmp, sizeof tmp, "%s.tmp", path); unlink(tmp);
    if (fails) { fprintf(stderr, "tpm_test: %d failure(s)\n", fails); return 1; }
    printf("tpm_test: all passed (libtpms %u.%u.%u)\n", TPMLIB_GetVersion() >> 16 & 0xff, TPMLIB_GetVersion() >> 8 & 0xff,
           TPMLIB_GetVersion() & 0xff);
    return 0;
}
