// SPDX-License-Identifier: GPL-2.0-or-later
// NVMe 1.4 controller (subset) for the winarm board: one namespace backed by an HvDisk, admin and
// I/O queues, PRP transfers, legacy INTx (pin A) only. Everything runs synchronously inside the
// doorbell write, under the device lock that Henge's MMIO dispatch already holds.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "devices_ext.h"
#include "winarm.h"
#include "disk.h"

#define NVME_MAX_QP 16          /* I/O queue pairs */
#define NVME_MQES 1023          /* max entries per queue (0-based value in CAP) */
#define NVME_MDTS 5             /* 2^5 pages: 128 KiB at 4 KiB pages */
#define NVME_BAR_SIZE 0x4000
#define NVME_MAX_AER 4

/* controller registers */
#define R_CAP 0x00
#define R_VS 0x08
#define R_INTMS 0x0c
#define R_INTMC 0x10
#define R_CC 0x14
#define R_CSTS 0x1c
#define R_AQA 0x24
#define R_ASQ 0x28
#define R_ACQ 0x30

/* status codes: (SCT << 8) | SC */
#define ST_OK 0x000
#define ST_INVALID_OPC 0x001
#define ST_INVALID_FIELD 0x002
#define ST_DATA_XFER 0x004
#define ST_INTERNAL 0x006
#define ST_INVALID_NS 0x00b
#define ST_LBA_RANGE 0x080
#define ST_READONLY 0x082 /* attempted write to a read-only range */
#define ST_INVALID_CQ 0x100
#define ST_INVALID_QID 0x101
#define ST_INVALID_QSIZE 0x102
#define ST_AER_LIMIT 0x105
#define ST_INVALID_VECTOR 0x108
#define ST_INVALID_QDEL 0x10c
#define ST_WRITE_FAULT 0x280
#define ST_READ_ERROR 0x281
#define ST_DNR 0x4000

typedef struct {
    uint64_t base;
    uint32_t size;      /* entries */
    uint32_t head, tail;
    uint16_t cqid;      /* SQ: its completion queue */
    uint8_t phase, ien, valid;
} NvmeQ;

typedef struct {
    HvPciDev pci;       /* first: the PCI callbacks recover the controller from it */
    HvMachine *m;
    HvDisk *disk;
    int readonly;
    uint64_t nlba;
    uint8_t guid[16];

    uint32_t intms, cc, csts, aqa;
    uint64_t unmask_ns; /* INTMC that left completions pending: INTx is raised by nvme_poll a little later */
    uint64_t raise_ns, touch_ns, rearm_ns; /* storm breaker: INTx last raised, last register access, re-raise time */
    unsigned storms;
    uint64_t asq, acq;
    uint32_t page_size;
    NvmeQ sq[NVME_MAX_QP + 1], cq[NVME_MAX_QP + 1];
    uint32_t features[0x100];
    int aer_pending;
    int nqueues;        /* granted by Set Features: number of queues */
} Nvme;

static void u16(uint8_t *p, uint16_t v) { memcpy(p, &v, 2); }
static void u32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static void u64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }

static void pad(uint8_t *p, size_t n, const char *s) {
    size_t l = strlen(s);
    memset(p, ' ', n);
    memcpy(p, s, l < n ? l : n);
}

/* ---- interrupts ---- */
static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
static int cq_pending(Nvme *n) {
    for (int i = 0; i <= NVME_MAX_QP; i++)
        if (n->cq[i].valid && n->cq[i].ien && n->cq[i].head != n->cq[i].tail) return 1;
    return 0;
}
static void update_irq(Nvme *n) {
    n->unmask_ns = 0;
    n->rearm_ns = 0;
    int level = 0;
    if (!(n->intms & 1)) {
        for (int i = 0; i <= NVME_MAX_QP; i++)
            if (n->cq[i].valid && n->cq[i].ien && n->cq[i].head != n->cq[i].tail) { level = 1; break; }
    }
    if (level != n->pci.intx) hv_trace(HVT_NVME_INTX, (uint64_t)level, (uint64_t)n->intms << 32 | n->cq[1].head << 16 | n->cq[1].tail);
    if (level && !n->pci.intx) n->raise_ns = now_ns();
    hv_pci_set_intx(&n->pci, level);
}

