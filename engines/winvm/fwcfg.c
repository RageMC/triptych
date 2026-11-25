// SPDX-License-Identifier: GPL-2.0-or-later
// fw_cfg (docs/specs/fw_cfg.rst in QEMU): MMIO at +0 data, +8 selector (16-bit
// big-endian), +16 DMA address (64-bit big-endian; writing the low half starts
// the transfer). Items: 0 signature "QEMU", 1 id (bit 0 traditional, bit 1 DMA),
// 5 CPU count, 0x19 file directory, 0x20+ files.
#include "fwcfg.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { KEY_SIGNATURE = 0, KEY_ID = 1, KEY_NB_CPUS = 5, KEY_MAX_CPUS = 0xf, KEY_FILE_DIR = 0x19, KEY_FILE_FIRST = 0x20 };
enum { DMA_ERROR = 1, DMA_READ = 2, DMA_SKIP = 4, DMA_SELECT = 8, DMA_WRITE = 0x10 };

static uint64_t be64(uint64_t v) { return __builtin_bswap64(v); }
static uint32_t be32(uint32_t v) { return __builtin_bswap32(v); }

static int item(FwCfg *f, uint16_t key, uint8_t **data, uint32_t *size, FwCfgFile **file) {
    *file = NULL;
    if (key == KEY_FILE_DIR) { *data = f->dir; *size = f->dir_size; return 0; }
    if (key >= KEY_FILE_FIRST && key < KEY_FILE_FIRST + f->nfiles) {
        *file = &f->files[key - KEY_FILE_FIRST];
        *data = (*file)->data; *size = (*file)->size; return 0;
    }
    if (key < 0x20 && f->fixed_size[key]) { *data = f->fixed[key]; *size = f->fixed_size[key]; return 0; }
    *data = NULL; *size = 0;
    return -1;
}

static int rebuild_dir(FwCfg *f) {
    uint32_t size = 4 + 64u * (uint32_t)f->nfiles;
    uint8_t *dir = calloc(1, size);
    if (!dir) return -1;
    free(f->dir);
    f->dir = dir;
    f->dir_size = size;
    uint32_t n = be32((uint32_t)f->nfiles);
    memcpy(f->dir, &n, 4);
    for (int i = 0; i < f->nfiles; i++) {
        uint8_t *e = f->dir + 4 + 64 * i;
        uint32_t sz = be32(f->files[i].size);
        uint16_t sel = __builtin_bswap16(f->files[i].select);
        memcpy(e, &sz, 4);
        memcpy(e + 4, &sel, 2);
        strncpy((char *)e + 8, f->files[i].name, 55);
    }
    return 0;
}

FwCfgFile *fwcfg_add_file(FwCfg *f, const char *name, const void *data, uint32_t size) {
    if (f->nfiles >= FWCFG_MAX_FILES) return NULL;
    FwCfgFile *x = &f->files[f->nfiles];
    memset(x, 0, sizeof *x);
    strncpy(x->name, name, sizeof x->name - 1);
    x->data = calloc(1, size ? size : 1);
    if (!x->data) return NULL;
    if (data) memcpy(x->data, data, size);
    x->size = size;
    x->select = (uint16_t)(KEY_FILE_FIRST + f->nfiles);
    f->nfiles++;
    if (rebuild_dir(f) != 0) {
        f->nfiles--;
        free(x->data);
        return NULL;
    }
    return x;
}

static void set_fixed(FwCfg *f, uint16_t key, const void *v, uint32_t n) {
    memcpy(f->fixed[key], v, n);
    f->fixed_size[key] = n;
}
void fwcfg_set_u16(FwCfg *f, uint16_t key, uint16_t v) { set_fixed(f, key, &v, 2); } /* little-endian, as QEMU */
void fwcfg_set_u32(FwCfg *f, uint16_t key, uint32_t v) { set_fixed(f, key, &v, 4); }

