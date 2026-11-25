// SPDX-License-Identifier: GPL-2.0-or-later
#include "winarm.h"
#include "acpi.h"
#include "fdt.h"
#include "timer.h"
#include "sysreg.h"
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

void winarm_add_poll(WinArm *b, void (*fn)(void *), void *opaque) {
    if (b->npoll < 8) { b->poll[b->npoll] = fn; b->poll_opaque[b->npoll++] = opaque; }
}

static uint64_t tick(HvMachine *m, HvCpu *cpu) {
    WinArm *b = m->tick_opaque;
    if (cpu->index != 0) return hv_timer_update(b->gic, cpu);
    hv_dev_lock(m);
    uint64_t deadline = hv_timer_update(b->gic, cpu);
    hv_pl031_tick(b->rtc);
    for (int i = 0; i < b->npoll; i++) b->poll[i](b->poll_opaque[i]);
    hv_dev_unlock(m);
    return deadline;
}

/* PCIe I/O window: no device has I/O BARs, but EDK2 and the OS expect the window. */
static uint64_t pio_read(void *o, uint64_t off, unsigned size) { (void)o; (void)off; (void)size; return ~0ull; }
static void pio_write(void *o, uint64_t off, uint64_t v, unsigned size) { (void)o; (void)off; (void)v; (void)size; }

/* etc/ramfb: 28 bytes, big-endian: addr u64, fourcc u32, flags u32, width, height, stride. */
static void ramfb_written(void *opaque, FwCfgFile *f) {
    WinArm *b = opaque;
    const uint8_t *d = f->data;
    uint64_t a; uint32_t v[5];
    memcpy(&a, d, 8); memcpy(v, d + 8, 20);
    b->fb.addr = __builtin_bswap64(a);
    b->fb.fourcc = __builtin_bswap32(v[0]); b->fb.flags = __builtin_bswap32(v[1]);
    b->fb.width = __builtin_bswap32(v[2]); b->fb.height = __builtin_bswap32(v[3]); b->fb.stride = __builtin_bswap32(v[4]);
    fprintf(stderr, "winarm: ramfb %ux%u stride %u at %#llx\n", b->fb.width, b->fb.height, b->fb.stride,
            (unsigned long long)b->fb.addr);
}

