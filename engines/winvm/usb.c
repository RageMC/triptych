// SPDX-License-Identifier: GPL-2.0-or-later
//
// USB for the winarm board. This is a fork of Henge's devices/xhci.c (engines/gesso,
// GPL-2.0-or-later, same licence as this file), generalised: where Henge's controller is
// hardwired to a keyboard and an Apple Magic Trackpad, this one has a small device
// interface (descriptors, control requests, endpoint IN/OUT handlers) and three devices:
//   - a HID boot keyboard,
//   - a HID absolute-pointer tablet (a QEMU usb-tablet style report: buttons, 16-bit X/Y, wheel),
//   - USB mass storage (bulk-only transport, SCSI) presenting an image as a CD-ROM
//     (type 5, 2048-byte blocks) or a disk (type 0, 512-byte blocks).
// Controller changes from Henge: 4 USB 2 + 2 USB 3 root ports, correct speed IDs and
// protocol capability counts, TD-based transfer processing (chained TRBs, Event Data,
// immediate data, short packets, stalls), bulk endpoints, command abort, MFINDEX,
// bounds-checked capability reads, interrupts on INTx only (no MSI/MSI-X capability).
//
// Debugging: WINVM_USB_LOG=1 logs commands, port writes and HID reports; =2 adds control requests and SCSI commands.
#include "usb.h"
#include "devices_ext.h"
#include "machine.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* ---- controller layout ---- */

#define USB_SLOTS 32
#define USB_INTRS 8
#define USB_EPS 32          /* device context index 1..31 */
#define USB2_PORTS 4        /* root ports 1..4 */
#define USB3_PORTS 2        /* root ports 5..6 */
#define USB_PORTS (USB2_PORTS + USB3_PORTS)
#define MAXTD 4096          /* TRBs in one transfer descriptor */
#define MAXXFER (32u << 20)

#define CAPLENGTH 0x40
#define OP 0x40
#define PORTREGS 0x440
#define RT 0x1000
#define DB 0x2000
#define XECP 0x800
#define BAR_SIZE 0x4000

enum {
    TRB_NORMAL = 1, TRB_SETUP = 2, TRB_DATA = 3, TRB_STATUS = 4, TRB_ISOCH = 5, TRB_LINK = 6, TRB_EVENT_DATA = 7,
    TRB_NOOP = 8, TRB_ENABLE_SLOT = 9, TRB_DISABLE_SLOT = 10, TRB_ADDRESS_DEVICE = 11, TRB_CONFIGURE_EP = 12,
    TRB_EVALUATE_CTX = 13, TRB_RESET_EP = 14, TRB_STOP_EP = 15, TRB_SET_TR_DEQUEUE = 16, TRB_RESET_DEVICE = 17,
    TRB_FORCE_EVENT = 18, TRB_NEGOTIATE_BW = 19, TRB_SET_LTV = 20, TRB_GET_PORT_BW = 21, TRB_FORCE_HEADER = 22,
    TRB_NOOP_CMD = 23, TRB_TRANSFER_EVENT = 32, TRB_CMD_COMPLETION = 33, TRB_PORT_STATUS = 34,
};
enum {
    CC_SUCCESS = 1, CC_TRB_ERROR = 5, CC_STALL = 6, CC_SLOTS_FULL = 9, CC_SLOT_NOT_ENABLED = 11,
    CC_EP_NOT_ENABLED = 12, CC_SHORT_PACKET = 13, CC_CONTEXT_STATE = 19, CC_CMD_RING_STOPPED = 24,
    CC_CMD_ABORTED = 25, CC_USB_TRANSACTION_ERROR = 4,
};

#define PORT_CCS (1u << 0)
#define PORT_PED (1u << 1)
#define PORT_PR (1u << 4)
#define PORT_PLS_SHIFT 5
#define PORT_PLS_MASK (0xfu << PORT_PLS_SHIFT)
#define PORT_PP (1u << 9)
#define PORT_SPEED_SHIFT 10
#define PORT_LWS (1u << 16)
#define PORT_CSC (1u << 17)
#define PORT_PEC (1u << 18)
#define PORT_WRC (1u << 19)
#define PORT_OCC (1u << 20)
#define PORT_PRC (1u << 21)
#define PORT_PLC (1u << 22)
#define PORT_CEC (1u << 23)
#define PORT_CHANGES (PORT_CSC | PORT_PEC | PORT_WRC | PORT_OCC | PORT_PRC | PORT_PLC | PORT_CEC)
#define PORT_WPR (1u << 31)
#define PORT_KEEP (3u << 14 | 7u << 25) /* PIC, wake enables */
#define PLS_U0 0
#define PLS_U3 3
#define PLS_RXDETECT 5
#define PLS_POLLING 7
#define PLS_RESUME 15
/* Default protocol speed IDs (no PSI entries): 1 full, 2 low, 3 high, 4 super. */
#define SPEED_FULL 1
#define SPEED_HIGH 3
#define SPEED_SUPER 4

static int ulog_on = -1;
#include <time.h>
static void ulog_t(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); fprintf(stderr, "%5ld.%03ld ", (long)(ts.tv_sec % 100000), ts.tv_nsec / 1000000); }
#define ulog2(...) do { if (ulog_on < 0) ulog_on = getenv("WINVM_USB_LOG") != NULL; if (ulog_on && atoi(getenv("WINVM_USB_LOG")) >= 2) { ulog_t(); fprintf(stderr, __VA_ARGS__); } } while (0)
#define ulog(...) do { if (ulog_on < 0) ulog_on = getenv("WINVM_USB_LOG") != NULL; if (ulog_on) { ulog_t(); fprintf(stderr, __VA_ARGS__); } } while (0)

/* ---- the device interface ---- */

typedef struct UsbDev UsbDev;
struct UsbDev {
    const char *name;
    int speed;                       /* SPEED_FULL or SPEED_HIGH */
    const uint8_t *dev_desc;         /* 18 bytes */
    const uint8_t *cfg_desc; int cfg_len;
    const uint8_t *qual_desc;        /* 10 bytes, or NULL: no device qualifier */
    const uint8_t *report_desc; int report_len; /* HID: the HID descriptor sits at cfg_desc + 18 */
    const char *const *strings;      /* index 1..nstrings; strings[0] unused */
    int nstrings;
    int configured, remote_wakeup;
    uint8_t halted[2][16];           /* [0] OUT, [1] IN, by endpoint number */
    /* Class and vendor control requests. `buf` holds the OUT data (len bytes) or receives the
       IN reply (up to len = wLength). Return the reply length (>= 0), or -1 to stall. */
    int (*control)(UsbDev *d, const uint8_t setup[8], uint8_t *buf, int len);
    /* An interrupt or bulk IN transfer of up to `max` bytes. 0: *got bytes; 1: nothing yet (NAK); -1: stall. */
    int (*ep_in)(UsbDev *d, int ep, uint8_t *buf, uint32_t max, uint32_t *got);
    /* A bulk or interrupt OUT transfer. 0: accepted; -1: stall. */
    int (*ep_out)(UsbDev *d, int ep, const uint8_t *buf, uint32_t len);
    void (*reset)(UsbDev *d);        /* port reset */
    /* Alternate settings: alt >= 0 is SET_INTERFACE (return 0, or -1 to stall), alt < 0 is GET_INTERFACE
       (return the current one). NULL: every interface has alternate 0 only. */
    int (*altsetting)(UsbDev *d, int intf, int alt);
};

/* ---- the controller ---- */

typedef struct { uint64_t deq; int ccs; } Ring;
typedef struct { uint64_t addr; uint32_t d[4]; } Trb;

typedef struct Usb {
    HvPciDev pci;
    HvMachine *m;
    uint32_t usbcmd, usbsts, dnctrl, config;
    uint64_t dcbaap;
    Ring cmd;
    int cmd_running;
    uint32_t portsc[USB_PORTS];
    UsbDev *port_dev[USB_PORTS];
    struct UsbIntr {
        uint32_t iman, imod, erstsz;
        uint64_t erstba, erdp;
        uint64_t seg_base;
        uint32_t seg_size, seg_index, index;
        int pcs;
        uint32_t npend, nfull;       /* events held while the ring is full (the guest hasn't moved ERDP on) */
        uint32_t pend[256][4];
    } intr[USB_INTRS];
    struct UsbSlot {
        int used;
        UsbDev *dev;                 /* NULL until Address Device */
        struct { Ring ring; int state; } ep[USB_EPS]; /* state: 0 disabled, 1 running, 2 halted, 3 stopped */
    } slots[USB_SLOTS + 1];
    Trb td[MAXTD];
} Usb;

static Usb *g_usb;
#ifdef WINVM_NET
#include "ncm.h"
#include "net_slirp.h"
static struct Ncm *g_ncm;      /* the network adapter, if attached */
#endif
static uint8_t *scratch;
static size_t scratch_cap;

static uint8_t *need_scratch(size_t n) {
    if (n > scratch_cap) {
        size_t c = n < 65536 ? 65536 : n;
        uint8_t *p = realloc(scratch, c);
        if (!p) return NULL;
        scratch = p;
        scratch_cap = c;
    }
    return scratch;
}

/* ---- guest memory ---- */

static void rd(Usb *x, uint64_t pa, void *buf, unsigned len) {
    if (hv_phys_read(x->m, pa, buf, len) != 0) memset(buf, 0, len);
}
static void wr(Usb *x, uint64_t pa, const void *buf, unsigned len) { hv_phys_write(x->m, pa, buf, len); }
static uint32_t rd32(Usb *x, uint64_t pa) { uint32_t v; rd(x, pa, &v, 4); return v; }

/* Copy a (possibly large) buffer to/from guest memory in page-sized pieces. */
static void wr_big(Usb *x, uint64_t pa, const uint8_t *p, uint32_t n) {
    while (n) { uint32_t c = n > 65536 ? 65536 : n; wr(x, pa, p, c); pa += c; p += c; n -= c; }
}
static void rd_big(Usb *x, uint64_t pa, uint8_t *p, uint32_t n) {
    while (n) { uint32_t c = n > 65536 ? 65536 : n; rd(x, pa, p, c); pa += c; p += c; n -= c; }
}

/* ---- interrupts and the event ring ---- */

static void update_irq(Usb *x) {
    int level = 0;
    for (int i = 0; i < USB_INTRS; i++) level |= (x->intr[i].iman & 1) && (x->intr[i].iman & 2);
    hv_pci_set_intx(&x->pci, level && (x->usbcmd & 4));
}

static void load_segment(Usb *x, struct UsbIntr *it) {
    uint64_t entry[2];
    rd(x, it->erstba + 16ull * it->seg_index, entry, 16);
    it->seg_base = entry[0] & ~0x3full;
    it->seg_size = (uint32_t)entry[1] & 0xffff;
    it->index = 0;
}

/* Is the ring full? The slot after the one we'd write next is where the guest's dequeue pointer (ERDP) sits. */
static int ring_full(Usb *x, struct UsbIntr *it) {
    uint64_t next;
    if (it->index + 1 < it->seg_size) next = it->seg_base + 16ull * (it->index + 1);
    else {
        uint64_t e[2];
        uint32_t si = it->seg_index + 1 >= it->erstsz ? 0 : it->seg_index + 1;
        rd(x, it->erstba + 16ull * si, e, 16);
        next = e[0] & ~0x3full;
    }
    return next == (it->erdp & ~0xfull);
}

static void put_trb(Usb *x, struct UsbIntr *it, const uint32_t *t) {
    uint32_t trb[4] = {t[0], t[1], t[2], (t[3] & ~1u) | (uint32_t)it->pcs};
    uint64_t pa = it->seg_base + 16ull * it->index;
    wr(x, pa, trb, 12);
    uint32_t *p = hv_phys_ptr(x->m, pa + 12, 4); /* the cycle bit goes last, with release */
    if (p) __atomic_store_n(p, trb[3], __ATOMIC_RELEASE); else wr(x, pa + 12, &trb[3], 4);
    if (++it->index == it->seg_size) {
        if (++it->seg_index >= it->erstsz) { it->seg_index = 0; it->pcs ^= 1; }
        load_segment(x, it);
    }
}

/* Post held events while there is room (after an ERDP write). */
static void flush_pending(Usb *x, struct UsbIntr *it) {
    uint32_t done = 0;
    while (done < it->npend && it->seg_size && !ring_full(x, it)) put_trb(x, it, it->pend[done++]);
    if (!done) return;
    memmove(it->pend, it->pend + done, (it->npend - done) * sizeof it->pend[0]);
    it->npend -= done;
    it->iman |= 1;
    x->usbsts |= 1u << 3;
    update_irq(x);
}