/* ---- PRP transfers ---- */
typedef int (*chunk_fn)(Nvme *n, uint64_t pa, uint32_t len, void *ctx);

/* Calls fn for each contiguous guest piece of a PRP1/PRP2 described transfer of len bytes. */
static int prp_walk(Nvme *n, uint64_t prp1, uint64_t prp2, uint32_t len, chunk_fn fn, void *ctx) {
    uint32_t ps = n->page_size;
    if (!len) return 0;
    uint32_t first = ps - (uint32_t)(prp1 & (ps - 1));
    if (first > len) first = len;
    if (fn(n, prp1, first, ctx) != 0) return -1;
    len -= first;
    if (!len) return 0;
    if (len <= ps) return fn(n, prp2, len, ctx); /* PRP2 is the second page */
    uint64_t list = prp2;
    uint32_t per = ps / 8, idx = (uint32_t)(list & (ps - 1)) / 8;
    list &= ~(uint64_t)(ps - 1);
    while (len) {
        uint64_t e;
        if (hv_phys_read(n->m, list + (uint64_t)idx * 8, &e, 8) != 0) return -1;
        if (idx == per - 1 && len > ps) { /* chain to the next list page */
            list = e & ~(uint64_t)(ps - 1);
            idx = 0;
            continue;
        }
        uint32_t c = len > ps ? ps : len;
        if (fn(n, e, c, ctx) != 0) return -1;
        len -= c;
        idx++;
    }
    return 0;
}

typedef struct { uint64_t disk_off; int write, disk_err; } XferCtx;

static int xfer_chunk(Nvme *n, uint64_t pa, uint32_t len, void *vctx) {
    XferCtx *x = vctx;
    void *p = hv_phys_ptr(n->m, pa, len);
    if (!p) return -1;
    if (x->write) { // guest -> disk
        if (hv_disk_write(n->disk, x->disk_off, p, len) != 0) { x->disk_err = 1; return -1; }
    } else {
        if (hv_disk_read(n->disk, x->disk_off, p, len) != 0) { x->disk_err = 1; return -1; }
        hv_dma_written(n->m, pa, len);
    }
    x->disk_off += len;
    return 0;
}

/* Returns a status. */
static int disk_xfer(Nvme *n, uint64_t prp1, uint64_t prp2, uint64_t off, uint32_t len, int write) {
    XferCtx x = {off, write, 0};
    if (prp_walk(n, prp1, prp2, len, xfer_chunk, &x) == 0) return ST_OK;
    if (x.disk_err) return write ? ST_WRITE_FAULT : ST_READ_ERROR;
    return ST_DATA_XFER; /* bad PRP */
}

typedef struct { uint8_t *buf; uint32_t pos; int to_guest; } BufCtx;
static int buf_chunk(Nvme *n, uint64_t pa, uint32_t len, void *vctx) {
    BufCtx *b = vctx;
    void *p = hv_phys_ptr(n->m, pa, len);
    if (!p) return -1;
    if (b->to_guest) { memcpy(p, b->buf + b->pos, len); hv_dma_written(n->m, pa, len); }
    else memcpy(b->buf + b->pos, p, len);
    b->pos += len;
    return 0;
}
static int buf_xfer(Nvme *n, uint64_t prp1, uint64_t prp2, uint8_t *buf, uint32_t len, int to_guest) {
    BufCtx b = {buf, 0, to_guest};
    return prp_walk(n, prp1, prp2, len, buf_chunk, &b) == 0 ? ST_OK : ST_DATA_XFER;
}

/* ---- queues ---- */
static void post(Nvme *n, int qid, uint32_t cid, uint32_t result, uint32_t status) {
    NvmeQ *sq = &n->sq[qid], *cq = &n->cq[sq->cqid];
    uint8_t e[16];
    u32(e, result);
    u32(e + 4, 0);
    u16(e + 8, (uint16_t)sq->head);
    u16(e + 10, (uint16_t)qid);
    u16(e + 12, (uint16_t)cid);
    u16(e + 14, (uint16_t)((status << 1) | cq->phase));
    hv_phys_write(n->m, cq->base + (uint64_t)cq->tail * 16, e, 16);
    hv_trace(HVT_NVME_POST, (uint64_t)qid << 32 | cid, (uint64_t)(sq->cqid) << 32 | cq->tail);
    cq->tail++;
    if (cq->tail == cq->size) { cq->tail = 0; cq->phase ^= 1; }
}

