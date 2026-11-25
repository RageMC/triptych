// SPDX-License-Identifier: GPL-2.0-or-later
// ACPI 6.3 tables for the winarm board. They go to the firmware as QEMU does it:
// fw_cfg files etc/acpi/rsdp and etc/acpi/tables, plus etc/table-loader commands
// (allocate, patch pointers, fix checksums). EDK2's QemuFwCfgAcpiPlatformDxe runs the
// loader and installs every table the XSDT points to. Windows on Arm boots from these.
#include "acpi.h"
#include "winarm.h"
#include "dsdt_aml.h"
#include "ssdt_tpm_aml.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define TABLES "etc/acpi/tables"
#define RSDP_FILE "etc/acpi/rsdp"

typedef struct Buf { uint8_t *d; uint32_t len, cap; } Buf;
static uint32_t grow(Buf *b, uint32_t n) {
    if (b->len + n > b->cap) { b->cap = (b->len + n) * 2 + 256; b->d = realloc(b->d, b->cap); }
    memset(b->d + b->len, 0, n);
    uint32_t at = b->len; b->len += n; return at;
}
static void put(Buf *b, const void *p, uint32_t n) { uint32_t at = grow(b, n); if (n) memcpy(b->d + at, p, n); }
static void w8(Buf *b, uint32_t at, uint8_t v) { b->d[at] = v; }
static void w16(Buf *b, uint32_t at, uint16_t v) { memcpy(b->d + at, &v, 2); }
static void w32(Buf *b, uint32_t at, uint32_t v) { memcpy(b->d + at, &v, 4); }
static void w64(Buf *b, uint32_t at, uint64_t v) { memcpy(b->d + at, &v, 8); }

/* Table loader. */
typedef struct Loader { Buf cmds; Buf sums; } Loader;
static void ld_alloc(Loader *l, const char *file, uint32_t align, uint8_t zone) {
    uint32_t at = grow(&l->cmds, 128);
    w32(&l->cmds, at, 1);
    strncpy((char *)l->cmds.d + at + 4, file, 55);
    w32(&l->cmds, at + 60, align);
    w8(&l->cmds, at + 64, zone);
}
static void ld_pointer(Loader *l, const char *dst, const char *src, uint32_t off, uint8_t size) {
    uint32_t at = grow(&l->cmds, 128);
    w32(&l->cmds, at, 2);
    strncpy((char *)l->cmds.d + at + 4, dst, 55);
    strncpy((char *)l->cmds.d + at + 60, src, 55);
    w32(&l->cmds, at + 116, off);
    w8(&l->cmds, at + 120, size);
}
static void ld_checksum(Loader *l, const char *file, uint32_t result, uint32_t start, uint32_t len) {
    uint32_t at = grow(&l->sums, 128); /* checksums go after every pointer is patched */
    w32(&l->sums, at, 3);
    strncpy((char *)l->sums.d + at + 4, file, 55);
    w32(&l->sums, at + 60, result);
    w32(&l->sums, at + 64, start);
    w32(&l->sums, at + 68, len);
}

/* A table header at t->len; returns its offset. Length is fixed by end_table. */
static uint32_t begin_table(Buf *t, const char *sig, uint8_t rev) {
    while (t->len & 7) grow(t, 1);
    uint32_t at = grow(t, 36);
    memcpy(t->d + at, sig, 4);
    w8(t, at + 8, rev);
    memcpy(t->d + at + 10, "TRPTCH", 6);
    memcpy(t->d + at + 16, "WINARM  ", 8);
    w32(t, at + 24, 1);
    memcpy(t->d + at + 28, "TRPT", 4);
    w32(t, at + 32, 1);
    return at;
}
static void end_table(Buf *t, Loader *l, uint32_t at) {
    w32(t, at + 4, t->len - at);
    ld_checksum(l, TABLES, at + 9, at, t->len - at);
}