static void event_to(Usb *x, int target, uint64_t param, uint32_t status, uint32_t control) {
    struct UsbIntr *it = &x->intr[target < USB_INTRS ? target : 0];
    ulog2("usb: event type %u -> interrupter %d (erstsz %u) cc %u slot %u ep %u\n", (control >> 10) & 63, target, it->erstsz, status >> 24, control >> 24, (control >> 16) & 31);
    if (!it->erstsz || !it->seg_size) { ulog("usb: event type %u to interrupter %d dropped: no event ring\n", (control >> 10) & 63, target); return; }
    uint32_t t[4] = {(uint32_t)param, (uint32_t)(param >> 32), status, control};
    if (it->npend || ring_full(x, it)) { /* hardware stops at a full ring; hold the event until the guest catches up */
        if (it->nfull++ < 5) fprintf(stderr, "usb: event ring %d full, holding events (%u held)\n", target, it->npend + 1);
        if (it->npend < 256) memcpy(it->pend[it->npend++], t, sizeof t);
        else ulog("usb: event ring %d: held events overflowed, one lost\n", target);
    } else put_trb(x, it, t);
    it->iman |= 1;
    x->usbsts |= 1u << 3; /* EINT */
    update_irq(x);
}

static void event(Usb *x, uint64_t param, uint32_t status, uint32_t control) { event_to(x, 0, param, status, control); }

static void port_event(Usb *x, int port) {
    x->usbsts |= 1u << 4; /* PCD */
    event(x, (uint64_t)(port + 1) << 24, (uint32_t)CC_SUCCESS << 24, TRB_PORT_STATUS << 10);
}

static void cmd_completion(Usb *x, uint64_t trb_pa, int cc, int slot) {
    event(x, trb_pa, (uint32_t)cc << 24, TRB_CMD_COMPLETION << 10 | (uint32_t)slot << 24);
}

static void xfer_event(Usb *x, int slot, int dci, const Trb *t, uint64_t param, int cc, uint32_t residual, int ed) {
    ulog2("usb:   xfer event slot %d dci %d param %llx cc %d residual %u ed %d\n", slot, dci, (unsigned long long)param, cc, residual, ed);
    event_to(x, (int)(t->d[2] >> 22), param, (uint32_t)cc << 24 | (residual & 0xffffff),
             TRB_TRANSFER_EVENT << 10 | (uint32_t)dci << 16 | (uint32_t)slot << 24 | (ed ? 4u : 0u));
}

/* ---- rings ---- */

/* Take the next TRB the guest owns on a ring, following links. 0: none yet. */
static int ring_get(Usb *x, Ring *r, Trb *t) {
    for (int guard = 0; guard < 64; guard++) {
        uint32_t *ctl = hv_phys_ptr(x->m, r->deq + 12, 4);
        uint32_t c = ctl ? __atomic_load_n(ctl, __ATOMIC_ACQUIRE) : 0;
        if ((c & 1) != (uint32_t)r->ccs) return 0;
        rd(x, r->deq, t->d, 12);
        t->d[3] = c;
        t->addr = r->deq;
        if (((c >> 10) & 0x3f) == TRB_LINK) {
            if (c & 2) r->ccs ^= 1;
            r->deq = ((uint64_t)t->d[1] << 32 | t->d[0]) & ~0xfull;
            continue;
        }
        r->deq += 16;
        return 1;
    }
    return 0;
}

static int trb_type(const Trb *t) { return (int)((t->d[3] >> 10) & 0x3f); }
static int is_data(const Trb *t) { int ty = trb_type(t); return ty == TRB_NORMAL || ty == TRB_DATA || ty == TRB_ISOCH; }

/* ---- device contexts (32 bytes each; the output context is at DCBAA[slot]) ---- */

static uint64_t out_ctx(Usb *x, int slot) {
    uint64_t p;
    rd(x, x->dcbaap + 8ull * slot, &p, 8);
    return p & ~0x3full;
}

static void set_ep_state(Usb *x, int slot, int dci, uint32_t state) {
    uint64_t ctx = out_ctx(x, slot) + 32ull * dci;
    uint32_t dw0 = rd32(x, ctx);
    dw0 = (dw0 & ~7u) | state;
    wr(x, ctx, &dw0, 4);
    x->slots[slot].ep[dci].state = (int)state;
}

/* ---- control transfers ---- */

static int put_string(const UsbDev *d, int idx, uint8_t *out, int max) {
    if (idx == 0) { out[0] = 4; out[1] = 3; out[2] = 0x09; out[3] = 0x04; return 4; }
    if (idx > d->nstrings || !d->strings[idx]) return -1;
    const char *s = d->strings[idx];
    int n = (int)strlen(s);
    if (2 + 2 * n > max) n = (max - 2) / 2;
    out[0] = (uint8_t)(2 + 2 * n); out[1] = 3;
    for (int i = 0; i < n; i++) { out[2 + 2 * i] = (uint8_t)s[i]; out[3 + 2 * i] = 0; }
    return 2 + 2 * n;
}

/* The standard requests, answered from the device's descriptors; class and vendor requests go to
   the device. `buf` is OUT data in (len bytes) or the reply out (up to len). Returns the reply
   length or -1 to stall. */
static int control_request(UsbDev *d, const uint8_t s[8], uint8_t *buf, int len) {
    uint8_t type = s[0], req = s[1];
    uint16_t value = (uint16_t)(s[2] | s[3] << 8), index = (uint16_t)(s[4] | s[5] << 8);
    int kind = (type >> 5) & 3, recip = type & 0x1f;
    ulog2("usb: %s request %02x %02x value %04x index %04x len %d\n", d->name, type, req, value, index, len);
    if (kind != 0) return d->control ? d->control(d, s, buf, len) : -1;
    const uint8_t *src = NULL;
    int n = 0;
    switch (req) {
    case 6: /* GET_DESCRIPTOR */
        if (!(type & 0x80)) return -1;
        if (recip == 0) {
            int dt = value >> 8, di = value & 0xff;
            if (dt == 1) src = d->dev_desc, n = 18;
            else if (dt == 2 && di == 0) src = d->cfg_desc, n = d->cfg_len;
            else if (dt == 3) {
                uint8_t tmp[128];
                n = put_string(d, di, tmp, sizeof tmp);
                if (n < 0) return -1;
                if (n > len) n = len;
                memcpy(buf, tmp, (size_t)n);
                return n;
            } else if (dt == 6 && d->qual_desc) src = d->qual_desc, n = 10;
            else return -1;
        } else if (recip == 1 && d->report_desc) {
            int dt = value >> 8;
            if (dt == 0x22) src = d->report_desc, n = d->report_len;
            else if (dt == 0x21) src = d->cfg_desc + 18, n = 9;
            else return -1;
        } else
            return -1;
        break;
    case 0: /* GET_STATUS */
        buf[0] = recip == 0 ? (uint8_t)(d->remote_wakeup << 1) : 0;
        if (recip == 2) buf[0] = d->halted[(index >> 7) & 1][index & 15];
        buf[1] = 0;
        return len < 2 ? len : 2;
    case 1: /* CLEAR_FEATURE */
        if (recip == 2 && value == 0) d->halted[(index >> 7) & 1][index & 15] = 0;
        else if (recip == 0 && value == 1) d->remote_wakeup = 0;
        return 0;
    case 3: /* SET_FEATURE */
        if (recip == 2 && value == 0) d->halted[(index >> 7) & 1][index & 15] = 1;
        else if (recip == 0 && value == 1) d->remote_wakeup = 1;
        return 0;
    case 5: return 0; /* SET_ADDRESS: Address Device did it */
    case 8: buf[0] = (uint8_t)d->configured; return len < 1 ? len : 1;
    case 9:
        d->configured = value & 0xff;
        if (d->altsetting) for (int i = 0; i < 8; i++) d->altsetting(d, i, 0); /* SET_CONFIGURATION resets them */
        return 0;
    case 10: /* GET_INTERFACE */
        buf[0] = (uint8_t)(d->altsetting ? d->altsetting(d, index & 0xff, -1) : 0);
        return len < 1 ? len : 1;
    case 11: /* SET_INTERFACE */
        return d->altsetting ? d->altsetting(d, index & 0xff, value & 0xff) : value == 0 ? 0 : -1;
    default: return -1;
    }
    if (n > len) n = len;
    memcpy(buf, src, (size_t)n);
    return n;
}

/* Report the events for a TD (or a control transfer's stages): which of its TRBs raise a Transfer Event,
   given `actual` bytes moved in the data TRBs (of `total`). Follows the xHCI rules for IOC, ISP,
   short packets and Event Data TRBs. */
static void report(Usb *x, int slot, int dci, const Trb *t, int n, uint32_t actual) {
    uint32_t total = 0, left = actual, edtla = 0;
    int lastdata = -1, short_seen = 0, short_rep = 0;
    for (int i = 0; i < n; i++) if (is_data(&t[i])) { total += t[i].d[2] & 0x1ffff; lastdata = i; }
    for (int i = 0; i < n; i++) {
        int ty = trb_type(&t[i]), ioc = (t[i].d[3] >> 5) & 1, isp = (t[i].d[3] >> 2) & 1;
        if (ty == TRB_SETUP || ty == TRB_STATUS) {
            short_seen = short_rep = 0;
            edtla = 0;
            if (ioc) xfer_event(x, slot, dci, &t[i], t[i].addr, CC_SUCCESS, 0, 0);
        } else if (is_data(&t[i])) {
            uint32_t len = t[i].d[2] & 0x1ffff, chunk = len < left ? len : left;
            left -= chunk;
            edtla += chunk;
            int here = chunk < len && !short_seen;
            if (here) short_seen = 1;
            if (here && (isp || ioc)) { xfer_event(x, slot, dci, &t[i], t[i].addr, CC_SHORT_PACKET, len - chunk, 0); short_rep = 1; }
            else if (!here && short_seen && ioc && i == lastdata && !short_rep) { xfer_event(x, slot, dci, &t[i], t[i].addr, CC_SHORT_PACKET, total - actual, 0); short_rep = 1; }
            else if (!short_seen && ioc) xfer_event(x, slot, dci, &t[i], t[i].addr, CC_SUCCESS, 0, 0);
        } else if (ty == TRB_EVENT_DATA) {
            if (ioc) {
                xfer_event(x, slot, dci, &t[i], (uint64_t)t[i].d[1] << 32 | t[i].d[0], short_seen ? CC_SHORT_PACKET : CC_SUCCESS, edtla, 1);
                edtla = 0;
            }
        } else if (ty == TRB_NOOP) {
            if (ioc) xfer_event(x, slot, dci, &t[i], t[i].addr, CC_SUCCESS, 0, 0);
        }
    }
}

/* Halt an endpoint at the TD starting at `td`: the dequeue pointer in the output context
   (which drivers read to find the halted TD) and our own ring point at its first TRB. */
static void halt_ep(Usb *x, int slot, int dci, const Trb *td, const Trb *t, uint32_t residual) {
    xfer_event(x, slot, dci, t, t->addr, CC_STALL, residual, 0);
    set_ep_state(x, slot, dci, 2);
    x->slots[slot].ep[dci].ring.deq = td->addr;
    x->slots[slot].ep[dci].ring.ccs = (int)(td->d[3] & 1);
    uint64_t deq = td->addr | (td->d[3] & 1);
    wr(x, out_ctx(x, slot) + 32ull * dci + 8, &deq, 8);
}

/* Scatter data into / gather data from the guest buffers of a run of data TRBs. */
static void trbs_to_guest(Usb *x, const Trb *t, int n, const uint8_t *p, uint32_t bytes) {
    for (int i = 0; i < n && bytes; i++) {
        if (!is_data(&t[i])) continue;
        uint32_t len = t[i].d[2] & 0x1ffff, c = len < bytes ? len : bytes;
        if (t[i].d[3] & 0x40) { /* immediate data in the pointer field (never for IN, but be safe) */ }
        else wr_big(x, (uint64_t)t[i].d[1] << 32 | t[i].d[0], p, c);
        p += c;
        bytes -= c;
    }
}

