// SPDX-License-Identifier: GPL-2.0-or-later
// The network adapter's pieces without a guest: ncm.h's NTB builder and parser (round trips, alignment,
// size limits, malformed blocks), then Henge's net_slirp through hv_net_attach_rx as usb.c uses it:
// a DHCP DISCOVER must come back as an OFFER of 10.0.2.15, and an ARP request for 10.0.2.2 must be answered.
#include "ncm.h"
#include "net_slirp.h"
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static int fails;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

void hv_machine_wake(HvMachine *m) { (void)m; } /* net_slirp wakes the CPUs; there are none here */
int hv_knob[HV_K_COUNT];                       /* dns_proxy's switches: all defaults */
int hv_virtio_net_receive(HvVirtioNet *n, const uint8_t *f, uint32_t len) { (void)n; (void)f; (void)len; return 0; } /* unused here */

/* ---- NTB codec ---- */

static uint8_t got[64][2048];
static uint32_t gotlen[64], ngot;
static void collect(void *o, const uint8_t *dg, uint32_t len) {
    (void)o;
    if (ngot < 64 && len <= sizeof got[0]) { memcpy(got[ngot], dg, len); gotlen[ngot] = len; }
    ngot++;
}

static void test_codec(void) {
    uint8_t blk[NCM_NTB_MAX], dg[3][1514];
    uint32_t sizes[3] = {60, 1514, 7}; /* 7: odd lengths must still leave the next datagram 4-aligned */
    for (int i = 0; i < 3; i++) for (uint32_t j = 0; j < sizes[i]; j++) dg[i][j] = (uint8_t)(i * 31 + j);
    NcmBuilder w;
    ncm_build_start(&w, blk, sizeof blk);
    CHECK(ncm_build_finish(&w, 0) == 0); /* nothing to send: no block */
    for (int i = 0; i < 3; i++) CHECK(ncm_build_add(&w, dg[i], sizes[i]));
    uint32_t len = ncm_build_finish(&w, 7);
    CHECK(len > 0 && len <= sizeof blk);
    CHECK(ncm_rd32(blk) == NCM_NTH16_SIG && ncm_rd16(blk + 6) == 7 && ncm_rd16(blk + 8) == len);
    uint32_t ndp = ncm_rd16(blk + 10);
    CHECK(ndp % NCM_ALIGN == 0);
    for (uint32_t i = 0; i < 3; i++) CHECK(ncm_rd16(blk + ndp + 8 + 4 * i) % NCM_ALIGN == 0);
    ngot = 0;
    CHECK(ncm_parse_ntb(blk, len, collect, NULL) == 3);
    for (int i = 0; i < 3; i++) CHECK(gotlen[i] == sizes[i] && !memcmp(got[i], dg[i], sizes[i]));
    /* the host's transfer size bounds the block: a 2048-byte NTB holds one full frame, not two */
    ncm_build_start(&w, blk, 2048);
    CHECK(ncm_build_add(&w, dg[1], 1514));
    CHECK(!ncm_build_add(&w, dg[1], 1514));
    CHECK(ncm_build_finish(&w, 0) <= 2048);
    /* 64 datagrams at most per NDP (the builder's table) */
    ncm_build_start(&w, blk, sizeof blk);
    int n = 0;
    while (ncm_build_add(&w, dg[2], 7)) n++;
    CHECK(n == 64);
    len = ncm_build_finish(&w, 1);
    ngot = 0;
    CHECK(ncm_parse_ntb(blk, len, collect, NULL) == 64);
    /* block length 0 (ended by a short packet) means "up to the transfer's end" */
    ncm_wr16(blk + 8, 0);
    ngot = 0;
    CHECK(ncm_parse_ntb(blk, len, collect, NULL) == 64);
    /* malformed blocks are refused, never read outside the buffer */
    ncm_build_start(&w, blk, sizeof blk);
    ncm_build_add(&w, dg[0], 60);
    len = ncm_build_finish(&w, 0);
    uint8_t bad[NCM_NTB_MAX];
    memcpy(bad, blk, len); bad[0] ^= 1; CHECK(ncm_parse_ntb(bad, len, collect, NULL) < 0);           /* NTH signature */
    memcpy(bad, blk, len); ncm_wr16(bad + 8, len + 4); CHECK(ncm_parse_ntb(bad, len, collect, NULL) < 0); /* longer than sent */
    memcpy(bad, blk, len); ncm_wr16(bad + 10, len); CHECK(ncm_parse_ntb(bad, len, collect, NULL) < 0);   /* NDP past the end */
    memcpy(bad, blk, len); ncm_wr16(bad + 10, 2); CHECK(ncm_parse_ntb(bad, len, collect, NULL) < 0);     /* NDP inside the NTH */
    ndp = ncm_rd16(blk + 10);
    memcpy(bad, blk, len); ncm_wr16(bad + ndp + 10, 2000); CHECK(ncm_parse_ntb(bad, len, collect, NULL) < 0); /* datagram past the end */
    memcpy(bad, blk, len); ncm_wr16(bad + ndp + 6, (uint16_t)ndp); CHECK(ncm_parse_ntb(bad, len, collect, NULL) < 0); /* NDP chain loops */
    CHECK(ncm_parse_ntb(blk, 11, collect, NULL) < 0);
    /* a CRC-mode NDP: the 4 CRC bytes are not part of the frame */
    memcpy(bad, blk, len); ncm_wr32(bad + ndp, NCM_NDP16_CRC); ngot = 0;
    CHECK(ncm_parse_ntb(bad, len, collect, NULL) == 1 && gotlen[0] == 56);
    uint8_t p[28];
    CHECK(ncm_ntb_parameters(p) == 28 && ncm_rd16(p) == 28 && ncm_rd16(p + 2) == 1 && ncm_rd32(p + 4) == NCM_NTB_MAX);
}