/* AML for the CPU SSDT: Device (Cxxx) { Name (_HID, "ACPI0007") Name (_UID, n) }. */
static void aml_pkglen(Buf *b, uint32_t len) { /* len includes the PkgLength bytes */
    if (len + 1 < 0x40) { uint8_t v = (uint8_t)(len + 1); put(b, &v, 1); return; }
    len += 2;
    uint8_t v[2] = {(uint8_t)(0x40 | (len & 0xf)), (uint8_t)(len >> 4)};
    put(b, v, 2);
}
static void build_cpu_ssdt(Buf *t, Loader *l, int ncpus) {
    uint32_t at = begin_table(t, "SSDT", 2);
    Buf body = {0};
    for (int i = 0; i < ncpus; i++) {
        Buf dev = {0};
        char name[5]; snprintf(name, sizeof name, "C%03X", i);
        put(&dev, name, 4);
        uint8_t hid[] = {0x08, '_', 'H', 'I', 'D', 0x0d, 'A', 'C', 'P', 'I', '0', '0', '0', '7', 0};
        put(&dev, hid, sizeof hid);
        uint8_t uid[] = {0x08, '_', 'U', 'I', 'D', 0x0a, (uint8_t)i};
        put(&dev, uid, sizeof uid);
        uint8_t op[2] = {0x5b, 0x82};
        put(&body, op, 2);
        aml_pkglen(&body, dev.len);
        put(&body, dev.d, dev.len);
        free(dev.d);
    }
    /* Scope (\_SB) { ... } */
    uint8_t scope = 0x10;
    put(t, &scope, 1);
    Buf inner = {0};
    uint8_t sb[] = {'\\', '_', 'S', 'B', '_'};
    put(&inner, sb, 5);
    put(&inner, body.d, body.len);
    /* PkgLength may need 2 or 3 bytes. */
    uint32_t len = inner.len;
    if (len + 1 < 0x40) { uint8_t v = (uint8_t)(len + 1); put(t, &v, 1); }
    else if (len + 2 < 0x1000) { len += 2; uint8_t v[2] = {(uint8_t)(0x40 | (len & 0xf)), (uint8_t)(len >> 4)}; put(t, v, 2); }
    else { len += 3; uint8_t v[3] = {(uint8_t)(0x80 | (len & 0xf)), (uint8_t)(len >> 4), (uint8_t)(len >> 12)}; put(t, v, 3); }
    put(t, inner.d, inner.len);
    free(inner.d); free(body.d);
    end_table(t, l, at);
}