static uint32_t trbs_from_guest(Usb *x, const Trb *t, int n, uint8_t *p, uint32_t cap) {
    uint32_t got = 0;
    for (int i = 0; i < n && got < cap; i++) {
        if (!is_data(&t[i])) continue;
        uint32_t len = t[i].d[2] & 0x1ffff, c = len < cap - got ? len : cap - got;
        if (t[i].d[3] & 0x40) { uint8_t imm[8]; memcpy(imm, t[i].d, 8); memcpy(p + got, imm, c > 8 ? 8 : c); }
        else rd_big(x, (uint64_t)t[i].d[1] << 32 | t[i].d[0], p + got, c);
        got += c;
    }
    return got;
}

/* Run the control transfers queued on a slot's endpoint 0. */
static void run_ep0(Usb *x, int slot) {
    struct UsbSlot *s = &x->slots[slot];
    UsbDev *d = s->dev;
    if (!d) return;
    for (;;) {
        if (s->ep[1].state != 1) return;
        Ring r = s->ep[1].ring;
        Trb *t = x->td;
        int n = 0, complete = 0, status_seen = 0;
        while (n < MAXTD) {
            if (!ring_get(x, &r, &t[n])) break;
            int ty = trb_type(&t[n]), chain = (t[n].d[3] >> 4) & 1;
            n++;
            if (n == 1 && ty != TRB_SETUP) { complete = 2; break; } /* junk: skip it */
            if (ty == TRB_STATUS) status_seen = 1;
            /* The TD ends at the first unchained TRB from the Status stage on: Windows chains an Event Data TRB after it. */
            if (status_seen && !chain) { complete = 1; break; }
        }
        if (complete == 2) { s->ep[1].ring = r; continue; }
        if (!complete) return; /* the guest is still writing the stages */
        for (int i = 0; i < n; i++)
            ulog2("usb:   ep0 trb %d @%llx type %d d0 %08x d1 %08x d2 %08x d3 %08x\n", i, (unsigned long long)t[i].addr, trb_type(&t[i]), t[i].d[0], t[i].d[1], t[i].d[2], t[i].d[3]);
        uint8_t setup[8];
        if (t[0].d[3] & 0x40) memcpy(setup, t[0].d, 8); /* IDT: the setup packet is in the TRB */
        else memcpy(setup, t[0].d, 8);
        int wlen = setup[6] | setup[7] << 8, in = (setup[0] & 0x80) != 0;
        uint32_t total = 0;
        int first_data = -1;
        for (int i = 1; i < n; i++) if (is_data(&t[i])) { total += t[i].d[2] & 0x1ffff; if (first_data < 0) first_data = i; }
        uint8_t *buf = need_scratch(65536 + 8);
        if (!buf) return;
        uint32_t cap = (uint32_t)wlen < total ? (uint32_t)wlen : total;
        if (!in && wlen) { cap = trbs_from_guest(x, t + 1, n - 1, buf, cap); }
        int rc = control_request(d, setup, buf, in ? wlen : (int)cap);
        if (rc < 0) {
            halt_ep(x, slot, 1, &t[0], &t[first_data >= 0 ? first_data : n - 1], total);
            return; /* the ring stays at this TD until the driver resets the endpoint */
        }
        uint32_t actual = 0;
        if (in) {
            actual = (uint32_t)rc < total ? (uint32_t)rc : total;
            trbs_to_guest(x, t + 1, n - 1, buf, actual);
        } else
            actual = cap;
        report(x, slot, 1, t, n, actual);
        s->ep[1].ring = r;
    }
}

/* ---- bulk and interrupt transfers ---- */

/* Run the transfers posted on a non-control endpoint. */
static void run_ep(Usb *x, int slot, int dci) {
    struct UsbSlot *s = &x->slots[slot];
    UsbDev *d = s->dev;
    if (!d || dci < 2) return;
    int in = dci & 1, epn = dci >> 1;
    for (;;) {
        if (s->ep[dci].state != 1) return;
        Ring r = s->ep[dci].ring;
        Trb *t = x->td;
        int n = 0, complete = 0;
        while (n < MAXTD) {
            if (!ring_get(x, &r, &t[n])) break;
            n++;
            if (!((t[n - 1].d[3] >> 4) & 1)) { complete = 1; break; }
        }
        if (!complete && n < MAXTD) return;
        uint32_t total = 0;
        for (int i = 0; i < n; i++) if (is_data(&t[i])) total += t[i].d[2] & 0x1ffff;
        if (total > MAXXFER) total = MAXXFER;
        uint8_t *buf = need_scratch(total + 8);
        if (!buf) return;
        uint32_t actual = 0;
        int rc;
        if (d->halted[in][epn]) rc = -1;
        else if (in) {
            rc = d->ep_in ? d->ep_in(d, epn, buf, total, &actual) : -1;
            if (rc == 1) return; /* NAK: leave the TD for the next poll or doorbell */
            if (rc == 0) { if (actual > total) actual = total; trbs_to_guest(x, t, n, buf, actual); }
        } else {
            actual = trbs_from_guest(x, t, n, buf, total);
            rc = d->ep_out ? d->ep_out(d, epn, buf, actual) : -1;
            if (rc == 1) return;
        }
        if (rc < 0) {
            halt_ep(x, slot, dci, &t[0], &t[0], total);
            return;
        }
        report(x, slot, dci, t, n, actual);
        s->ep[dci].ring = r;
    }
}

/* ---- commands ---- */

static void init_ring_from_ctx(Usb *x, int slot, int dci) {
    uint64_t ctx = out_ctx(x, slot) + 32ull * dci;
    uint64_t deq;
    rd(x, ctx + 8, &deq, 8);
    x->slots[slot].ep[dci].ring.deq = deq & ~0xfull;
    x->slots[slot].ep[dci].ring.ccs = (int)(deq & 1);
    x->slots[slot].ep[dci].state = 1;
}

static int address_device(Usb *x, int slot, uint64_t input, int bsr) {
    uint64_t out = out_ctx(x, slot);
    uint8_t slot_ctx[32], ep0[32];
    rd(x, input + 32, slot_ctx, 32);
    rd(x, input + 64, ep0, 32);
    int port = slot_ctx[6]; /* root hub port number, dword 1 bits 23:16 */
    if (port < 1 || port > USB_PORTS || !x->port_dev[port - 1]) return CC_USB_TRANSACTION_ERROR;
    x->slots[slot].dev = x->port_dev[port - 1];
    uint32_t dw3 = (uint32_t)(bsr ? 1 : 2) << 27 | (uint32_t)(bsr ? 0 : slot); /* default or addressed; address = slot */
    memcpy(slot_ctx + 12, &dw3, 4);
    uint32_t e0;
    memcpy(&e0, ep0, 4);
    e0 = (e0 & ~7u) | 1;
    memcpy(ep0, &e0, 4);
    wr(x, out, slot_ctx, 32);
    wr(x, out + 32, ep0, 32);
    init_ring_from_ctx(x, slot, 1);
    return CC_SUCCESS;
}

static int configure_endpoints(Usb *x, int slot, uint64_t input, int deconfigure) {
    struct UsbSlot *s = &x->slots[slot];
    uint64_t out = out_ctx(x, slot);
    if (!s->dev) return CC_CONTEXT_STATE;
    if (deconfigure) {
        for (int dci = 2; dci < USB_EPS; dci++) if (s->ep[dci].state) set_ep_state(x, slot, dci, 0);
        uint32_t dw3 = rd32(x, out + 12);
        dw3 = (dw3 & ~(0x1fu << 27)) | (uint32_t)2 << 27; /* addressed */
        wr(x, out + 12, &dw3, 4);
        return CC_SUCCESS;
    }
    uint32_t drop = rd32(x, input), add = rd32(x, input + 4);
    for (int dci = 2; dci < USB_EPS; dci++) {
        if (drop & (1u << dci)) {
            uint8_t zero[32] = {0};
            wr(x, out + 32ull * dci, zero, 32);
            s->ep[dci].state = 0;
        }
        if (add & (1u << dci)) {
            uint8_t ep[32];
            rd(x, input + 32ull * (dci + 1), ep, 32);
            uint32_t e0;
            memcpy(&e0, ep, 4);
            e0 = (e0 & ~7u) | 1;
            memcpy(ep, &e0, 4);
            wr(x, out + 32ull * dci, ep, 32);
            init_ring_from_ctx(x, slot, dci);
        }
    }
    uint8_t slot_ctx[32];
    if (add & 1) rd(x, input + 32, slot_ctx, 32);
    else rd(x, out, slot_ctx, 32);
    uint32_t dw3 = (uint32_t)3 << 27 | (uint32_t)slot; /* configured */
    memcpy(slot_ctx + 12, &dw3, 4);
    wr(x, out, slot_ctx, 32);
    return CC_SUCCESS;
}

static void run_commands(Usb *x) {
    Trb t;
    while (x->cmd_running && ring_get(x, &x->cmd, &t)) {
        int type = trb_type(&t);
        int slot = (int)(t.d[3] >> 24);
        uint64_t ptr = ((uint64_t)t.d[1] << 32 | t.d[0]) & ~0xfull;
        int cc = CC_SUCCESS;
        ulog("usb: command %d slot %d ptr %llx dw3 %08x\n", type, slot, (unsigned long long)ptr, t.d[3]);
        if (type != TRB_ENABLE_SLOT && type != TRB_NOOP_CMD && type != TRB_FORCE_EVENT && type != TRB_NEGOTIATE_BW &&
            type != TRB_SET_LTV && type != TRB_GET_PORT_BW && type != TRB_FORCE_HEADER &&
            (slot < 1 || slot > USB_SLOTS || !x->slots[slot].used)) {
            cmd_completion(x, t.addr, CC_SLOT_NOT_ENABLED, slot);
            continue;
        }
        switch (type) {
        case TRB_ENABLE_SLOT: {
            int s = 1;
            while (s <= USB_SLOTS && x->slots[s].used) s++;
            if (s > USB_SLOTS) { cmd_completion(x, t.addr, CC_SLOTS_FULL, 0); continue; }
            memset(&x->slots[s], 0, sizeof x->slots[s]);
            x->slots[s].used = 1;
            cmd_completion(x, t.addr, CC_SUCCESS, s);
            continue;
        }
        case TRB_DISABLE_SLOT:
            memset(&x->slots[slot], 0, sizeof x->slots[slot]);
            break;
        case TRB_ADDRESS_DEVICE: cc = address_device(x, slot, ptr, (t.d[3] >> 9) & 1); break;
        case TRB_CONFIGURE_EP: cc = configure_endpoints(x, slot, ptr, (t.d[3] >> 9) & 1); break;
        case TRB_EVALUATE_CTX: {
            uint32_t add = rd32(x, ptr + 4);
            uint64_t out = out_ctx(x, slot);
            if (add & 1) { /* slot: max exit latency, interrupter target */
                uint32_t in1 = rd32(x, ptr + 32 + 4), in2 = rd32(x, ptr + 32 + 8);
                uint32_t o1 = rd32(x, out + 4), o2 = rd32(x, out + 8);
                o1 = (o1 & ~0xffffu) | (in1 & 0xffff);
                o2 = (o2 & 0x003fffffu) | (in2 & 0xffc00000u);
                wr(x, out + 4, &o1, 4);
                wr(x, out + 8, &o2, 4);
            }
            if (add & 2) { /* endpoint 0: max packet size */
                uint32_t in1 = rd32(x, ptr + 64 + 4), o1 = rd32(x, out + 32 + 4);
                o1 = (o1 & 0xffffu) | (in1 & 0xffff0000u);
                wr(x, out + 32 + 4, &o1, 4);
            }
            break;
        }
        case TRB_RESET_EP: {
            int dci = (t.d[3] >> 16) & 0x1f;
            if (dci < 1 || x->slots[slot].ep[dci].state != 2) { cc = CC_CONTEXT_STATE; break; }
            set_ep_state(x, slot, dci, 3);
            break;
        }
        case TRB_STOP_EP: {
            int dci = (t.d[3] >> 16) & 0x1f;
            if (dci < 1 || !x->slots[slot].ep[dci].state) { cc = CC_EP_NOT_ENABLED; break; }
            set_ep_state(x, slot, dci, 3);
            uint64_t deq = x->slots[slot].ep[dci].ring.deq | (uint64_t)x->slots[slot].ep[dci].ring.ccs;
            wr(x, out_ctx(x, slot) + 32ull * dci + 8, &deq, 8);
            break;
        }
        case TRB_SET_TR_DEQUEUE: {
            int dci = (t.d[3] >> 16) & 0x1f;
            if (dci < 1 || !x->slots[slot].ep[dci].state) { cc = CC_EP_NOT_ENABLED; break; }
            uint64_t p = (uint64_t)t.d[1] << 32 | t.d[0];
            x->slots[slot].ep[dci].ring.deq = p & ~0xfull;
            x->slots[slot].ep[dci].ring.ccs = (int)(p & 1);
            wr(x, out_ctx(x, slot) + 32ull * dci + 8, &p, 8);
            break;
        }
        case TRB_RESET_DEVICE: {
            for (int dci = 2; dci < USB_EPS; dci++) if (x->slots[slot].ep[dci].state) set_ep_state(x, slot, dci, 0);
            uint32_t dw3 = (uint32_t)1 << 27; /* default state, address 0 */
            wr(x, out_ctx(x, slot) + 12, &dw3, 4);
            if (x->slots[slot].dev && x->slots[slot].dev->reset) x->slots[slot].dev->reset(x->slots[slot].dev);
            break;
        }
        case TRB_GET_PORT_BW: { /* the port bandwidth context: one byte a port, all free */
            if (ptr) { uint8_t bw[16] = {0}; for (int i = 1; i <= USB_PORTS && i < 16; i++) bw[i] = 80; wr(x, ptr, bw, sizeof bw); }
            break;
        }
        case TRB_NOOP_CMD: case TRB_FORCE_EVENT: case TRB_NEGOTIATE_BW: case TRB_SET_LTV: case TRB_FORCE_HEADER:
            break;
        default:
            ulog("usb: unhandled command TRB type %d\n", type);
            cc = CC_TRB_ERROR;
            break;
        }
        cmd_completion(x, t.addr, cc, slot);
    }
}