static void do_dma(FwCfg *f, uint64_t addr) {
    struct { uint32_t control, length; uint64_t address; } __attribute__((packed)) d;
    if (hv_phys_read(f->m, addr, &d, sizeof d) != 0) return;
    uint32_t control = be32(d.control), length = be32(d.length);
    uint64_t address = be64(d.address);
    static int lg = -1; if (lg < 0) lg = getenv("WINVM_FWCFG_LOG") != NULL;
    if (lg) fprintf(stderr, "fwcfg dma ctl %#x len %u cur %#x off %u\n", control, length, f->cur, f->off);
    if (control & DMA_SELECT) { f->cur = (uint16_t)(control >> 16); f->off = 0; }
    uint8_t *data; uint32_t size; FwCfgFile *file;
    int ok = item(f, f->cur, &data, &size, &file) == 0;
    uint32_t err = 0;
    if (control & (DMA_READ | DMA_SKIP | DMA_WRITE)) {
        uint32_t avail = ok && f->off < size ? size - f->off : 0;
        uint32_t n = length < avail ? length : avail;
        if (control & DMA_READ) {
            if (n && hv_phys_write(f->m, address, data + f->off, n) != 0) err = 1;
            if (n) hv_dma_written(f->m, address, n);
            /* Past the end reads zeroes. */
            static const uint8_t zero[256];
            for (uint32_t z = n; z < length; z += sizeof zero) {
                uint32_t k = length - z < sizeof zero ? length - z : (uint32_t)sizeof zero;
                hv_phys_write(f->m, address + z, zero, k);
            }
        } else if (control & DMA_WRITE) {
            if (!file) err = 1; /* only files are writable (ramfb, etc/...) */
            else if (n && hv_phys_read(f->m, address, data + f->off, n) != 0) err = 1;
        }
        f->off += length;
        if ((control & DMA_WRITE) && file && !err && file->on_write) file->on_write(file->opaque, file);
    }
    uint32_t done = be32(err ? DMA_ERROR : 0);
    hv_phys_write(f->m, addr, &done, 4);
}

static uint64_t fwcfg_read(void *opaque, uint64_t off, unsigned size) {
    FwCfg *f = opaque;
    if (off < 8) { /* data register: size bytes, in order (big-endian as a number) */
        uint8_t *data; uint32_t isize; FwCfgFile *file;
        int ok = item(f, f->cur, &data, &isize, &file) == 0;
        uint64_t v = 0;
        for (unsigned i = 0; i < size; i++) {
            uint8_t b = ok && f->off < isize ? data[f->off] : 0;
            f->off++;
            v |= (uint64_t)b << (8 * i); /* memory order: first byte lowest address */
        }
        return v;
    }
    if (off >= 16 && off < 24) { /* DMA register reads back "QEMU CFG" */
        static const uint64_t magic = 0x51454d5520434647ull;
        uint64_t be = be64(magic);
        uint64_t v = 0;
        memcpy(&v, (uint8_t *)&be + (off - 16), size);
        return v;
    }
    return 0;
}

static void fwcfg_write(void *opaque, uint64_t off, uint64_t v, unsigned size) {
    FwCfg *f = opaque;
    if (getenv("WINVM_FWCFG_LOG")) fprintf(stderr, "fwcfg write +%llu size %u v %#llx\n", (unsigned long long)off, size, (unsigned long long)v);
    if (off == 8 && size == 2) { f->cur = __builtin_bswap16((uint16_t)v); f->off = 0; return; }
    if (off == 16 && size == 8) { do_dma(f, be64(v)); return; }
    if (off == 16 && size == 4) { f->dma_addr = (uint64_t)be32((uint32_t)v) << 32; return; }
    if (off == 20 && size == 4) { do_dma(f, f->dma_addr | be32((uint32_t)v)); f->dma_addr = 0; return; }
}

FwCfg *fwcfg_create(HvMachine *m, uint64_t pa) {
    FwCfg *f = calloc(1, sizeof *f);
    if (!f) return NULL;
    f->m = m;
    set_fixed(f, KEY_SIGNATURE, "QEMU", 4);
    fwcfg_set_u32(f, KEY_ID, 3); /* traditional + DMA */
    if (rebuild_dir(f) != 0) { free(f); return NULL; }
    hv_machine_add_mmio(m, pa, 0x18, f, fwcfg_read, fwcfg_write, "fw-cfg");
    return f;
}
