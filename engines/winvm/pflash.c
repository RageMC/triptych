// SPDX-License-Identifier: GPL-2.0-or-later
// CFI parallel NOR flash, Intel/Sharp command set, as QEMU's pflash_cfi01 on the
// ARM virt board: two 16-bit chips side by side (bank width 4), 256 KB blocks.
// EDK2's VirtNorFlashDxe writes commands to both chips at once (cmd << 16 | cmd).
// Bank 0 (firmware code) is mapped as read-only RAM so code runs from it directly;
// this device is bank 1, the UEFI variable store, saved back to its file.
#include "pflash.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

enum { MODE_ARRAY, MODE_STATUS, MODE_QUERY, MODE_ID, MODE_PROGRAM, MODE_ERASE, MODE_BUF_COUNT, MODE_BUF_DATA, MODE_BUF_CONFIRM };
#define BLOCK (256u * 1024u)

static uint32_t dual(uint16_t v) { return (uint32_t)v << 16 | v; }

/* CFI query table (one chip's view, 16-bit), the fields EDK2 and Linux read. */
static uint16_t cfi(PFlash *p, uint64_t chip_off) {
    uint64_t a = chip_off; /* in chip words */
    uint64_t chip_size = p->size / 2, blocks = chip_size / (BLOCK / 2);
    switch (a) {
    case 0x10: return 'Q'; case 0x11: return 'R'; case 0x12: return 'Y';
    case 0x13: return 0x01; case 0x14: return 0x00; /* primary command set: Intel */
    case 0x15: return 0x31; case 0x16: return 0x00;
    case 0x1b: return 0x45; case 0x1c: return 0x55; case 0x1f: return 0x07; case 0x20: return 0x07;
    case 0x21: return 0x0a; case 0x22: return 0x00; case 0x23: return 0x04; case 0x24: return 0x00;
    case 0x25: return 0x04; case 0x26: return 0x00;
    case 0x27: { int b = 0; while ((1ull << b) < chip_size) b++; return (uint16_t)b; } /* device size, log2 */
    case 0x28: return 0x01; case 0x29: return 0x00; /* x16 */
    case 0x2a: return 0x0b; case 0x2b: return 0x00; /* write buffer 2^11 bytes */
    case 0x2c: return 0x01; /* one erase region */
    case 0x2d: return (uint16_t)((blocks - 1) & 0xff); case 0x2e: return (uint16_t)((blocks - 1) >> 8);
    case 0x2f: return (uint16_t)(((BLOCK / 2) >> 8) & 0xff); case 0x30: return (uint16_t)((BLOCK / 2) >> 16);
    case 0x31: return 'P'; case 0x32: return 'R'; case 0x33: return 'I';
    case 0x34: return '1'; case 0x35: return '0';
    default: return 0;
    }
}

static void save(PFlash *p, uint64_t off, uint64_t len) {
    if (p->fd < 0) return;
    pwrite(p->fd, p->data + off, len, (off_t)off);
}

static uint64_t pflash_read(void *opaque, uint64_t off, unsigned size) {
    PFlash *p = opaque;
    if (off + size > p->size) return 0;
    switch (p->mode) {
    case MODE_ARRAY: { uint64_t v = 0; memcpy(&v, p->data + off, size); return v; }
    case MODE_QUERY: {
        uint32_t w = dual(cfi(p, off / 4));
        return size >= 4 ? w : (w & ((1u << (8 * size)) - 1));
    }
    case MODE_ID: {
        uint64_t a = off / 4;
        uint32_t w = a == 0 ? dual(0x89) : a == 1 ? dual(0x18) : 0;
        return w;
    }
    default: return dual(0x80); /* status: ready, no errors */
    }
}

static void pflash_write(void *opaque, uint64_t off, uint64_t v, unsigned size) {
    PFlash *p = opaque;
    if (off + size > p->size) return;
    uint8_t cmd = (uint8_t)v;
    switch (p->mode) {
    case MODE_PROGRAM: /* single word program */
        for (unsigned i = 0; i < size; i++) p->data[off + i] &= (uint8_t)(v >> (8 * i));
        save(p, off, size);
        p->mode = MODE_STATUS;
        return;
    case MODE_ERASE:
        if (cmd == 0xd0) {
            uint64_t b = off & ~(uint64_t)(BLOCK - 1);
            memset(p->data + b, 0xff, BLOCK);
            save(p, b, BLOCK);
        }
        p->mode = MODE_STATUS;
        return;
    case MODE_BUF_COUNT:
        p->buf_left = (uint32_t)((v & 0xffff) + 1); /* words per chip = bus words */
        p->mode = MODE_BUF_DATA;
        return;
    case MODE_BUF_DATA:
        for (unsigned i = 0; i < size; i++) p->data[off + i] &= (uint8_t)(v >> (8 * i));
        if (p->buf_lo == 0 || off < p->buf_lo) p->buf_lo = off;
        if (off + size > p->buf_hi) p->buf_hi = off + size;
        if (--p->buf_left == 0) p->mode = MODE_BUF_CONFIRM;
        return;
    case MODE_BUF_CONFIRM:
        if (p->buf_hi > p->buf_lo) save(p, p->buf_lo, p->buf_hi - p->buf_lo);
        p->buf_lo = p->buf_hi = 0;
        p->mode = MODE_STATUS;
        return;
    default: break;
    }
    switch (cmd) {
    case 0xff: p->mode = MODE_ARRAY; break;          /* read array */
    case 0x70: p->mode = MODE_STATUS; break;         /* read status */
    case 0x50: break;                                /* clear status */
    case 0x98: p->mode = MODE_QUERY; break;          /* CFI query */
    case 0x90: p->mode = MODE_ID; break;             /* read identifier */
    case 0x10: case 0x40: p->mode = MODE_PROGRAM; break;
    case 0x20: p->mode = MODE_ERASE; break;
    case 0xe8: p->mode = MODE_BUF_COUNT; p->buf_lo = p->buf_hi = 0; break;
    case 0x60: case 0x01: case 0xd0: case 0x2f: p->mode = MODE_STATUS; break; /* block lock/unlock: no locking */
    default:
        if (p->log) fprintf(stderr, "pflash: unknown command %#x at +%#llx\n", cmd, (unsigned long long)off);
        p->mode = MODE_ARRAY;
    }
}

int pflash_open(PFlash *p, HvMachine *m, uint64_t pa, uint64_t size, const char *path) {
    memset(p, 0, sizeof *p);
    p->size = size;
    p->fd = -1;
    p->data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p->data == MAP_FAILED) return -1;
    memset(p->data, 0xff, size);
    if (path) {
        p->fd = open(path, O_RDWR);
        if (p->fd < 0) return -1;
        ssize_t n = pread(p->fd, p->data, size, 0);
        if (n < 0) return -1;
    }
    p->log = getenv("WINVM_FLASH_LOG") != NULL;
    hv_machine_add_mmio(m, pa, size, p, pflash_read, pflash_write, "pflash");
    return 0;
}

void pflash_close(PFlash *p) {
    if (p->fd >= 0) { fsync(p->fd); close(p->fd); }
    if (p->data && p->data != MAP_FAILED) munmap(p->data, p->size);
    memset(p, 0, sizeof *p);
    p->fd = -1;
}