int acpi_build(WinArm *b) {
    Buf t = {0}, rsdp = {0};
    Loader l = {0};
    uint32_t off[16]; int n = 0; /* tables the XSDT lists */

    /* The SSDT goes first: a table at offset 0 of the blob reads as a NULL pointer to EDK2's loader. */
    while (t.len & 7) grow(&t, 1);
    uint32_t ssdt = t.len; build_cpu_ssdt(&t, &l, b->ncpus); off[n++] = ssdt;

    while (t.len & 7) grow(&t, 1);
    uint32_t dsdt = t.len; /* the compiled DSDT carries its own header */
    put(&t, dsdt_aml, sizeof dsdt_aml);
    memcpy(t.d + dsdt + 10, "TRPTCH", 6);
    t.d[dsdt + 9] = 0; /* the loader's checksum command sums the old byte too: it must start at 0 (iasl's was not) */
    end_table(&t, &l, dsdt);

    /* FADT, ACPI 6.3: hardware-reduced, PSCI over SMC (no HVC flag). */
    uint32_t fadt = begin_table(&t, "FACP", 6);
    grow(&t, 276 - 36);
    w32(&t, fadt + 112, 1u << 20);              /* Flags: HW_REDUCED_ACPI */
    w16(&t, fadt + 129, 1);                     /* ARM boot arch: PSCI_COMPLIANT */
    w8(&t, fadt + 131, 3);                      /* FADT minor version */
    memcpy(t.d + fadt + 268, "TRPTCH  ", 8);    /* hypervisor vendor identity */
    end_table(&t, &l, fadt); off[n++] = fadt;
    ld_pointer(&l, TABLES, TABLES, fadt + 140, 8); /* X_DSDT */
    w64(&t, fadt + 140, dsdt);
    ld_pointer(&l, TABLES, TABLES, fadt + 40, 4); /* legacy DSDT: EDK2 follows this one to install the DSDT */
    w32(&t, fadt + 40, dsdt);

    /* MADT: one GICC per CPU, GICD, one GICR range. */
    uint32_t madt = begin_table(&t, "APIC", 5);
    grow(&t, 8);
    for (int i = 0; i < b->ncpus; i++) {
        uint32_t g = grow(&t, 80);
        w8(&t, g, 0x0b); w8(&t, g + 1, 80);
        w32(&t, g + 4, (uint32_t)i);            /* CPU interface number */
        w32(&t, g + 8, (uint32_t)i);            /* ACPI processor UID (matches the SSDT's _UID) */
        w32(&t, g + 12, 1);                     /* enabled */
        w32(&t, g + 20, 23);                    /* performance interrupt (PMU PPI 7) */
        w32(&t, g + 56, 25);                    /* VGIC maintenance interrupt */
        w64(&t, g + 68, (uint64_t)i);           /* MPIDR (Aff0 = i) */
    }
    uint32_t gd = grow(&t, 24);
    w8(&t, gd, 0x0c); w8(&t, gd + 1, 24);
    w64(&t, gd + 8, WA_GIC_DIST);
    w8(&t, gd + 20, 3);                         /* GICv3 */
    uint32_t gr = grow(&t, 16);
    w8(&t, gr, 0x0e); w8(&t, gr + 1, 16);
    w64(&t, gr + 4, WA_GIC_REDIST);
    w32(&t, gr + 12, 0x20000u * (uint32_t)b->ncpus);
    end_table(&t, &l, madt); off[n++] = madt;

    /* GTDT: EL1 physical (secure, non-secure), virtual and EL2 timers; level, active high, always on. */
    uint32_t gtdt = begin_table(&t, "GTDT", 3);
    grow(&t, 104 - 36);
    w64(&t, gtdt + 36, ~0ull);                  /* CntControlBase: none */
    w32(&t, gtdt + 48, 29); w32(&t, gtdt + 52, 4);
    w32(&t, gtdt + 56, 30); w32(&t, gtdt + 60, 4);
    w32(&t, gtdt + 64, 27); w32(&t, gtdt + 68, 4);
    w32(&t, gtdt + 72, 26); w32(&t, gtdt + 76, 4);
    w64(&t, gtdt + 80, ~0ull);                  /* CntReadBase: none */
    w32(&t, gtdt + 96, 28); w32(&t, gtdt + 100, 4); /* virtual EL2 timer */
    end_table(&t, &l, gtdt); off[n++] = gtdt;

    /* MCFG: ECAM for segment 0, buses 0-15. */
    uint32_t mcfg = begin_table(&t, "MCFG", 1);
    grow(&t, 8);
    uint32_t e = grow(&t, 16);
    w64(&t, e, WA_PCIE_ECAM);
    w8(&t, e + 11, (uint8_t)((WA_PCIE_ECAM_SIZE >> 20) - 1));
    end_table(&t, &l, mcfg); off[n++] = mcfg;

    /* SPCR: the PL011 as the console and Windows' EMS/debug port. */
    uint32_t spcr = begin_table(&t, "SPCR", 2);
    grow(&t, 80 - 36);
    w8(&t, spcr + 36, 3);                       /* ARM PL011 */
    w8(&t, spcr + 40, 0); w8(&t, spcr + 41, 32); w8(&t, spcr + 43, 3); /* GAS: MMIO, 32 bits, dword access */
    w64(&t, spcr + 44, WA_UART);
    w8(&t, spcr + 52, 8);                       /* interrupt type: GIC */
    w32(&t, spcr + 54, 32 + WA_IRQ_UART);
    w8(&t, spcr + 58, 7);                       /* 115200 */
    w8(&t, spcr + 60, 1);                       /* one stop bit */
    w16(&t, spcr + 64, 0xffff); w16(&t, spcr + 66, 0xffff); /* not a PCI device */
    end_table(&t, &l, spcr); off[n++] = spcr;

    if (b->tpm) {
        /* TPM2 (TCG ACPI spec rev 4): TIS/FIFO at WA_TPM, start method 6 = memory-mapped I/O (what QEMU
           publishes for tpm-tis-device; Windows' tpm.sys drives it). No control area (CRB only), no event
           log area: the TCG log reaches the OS through EDK2's Tcg2 protocol and the EFI log config table. */
        uint32_t tpm2 = begin_table(&t, "TPM2", 4);
        grow(&t, 76 - 36);
        w16(&t, tpm2 + 36, 0);                  /* platform class: client */
        w32(&t, tpm2 + 48, 6);                  /* start method: MMIO (TIS) */
        end_table(&t, &l, tpm2); off[n++] = tpm2;

        /* SSDT with the MSFT0101 device and its register window. */
        while (t.len & 7) grow(&t, 1);
        uint32_t ssdt2 = t.len;
        put(&t, ssdt_tpm_aml, sizeof ssdt_tpm_aml);
        memcpy(t.d + ssdt2 + 10, "TRPTCH", 6);
        t.d[ssdt2 + 9] = 0;
        end_table(&t, &l, ssdt2); off[n++] = ssdt2;
    }

    /* XSDT, last so every table offset is known. */
    uint32_t xsdt = begin_table(&t, "XSDT", 1);
    for (int i = 0; i < n; i++) {
        uint32_t p = grow(&t, 8);
        w64(&t, p, off[i]);
        ld_pointer(&l, TABLES, TABLES, p, 8);
    }
    end_table(&t, &l, xsdt);

    /* RSDP 2.0. */
    grow(&rsdp, 36);
    memcpy(rsdp.d, "RSD PTR ", 8);
    memcpy(rsdp.d + 9, "TRPTCH", 6);
    w8(&rsdp, 15, 2);
    w32(&rsdp, 20, 36);
    w64(&rsdp, 24, xsdt);

    /* Commands: allocate both files, patch pointers, then checksums. */
    Loader out = {0};
    ld_alloc(&out, RSDP_FILE, 16, 2);
    ld_alloc(&out, TABLES, 64, 1);
    put(&out.cmds, l.cmds.d, l.cmds.len);
    ld_pointer(&out, RSDP_FILE, TABLES, 24, 8);
    ld_checksum(&out, RSDP_FILE, 8, 0, 20);
    ld_checksum(&out, RSDP_FILE, 32, 0, 36);
    put(&out.cmds, l.sums.d, l.sums.len);
    put(&out.cmds, out.sums.d, out.sums.len);

    if (getenv("WINVM_ACPI_DUMP")) { /* debugging: the blobs and the loader script, for iasl/acpidump checks */
        const char *dir = getenv("WINVM_ACPI_DUMP"); char p[512]; FILE *f;
        snprintf(p, sizeof p, "%s/tables.bin", dir); if ((f = fopen(p, "wb"))) { fwrite(t.d, 1, t.len, f); fclose(f); }
        snprintf(p, sizeof p, "%s/rsdp.bin", dir); if ((f = fopen(p, "wb"))) { fwrite(rsdp.d, 1, rsdp.len, f); fclose(f); }
        snprintf(p, sizeof p, "%s/loader.bin", dir); if ((f = fopen(p, "wb"))) { fwrite(out.cmds.d, 1, out.cmds.len, f); fclose(f); }
    }
    int ok = fwcfg_add_file(b->fwcfg, TABLES, t.d, t.len) &&
             fwcfg_add_file(b->fwcfg, RSDP_FILE, rsdp.d, rsdp.len) &&
             fwcfg_add_file(b->fwcfg, "etc/table-loader", out.cmds.d, out.cmds.len);
    free(t.d); free(rsdp.d); free(l.cmds.d); free(l.sums.d); free(out.cmds.d); free(out.sums.d);
    return ok ? 0 : -1;
}