/* ---- ports ---- */

static uint32_t port_connected_state(Usb *x, int p) {
    UsbDev *d = x->port_dev[p];
    if (p >= USB2_PORTS) return PORT_PP | PLS_RXDETECT << PORT_PLS_SHIFT; /* USB 3 ports: nothing attached */
    if (!d) return PORT_PP | PLS_RXDETECT << PORT_PLS_SHIFT;
    return PORT_PP | PORT_CCS | PORT_CSC | (uint32_t)d->speed << PORT_SPEED_SHIFT | PLS_POLLING << PORT_PLS_SHIFT;
}

static void port_write(Usb *x, int p, uint32_t v) {
    uint32_t s = x->portsc[p];
    UsbDev *d = x->port_dev[p];
    ulog("usb: portsc %d write %08x (was %08x)\n", p + 1, v, s);
    s &= ~(v & PORT_CHANGES); /* write 1 to clear */
    if (v & PORT_PED) s &= ~PORT_PED;
    s = (s & ~PORT_KEEP) | (v & PORT_KEEP);
    if (((v & PORT_PR) || (v & PORT_WPR)) && (s & PORT_CCS) && d) {
        s = (s & ~PORT_PLS_MASK) | PORT_PED | PORT_PRC | ((v & PORT_WPR) ? PORT_WRC : 0);
        if (d->reset) d->reset(d);
        d->configured = 0;
        x->portsc[p] = s;
        port_event(x, p);
        return;
    }
    if ((v & PORT_LWS) && (s & PORT_CCS)) {
        uint32_t pls = (v >> PORT_PLS_SHIFT) & 0xf;
        if (pls == PLS_U0 || pls == PLS_RESUME) pls = PLS_U0;
        s = (s & ~PORT_PLS_MASK) | pls << PORT_PLS_SHIFT | PORT_PLC;
        x->portsc[p] = s;
        port_event(x, p);
        return;
    }
    s = (s & ~PORT_PP) | (v & PORT_PP);
    x->portsc[p] = s;
}

/* ---- registers ---- */

static void controller_reset(Usb *x) {
    x->usbcmd = 0;
    x->usbsts = 1; /* halted */
    x->dnctrl = x->config = 0;
    x->dcbaap = 0;
    x->cmd_running = 0;
    memset(&x->cmd, 0, sizeof x->cmd);
    memset(x->intr, 0, sizeof x->intr);
    for (int i = 0; i < USB_INTRS; i++) x->intr[i].pcs = 1;
    memset(x->slots, 0, sizeof x->slots);
    for (int p = 0; p < USB_PORTS; p++) {
        x->portsc[p] = port_connected_state(x, p);
        if (x->port_dev[p] && x->port_dev[p]->reset) x->port_dev[p]->reset(x->port_dev[p]);
        if (x->port_dev[p]) x->port_dev[p]->configured = 0;
    }
    update_irq(x);
}

static uint32_t mfindex(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint32_t)(((uint64_t)ts.tv_sec * 1000000 + (uint64_t)ts.tv_nsec / 1000) / 125) & 0x3fff;
}

static uint64_t bar_read(HvPciDev *d, int bar, uint64_t off, unsigned size) {
    Usb *x = d->opaque;
    if (bar != 0) return 0;
    uint64_t v = 0;
    if (off < CAPLENGTH) {
        uint32_t cap[16] = {
            CAPLENGTH | 0x0100u << 16,                                                 /* CAPLENGTH, HCIVERSION 1.0 */
            USB_SLOTS | (uint32_t)USB_INTRS << 8 | (uint32_t)USB_PORTS << 24,          /* HCSPARAMS1 */
            1u | 4u << 4,                                                              /* HCSPARAMS2: IST 1, ERST max 2^4 */
            0,                                                                         /* HCSPARAMS3 */
            1u | (uint32_t)(XECP / 4) << 16,                                           /* HCCPARAMS1: 64-bit, 32-byte contexts, xECP */
            DB, RT, 0,
        };
        uint32_t i = (uint32_t)off / 4;
        v = cap[i];
        if (size == 8 && i + 1 < 16) v |= (uint64_t)cap[i + 1] << 32;
        v >>= 8 * (off & 3);
    } else if (off >= XECP && off < XECP + 32) { /* Supported Protocol: USB 2.0 ports 1-4, USB 3.0 ports 5-6 */
        static const uint32_t ext[8] = {
            2u | 4u << 8 | 0x0200u << 16, 0x20425355, 1u | (uint32_t)USB2_PORTS << 8, 0,
            2u | 0u << 8 | 0x0300u << 16, 0x20425355, (uint32_t)(USB2_PORTS + 1) | (uint32_t)USB3_PORTS << 8, 0,
        };
        uint32_t i = (uint32_t)(off - XECP) / 4;
        v = ext[i];
        if (size == 8 && i + 1 < 8) v |= (uint64_t)ext[i + 1] << 32;
        v >>= 8 * (off & 3);
    } else if (off >= OP && off < PORTREGS) {
        switch (off - OP) {
        case 0x00: v = x->usbcmd; break;
        case 0x04: v = x->usbsts; break;
        case 0x08: v = 1; break; /* 4 KB pages */
        case 0x14: v = x->dnctrl; break;
        case 0x18: v = x->cmd_running ? 8 : 0; break; /* CRCR reads CRR only */
        case 0x1c: v = 0; break;
        case 0x30: v = size == 8 ? x->dcbaap : (uint32_t)x->dcbaap; break;
        case 0x34: v = x->dcbaap >> 32; break;
        case 0x38: v = x->config; break;
        }
    } else if (off >= PORTREGS && off < PORTREGS + 16u * USB_PORTS) {
        int p = (int)(off - PORTREGS) / 16;
        v = (off - PORTREGS) % 16 == 0 ? x->portsc[p] : 0;
    } else if (off >= RT && off < RT + 0x20 + 32u * USB_INTRS) {
        if (off - RT < 0x20) return off == RT ? mfindex() : 0;
        struct UsbIntr *it = &x->intr[(off - RT - 0x20) / 32];
        switch ((off - RT - 0x20) % 32) {
        case 0x00: v = it->iman; break;
        case 0x04: v = it->imod; break;
        case 0x08: v = it->erstsz; break;
        case 0x10: v = size == 8 ? it->erstba : (uint32_t)it->erstba; break;
        case 0x14: v = it->erstba >> 32; break;
        case 0x18: v = size == 8 ? it->erdp : (uint32_t)it->erdp; break;
        case 0x1c: v = it->erdp >> 32; break;
        }
    }
    return v;
}

static void set64(uint64_t *f, uint64_t off_in_reg, uint64_t v, unsigned size) {
    if (size == 8) *f = v;
    else if (off_in_reg) *f = (*f & 0xffffffffull) | v << 32;
    else *f = (*f & ~0xffffffffull) | (uint32_t)v;
}

static void kick_endpoint(Usb *x, int slot, int dci) {
    struct UsbSlot *s = &x->slots[slot];
    if (!s->used || !s->dev || dci < 1 || dci >= USB_EPS) return;
    int st = s->ep[dci].state;
    if (st == 0 || st == 2) return; /* disabled, or halted: waits for Reset Endpoint */
    if (st != 1) set_ep_state(x, slot, dci, 1); /* a stopped endpoint runs again */
    if (dci == 1) run_ep0(x, slot);
    else run_ep(x, slot, dci);
}

static void bar_write(HvPciDev *d, int bar, uint64_t off, uint64_t v, unsigned size) {
    Usb *x = d->opaque;
    if (bar != 0) return;
    if (off >= OP && off < PORTREGS) {
        uint64_t r = off - OP;
        switch (r) {
        case 0x00:
            if (v & 2) { /* HCRST */
                controller_reset(x);
                return;
            }
            if ((v & 1) && !(x->usbcmd & 1)) {
                x->usbcmd = (uint32_t)v;
                x->usbsts &= ~1u;
                for (int p = 0; p < USB_PORTS; p++) if (x->portsc[p] & PORT_CSC) port_event(x, p);
            } else if (!(v & 1)) {
                x->usbcmd = (uint32_t)v;
                x->usbsts |= 1;
            } else
                x->usbcmd = (uint32_t)v;
            update_irq(x);
            break;
        case 0x04:
            x->usbsts &= ~((uint32_t)v & (1u << 2 | 1u << 3 | 1u << 4 | 1u << 10));
            update_irq(x);
            break;
        case 0x14: x->dnctrl = (uint32_t)v; break;
        case 0x18:
        case 0x1c: {
            if (r == 0x18 && (v & 6)) { /* CS / CA: stop the command ring */
                int was = x->cmd_running;
                x->cmd_running = 0;
                if (was || (v & 4)) event(x, x->cmd.deq | (uint64_t)x->cmd.ccs, (uint32_t)CC_CMD_RING_STOPPED << 24, TRB_CMD_COMPLETION << 10);
                break;
            }
            if (r == 0x18 && size == 4) {
                x->cmd.deq = (x->cmd.deq & ~0xffffffffull) | ((uint32_t)v & ~0x3fu);
                x->cmd.ccs = (int)(v & 1);
            } else if (r == 0x1c) {
                x->cmd.deq = (x->cmd.deq & 0xffffffffull) | v << 32;
            } else {
                x->cmd.deq = v & ~0x3full;
                x->cmd.ccs = (int)(v & 1);
            }
            break;
        }
        case 0x30:
        case 0x34: set64(&x->dcbaap, r - 0x30, v, size); x->dcbaap &= ~0x3full; break;
        case 0x38: x->config = (uint32_t)v; break;
        }
    } else if (off >= PORTREGS && off < PORTREGS + 16u * USB_PORTS) {
        if ((off - PORTREGS) % 16 == 0) port_write(x, (int)(off - PORTREGS) / 16, (uint32_t)v);
    } else if (off >= RT + 0x20 && off < RT + 0x20 + 32u * USB_INTRS) {
        struct UsbIntr *it = &x->intr[(off - RT - 0x20) / 32];
        uint64_t r = (off - RT - 0x20) % 32;
        switch (r) {
        case 0x00:
            if (v & 1) it->iman &= ~1u; /* IP: write 1 to clear */
            it->iman = (it->iman & 1) | ((uint32_t)v & 2);
            update_irq(x);
            break;
        case 0x04: it->imod = (uint32_t)v; break;
        case 0x08: it->erstsz = (uint32_t)v & 0xffff; break;
        case 0x10:
        case 0x14:
            set64(&it->erstba, r - 0x10, v, size);
            if (r == 0x14 || size == 8) {
                it->erstba &= ~0x3full;
                it->seg_index = 0;
                it->npend = 0;
                it->pcs = 1;
                load_segment(x, it);
            }
            break;
        case 0x18:
        case 0x1c:
            set64(&it->erdp, r - 0x18, v, size);
            if (r == 0x18 && (v & 8)) it->erdp &= ~8ull; /* EHB: write 1 to clear */
            if (it->npend) flush_pending(x, it);
            break;
        }
    } else if (off >= DB && off < DB + 4u * (USB_SLOTS + 1)) {
        int slot = (int)(off - DB) / 4;
        if (slot == 0) {
            x->cmd_running = 1;
            run_commands(x);
        } else
            kick_endpoint(x, slot, (int)(v & 0xff));
    }
}