int winarm_create(WinArm *b, HvMachine *m, HvCpu *cpus, const WinArmConfig *c, char *err, int errlen) {
    memset(b, 0, sizeof *b);
    b->vars.fd = -1;
    b->m = m; b->cpus = cpus;
    b->ncpus = c->ncpus < 1 ? 1 : c->ncpus > HV_MAX_CPUS ? HV_MAX_CPUS : c->ncpus;
    b->ram_size = (c->ram_mb ? c->ram_mb : 4096) << 20;
    m->psci_smc = 1;
    m->pmu_regs = 1;
    m->hafdbs = 1; /* Windows on Arm needs hardware Access flag updates */
    m->lse2 = 1;   /* and unaligned STLR (FEAT_LSE2): its clock writes KUSER_SHARED_DATA.SystemTime at +0x14 */
    b->ram = mmap(NULL, b->ram_size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    b->code = mmap(NULL, WA_FLASH_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (b->ram == MAP_FAILED || b->code == MAP_FAILED) { snprintf(err, errlen, "not enough memory for the guest"); return -1; }
    int fd = open(c->code_path, O_RDONLY);
    if (fd < 0 || read(fd, b->code, WA_FLASH_SIZE) <= 0) { snprintf(err, errlen, "cannot read firmware %s", c->code_path); if (fd >= 0) close(fd); return -1; }
    close(fd);
    if (hv_machine_add_ram(m, WA_FLASH0, WA_FLASH_SIZE, b->code, 1) != 0) {
        snprintf(err, errlen, "cannot map firmware");
        return -1;
    }
    if (pflash_open(&b->vars, m, WA_FLASH1, WA_FLASH_SIZE, c->vars_path) != 0) {
        snprintf(err, errlen, "cannot open the UEFI variable store %s", c->vars_path ? c->vars_path : "");
        return -1;
    }
    if (hv_machine_add_ram(m, WA_MEM, b->ram_size, b->ram, 0) != 0) {
        snprintf(err, errlen, "cannot map guest memory");
        return -1;
    }

    b->gic = hv_gicv3_create(m, WA_GIC_DIST, WA_GIC_REDIST);
    b->uart = hv_pl011_create(m, b->gic, WA_UART, 32 + WA_IRQ_UART);
    b->rtc = hv_pl031_create(m, b->gic, WA_RTC, 32 + WA_IRQ_RTC);
    b->gpio = hv_pl061_create(m, b->gic, WA_GPIO, 32 + WA_IRQ_GPIO);
    b->fwcfg = fwcfg_create(m, WA_FWCFG);
    hv_machine_add_mmio(m, WA_PCIE_PIO, 0x10000, b, pio_read, pio_write, "pcie-pio");
    b->pcie = hv_pcie_create(m, b->gic, WA_PCIE_ECAM, WA_PCIE_ECAM_SIZE, WA_PCIE_MMIO, WA_PCIE_MMIO_SIZE, 32 + WA_IRQ_PCIE);
    if (!b->gic || !b->uart || !b->rtc || !b->gpio || !b->fwcfg || !b->pcie) {
        snprintf(err, errlen, "cannot create the board devices");
        return -1;
    }
    fwcfg_set_u16(b->fwcfg, 5, (uint16_t)b->ncpus);   /* FW_CFG_NB_CPUS */
    fwcfg_set_u16(b->fwcfg, 0xf, (uint16_t)b->ncpus); /* FW_CFG_MAX_CPUS */
    FwCfgFile *rf = fwcfg_add_file(b->fwcfg, "etc/ramfb", NULL, 28);
    if (!rf) { snprintf(err, errlen, "cannot create ramfb"); return -1; }
    rf->on_write = ramfb_written; rf->opaque = b;

    if (c->display_width && c->display_height) {
        uint32_t w = c->display_width, h = c->display_height;
        uint8_t mode[] = {w >> 24, w >> 16, w >> 8, w, h >> 24, h >> 16, h >> 8, h};
        if (!fwcfg_add_file(b->fwcfg, "opt/org.triptych/ramfb-mode", mode, sizeof mode)) {
            snprintf(err, errlen, "cannot publish the preferred ramfb mode");
            return -1;
        }
    }

    m->tick = tick;
    m->tick_opaque = b;
    for (int i = 0; i < b->ncpus; i++) cpus[i].m = m;
    return 0;
}

/* Only after all CPU and device workers have stopped. */
void winarm_destroy(WinArm *b) {
    if (!b->m) return;
    free(b->dtb);
    if (b->fwcfg) {
        for (int i = 0; i < b->fwcfg->nfiles; i++) free(b->fwcfg->files[i].data);
        free(b->fwcfg->dir);
        free(b->fwcfg);
    }
    free(b->nvme);
    free(b->pcie);
    free(b->uart);
    free(b->rtc);
    free(b->gpio);
    if (b->gic) {
        pthread_mutex_destroy(&b->gic->mu);
        free(b->gic);
    }
    pflash_close(&b->vars);
    if (b->code && b->code != MAP_FAILED) munmap(b->code, WA_FLASH_SIZE);
    if (b->ram && b->ram != MAP_FAILED) munmap(b->ram, b->ram_size);
    memset(b, 0, sizeof *b);
}

static void cells64(uint32_t *c, uint64_t a, uint64_t s) { c[0] = (uint32_t)(a >> 32); c[1] = (uint32_t)a; c[2] = (uint32_t)(s >> 32); c[3] = (uint32_t)s; }

/* The device tree EDK2's ArmVirtQemu reads (QEMU hw/arm/virt.c shape). */
static void build_dtb(WinArm *b) {
    enum { PH_GIC = 1, PH_CLK = 2 };
    Fdt f; fdt_begin(&f);
    uint32_t c[64];
    char name[64];
    fdt_node(&f, "");
    fdt_prop_str(&f, "compatible", "linux,dummy-virt");
    fdt_prop_str(&f, "model", "Triptych winarm");
    fdt_prop_u32(&f, "#address-cells", 2);
    fdt_prop_u32(&f, "#size-cells", 2);
    fdt_prop_u32(&f, "interrupt-parent", PH_GIC);

    fdt_node(&f, "chosen");
    fdt_prop_str(&f, "stdout-path", "/pl011@9000000");
    fdt_end_node(&f);

    snprintf(name, sizeof name, "memory@%llx", (unsigned long long)WA_MEM);
    fdt_node(&f, name);
    fdt_prop_str(&f, "device_type", "memory");
    cells64(c, WA_MEM, b->ram_size); fdt_prop_cells(&f, "reg", c, 4);
    fdt_end_node(&f);

    fdt_node(&f, "psci");
    const char *psci_compat[] = {"arm,psci-1.0", "arm,psci-0.2", "arm,psci"};
    fdt_prop_strs(&f, "compatible", psci_compat, 3);
    fdt_prop_str(&f, "method", "smc");
    fdt_end_node(&f);

    fdt_node(&f, "cpus");
    fdt_prop_u32(&f, "#address-cells", 1);
    fdt_prop_u32(&f, "#size-cells", 0);
    for (int i = 0; i < b->ncpus; i++) {
        snprintf(name, sizeof name, "cpu@%d", i);
        fdt_node(&f, name);
        fdt_prop_str(&f, "device_type", "cpu");
        fdt_prop_str(&f, "compatible", "arm,arm-v8");
        fdt_prop_u32(&f, "reg", (uint32_t)i);
        if (b->ncpus > 1) fdt_prop_str(&f, "enable-method", "psci");
        fdt_end_node(&f);
    }
    fdt_end_node(&f);

    snprintf(name, sizeof name, "intc@%llx", (unsigned long long)WA_GIC_DIST);
    fdt_node(&f, name);
    fdt_prop_str(&f, "compatible", "arm,gic-v3");
    fdt_prop_u32(&f, "#interrupt-cells", 3);
    fdt_prop_empty(&f, "interrupt-controller");
    fdt_prop_u32(&f, "#redistributor-regions", 1);
    cells64(c, WA_GIC_DIST, 0x10000); cells64(c + 4, WA_GIC_REDIST, 0x20000ull * (uint64_t)b->ncpus);
    fdt_prop_cells(&f, "reg", c, 8);
    fdt_prop_u32(&f, "phandle", PH_GIC);
    fdt_end_node(&f);

    fdt_node(&f, "timer");
    fdt_prop_str(&f, "compatible", "arm,armv8-timer");
    /* PPIs 13 (secure), 14 (non-secure), 11 (virtual), 10 (hyp); level, all CPUs. */
    uint32_t t[] = {1, 13, 0xf04, 1, 14, 0xf04, 1, 11, 0xf04, 1, 10, 0xf04};
    fdt_prop_cells(&f, "interrupts", t, 12);
    fdt_prop_empty(&f, "always-on");
    fdt_end_node(&f);

    fdt_node(&f, "apb-pclk");
    fdt_prop_str(&f, "compatible", "fixed-clock");
    fdt_prop_u32(&f, "#clock-cells", 0);
    fdt_prop_u32(&f, "clock-frequency", 24000000);
    fdt_prop_str(&f, "clock-output-names", "clk24mhz");
    fdt_prop_u32(&f, "phandle", PH_CLK);
    fdt_end_node(&f);

    struct { uint64_t pa; int irq; const char *n, *compat; } apb[] = {
        {WA_UART, WA_IRQ_UART, "pl011", "arm,pl011"}, {WA_RTC, WA_IRQ_RTC, "pl031", "arm,pl031"}, {WA_GPIO, WA_IRQ_GPIO, "pl061", "arm,pl061"}};
    for (int i = 0; i < 3; i++) {
        snprintf(name, sizeof name, "%s@%llx", apb[i].n, (unsigned long long)apb[i].pa);
        fdt_node(&f, name);
        const char *cs[] = {apb[i].compat, "arm,primecell"};
        fdt_prop_strs(&f, "compatible", cs, 2);
        cells64(c, apb[i].pa, 0x1000); fdt_prop_cells(&f, "reg", c, 4);
        uint32_t irq[] = {0, (uint32_t)apb[i].irq, 4};
        fdt_prop_cells(&f, "interrupts", irq, 3);
        uint32_t clk[] = {PH_CLK, PH_CLK};
        fdt_prop_cells(&f, "clocks", clk, i == 0 ? 2 : 1);
        const char *cn[] = {"uartclk", "apb_pclk"};
        if (i == 0) fdt_prop_strs(&f, "clock-names", cn, 2); else fdt_prop_strs(&f, "clock-names", cn + 1, 1);
        if (i == 2) { fdt_prop_u32(&f, "#gpio-cells", 2); fdt_prop_empty(&f, "gpio-controller"); }
        fdt_end_node(&f);
    }

    snprintf(name, sizeof name, "fw-cfg@%llx", (unsigned long long)WA_FWCFG);
    fdt_node(&f, name);
    fdt_prop_str(&f, "compatible", "qemu,fw-cfg-mmio");
    cells64(c, WA_FWCFG, 0x18); fdt_prop_cells(&f, "reg", c, 4);
    fdt_prop_empty(&f, "dma-coherent");
    fdt_end_node(&f);

    fdt_node(&f, "flash@0");
    fdt_prop_str(&f, "compatible", "cfi-flash");
    cells64(c, WA_FLASH0, WA_FLASH_SIZE); cells64(c + 4, WA_FLASH1, WA_FLASH_SIZE);
    fdt_prop_cells(&f, "reg", c, 8);
    fdt_prop_u32(&f, "bank-width", 4);
    fdt_end_node(&f);

    if (b->tpm) { /* EDK2's PlatformPei looks for this node to find the TPM (QEMU's tpm-tis-device on virt) */
        snprintf(name, sizeof name, "tpm_tis@%llx", (unsigned long long)WA_TPM);
        fdt_node(&f, name);
        fdt_prop_str(&f, "compatible", "tcg,tpm-tis-mmio");
        cells64(c, WA_TPM, WA_TPM_SIZE); fdt_prop_cells(&f, "reg", c, 4);
        fdt_end_node(&f);
    }

    snprintf(name, sizeof name, "pcie@%llx", (unsigned long long)WA_PCIE_MMIO);
    fdt_node(&f, name);
    fdt_prop_str(&f, "compatible", "pci-host-ecam-generic");
    fdt_prop_str(&f, "device_type", "pci");
    fdt_prop_u32(&f, "#address-cells", 3);
    fdt_prop_u32(&f, "#size-cells", 2);
    fdt_prop_u32(&f, "#interrupt-cells", 1);
    fdt_prop_u32(&f, "linux,pci-domain", 0);
    uint32_t bus[] = {0, (uint32_t)(WA_PCIE_ECAM_SIZE >> 20) - 1};
    fdt_prop_cells(&f, "bus-range", bus, 2);
    fdt_prop_empty(&f, "dma-coherent");
    cells64(c, WA_PCIE_ECAM, WA_PCIE_ECAM_SIZE); fdt_prop_cells(&f, "reg", c, 4);
    uint32_t ranges[] = {0x01000000, 0, 0, (uint32_t)(WA_PCIE_PIO >> 32), (uint32_t)WA_PCIE_PIO, 0, 0x10000,
                         0x02000000, 0, (uint32_t)WA_PCIE_MMIO, (uint32_t)(WA_PCIE_MMIO >> 32), (uint32_t)WA_PCIE_MMIO, 0, (uint32_t)WA_PCIE_MMIO_SIZE};
    fdt_prop_cells(&f, "ranges", ranges, 14);
    /* Henge's bridge: slot s's INTx on SPI WA_IRQ_PCIE + s, whichever pin. */
    uint32_t map[WA_PCI_SLOTS * 4 * 10], n = 0;
    for (uint32_t s = 0; s < WA_PCI_SLOTS; s++)
        for (uint32_t pin = 1; pin <= 4; pin++) {
            uint32_t e[] = {s << 11, 0, 0, pin, PH_GIC, 0, 0, 0, WA_IRQ_PCIE + s, 4};
            memcpy(map + n, e, sizeof e); n += 10;
        }
    fdt_prop_cells(&f, "interrupt-map", map, (int)n);
    uint32_t mask[] = {0xf800, 0, 0, 7};
    fdt_prop_cells(&f, "interrupt-map-mask", mask, 4);
    fdt_end_node(&f);

    fdt_end_node(&f);
    b->dtb = fdt_finish(&f, &b->dtb_size);
}

int winarm_finalize(WinArm *b) {
    build_dtb(b);
    if (acpi_build(b) != 0) return -1;
    return 0;
}

/* The GIC powers on with the board: a guest restart must not inherit active
   or pending interrupts, priorities or enables (EDK2 hung after Windows'
   restart with SGIs still active). Input line levels belong to the devices
   and stay as they are. */
static void gic_reset(HvGic *g) {
    pthread_mutex_lock(&g->mu);
    g->ctlr = 0;
    memset(g->group, 0, sizeof g->group); memset(g->grpmod, 0, sizeof g->grpmod);
    memset(g->enabled, 0, sizeof g->enabled); memset(g->latch, 0, sizeof g->latch);
    memset(g->active, 0, sizeof g->active); memset(g->priority, 0, sizeof g->priority);
    memset(g->edge, 0, sizeof g->edge); memset(g->route, 0, sizeof g->route); memset(g->spi_on, 0, sizeof g->spi_on);
    for (int c = 0; c < HV_MAX_CPUS; c++) {
        HvGicCpu *k = &g->cpu[c];
        uint8_t level[32];
        memcpy(level, k->level, sizeof level);
        memset(k, 0, sizeof *k);
        memcpy(k->level, level, sizeof level);
        k->waker = 6;
        for (int i = 0; i < 16; i++) k->edge[i] = 1;
    }
    hv_gicv3_update(g);
    pthread_mutex_unlock(&g->mu);
}

void winarm_reset(WinArm *b) {
    gic_reset(b->gic);
    if (b->tpm_reset) b->tpm_reset(b->tpm); /* the TPM powers on with the board */
    memset(b->ram, 0, 0x200000);
    memcpy(b->ram, b->dtb, b->dtb_size); /* ArmVirtQemu finds the tree at the start of RAM */
    b->m->cntvoff = 0; /* CNTVCT == CNTPCT as on QEMU virt: Windows mixes the two (a boot-relative virtual count made its timebase delta huge, and KeQueryInterruptTime spun) */
    for (int i = 0; i < b->ncpus; i++) {
        HvCpu *c = &b->cpus[i];
        hv_cpu_reset_index(c, b->m, (uint32_t)i);
        c->mpidr = 0x80000000u | (uint32_t)i;
        c->pc = WA_FLASH0;
        c->x[0] = WA_MEM;
        c->off = i != 0;
    }
}