static int cq_full(NvmeQ *cq) { return (cq->tail + 1) % cq->size == cq->head; }

static void ident_ctrl(Nvme *n, uint8_t *d) {
    u16(d + 0, 0x1b36);
    u16(d + 2, 0x1af4);
    pad(d + 4, 20, "WINARM0001");
    pad(d + 24, 40, "winarm NVMe Controller");
    pad(d + 64, 8, "1.0");
    d[72] = 0;       /* RAB */
    d[73] = 0x00; d[74] = 0x00; d[75] = 0x00;
    d[77] = NVME_MDTS;
    u16(d + 78, 0);  /* CNTLID */
    u32(d + 80, 0x10400);
    d[258] = 3;      /* ACL */
    d[259] = NVME_MAX_AER - 1;
    d[260] = 0x01;   /* FRMW: slot 1 read-only */
    d[262] = 63;     /* ELPE */
    d[512] = 0x66;   /* SQES */
    d[513] = 0x44;   /* CQES */
    u16(d + 514, 0x400); /* MAXCMD */
    u32(d + 516, 1); /* NN */
    u16(d + 520, 0x000c); /* ONCS: DSM, write zeroes */
    d[525] = 1;      /* VWC present */
    strcpy((char *)d + 768, "nqn.2014-08.org.nvme:winarm");
    (void)n;
}

static void ident_ns(Nvme *n, uint8_t *d) {
    u64(d + 0, n->nlba);
    u64(d + 8, n->nlba);
    u64(d + 16, n->nlba);
    d[25] = 0;       /* NLBAF: one format */
    d[26] = 0;       /* FLBAS */
    memcpy(d + 104, n->guid, 16);
    d[128 + 2] = 9;  /* LBAF0: 512-byte data size, no metadata */
}