/* Called on CPU 0's tick: hand waiting input to posted interrupt transfers. */
static void usb_poll(void *opaque) {
    Usb *x = opaque;
    if (!(x->usbcmd & 1)) return;
#ifdef WINVM_NET
    if (g_ncm) hv_net_poll(); /* frames net_slirp queued for the guest */
#endif
    for (int slot = 1; slot <= USB_SLOTS; slot++) {
        struct UsbSlot *s = &x->slots[slot];
        if (!s->used || !s->dev) continue;
        for (int dci = 3; dci < USB_EPS; dci += 2)
            if (s->ep[dci].state == 1) run_ep(x, slot, dci);
    }
}

/* ======================================================================== */
/* HID devices                                                              */
/* ======================================================================== */

#define HID_Q 64

typedef struct Hid {
    UsbDev d;
    pthread_mutex_t mu;
    uint8_t q[HID_Q][8];
    uint32_t head, tail;
    unsigned rlen;
    uint8_t state[8];               /* the keyboard's current report */
    int x, y, buttons;              /* the tablet */
    int protocol;
} Hid;

static Hid kbd, tab;

static void hid_push(Hid *h, const uint8_t *rep) {
    if (h->tail - h->head >= HID_Q) h->tail--; /* full: overwrite the newest */
    memcpy(h->q[h->tail % HID_Q], rep, h->rlen);
    h->tail++;
}

static int hid_ep_in(UsbDev *d, int ep, uint8_t *buf, uint32_t max, uint32_t *got) {
    Hid *h = (Hid *)d;
    (void)ep;
    pthread_mutex_lock(&h->mu);
    if (h->head == h->tail) { pthread_mutex_unlock(&h->mu); return 1; }
    uint32_t n = h->rlen < max ? h->rlen : max;
    memcpy(buf, h->q[h->head % HID_Q], n);
    h->head++;
    pthread_mutex_unlock(&h->mu);
    ulog("usb: %s report %02x %02x %02x %02x %02x %02x -> guest\n", d->name, buf[0], buf[1], buf[2], buf[3], n > 4 ? buf[4] : 0, n > 5 ? buf[5] : 0);
    *got = n;
    return 0;
}

static int hid_control(UsbDev *d, const uint8_t s[8], uint8_t *buf, int len) {
    Hid *h = (Hid *)d;
    uint8_t type = s[0], req = s[1];
    if (type == 0xa1 && req == 1) { /* GET_REPORT */
        pthread_mutex_lock(&h->mu);
        unsigned n = h->rlen;
        if (d == &tab.d) {
            uint8_t r[6] = {(uint8_t)h->buttons, (uint8_t)h->x, (uint8_t)(h->x >> 8), (uint8_t)h->y, (uint8_t)(h->y >> 8), 0};
            memcpy(buf, r, 6);
        } else
            memcpy(buf, h->state, 8);
        pthread_mutex_unlock(&h->mu);
        return len < (int)n ? len : (int)n;
    }
    if (type == 0xa1 && (req == 2 || req == 3)) { buf[0] = req == 3 ? (uint8_t)h->protocol : 0; return len < 1 ? len : 1; } /* GET_IDLE, GET_PROTOCOL */
    if (type == 0x21 && req == 11) { h->protocol = s[2]; return 0; } /* SET_PROTOCOL */
    if (type == 0x21 && (req == 9 || req == 10)) return 0;           /* SET_REPORT (LEDs), SET_IDLE */
    return -1;
}

static void hid_reset(UsbDev *d) {
    Hid *h = (Hid *)d;
    pthread_mutex_lock(&h->mu);
    h->head = h->tail = 0;
    h->protocol = 1;
    pthread_mutex_unlock(&h->mu);
}

static const uint8_t kbd_report_desc[] = {
    0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x05, 0x07, 0x19, 0xe0, 0x29, 0xe7, 0x15, 0x00, 0x25, 0x01,
    0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x05, 0x75, 0x01,
    0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x91, 0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0x95, 0x06,
    0x75, 0x08, 0x15, 0x00, 0x26, 0xff, 0x00, 0x05, 0x07, 0x19, 0x00, 0x29, 0xff, 0x81, 0x00, 0xc0,
};

/* A QEMU usb-tablet style absolute pointer: buttons, X and Y 0..32767 (16 bits each), wheel. */
static const uint8_t tab_report_desc[] = {
    0x05, 0x01, 0x09, 0x02, 0xa1, 0x01, 0x09, 0x01, 0xa1, 0x00,
    0x05, 0x09, 0x19, 0x01, 0x29, 0x03, 0x15, 0x00, 0x25, 0x01, 0x95, 0x03, 0x75, 0x01, 0x81, 0x02,
    0x95, 0x01, 0x75, 0x05, 0x81, 0x01,
    0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 0x15, 0x00, 0x26, 0xff, 0x7f, 0x35, 0x00, 0x46, 0xff, 0x7f,
    0x75, 0x10, 0x95, 0x02, 0x81, 0x02,
    0x05, 0x01, 0x09, 0x38, 0x15, 0x81, 0x25, 0x7f, 0x35, 0x00, 0x45, 0x00, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06,
    0xc0, 0xc0,
};

#define LO(v) ((v) & 0xff), ((v) >> 8)
static const uint8_t kbd_dev_desc[18] = {18, 1, 0x00, 0x02, 0, 0, 0, 64, LO(0x1209), LO(0x7a01), LO(0x0100), 1, 2, 3, 1};
static const uint8_t tab_dev_desc[18] = {18, 1, 0x00, 0x02, 0, 0, 0, 64, LO(0x1209), LO(0x7a02), LO(0x0100), 1, 2, 3, 1};
static const uint8_t kbd_cfg_desc[34] = {
    9, 2, 34, 0, 1, 1, 0, 0x80, 50,
    9, 4, 0, 0, 1, 3, 1, 1, 0,                              /* HID, boot interface, keyboard */
    9, 0x21, 0x11, 0x01, 0, 1, 0x22, sizeof kbd_report_desc, 0,
    7, 5, 0x81, 3, 8, 0, 10,                                /* EP1 IN, interrupt, 8 bytes, 10 ms */
};
static const uint8_t tab_cfg_desc[34] = {
    9, 2, 34, 0, 1, 1, 0, 0x80, 50,
    9, 4, 0, 0, 1, 3, 1, 2, 0,                              /* HID, boot subclass, mouse: as QEMU's usb-tablet (EDK2 binds only this) */
    9, 0x21, 0x01, 0x00, 0, 1, 0x22, sizeof tab_report_desc, 0,
    7, 5, 0x81, 3, 8, 0, 4,                                 /* EP1 IN, interrupt, 8 bytes, 4 ms */
};
static const char *const kbd_strings[] = {NULL, "WinVM", "WinVM USB Keyboard", "WINVMKBD0001"};
static const char *const tab_strings[] = {NULL, "WinVM", "WinVM USB Tablet", "WINVMTAB0001"};

static void hid_init(Hid *h, int is_kbd) {
    memset(h, 0, sizeof *h);
    pthread_mutex_init(&h->mu, NULL);
    UsbDev *d = &h->d;
    d->speed = SPEED_FULL;
    d->nstrings = 3;
    d->ep_in = hid_ep_in;
    d->control = hid_control;
    d->reset = hid_reset;
    if (is_kbd) {
        d->name = "keyboard";
        d->dev_desc = kbd_dev_desc; d->cfg_desc = kbd_cfg_desc; d->cfg_len = sizeof kbd_cfg_desc;
        d->report_desc = kbd_report_desc; d->report_len = sizeof kbd_report_desc;
        d->strings = kbd_strings;
        h->rlen = 8;
    } else {
        d->name = "tablet";
        d->dev_desc = tab_dev_desc; d->cfg_desc = tab_cfg_desc; d->cfg_len = sizeof tab_cfg_desc;
        d->report_desc = tab_report_desc; d->report_len = sizeof tab_report_desc;
        d->strings = tab_strings;
        h->rlen = 6;
    }
    h->protocol = 1;
}

void usb_key(uint8_t usage, int down) {
    Hid *h = &kbd;
    if (!usage || !g_usb) return;
    pthread_mutex_lock(&h->mu);
    uint8_t *s = h->state;
    if (usage >= 0xe0 && usage <= 0xe7) {
        uint8_t bit = (uint8_t)(1u << (usage - 0xe0));
        s[0] = down ? (uint8_t)(s[0] | bit) : (uint8_t)(s[0] & ~bit);
    } else {
        int i;
        for (i = 2; i < 8 && s[i] != usage; i++) {}
        if (down && i == 8) {
            for (i = 2; i < 8 && s[i]; i++) {}
            if (i < 8) s[i] = usage;
        } else if (!down && i < 8) {
            memmove(s + i, s + i + 1, (size_t)(7 - i));
            s[7] = 0;
        }
    }
    hid_push(h, s);
    pthread_mutex_unlock(&h->mu);
    hv_machine_wake(g_usb->m);
}

void usb_tablet(int x, int y, int buttons, int wheel) {
    Hid *h = &tab;
    if (!g_usb) return;
    if (x < 0) x = 0;
    if (x > 32767) x = 32767;
    if (y < 0) y = 0;
    if (y > 32767) y = 32767;
    if (wheel > 127) wheel = 127;
    if (wheel < -127) wheel = -127;
    pthread_mutex_lock(&h->mu);
    h->x = x; h->y = y; h->buttons = buttons & 7;
    uint8_t r[8] = {(uint8_t)h->buttons, (uint8_t)x, (uint8_t)(x >> 8), (uint8_t)y, (uint8_t)(y >> 8), (uint8_t)(int8_t)wheel, 0, 0};
    hid_push(h, r);
    pthread_mutex_unlock(&h->mu);
    hv_machine_wake(g_usb->m);
}

/* ======================================================================== */
/* Mass storage: bulk-only transport and SCSI                               */
/* ======================================================================== */

enum { MS_CBW = 0, MS_DATA_IN, MS_DATA_OUT, MS_CSW };

typedef struct Msc {
    UsbDev d;
    HvDisk disk;
    int cdrom, ro;
    uint32_t bs;
    uint64_t nblocks;
    int state;
    uint32_t tag, dn, moved;         /* CBW tag, expected transfer length, bytes moved so far */
    uint8_t status;                  /* CSW status */
    uint8_t small[512];
    uint32_t small_len, small_pos;
    int in_disk;                     /* data-in streams from the disk instead of `small` */
    uint64_t in_off, in_left;
    int out_write;                   /* data-out goes to the disk instead of nowhere */
    uint64_t out_off, out_left;
    uint8_t sk, asc, ascq;
    char serial[16];
} Msc;

static const uint8_t msc_dev_desc[18] = {18, 1, 0x00, 0x02, 0, 0, 0, 64, LO(0x1209), LO(0x7a03), LO(0x0100), 1, 2, 3, 1};
static const uint8_t msc_qual_desc[10] = {10, 6, 0x00, 0x02, 0, 0, 0, 64, 1, 0};
static const uint8_t msc_cfg_desc[32] = {
    9, 2, 32, 0, 1, 1, 0, 0x80, 50,
    9, 4, 0, 0, 2, 8, 6, 0x50, 0,                            /* mass storage, SCSI transparent, bulk-only */
    7, 5, 0x81, 2, 0x00, 0x02, 0,                            /* EP1 IN, bulk, 512 */
    7, 5, 0x02, 2, 0x00, 0x02, 0,                            /* EP2 OUT, bulk, 512 */
};
static const char *msc_strings_cd[] = {NULL, "WinVM", "WinVM USB CD-ROM", NULL};
static const char *msc_strings_disk[] = {NULL, "WinVM", "WinVM USB Disk", NULL};

static void be16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)v; }
static void be32(uint8_t *p, uint32_t v) { be16(p, v >> 16); be16(p + 2, v & 0xffff); }
static uint32_t rbe16(const uint8_t *p) { return (uint32_t)p[0] << 8 | p[1]; }
static uint32_t rbe32(const uint8_t *p) { return rbe16(p) << 16 | rbe16(p + 2); }
static uint64_t rbe64(const uint8_t *p) { return (uint64_t)rbe32(p) << 32 | rbe32(p + 4); }

