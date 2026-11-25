// SPDX-License-Identifier: GPL-2.0-or-later
// USB CDC NCM 1.0 transfer blocks, 16-bit format (NTH16 + NDP16): what the guest's UsbNcm driver
// (inbox in Windows 10 2004 and later, Linux cdc_ncm) sends on the bulk OUT endpoint and expects on bulk IN.
// Pure functions, no device state: usb.c's network adapter and tests/ncm_test.c use them.
#ifndef WINVM_NCM_H
#define WINVM_NCM_H
#include <stdint.h>
#include <string.h>

#define NCM_NTH16_SIG 0x484d434eu /* "NCMH" */
#define NCM_NDP16_SIG 0x304d434eu /* "NCM0": no CRC */
#define NCM_NDP16_CRC 0x314d434eu /* "NCM1": each datagram carries a CRC-32 we don't check (we never offer CRC mode) */
#define NCM_NTB_MAX 32768u        /* dwNtbInMaxSize / dwNtbOutMaxSize we offer */
#define NCM_ALIGN 4u              /* wNdp{In,Out}Divisor, and the NDP alignment */
#define NCM_MAX_DATAGRAM 1514u    /* an Ethernet frame without FCS */

static inline uint32_t ncm_rd16(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8; }
static inline uint32_t ncm_rd32(const uint8_t *p) { return ncm_rd16(p) | ncm_rd16(p + 2) << 16; }
static inline void ncm_wr16(uint8_t *p, uint32_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static inline void ncm_wr32(uint8_t *p, uint32_t v) { ncm_wr16(p, v & 0xffff); ncm_wr16(p + 2, v >> 16); }

/* GET_NTB_PARAMETERS reply (NCM 1.0 table 6-3), 28 bytes. */
static inline int ncm_ntb_parameters(uint8_t out[28]) {
    memset(out, 0, 28);
    ncm_wr16(out + 0, 28);            /* wLength */
    ncm_wr16(out + 2, 1);             /* bmNtbFormatsSupported: 16-bit only */
    ncm_wr32(out + 4, NCM_NTB_MAX);   /* dwNtbInMaxSize */
    ncm_wr16(out + 8, NCM_ALIGN);     /* wNdpInDivisor */
    ncm_wr16(out + 10, 0);            /* wNdpInPayloadRemainder */
    ncm_wr16(out + 12, NCM_ALIGN);    /* wNdpInAlignment */
    ncm_wr32(out + 16, NCM_NTB_MAX);  /* dwNtbOutMaxSize */
    ncm_wr16(out + 20, NCM_ALIGN);    /* wNdpOutDivisor */
    ncm_wr16(out + 22, 0);            /* wNdpOutPayloadRemainder */
    ncm_wr16(out + 24, NCM_ALIGN);    /* wNdpOutAlignment */
    ncm_wr16(out + 26, 0);            /* wNtbOutMaxDatagrams: no limit */
    return 28;
}

/* Walk an NTB the guest sent: call fn for each datagram. Returns the number of datagrams, or -1 if the
   block is malformed (bad signature, lengths or indexes pointing outside it, an NDP loop). Datagrams
   before the fault have already been delivered, as a real device would have. */
static inline int ncm_parse_ntb(const uint8_t *b, uint32_t len,
                                void (*fn)(void *opaque, const uint8_t *dg, uint32_t len), void *opaque) {
    if (len < 12 || ncm_rd32(b) != NCM_NTH16_SIG || ncm_rd16(b + 4) != 12) return -1;
    uint32_t block = ncm_rd16(b + 8), ndp = ncm_rd16(b + 10), count = 0;
    if (block == 0) block = len; /* a block length of 0 is allowed when the NTB ends with a short packet */
    if (block > len) return -1;
    for (int hops = 0; ndp; hops++) {
        if (hops > 64 || ndp < 12 || ndp % NCM_ALIGN || ndp + 16 > block) return -1;
        uint32_t sig = ncm_rd32(b + ndp), nlen = ncm_rd16(b + ndp + 4);
        if ((sig != NCM_NDP16_SIG && sig != NCM_NDP16_CRC) || nlen < 16 || nlen % 4 || ndp + nlen > block) return -1;
        for (uint32_t e = ndp + 8; e + 4 <= ndp + nlen; e += 4) {
            uint32_t off = ncm_rd16(b + e), dl = ncm_rd16(b + e + 2);
            if (off == 0 || dl == 0) break; /* the terminating entry */
            if (off < 12 || off + dl > block) return -1;
            if (sig == NCM_NDP16_CRC) { if (dl < 4) return -1; dl -= 4; }
            fn(opaque, b + off, dl);
            count++;
        }
        ndp = ncm_rd16(b + ndp + 6);
    }
    return (int)count;
}

/* Building an NTB for the guest: the NTH16, then the datagrams (each 4-aligned), then one NDP16 at the end. */
typedef struct NcmBuilder {
    uint8_t *b;
    uint32_t max, pos, n;
    uint16_t off[64], len[64];
} NcmBuilder;

static inline void ncm_build_start(NcmBuilder *w, uint8_t *buf, uint32_t max) {
    w->b = buf; w->max = max; w->pos = 12; w->n = 0;
}
/* Space the NDP16 needs for n datagrams plus the terminating entry. */
static inline uint32_t ncm_ndp_size(uint32_t n) { return 8 + 4 * (n + 1); }
static inline uint32_t ncm_up(uint32_t v) { return (v + NCM_ALIGN - 1) & ~(NCM_ALIGN - 1); }
/* 1 if a datagram of len bytes still fits (with the NDP that would follow it). */
static inline int ncm_build_fits(const NcmBuilder *w, uint32_t len) {
    if (w->n >= 64 || len > 0xffff) return 0;
    uint32_t start = ncm_up(w->pos);
    return ncm_up(start + len) + ncm_ndp_size(w->n + 1) <= w->max;
}
static inline int ncm_build_add(NcmBuilder *w, const uint8_t *dg, uint32_t len) {
    if (!ncm_build_fits(w, len)) return 0;
    uint32_t start = ncm_up(w->pos);
    memset(w->b + w->pos, 0, start - w->pos);
    memcpy(w->b + start, dg, len);
    w->off[w->n] = (uint16_t)start; w->len[w->n] = (uint16_t)len; w->n++;
    w->pos = start + len;
    return 1;
}
/* Write the NTH16 and NDP16. Returns the block length (0 if there are no datagrams). */
static inline uint32_t ncm_build_finish(NcmBuilder *w, uint16_t seq) {
    if (!w->n) return 0;
    uint32_t ndp = ncm_up(w->pos), nlen = ncm_ndp_size(w->n);
    memset(w->b + w->pos, 0, ndp - w->pos);
    uint8_t *p = w->b + ndp;
    ncm_wr32(p, NCM_NDP16_SIG); ncm_wr16(p + 4, nlen); ncm_wr16(p + 6, 0);
    for (uint32_t i = 0; i < w->n; i++) { ncm_wr16(p + 8 + 4 * i, w->off[i]); ncm_wr16(p + 10 + 4 * i, w->len[i]); }
    ncm_wr32(p + 8 + 4 * w->n, 0);
    uint32_t block = ndp + nlen;
    ncm_wr32(w->b, NCM_NTH16_SIG); ncm_wr16(w->b + 4, 12); ncm_wr16(w->b + 6, seq);
    ncm_wr16(w->b + 8, block); ncm_wr16(w->b + 10, ndp);
    return block;
}

#endif