static void admin_cmd(Nvme *n, const uint8_t *c) {
    uint8_t op = c[0];
    uint16_t cid; memcpy(&cid, c + 2, 2);
    uint32_t nsid, d10, d11;
    uint64_t prp1, prp2;
    memcpy(&nsid, c + 4, 4); memcpy(&prp1, c + 24, 8); memcpy(&prp2, c + 32, 8);
    memcpy(&d10, c + 40, 4); memcpy(&d11, c + 44, 4);
    uint32_t status = ST_OK, result = 0;
    static uint8_t page[4096];

    if (getenv("WINVM_NVME_LOG")) fprintf(stderr, "nvme: admin op %02x cid %u nsid %u d10 %x d11 %x\n", op, cid, nsid, d10, d11);
    switch (op) {
    case 0x00: { /* delete SQ */
        uint32_t q = d10 & 0xffff;
        if (!q || q > NVME_MAX_QP || !n->sq[q].valid) { status = ST_INVALID_QID; break; }
        n->sq[q].valid = 0;
        break;
    }
    case 0x04: { /* delete CQ */
        uint32_t q = d10 & 0xffff;
        if (!q || q > NVME_MAX_QP || !n->cq[q].valid) { status = ST_INVALID_QID; break; }
        for (int i = 1; i <= NVME_MAX_QP; i++)
            if (n->sq[i].valid && n->sq[i].cqid == q) status = ST_INVALID_QDEL;
        if (status == ST_OK) n->cq[q].valid = 0;
        break;
    }
    case 0x01: { /* create SQ */
        uint32_t q = d10 & 0xffff, qs = (d10 >> 16) + 1, cqid = d11 >> 16;
        if (!q || q > NVME_MAX_QP || n->sq[q].valid) status = ST_INVALID_QID;
        else if (qs < 2 || qs > NVME_MQES + 1) status = ST_INVALID_QSIZE;
        else if (!cqid || cqid > NVME_MAX_QP || !n->cq[cqid].valid) status = ST_INVALID_CQ;
        else if (!(d11 & 1) || (prp1 & (n->page_size - 1))) status = ST_INVALID_FIELD;
        else n->sq[q] = (NvmeQ){.base = prp1, .size = qs, .cqid = (uint16_t)cqid, .valid = 1};
        break;
    }
    case 0x05: { /* create CQ */
        uint32_t q = d10 & 0xffff, qs = (d10 >> 16) + 1;
        if (!q || q > NVME_MAX_QP || n->cq[q].valid) status = ST_INVALID_QID;
        else if (qs < 2 || qs > NVME_MQES + 1) status = ST_INVALID_QSIZE;
        else if (!(d11 & 1) || (prp1 & (n->page_size - 1))) status = ST_INVALID_FIELD;
        else n->cq[q] = (NvmeQ){.base = prp1, .size = qs, .phase = 1, .ien = (d11 >> 1) & 1, .valid = 1};
        break;
    }
    case 0x02: { /* get log page */
        uint32_t lid = d10 & 0xff, numd = (((d11 & 0xffff) << 16) | (d10 >> 16)) + 1;
        uint32_t len = numd * 4;
        if (len > sizeof page) len = sizeof page;
        memset(page, 0, sizeof page);
        if (lid == 0x03) page[0] = 1;                        /* firmware slot: active slot 1 */
        if (lid == 0x02) u16(page + 1, 310);                 /* SMART: composite temperature, K */
        if (lid == 0x02) page[3] = 100;                      /* available spare */
        status = buf_xfer(n, prp1, prp2, page, len, 1);
        break;
    }
    case 0x06: { /* identify */
        uint32_t cns = d10 & 0xff;
        memset(page, 0, sizeof page);
        if (cns == 0) {
            if (nsid != 1 && nsid != 0xffffffffu) { status = ST_INVALID_NS; break; }
            ident_ns(n, page);
        } else if (cns == 1) ident_ctrl(n, page);
        else if (cns == 2) { if (nsid < 1) u32(page, 1); }
        else if (cns == 3) {
            if (nsid != 1) { status = ST_INVALID_NS; break; }
            page[0] = 2; page[1] = 16; memcpy(page + 4, n->guid, 16); /* NGUID; the rest is zero (end) */
        } else { status = ST_INVALID_FIELD; break; }
        status = buf_xfer(n, prp1, prp2, page, 4096, 1);
        break;
    }
    case 0x08: result = 1; break; /* abort: not aborted */
    case 0x09: { /* set features */
        uint32_t fid = d10 & 0xff;
        if (fid == 0x07) {
            uint32_t nsq = (d11 & 0xffff) + 1, ncq = (d11 >> 16) + 1;
            if (nsq > NVME_MAX_QP) nsq = NVME_MAX_QP;
            if (ncq > NVME_MAX_QP) ncq = NVME_MAX_QP;
            n->features[fid] = ((ncq - 1) << 16) | (nsq - 1);
            result = n->features[fid];
        } else if (fid >= 1 && fid <= 0x0b && fid != 0x0d && fid != 0x0e && fid != 0x0c) n->features[fid] = d11;
        else status = ST_INVALID_FIELD;
        break;
    }
    case 0x0a: { /* get features */
        uint32_t fid = d10 & 0xff;
        if (fid >= 1 && fid <= 0x0b && fid != 0x0d && fid != 0x0e && fid != 0x0c) {
            result = n->features[fid];
            if (fid == 0x07 && !result) result = ((NVME_MAX_QP - 1) << 16) | (NVME_MAX_QP - 1);
        } else status = ST_INVALID_FIELD;
        break;
    }
    case 0x0c: /* async event request: held, never completed */
        if (n->aer_pending >= NVME_MAX_AER) { status = ST_AER_LIMIT; break; }
        n->aer_pending++;
        return;
    default: status = ST_INVALID_OPC; break;
    }
    post(n, 0, cid, result, status);
}

