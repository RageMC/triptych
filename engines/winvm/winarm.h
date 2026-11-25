// SPDX-License-Identifier: GPL-2.0-or-later
// "winarm": a virtual ARM64 PC for Windows 11 on Arm (and any UEFI/ACPI OS), built on
// Henge's CPU core and devices. Memory map and interrupts follow QEMU's "virt" board
// so stock EDK2 firmware can also boot.
#ifndef WINVM_WINARM_H
#define WINVM_WINARM_H
#include <stdint.h>
#include "machine.h"
#include "gicv3.h"
#include "pl011.h"
#include "pl031.h"
#include "pl061.h"
#include "pcie.h"
#include "fwcfg.h"
#include "pflash.h"

#define WA_FLASH0      0x00000000ull /* firmware code, 64 MB */
#define WA_FLASH1      0x04000000ull /* UEFI variables, 64 MB */
#define WA_FLASH_SIZE  0x04000000ull
#define WA_GIC_DIST    0x08000000ull
#define WA_GIC_REDIST  0x080a0000ull
#define WA_UART        0x09000000ull
#define WA_RTC         0x09010000ull
#define WA_FWCFG       0x09020000ull
#define WA_GPIO        0x09030000ull
#define WA_TPM         0x0c000000ull /* TPM 2.0 TIS (FIFO): 5 localities of 4 KB, the 0x5000 window of QEMU's tpm-tis-device */
#define WA_TPM_SIZE    0x00005000ull
#define WA_PCIE_MMIO   0x10000000ull
#define WA_PCIE_MMIO_SIZE 0x2eff0000ull
#define WA_PCIE_PIO    0x3eff0000ull
#define WA_PCIE_ECAM   0x3f000000ull
#define WA_PCIE_ECAM_SIZE 0x01000000ull /* buses 0-15 */
#define WA_MEM         0x40000000ull

/* SPIs (INTID = 32 + n). PCIe slot s raises INTID 32 + WA_IRQ_PCIE + s (Henge's host bridge). */
#define WA_IRQ_UART 1
#define WA_IRQ_RTC  2
#define WA_IRQ_PCIE 3   /* slots 0..15: SPIs 3..18 */
#define WA_IRQ_GPIO 20  /* power button (ACPI GED), not on QEMU's line 7: that would share a PCIe slot's */
#define WA_PCI_SLOTS 16

typedef struct WinArm {
    HvMachine *m;
    HvCpu *cpus;
    int ncpus;
    uint64_t ram_size;
    uint8_t *ram, *code;
    PFlash vars;
    HvGic *gic;
    HvPl011 *uart;
    HvPl031 *rtc;
    HvPl061 *gpio;
    HvPcie *pcie;
    FwCfg *fwcfg;
    uint8_t *dtb; uint32_t dtb_size;
    /* TPM 2.0 (tpm.c): present when set; the board's DT, TPM2 table and SSDT describe it. */
    void *nvme;
    void *tpm; void (*tpm_reset)(void *tpm);
    /* ramfb: the guest's framebuffer, as EDK2 (and Windows' basic display driver) see it. */
    struct { uint64_t addr; uint32_t fourcc, flags, width, height, stride; } fb;
    void (*poll[8])(void *); void *poll_opaque[8]; int npoll; /* device work on CPU 0's tick */
} WinArm;

typedef struct WinArmConfig {
    int ncpus;
    uint64_t ram_mb;
    uint32_t display_width, display_height;  /* optional preferred GOP mode */
    const char *code_path;   /* QEMU_EFI.fd (read-only) */
    const char *vars_path;   /* a writable copy of QEMU_VARS.fd */
} WinArmConfig;

int winarm_create(WinArm *b, HvMachine *m, HvCpu *cpus, const WinArmConfig *c, char *err, int errlen);
/* After every device is attached: device tree, ACPI tables, fw_cfg files. */
void winarm_destroy(WinArm *b);
int winarm_finalize(WinArm *b);
void winarm_reset(WinArm *b);
void winarm_add_poll(WinArm *b, void (*fn)(void *), void *opaque);

#endif