static void sense(Msc *m, uint8_t sk, uint8_t asc, uint8_t ascq) {
    m->status = 1;
    m->sk = sk; m->asc = asc; m->ascq = ascq;
}

/* Queue a short reply (clamped to the allocation length) for the data-in phase. */
static void reply(Msc *m, const uint8_t *p, uint32_t n, uint32_t alloc) {
    if (n > sizeof m->small) n = sizeof m->small;
    if (n > alloc) n = alloc;
    memcpy(m->small, p, n);
    m->small_len = n; m->small_pos = 0;
    m->in_disk = 0;
    m->in_left = n;
}

static _Atomic uint64_t storage_read_bytes;
uint64_t usb_storage_bytes_read(void) { return atomic_load(&storage_read_bytes); }

static int disk_read_pad(Msc *m, uint64_t off, uint8_t *buf, uint32_t len) {
    uint64_t avail = off < m->disk.size ? m->disk.size - off : 0;
    uint32_t n = avail < len ? (uint32_t)avail : len;
    if (n && hv_disk_read(&m->disk, off, buf, n) != 0) return -1;
    atomic_fetch_add(&storage_read_bytes, n);
    if (n < len) memset(buf + n, 0, len - n);
    return 0;
}

static void msf(uint8_t *p, uint32_t lba) {
    uint32_t v = lba + 150;
    p[0] = 0;
    p[1] = (uint8_t)(v / (75 * 60));
    p[2] = (uint8_t)((v / 75) % 60);
    p[3] = (uint8_t)(v % 75);
}

static void put_addr(uint8_t *p, uint32_t lba, int use_msf) { if (use_msf) msf(p, lba); else be32(p, lba); }

static void msc_inquiry(Msc *m, const uint8_t *cb) {
    uint8_t b[96] = {0};
    uint32_t alloc = rbe16(cb + 3);
    uint8_t type = m->cdrom ? 5 : 0;
    const char *prod = m->cdrom ? "Virtual CD-ROM  " : "Virtual Disk    ";
    if (cb[1] & 1) { /* VPD */
        b[0] = type;
        b[1] = cb[2];
        switch (cb[2]) {
        case 0x00: b[3] = 3; b[4] = 0x00; b[5] = 0x80; b[6] = 0x83; reply(m, b, 7, alloc); return;
        case 0x80: b[3] = (uint8_t)strlen(m->serial); memcpy(b + 4, m->serial, strlen(m->serial)); reply(m, b, 4u + b[3], alloc); return;
        case 0x83: {
            uint32_t sl = (uint32_t)strlen(m->serial);
            b[4] = 0x02; b[5] = 0x01; b[6] = 0; b[7] = (uint8_t)(8 + 16 + sl);
            memcpy(b + 8, "WINVM   ", 8); memcpy(b + 16, prod, 16); memcpy(b + 32, m->serial, sl);
            b[3] = (uint8_t)(4 + 8 + 16 + sl);
            reply(m, b, 4u + b[3], alloc);
            return;
        }
        default: sense(m, 5, 0x24, 0); return;
        }
    }
    b[0] = type;
    b[1] = m->cdrom ? 0x80 : 0x00; /* RMB */
    b[2] = 5; b[3] = 2; b[4] = 31;
    memcpy(b + 8, "WinVM   ", 8);
    memcpy(b + 16, prod, 16);
    memcpy(b + 32, "1.0 ", 4);
    reply(m, b, 36, alloc);
}

static void msc_mode_sense(Msc *m, const uint8_t *cb, int ten) {
    uint8_t b[128] = {0};
    uint32_t alloc = ten ? rbe16(cb + 7) : cb[4];
    int page = cb[2] & 0x3f;
    uint32_t hdr = ten ? 8 : 4, n = hdr;
    int all = page == 0x3f;
    if (m->cdrom) {
        if (all || page == 0x01) { /* read/write error recovery */
            b[n] = 0x01; b[n + 1] = 0x06; b[n + 2] = 0x00; b[n + 3] = 3; n += 8;
        }
        if (all || page == 0x2a) { /* CD/DVD capabilities and mechanical status */
            b[n] = 0x2a; b[n + 1] = 0x14;
            b[n + 2] = 0x0b;              /* reads CD-R, CD-RW, DVD-ROM */
            b[n + 3] = 0x00;              /* no writing */
            b[n + 4] = 0x01;              /* audio play */
            b[n + 5] = 0x40;
            b[n + 6] = 0x29;              /* tray, can eject, can lock */
            b[n + 7] = 0x03;
            be16(b + n + 8, 0x1590);      /* max read speed, KB/s */
            be16(b + n + 10, 0x0100);     /* volume levels */
            be16(b + n + 12, 0x0100);     /* buffer size, KB */
            be16(b + n + 14, 0x1590);     /* current read speed */
            n += 22;
        }
    } else {
        if (all || page == 0x08) { /* caching: write cache off, our writes go straight through */
            b[n] = 0x08; b[n + 1] = 0x12; n += 20;
        }
    }
    if (n == hdr && !all) { sense(m, 5, 0x24, 0); return; }
    if (ten) { be16(b, n - 2); b[3] = (!m->cdrom && m->ro) ? 0x80 : 0; }
    else { b[0] = (uint8_t)(n - 1); b[2] = (!m->cdrom && m->ro) ? 0x80 : 0; }
    reply(m, b, n, alloc);
}

static void msc_read_toc(Msc *m, const uint8_t *cb) {
    uint8_t b[64] = {0};
    int use_msf = (cb[1] & 2) != 0, format = cb[2] & 0xf, track = cb[6];
    uint32_t alloc = rbe16(cb + 7), n = 0;
    uint32_t end = (uint32_t)m->nblocks;
    if (format == 0 && (cb[9] >> 6)) format = cb[9] >> 6; /* the old format field */
    switch (format) {
    case 0: /* TOC: track 1, then the lead-out */
        if (track > 1 && track != 0xaa) { sense(m, 5, 0x24, 0); return; }
        b[2] = 1; b[3] = 1; n = 4;
        if (track <= 1) { b[n + 1] = 0x14; b[n + 2] = 1; put_addr(b + n + 4, 0, use_msf); n += 8; }
        b[n + 1] = 0x14; b[n + 2] = 0xaa; put_addr(b + n + 4, end, use_msf); n += 8;
        break;
    case 1: /* multi-session: the first track of the last session */
        b[2] = 1; b[3] = 1; n = 4;
        b[n + 1] = 0x14; b[n + 2] = 1; put_addr(b + n + 4, 0, use_msf); n += 8;
        break;
    case 2: { /* full TOC */
        b[2] = 1; b[3] = 1; n = 4;
        uint8_t ent[4][11] = {
            {1, 0x14, 0, 0xa0, 0, 0, 0, 0, 1, 0, 0},
            {1, 0x14, 0, 0xa1, 0, 0, 0, 0, 1, 0, 0},
            {1, 0x14, 0, 0xa2, 0, 0, 0, 0, 0, 0, 0},
            {1, 0x14, 0, 1, 0, 0, 0, 0, 0, 2, 0},
        };
        uint8_t lo[4]; msf(lo, end);
        ent[2][8] = lo[1]; ent[2][9] = lo[2]; ent[2][10] = lo[3];
        for (int i = 0; i < 4; i++) { memcpy(b + n, ent[i], 11); n += 11; }
        break;
    }
    default: sense(m, 5, 0x24, 0); return;
    }
    be16(b, n - 2);
    reply(m, b, n, alloc);
}

static void msc_get_configuration(Msc *m, const uint8_t *cb) {
    uint8_t b[256] = {0};
    int rt = cb[1] & 3;
    uint32_t start = rbe16(cb + 2), alloc = rbe16(cb + 7), n = 8;
    int dvd = m->nblocks * 2048ull > 737280000ull;
    uint32_t profile = dvd ? 0x0010 : 0x0008;
    be16(b + 6, profile);
    struct { uint16_t code; uint8_t flags; uint8_t len; uint8_t data[8]; } f[] = {
        {0x0000, 0x03, 8, {0x00, 0x10, dvd, 0, 0x00, 0x08, !dvd, 0}},
        {0x0001, 0x07, 8, {0, 0, 0, 8, 0x03, 0, 0, 0}},
        {0x0002, 0x07, 4, {0x02, 0, 0, 0}},
        {0x0003, 0x03, 4, {0x29, 0, 0, 0}},
        {0x0010, 0x03, 8, {0, 0, 0x08, 0, 0, 0x10, 0, 0}},
        {0x001d, 0x03, 0, {0}},
        {0x001e, 0x0b, 4, {0, 0, 0, 0}},
        {0x001f, 0x03, 4, {0, 0, 0, 0}},
        {0x0100, 0x03, 0, {0}},
    };
    for (unsigned i = 0; i < sizeof f / sizeof f[0]; i++) {
        if (f[i].code == 0x001f && !dvd) continue;
        if (rt == 2 ? f[i].code != start : f[i].code < start) continue;
        be16(b + n, f[i].code); b[n + 2] = f[i].flags; b[n + 3] = f[i].len;
        memcpy(b + n + 4, f[i].data, f[i].len);
        n += 4u + f[i].len;
    }
    be32(b, n - 4);
    reply(m, b, n, alloc);
}

static void msc_event_status(Msc *m, const uint8_t *cb) {
    uint8_t b[8] = {0};
    uint32_t alloc = rbe16(cb + 7);
    if (!(cb[1] & 1)) { sense(m, 5, 0x24, 0); return; } /* only the polled form */
    if (cb[4] & 0x10) { /* media class */
        be16(b, 6);
        b[2] = 4; b[3] = 0x10;
        b[4] = 0; b[5] = 0x02; /* no change, media present */
        reply(m, b, 8, alloc);
    } else {
        be16(b, 2);
        b[2] = 0x80; b[3] = 0x10; /* no event class requested is supported */
        reply(m, b, 4, alloc);
    }
}

static void msc_read_disc_info(Msc *m, const uint8_t *cb) {
    uint8_t b[34] = {0};
    be16(b, 32);
    b[2] = 0x0e;           /* complete, finalised */
    b[3] = 1; b[4] = 1; b[5] = 1; b[6] = 1;
    reply(m, b, 34, rbe16(cb + 7));
}

static void msc_start_read(Msc *m, uint64_t lba, uint64_t cnt) {
    if (lba >= m->nblocks + 0 && cnt) { sense(m, 5, 0x21, 0); return; }
    if (lba + cnt > m->nblocks) { sense(m, 5, 0x21, 0); return; }
    m->in_disk = 1;
    m->in_off = lba * m->bs;
    m->in_left = cnt * m->bs;
}

static void msc_start_write(Msc *m, uint64_t lba, uint64_t cnt) {
    if (m->cdrom || m->ro) { sense(m, 7, 0x27, 0); return; }
    if (lba + cnt > m->nblocks) { sense(m, 5, 0x21, 0); return; }
    m->out_write = 1;
    m->out_off = lba * m->bs;
    m->out_left = cnt * m->bs;
}