static void io_cmd(Nvme *n, int qid, const uint8_t *c) {
    uint8_t op = c[0];
    uint16_t cid; memcpy(&cid, c + 2, 2);
    uint32_t nsid, d10, d11, d12;
    uint64_t prp1, prp2;
    memcpy(&nsid, c + 4, 4); memcpy(&prp1, c + 24, 8); memcpy(&prp2, c + 32, 8);
    memcpy(&d10, c + 40, 4); memcpy(&d11, c + 44, 4); memcpy(&d12, c + 48, 4);
    uint32_t status = ST_OK;
    if (nsid != 1 && nsid != 0xffffffffu) { post(n, qid, cid, 0, ST_INVALID_NS | ST_DNR); return; }
    if (op == 0x01 && n->readonly) { post(n, qid, cid, 0, ST_READONLY | ST_DNR); return; }

    switch (op) {
    case 0x00:
        if (hv_disk_flush(n->disk) != 0) status = ST_INTERNAL;
        break;
    case 0x01:
    case 0x02: {
        uint64_t slba = ((uint64_t)d11 << 32) | d10;
        uint32_t nlb = (d12 & 0xffff) + 1;
        if (slba >= n->nlba || nlb > n->nlba - slba) status = ST_LBA_RANGE | ST_DNR;
        else if ((uint64_t)nlb * 512 > ((uint64_t)n->page_size << NVME_MDTS)) status = ST_INVALID_FIELD | ST_DNR;
        else {
            status = disk_xfer(n, prp1, prp2, slba * 512, nlb * 512, op == 0x01);
        }
        break;
    }
    case 0x08: {
        uint64_t slba = ((uint64_t)d11 << 32) | d10;
        uint32_t nlb = (d12 & 0xffff) + 1;
        if (slba >= n->nlba || nlb > n->nlba - slba) status = ST_LBA_RANGE | ST_DNR;
        else if (hv_disk_zero(n->disk, slba * 512, (uint64_t)nlb * 512) != 0) status = ST_WRITE_FAULT;
        break;
    }
    case 0x09: /* dataset management: deallocate is a no-op (reads still return the old data; DLFEAT says so) */
        if ((d11 & 4) && n->readonly) status = ST_READONLY | ST_DNR;
        break;
    default: status = ST_INVALID_OPC | ST_DNR; break;
    }
    post(n, qid, cid, 0, status);
}

/* Run every SQ with pending commands while its CQ has room. */
static void process(Nvme *n) {
    int progress;
    do {
        progress = 0;
        for (int q = 0; q <= NVME_MAX_QP; q++) {
            NvmeQ *sq = &n->sq[q];
            if (!sq->valid) continue;
            while (sq->head != sq->tail && !cq_full(&n->cq[sq->cqid])) {
                uint8_t cmd[64];
                if (hv_phys_read(n->m, sq->base + (uint64_t)sq->head * 64, cmd, 64) != 0) memset(cmd, 0xff, 64);
                sq->head = (sq->head + 1) % sq->size;
                if (q == 0) admin_cmd(n, cmd); else io_cmd(n, q, cmd);
                progress = 1;
            }
        }
    } while (progress);
    update_irq(n);
}

/* ---- controller state ---- */
static void ctrl_reset(Nvme *n) {
    memset(n->sq, 0, sizeof n->sq);
    memset(n->cq, 0, sizeof n->cq);
    memset(n->features, 0, sizeof n->features);
    n->aer_pending = 0;
    n->csts = 0;
    n->cc = 0;
    n->intms = 0;
    update_irq(n);
}

static void ctrl_enable(Nvme *n) {
    uint32_t mps = (n->cc >> 7) & 0xf;
    uint32_t asqs = (n->aqa & 0xfff) + 1, acqs = ((n->aqa >> 16) & 0xfff) + 1;
    if (mps > 4 || asqs < 2 || acqs < 2 || !n->asq || !n->acq) { n->csts = 2; /* CFS */ return; }
    n->page_size = 4096u << mps;
    n->sq[0] = (NvmeQ){.base = n->asq & ~(uint64_t)(n->page_size - 1), .size = asqs, .valid = 1};
    n->cq[0] = (NvmeQ){.base = n->acq & ~(uint64_t)(n->page_size - 1), .size = acqs, .phase = 1, .ien = 1, .valid = 1};
    n->csts = 1;
}

