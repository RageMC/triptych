// SPDX-License-Identifier: GPL-2.0-or-later
// QEMU's fw_cfg interface, MMIO flavour (the ARM "virt" board): EDK2's ArmVirtQemu
// reads its boot options, ACPI tables (through the table loader) and ramfb from it.
#ifndef WINVM_FWCFG_H
#define WINVM_FWCFG_H
#include <stdint.h>
#include "machine.h"

#define FWCFG_MAX_FILES 32

typedef struct FwCfgFile {
    char name[56];
    uint8_t *data;
    uint32_t size;
    uint16_t select;
    void (*on_write)(void *opaque, struct FwCfgFile *f); /* guest wrote the file (DMA write) */
    void *opaque;
} FwCfgFile;

typedef struct FwCfg {
    HvMachine *m;
    uint16_t cur;          /* selected key */
    uint32_t off;          /* read offset in the selected item */
    uint64_t dma_addr;     /* high half latched until the low half is written */
    FwCfgFile files[FWCFG_MAX_FILES];
    int nfiles;
    uint8_t *dir;          /* FW_CFG_FILE_DIR blob */
    uint32_t dir_size;
    uint8_t fixed[0x20][8];  /* small fixed keys (signature, id, cpus, ...) */
    uint32_t fixed_size[0x20];
} FwCfg;

FwCfg *fwcfg_create(HvMachine *m, uint64_t pa);
/* data is copied. Returns the file (to hook on_write) or NULL. */
FwCfgFile *fwcfg_add_file(FwCfg *f, const char *name, const void *data, uint32_t size);
void fwcfg_set_u16(FwCfg *f, uint16_t key, uint16_t v);
void fwcfg_set_u32(FwCfg *f, uint16_t key, uint32_t v);

#endif