/* Execute one SCSI command; sets m->status, and either the data-in source or the data-out sink. */
static void msc_scsi(Msc *m, const uint8_t *cb) {
    ulog2("usb: scsi %02x %02x %02x %02x %02x %02x %02x %02x %02x %02x\n", cb[0], cb[1], cb[2], cb[3], cb[4], cb[5], cb[6], cb[7], cb[8], cb[9]);
    m->status = 0;
    m->in_disk = 0; m->in_left = 0; m->small_len = m->small_pos = 0;
    m->out_write = 0; m->out_left = 0;
    uint8_t b[64] = {0};
    switch (cb[0]) {
    case 0x00: break;                                  /* TEST UNIT READY */
    case 0x03: {                                       /* REQUEST SENSE */
        b[0] = 0x70; b[2] = m->sk; b[7] = 10; b[12] = m->asc; b[13] = m->ascq;
        m->sk = m->asc = m->ascq = 0;
        reply(m, b, 18, cb[4]);
        break;
    }
    case 0x12: msc_inquiry(m, cb); break;
    case 0x1a: msc_mode_sense(m, cb, 0); break;
    case 0x5a: msc_mode_sense(m, cb, 1); break;
    case 0x15: m->out_left = cb[4]; break;             /* MODE SELECT(6): take and ignore */
    case 0x55: m->out_left = rbe16(cb + 7); break;
    case 0x1b: case 0x1e: case 0x1d: case 0x2f: case 0xbb: case 0xb6: break; /* START STOP, PREVENT ALLOW, SEND DIAGNOSTIC, VERIFY, SET CD SPEED, SET STREAMING */
    case 0x35: case 0x91: if (!m->cdrom) hv_disk_flush(&m->disk); break; /* SYNCHRONIZE CACHE */
    case 0x25: { /* READ CAPACITY(10) */
        uint64_t last = m->nblocks ? m->nblocks - 1 : 0;
        be32(b, last > 0xffffffffull ? 0xffffffffu : (uint32_t)last);
        be32(b + 4, m->bs);
        reply(m, b, 8, 8);
        break;
    }
    case 0x9e: { /* SERVICE ACTION IN(16): READ CAPACITY(16) */
        if ((cb[1] & 0x1f) != 0x10 || m->cdrom) { sense(m, 5, 0x20, 0); break; }
        uint64_t last = m->nblocks ? m->nblocks - 1 : 0;
        be32(b, (uint32_t)(last >> 32)); be32(b + 4, (uint32_t)last); be32(b + 8, m->bs);
        reply(m, b, 32, rbe32(cb + 10));
        break;
    }
    case 0xa0: { /* REPORT LUNS */
        be32(b, 8);
        reply(m, b, 16, rbe32(cb + 6));
        break;
    }
    case 0x08: { uint32_t cnt = cb[4] ? cb[4] : 256; msc_start_read(m, (uint32_t)(cb[1] & 0x1f) << 16 | rbe16(cb + 2), cnt); break; }
    case 0x28: msc_start_read(m, rbe32(cb + 2), rbe16(cb + 7)); break;
    case 0xa8: msc_start_read(m, rbe32(cb + 2), rbe32(cb + 6)); break;
    case 0x88: msc_start_read(m, rbe64(cb + 2), rbe32(cb + 10)); break;
    case 0x0a: { uint32_t cnt = cb[4] ? cb[4] : 256; msc_start_write(m, (uint32_t)(cb[1] & 0x1f) << 16 | rbe16(cb + 2), cnt); break; }
    case 0x2a: msc_start_write(m, rbe32(cb + 2), rbe16(cb + 7)); break;
    case 0xaa: msc_start_write(m, rbe32(cb + 2), rbe32(cb + 6)); break;
    case 0x8a: msc_start_write(m, rbe64(cb + 2), rbe32(cb + 10)); break;
    default:
        if (m->cdrom) {
            switch (cb[0]) {
            case 0x43: msc_read_toc(m, cb); return;
            case 0x46: msc_get_configuration(m, cb); return;
            case 0x4a: msc_event_status(m, cb); return;
            case 0x51: msc_read_disc_info(m, cb); return;
            case 0xbe: /* READ CD: user data only */
                if ((cb[9] & 0xf8) == 0x10) { msc_start_read(m, rbe32(cb + 2), (uint32_t)cb[6] << 16 | rbe16(cb + 7)); return; }
                sense(m, 5, 0x24, 0);
                return;
            default: break;
            }
        }
        sense(m, 5, 0x20, 0); /* invalid command operation code */
        break;
    }
}

static void msc_finish(Msc *m) { m->state = MS_CSW; }

static void msc_cbw(Msc *m, const uint8_t *p) {
    m->tag = (uint32_t)p[4] | (uint32_t)p[5] << 8 | (uint32_t)p[6] << 16 | (uint32_t)p[7] << 24;
    m->dn = (uint32_t)p[8] | (uint32_t)p[9] << 8 | (uint32_t)p[10] << 16 | (uint32_t)p[11] << 24;
    int host_in = (p[12] & 0x80) != 0;
    m->moved = 0;
    if (p[13] != 0) { /* only LUN 0 */
        m->status = 1; m->in_left = m->out_left = 0; m->in_disk = 0; m->out_write = 0;
        m->sk = 5; m->asc = 0x25; m->ascq = 0;
    } else
        msc_scsi(m, p + 15);
    uint64_t dev_in = m->in_left, dev_out = m->out_left;
    if (m->dn == 0) { /* no data phase: a command that wanted one is a phase error */
        if (m->status == 0 && (dev_in || dev_out)) m->status = 2;
        msc_finish(m);
        return;
    }
    if (host_in) {
        if (m->in_left > m->dn) m->in_left = m->dn;
        m->out_left = 0;
        m->state = MS_DATA_IN;
    } else {
        m->in_left = 0;
        m->state = MS_DATA_OUT; /* take Dn bytes; the first out_left of them are the command's */
    }
}

static int msc_ep_out(UsbDev *d, int ep, const uint8_t *buf, uint32_t len) {
    Msc *m = (Msc *)d;
    (void)ep;
    if (m->state == MS_DATA_OUT) {
        uint32_t n = len;
        if (m->dn - m->moved < n) n = m->dn - m->moved;
        uint32_t use = m->out_left < n ? (uint32_t)m->out_left : n;
        if (m->out_write && use) {
            if (hv_disk_write(&m->disk, m->out_off, buf, use) != 0) { sense(m, 3, 0x0c, 0); m->out_write = 0; }
            m->out_off += use;
        }
        m->out_left -= use;
        m->moved += n;
        if (m->moved >= m->dn) msc_finish(m);
        return 0;
    }
    if (len == 31 && buf[0] == 'U' && buf[1] == 'S' && buf[2] == 'B' && buf[3] == 'C' && buf[14] >= 1 && buf[14] <= 16) {
        msc_cbw(m, buf);
        return 0;
    }
    ulog("usb: storage: invalid CBW (%u bytes), stalling\n", len);
    d->halted[0][2] = d->halted[1][1] = 1;
    return -1;
}

static int msc_ep_in(UsbDev *d, int ep, uint8_t *buf, uint32_t max, uint32_t *got) {
    Msc *m = (Msc *)d;
    (void)ep;
    if (m->state == MS_DATA_IN) {
        uint32_t n = m->in_left < max ? (uint32_t)m->in_left : max;
        if (m->in_disk) {
            if (n && disk_read_pad(m, m->in_off, buf, n) != 0) {
                sense(m, 3, 0x11, 0); /* unrecovered read error */
                m->in_left = 0; n = 0; m->in_disk = 0;
            } else
                m->in_off += n;
        } else {
            memcpy(buf, m->small + m->small_pos, n);
            m->small_pos += n;
        }
        m->in_left -= n;
        m->moved += n;
        if (m->in_left == 0 && (n < max || m->moved >= m->dn)) msc_finish(m);
        *got = n;
        return 0;
    }
    if (m->state == MS_CSW) {
        uint8_t csw[13] = {'U', 'S', 'B', 'S'};
        csw[4] = (uint8_t)m->tag; csw[5] = (uint8_t)(m->tag >> 8); csw[6] = (uint8_t)(m->tag >> 16); csw[7] = (uint8_t)(m->tag >> 24);
        uint32_t res = m->dn > m->moved ? m->dn - m->moved : 0;
        csw[8] = (uint8_t)res; csw[9] = (uint8_t)(res >> 8); csw[10] = (uint8_t)(res >> 16); csw[11] = (uint8_t)(res >> 24);
        csw[12] = m->status;
        uint32_t n = max < 13 ? max : 13;
        memcpy(buf, csw, n);
        *got = n;
        m->state = MS_CBW;
        return 0;
    }
    return 1; /* nothing to send until a command arrives */
}

static int msc_control(UsbDev *d, const uint8_t s[8], uint8_t *buf, int len) {
    Msc *m = (Msc *)d;
    if (s[0] == 0xa1 && s[1] == 0xfe) { buf[0] = 0; return len < 1 ? len : 1; } /* Get Max LUN */
    if (s[0] == 0x21 && s[1] == 0xff) { m->state = MS_CBW; return 0; }          /* Bulk-Only Mass Storage Reset */
    return -1;
}

static void msc_reset(UsbDev *d) { ((Msc *)d)->state = MS_CBW; }

/* ======================================================================== */
/* Wiring                                                                   */
/* ======================================================================== */

static int usb_attach(Usb *x, UsbDev *d, int first, int last) {
    for (int p = first; p <= last; p++) {
        if (x->port_dev[p]) continue;
        x->port_dev[p] = d;
        x->portsc[p] = port_connected_state(x, p);
        return p;
    }
    return -1;
}

void *winvm_usb_create(WinArm *b) {
    if (g_usb) return g_usb;
    if (!b || !b->pcie) return NULL;
    Usb *x = calloc(1, sizeof *x);
    if (!x) return NULL;
    x->m = b->m;
    /* QEMU's xHCI IDs, class 0x0c0330. No MSI or MSI-X capability: interrupts are INTx. */
    hv_pci_init(&x->pci, 0x1b36, 0x000d, 0x0c033000, 0x1af4, 0x1100);
    x->pci.opaque = x;
    x->pci.bar_read = bar_read;
    x->pci.bar_write = bar_write;
    hv_pci_add_bar(&x->pci, 0, BAR_SIZE, 1);
    x->pci.config[0x60] = 0x30; /* SBRN: USB 3.0 */
    x->pci.config[0x61] = 0x20; /* FLADJ */
    if (hv_pcie_attach(b->pcie, &x->pci) < 0) { free(x); return NULL; }
    hid_init(&kbd, 1);
    hid_init(&tab, 0);
    usb_attach(x, &kbd.d, 0, 0);
    usb_attach(x, &tab.d, 1, 1);
    controller_reset(x);
    g_usb = x;
    winarm_add_poll(b, usb_poll, x);
    return x;
}

void *winvm_usb_storage_create(WinArm *b, HvDisk *disk, int cdrom) {
    Usb *x = winvm_usb_create(b);
    if (!x || !disk) return NULL;
    static int count;
    Msc *m = calloc(1, sizeof *m);
    if (!m) return NULL;
    m->disk = *disk;
    m->cdrom = cdrom;
    m->ro = cdrom || disk->readonly;
    m->bs = cdrom ? 2048 : 512;
    m->nblocks = (disk->size + m->bs - 1) / m->bs;
    if (!cdrom) m->nblocks = disk->size / m->bs;
    snprintf(m->serial, sizeof m->serial, "WINVMSD%04d", ++count);
    UsbDev *d = &m->d;
    d->name = cdrom ? "cdrom" : "disk";
    d->speed = SPEED_HIGH;
    d->dev_desc = msc_dev_desc; d->cfg_desc = msc_cfg_desc; d->cfg_len = sizeof msc_cfg_desc;
    d->qual_desc = msc_qual_desc;
    /* per-device string table (the serial differs) */
    const char **tbl = calloc(4, sizeof *tbl);
    if (!tbl) { free(m); return NULL; }
    tbl[1] = "WinVM"; tbl[2] = cdrom ? msc_strings_cd[2] : msc_strings_disk[2]; tbl[3] = m->serial;
    d->strings = tbl; d->nstrings = 3;
    d->control = msc_control; d->ep_in = msc_ep_in; d->ep_out = msc_ep_out; d->reset = msc_reset;
    if (usb_attach(x, d, 2, USB2_PORTS - 1) < 0) { free(tbl); free(m); return NULL; }
    /* A device attached after the guest started would raise a port event; at board build time the
       reset state already shows it connected. */
    return m;
}

/* ======================================================================== */
/* Network: a USB CDC NCM Ethernet adapter on Henge's user-mode NAT          */
/* ======================================================================== */
/* Windows binds its inbox UsbNcm driver to it by class (02/0d), so no driver is needed; Linux uses cdc_ncm.
   Frames come from net_slirp's thread through hv_net_poll (called on CPU 0's tick, usb_poll) into a small
   queue here; each bulk IN transfer packs as many as fit into one NTB. Each bulk OUT transfer is one NTB,
   whose datagrams go to hv_net_transmit. Built only with WINVM_NET (libslirp linked). */
#ifdef WINVM_NET

#define NCM_RXQ 256

typedef struct Ncm {
    UsbDev d;
    pthread_mutex_t mu;
    int alt;                        /* data interface's alternate setting: 1 = link up */
    int notify;                     /* notifications still to send after the link came up: 2 speed, 1 connect, 0 none */
    uint32_t in_max;                /* SET_NTB_INPUT_SIZE */
    uint16_t seq;
    uint8_t *q[NCM_RXQ];
    uint16_t qlen[NCM_RXQ];
    uint32_t head, tail;
    char mac[13];
} Ncm;

uint64_t winvm_net_rx_frames, winvm_net_tx_frames;