static void reg_write32(Nvme *n, uint32_t off, uint32_t v) {
    switch (off) {
    case R_INTMS: n->intms |= v; hv_trace(HVT_NVME_INTMS, v, 0); update_irq(n); break;
    case R_INTMC: /* On hardware the INTx message reaches the CPU some microseconds after the unmask write. Windows' stornvme
                     re-checks its completion queue right after INTMC and declines an interrupt that arrives inside that
                     window (its DPC is still running), so an instant re-raise storms CPU 0 for ever. Raise it from the poll. */
        n->intms &= ~v; hv_trace(HVT_NVME_INTMC, v, 0);
        if (!n->pci.intx && cq_pending(n)) n->unmask_ns = now_ns() | 1;
        else update_irq(n);
        break;
    case R_CC: {
        uint32_t old = n->cc;
        if (getenv("WINVM_NVME_LOG")) fprintf(stderr, "nvme: CC %08x -> %08x\n", old, (uint32_t)v);
        n->cc = (v & 0x00ffffffu) & ~0x0000000eu;
        if ((n->cc & 1) && !(old & 1)) { n->csts &= ~0xcu; ctrl_enable(n); }
        else if (!(n->cc & 1) && (old & 1)) { uint32_t cc = n->cc; ctrl_reset(n); n->cc = cc & ~1u; }
        if ((n->cc & 1) && ((n->cc >> 14) & 3)) n->csts = (n->csts & ~0xcu) | 8;      /* SHST: complete */
        else if (!((n->cc >> 14) & 3)) n->csts &= ~0xcu;
        break;
    }
    case R_AQA: if (!(n->cc & 1)) n->aqa = v & 0x0fff0fff; break;
    case R_ASQ: if (!(n->cc & 1)) n->asq = (n->asq & ~0xffffffffull) | v; break;
    case R_ASQ + 4: if (!(n->cc & 1)) n->asq = (n->asq & 0xffffffffull) | ((uint64_t)v << 32); break;
    case R_ACQ: if (!(n->cc & 1)) n->acq = (n->acq & ~0xffffffffull) | v; break;
    case R_ACQ + 4: if (!(n->cc & 1)) n->acq = (n->acq & 0xffffffffull) | ((uint64_t)v << 32); break;
    default: break;
    }
}

static uint32_t reg_read32(Nvme *n, uint32_t off) {
    switch (off) {
    case R_CAP: return NVME_MQES | (1u << 16) | (20u << 24); /* CQR, TO = 10 s */
    case R_CAP + 4: return (1u << 5) | (0u << 16) | (4u << 20); /* CSS: NVM; MPSMIN 0, MPSMAX 4; DSTRD 0 */
    case R_VS: return 0x00010400;
    case R_INTMS: case R_INTMC: return n->intms;
    case R_CC: return n->cc;
    case R_CSTS: return n->csts;
    case R_AQA: return n->aqa;
    case R_ASQ: return (uint32_t)n->asq;
    case R_ASQ + 4: return (uint32_t)(n->asq >> 32);
    case R_ACQ: return (uint32_t)n->acq;
    case R_ACQ + 4: return (uint32_t)(n->acq >> 32);
    default: return 0;
    }
}

static uint64_t bar_read(HvPciDev *d, int bar, uint64_t off, unsigned size) {
    Nvme *n = (Nvme *)d;
    (void)bar;
    n->touch_ns = now_ns();
    if (off >= 0x1000) return 0;
    uint64_t v = reg_read32(n, (uint32_t)(off & ~3ull)) | ((uint64_t)reg_read32(n, (uint32_t)(off & ~3ull) + 4) << 32);
    v >>= (off & 3) * 8;
    return size >= 8 ? v : v & ((1ull << (size * 8)) - 1);
}

static void bar_write(HvPciDev *d, int bar, uint64_t off, uint64_t v, unsigned size) {
    Nvme *n = (Nvme *)d;
    (void)bar;
    n->touch_ns = now_ns();
    if (off >= 0x1000) {
        if (off >= 0x1000 + 8 * (NVME_MAX_QP + 1) * 1ull || (off & 3)) return;
        uint32_t idx = (uint32_t)(off - 0x1000) / 4, q = idx / 2, val = (uint32_t)v;
        if (!n->csts || !(n->csts & 1)) return;
        if (idx & 1) {
            if (!n->cq[q].valid || val >= n->cq[q].size) return;
            hv_trace(HVT_NVME_CQDB, (uint64_t)q, (uint64_t)val << 16 | n->cq[q].tail);
            n->cq[q].head = val;
        } else {
            if (!n->sq[q].valid || val >= n->sq[q].size) return;
            hv_trace(HVT_NVME_SQDB, (uint64_t)q, (uint64_t)val << 16 | n->sq[q].head);
            n->sq[q].tail = val;
        }
        process(n);
        return;
    }
    if (size == 8) {
        reg_write32(n, (uint32_t)off, (uint32_t)v);
        reg_write32(n, (uint32_t)off + 4, (uint32_t)(v >> 32));
    } else if (size == 4 && !(off & 3)) {
        reg_write32(n, (uint32_t)off, (uint32_t)v);
    } else {
        uint32_t base = (uint32_t)(off & ~3ull), sh = (uint32_t)(off & 3) * 8;
        uint32_t mask = (size >= 4 ? 0xffffffffu : (1u << (size * 8)) - 1) << sh;
        reg_write32(n, base, (reg_read32(n, base) & ~mask) | (((uint32_t)v << sh) & mask));
    }
}