/* ---- net_slirp end to end ---- */

static const uint8_t mac[6] = {0x52, 0x54, 0x00, 0x12, 0x34, 0x56};
static uint8_t rxf[64][2048];
static uint32_t rxl[64], nrx;
static int room = 1;
static int rx(void *o, const uint8_t *f, uint32_t len) {
    (void)o;
    if (!room) return 0;
    if (nrx < 64 && len <= sizeof rxf[0]) { memcpy(rxf[nrx], f, len); rxl[nrx] = len; nrx++; }
    return 1;
}

static uint16_t csum(const uint8_t *p, int n) {
    uint32_t s = 0;
    for (int i = 0; i + 1 < n; i += 2) s += (uint32_t)p[i] << 8 | p[i + 1];
    while (s >> 16) s = (s & 0xffff) + (s >> 16);
    return (uint16_t)~s;
}

static int wait_for(int (*match)(const uint8_t *, uint32_t)) {
    for (int t = 0; t < 300; t++) {
        hv_net_poll();
        for (uint32_t i = 0; i < nrx; i++) if (match(rxf[i], rxl[i])) return 1;
        usleep(10000);
    }
    return 0;
}

static int is_offer(const uint8_t *f, uint32_t len) {
    if (len < 14 + 20 + 8 + 240 || f[12] != 0x08 || f[13] != 0 || f[23] != 17) return 0;
    const uint8_t *b = f + 14 + 20 + 8;
    if (b[0] != 2 || b[4] != 0xde || b[5] != 0xad) return 0;
    if (!(b[16] == 10 && b[17] == 0 && b[18] == 2 && b[19] == 15)) return 0; /* yiaddr 10.0.2.15 */
    for (uint32_t o = 240; 14 + 28 + o + 2 < len; ) {
        uint8_t code = b[o];
        if (code == 255) break;
        if (code == 0) { o++; continue; }
        if (code == 53) return b[o + 2] == 2; /* DHCPOFFER */
        o += 2u + b[o + 1];
    }
    return 0;
}

static int is_arp_reply(const uint8_t *f, uint32_t len) {
    return len >= 42 && f[12] == 0x08 && f[13] == 0x06 && f[20] == 0 && f[21] == 2 &&
           f[28] == 10 && f[29] == 0 && f[30] == 2 && f[31] == 2 && !memcmp(f, mac, 6);
}

static void test_slirp(void) {
    static HvMachine m; /* large: not on the stack */
    memset(&m, 0, sizeof m);
    CHECK(hv_net_attach_rx(&m, NULL, NULL) != 0);
    CHECK(hv_net_attach_rx(&m, rx, NULL) == 0);
    CHECK(hv_net_attach_rx(&m, rx, NULL) != 0); /* one network at a time */

    uint8_t f[14 + 20 + 8 + 300];
    memset(f, 0, sizeof f);
    memset(f, 0xff, 6); memcpy(f + 6, mac, 6); f[12] = 0x08;
    uint8_t *ip = f + 14, *udp = ip + 20, *b = udp + 8;
    ip[0] = 0x45; ip[2] = (uint8_t)((20 + 8 + 300) >> 8); ip[3] = (uint8_t)(20 + 8 + 300); ip[8] = 64; ip[9] = 17;
    memset(ip + 16, 0xff, 4);
    uint16_t c = csum(ip, 20); ip[10] = (uint8_t)(c >> 8); ip[11] = (uint8_t)c;
    udp[1] = 68; udp[3] = 67; udp[4] = (uint8_t)((8 + 300) >> 8); udp[5] = (uint8_t)(8 + 300);
    b[0] = 1; b[1] = 1; b[2] = 6; b[4] = 0xde; b[5] = 0xad; b[6] = 0xbe; b[7] = 0xef; b[10] = 0x80;
    memcpy(b + 28, mac, 6);
    b[236] = 99; b[237] = 130; b[238] = 83; b[239] = 99;
    b[240] = 53; b[241] = 1; b[242] = 1; b[243] = 255;
    room = 0;           /* the device has no room: the frame must wait in net_slirp, not be lost */
    hv_net_transmit(f, sizeof f);
    for (int i = 0; i < 20; i++) { hv_net_poll(); usleep(10000); }
    CHECK(nrx == 0);
    room = 1;
    CHECK(wait_for(is_offer));

    uint8_t a[42] = {0};
    memset(a, 0xff, 6); memcpy(a + 6, mac, 6); a[12] = 0x08; a[13] = 0x06;
    a[14] = 0; a[15] = 1; a[16] = 0x08; a[17] = 0; a[18] = 6; a[19] = 4; a[20] = 0; a[21] = 1;
    memcpy(a + 22, mac, 6); a[28] = 10; a[29] = 0; a[30] = 2; a[31] = 15;
    a[38] = 10; a[39] = 0; a[40] = 2; a[41] = 2;
    hv_net_transmit(a, sizeof a);
    CHECK(wait_for(is_arp_reply));
    hv_net_detach();
    CHECK(hv_net_attach_rx(&m, rx, NULL) == 0); /* detach leaves it reusable */
    hv_net_detach();
}

int main(void) {
    test_codec();
    test_slirp();
    if (fails) { fprintf(stderr, "ncm_test: %d failures\n", fails); return 1; }
    printf("ncm_test: all passed\n");
    return 0;
}