static const uint8_t ncm_dev_desc[18] = {18, 1, 0x00, 0x02, 0xef, 0x02, 0x01, 64, LO(0x1209), LO(0x7a04), LO(0x0100), 1, 2, 3, 1};
static const uint8_t ncm_qual_desc[10] = {10, 6, 0x00, 0x02, 0xef, 0x02, 0x01, 64, 1, 0};
static const uint8_t ncm_cfg_desc[94] = {
    9, 2, 94, 0, 2, 1, 0, 0x80, 50,
    8, 0x0b, 0, 2, 0x02, 0x0d, 0x00, 0,                    /* IAD: interfaces 0-1, CDC NCM */
    9, 4, 0, 0, 1, 0x02, 0x0d, 0x00, 0,                    /* communication interface: CDC, NCM */
    5, 0x24, 0x00, 0x10, 0x01,                             /* header, CDC 1.10 */
    5, 0x24, 0x06, 0, 1,                                   /* union: control 0, data 1 */
    13, 0x24, 0x0f, 4, 0, 0, 0, 0, LO(1514), 0, 0, 0,      /* Ethernet: MAC in string 4, no statistics, 1514, no MC filters */
    6, 0x24, 0x1a, 0x00, 0x01, 0x13,                       /* NCM 1.0: packet filter, net address, max datagram size */
    7, 5, 0x81, 3, 16, 0, 8,                               /* EP1 IN, interrupt, 16 bytes, 16 ms */
    9, 4, 1, 0, 0, 0x0a, 0x00, 0x01, 0,                    /* data interface, alternate 0: no endpoints (link down) */
    9, 4, 1, 1, 2, 0x0a, 0x00, 0x01, 0,                    /* data interface, alternate 1: NTB transfers */
    7, 5, 0x82, 2, 0x00, 0x02, 0,                          /* EP2 IN, bulk, 512 */
    7, 5, 0x02, 2, 0x00, 0x02, 0,                          /* EP2 OUT, bulk, 512 */
};

static void ncm_flush(Ncm *n) {
    while (n->head != n->tail) { free(n->q[n->head % NCM_RXQ]); n->head++; }
}

/* CPU thread (hv_net_poll): a frame for the guest. 0 = no room, keep it queued in net_slirp. */
static int ncm_rx(void *opaque, const uint8_t *frame, uint32_t len) {
    Ncm *n = opaque;
    pthread_mutex_lock(&n->mu);
    int r = 1;
    if (n->alt != 1 || len > NCM_MAX_DATAGRAM) {
        /* link down (no driver yet) or oversized: dropped, as a cable with nothing on it */
    } else if (n->tail - n->head >= NCM_RXQ) r = 0;
    else {
        uint8_t *c = malloc(len);
        if (!c) r = 0;
        else { memcpy(c, frame, len); n->q[n->tail % NCM_RXQ] = c; n->qlen[n->tail % NCM_RXQ] = (uint16_t)len; n->tail++; }
    }
    pthread_mutex_unlock(&n->mu);
    return r;
}

static int ncm_altsetting(UsbDev *d, int intf, int alt) {
    Ncm *n = (Ncm *)d;
    if (intf == 0) return alt < 0 ? 0 : alt == 0 ? 0 : -1;
    if (intf != 1) return -1;
    if (alt < 0) return n->alt;
    if (alt > 1) return -1;
    pthread_mutex_lock(&n->mu);
    if (alt != n->alt) {
        n->alt = alt;
        n->notify = alt == 1 ? 2 : 0;
        ncm_flush(n);
        n->seq = 0;
    }
    pthread_mutex_unlock(&n->mu);
    ulog("usb: net: data interface alternate %d (link %s)\n", alt, alt ? "up" : "down");
    return 0;
}

static void ncm_reset(UsbDev *d) {
    Ncm *n = (Ncm *)d;
    pthread_mutex_lock(&n->mu);
    n->alt = 0; n->notify = 0; n->in_max = NCM_NTB_MAX; n->seq = 0;
    ncm_flush(n);
    pthread_mutex_unlock(&n->mu);
}

static int ncm_control(UsbDev *d, const uint8_t s[8], uint8_t *buf, int len) {
    Ncm *n = (Ncm *)d;
    uint8_t req = s[1];
    uint16_t value = (uint16_t)(s[2] | s[3] << 8);
    if (((s[0] >> 5) & 3) != 1 || (s[0] & 0x1f) != 1) return -1; /* class requests to an interface only */
    uint8_t r[28];
    int rn = -1;
    switch (req) {
    case 0x80: rn = ncm_ntb_parameters(r); break;                      /* GET_NTB_PARAMETERS */
    case 0x81:                                                         /* GET_NET_ADDRESS */
        for (int i = 0; i < 6; i++) { unsigned v; sscanf(n->mac + 2 * i, "%2x", &v); r[i] = (uint8_t)v; }
        rn = 6; break;
    case 0x82: return 0;                                               /* SET_NET_ADDRESS: kept as given by the descriptor */
    case 0x83: ncm_wr16(r, 0); rn = 2; break;                          /* GET_NTB_FORMAT: 16-bit */
    case 0x84: return value == 0 ? 0 : -1;                             /* SET_NTB_FORMAT */
    case 0x85: ncm_wr32(r, n->in_max); ncm_wr32(r + 4, 0); rn = len >= 8 ? 8 : 4; break; /* GET_NTB_INPUT_SIZE */
    case 0x86:                                                         /* SET_NTB_INPUT_SIZE */
        if (len < 4) return -1;
        { uint32_t v = ncm_rd32(buf); if (v < 2048 || v > NCM_NTB_MAX) return -1;
          pthread_mutex_lock(&n->mu); n->in_max = v; pthread_mutex_unlock(&n->mu); }
        return 0;
    case 0x87: ncm_wr16(r, NCM_MAX_DATAGRAM); rn = 2; break;           /* GET_MAX_DATAGRAM_SIZE */
    case 0x88: return 0;                                               /* SET_MAX_DATAGRAM_SIZE: we take up to 1514 regardless */
    case 0x89: ncm_wr16(r, 0); rn = 2; break;                          /* GET_CRC_MODE: none */
    case 0x8a: return value == 0 ? 0 : -1;                             /* SET_CRC_MODE */
    case 0x40: case 0x41: case 0x42: case 0x43: return 0;              /* multicast and packet filters: everything passes */
    default: return -1;
    }
    if (rn > len) rn = len;
    memcpy(buf, r, (size_t)rn);
    return rn;
}

static int ncm_ep_in(UsbDev *d, int ep, uint8_t *buf, uint32_t max, uint32_t *got) {
    Ncm *n = (Ncm *)d;
    if (ep == 1) { /* notifications: the link speed, then "connected" */
        pthread_mutex_lock(&n->mu);
        int which = n->notify;
        if (which) n->notify--;
        pthread_mutex_unlock(&n->mu);
        if (!which) return 1;
        uint8_t m[16] = {0xa1, which == 2 ? 0x2a : 0x00, which == 1 ? 1 : 0, 0, 0, 0, which == 2 ? 8 : 0, 0};
        uint32_t ml = 8;
        if (which == 2) { ncm_wr32(m + 8, 1000000000u); ncm_wr32(m + 12, 1000000000u); ml = 16; } /* 1 Gb/s both ways */
        if (ml > max) ml = max;
        memcpy(buf, m, ml);
        *got = ml;
        return 0;
    }
    if (ep != 2) return -1;
    pthread_mutex_lock(&n->mu);
    if (n->alt != 1 || n->head == n->tail) { pthread_mutex_unlock(&n->mu); return 1; }
    uint32_t lim = n->in_max < max ? n->in_max : max;
    NcmBuilder w;
    ncm_build_start(&w, buf, lim);
    while (n->head != n->tail) {
        uint32_t i = n->head % NCM_RXQ;
        if (!ncm_build_add(&w, n->q[i], n->qlen[i])) break;
        free(n->q[i]);
        n->head++;
        winvm_net_rx_frames++;
    }
    uint32_t len = ncm_build_finish(&w, n->seq);
    if (len) n->seq++;
    pthread_mutex_unlock(&n->mu);
    if (!len) return 1; /* the host's transfer is too small for even one frame: wait for a bigger one */
    *got = len;
    return 0;
}

static void ncm_datagram(void *opaque, const uint8_t *dg, uint32_t len) {
    (void)opaque;
    if (len < 14 || len > NCM_MAX_DATAGRAM) return;
    winvm_net_tx_frames++;
    hv_net_transmit(dg, len);
}

static int ncm_ep_out(UsbDev *d, int ep, const uint8_t *buf, uint32_t len) {
    Ncm *n = (Ncm *)d;
    if (ep != 2) return -1;
    if (n->alt != 1) return 0;
    if (ncm_parse_ntb(buf, len, ncm_datagram, n) < 0) ulog("usb: net: malformed NTB (%u bytes) dropped\n", len);
    return 0;
}

void *winvm_usb_net_create(WinArm *b, const uint8_t mac[6]) {
    Usb *x = winvm_usb_create(b);
    if (!x || g_ncm) return g_ncm;
    Ncm *n = calloc(1, sizeof *n);
    if (!n) return NULL;
    pthread_mutex_init(&n->mu, NULL);
    snprintf(n->mac, sizeof n->mac, "%02X%02X%02X%02X%02X%02X", mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    n->in_max = NCM_NTB_MAX;
    static const char *strings[5];
    strings[1] = "WinVM"; strings[2] = "WinVM USB Ethernet"; strings[3] = "WINVMNET0001"; strings[4] = n->mac;
    UsbDev *d = &n->d;
    d->name = "net";
    d->speed = SPEED_HIGH;
    d->dev_desc = ncm_dev_desc; d->cfg_desc = ncm_cfg_desc; d->cfg_len = sizeof ncm_cfg_desc;
    d->qual_desc = ncm_qual_desc;
    d->strings = strings; d->nstrings = 4;
    d->control = ncm_control; d->ep_in = ncm_ep_in; d->ep_out = ncm_ep_out; d->reset = ncm_reset;
    d->altsetting = ncm_altsetting;
    if (hv_net_attach_rx(x->m, ncm_rx, n) != 0) {
        pthread_mutex_destroy(&n->mu);
        free(n);
        return NULL;
    }
    if (usb_attach(x, d, 2, USB2_PORTS - 1) < 0) {
        hv_net_detach();
        pthread_mutex_destroy(&n->mu);
        free(n);
        return NULL;
    }
    g_ncm = n;
    return n;
}
#else
uint64_t winvm_net_rx_frames, winvm_net_tx_frames;
void *winvm_usb_net_create(WinArm *b, const uint8_t mac[6]) { (void)b; (void)mac; return NULL; }
#endif

static pthread_t autoboot;
static int autoboot_started;
static atomic_bool autoboot_stop;

/* After the CPUs and host input have stopped. Join the helper before freeing HID. */
void winvm_usb_destroy(void) {
    if (autoboot_started) {
        atomic_store(&autoboot_stop, true);
        pthread_join(autoboot, NULL);
        autoboot_started = 0;
    }
    if (!g_usb) return;
#ifdef WINVM_NET
    if (g_ncm) {
        hv_net_detach();
        ncm_flush(g_ncm);
        pthread_mutex_destroy(&g_ncm->mu);
    }
#endif
    for (int port = 2; port < USB2_PORTS; port++) {
        UsbDev *d = g_usb->port_dev[port];
#ifdef WINVM_NET
        if (g_ncm && d == &g_ncm->d) continue;
#endif
        if (d) { free((void *)d->strings); free(d); }
    }
#ifdef WINVM_NET
    free(g_ncm);
    g_ncm = NULL;
#endif
    pthread_mutex_destroy(&kbd.mu);
    pthread_mutex_destroy(&tab.mu);
    free(g_usb);
    g_usb = NULL;
    free(scratch);
    scratch = NULL;
    scratch_cap = 0;
    atomic_store(&storage_read_bytes, 0);
}

/* usb_autoboot_cd: see usb.h. */
static void *autoboot_thread(void *arg) {
    (void)arg;
    for (int tick = 0; tick < 1200 && !atomic_load(&autoboot_stop) &&
         usb_storage_bytes_read() < (32u << 20); tick++) {
        if (tick % 10 == 0) usb_key(0x2c, 1); /* Space for cdboot */
        if (tick % 10 == 1) usb_key(0x2c, 0);
        usleep(100000);
    }
    usb_key(0x2c, 0);
    return NULL;
}

int usb_autoboot_cd(HvDisk *disk) {
    if (autoboot_started || !winvm_disk_blank(disk)) return 0;
    atomic_store(&autoboot_stop, false);
    autoboot_started = pthread_create(&autoboot, NULL, autoboot_thread, NULL) == 0;
    return autoboot_started;
}