static void nvme_poll(void *o) {
    Nvme *n = o;
    uint64_t t = now_ns();
    if (n->unmask_ns && t - n->unmask_ns >= 20000) { update_irq(n); return; }
    if (n->rearm_ns) { if (t >= n->rearm_ns) update_irq(n); return; }
    /* Storm breaker. If stornvme still declines a raise (its DPC was preempted inside the INTMC window), the level
       line re-enters CPU 0 forever and the DPC never finishes: Windows hung at "Installing 33%" for 20 hours. A raise
       that the driver leaves untouched (no register access) for 2 ms is dropped for 1 ms, which lets the DPC run. */
    uint64_t last = n->raise_ns > n->touch_ns ? n->raise_ns : n->touch_ns;
    if (n->pci.intx && t - last >= 2000000) {
        if (n->storms++ < 8) fprintf(stderr, "winvm nvme: INTx unclaimed for 2 ms, dropped for 1 ms (#%u)\n", n->storms);
        hv_pci_set_intx(&n->pci, 0);
        n->rearm_ns = t + 1000000;
    }
}

void *winvm_nvme_create(WinArm *b, HvDisk *disk, int readonly) {
    Nvme *n = calloc(1, sizeof *n);
    if (!n) return NULL;
    n->m = b->m;
    n->disk = disk;
    n->readonly = readonly || disk->readonly;
    n->nlba = disk->size / 512;
    n->page_size = 4096;
    uint64_t h = 0xcbf29ce484222325ull ^ n->nlba;
    for (int i = 0; i < 16; i++) { h = (h ^ (uint64_t)(i + 1)) * 0x100000001b3ull; n->guid[i] = (uint8_t)(h >> 24); }
    n->guid[0] |= 0x01;

    HvPciDev *d = &n->pci;
    hv_pci_init(d, 0x1b36, 0x0010, 0x01080200, 0x1af4, 0x1100);
    hv_pci_add_bar(d, 0, NVME_BAR_SIZE, 1);
    d->opaque = n;
    d->bar_read = bar_read;
    d->bar_write = bar_write;
    d->config[0x06] |= 0x10;  /* status: capabilities list */
    d->config[0x34] = 0x40;
    /* power management capability */
    d->config[0x40] = 0x01; d->config[0x41] = 0x50;
    u16(d->config + 0x42, 0x0003);
    d->wmask[0x44] = 0x03;
    /* PCI Express capability: root-complex integrated... endpoint, v2 */
    d->config[0x50] = 0x10; d->config[0x51] = 0x00;
    u16(d->config + 0x52, 0x0092);          /* root-complex integrated endpoint (it sits on the root bus, as QEMU's do), version 2.
                                               A plain endpoint (type 0) there has no port above it, and Windows' PCI driver left it unstarted. */
    u32(d->config + 0x54, 0x00008000);      /* device caps: role-based error reporting */
    d->wmask[0x58] = 0xff; d->wmask[0x59] = 0x7f;
    u32(d->config + 0x5c, 0x00000043);      /* link caps: 8 GT/s, x4 */
    d->wmask[0x60] = 0x03;
    u16(d->config + 0x62, 0x0043);          /* link status: 8 GT/s, x4 */
    u32(d->config + 0x74, 0);               /* device caps 2 */
    d->wmask[0x78] = 0xff;
    u16(d->config + 0x82, 0x0003);          /* link status 2 */
    if (hv_pcie_attach(b->pcie, d) < 0) { free(n); return NULL; }
    b->nvme = n;
    winarm_add_poll(b, nvme_poll, n);
    return n;
}
