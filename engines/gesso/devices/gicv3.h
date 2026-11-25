#ifndef HENGEVM_GICV3_H
#define HENGEVM_GICV3_H

#include <pthread.h>
#include <stdint.h>

#include "machine.h"

/* GICv3 with one security state (DS=1), no LPIs or ITS: the distributor, one
   redistributor per CPU, and each CPU's ICC_* system registers. INTIDs 0-15
   are SGIs, 16-31 PPIs (both banked per CPU), 32 and up SPIs. */
#define HV_GIC_NUM_IRQS (256 + 32) /* vmapple: 256 SPIs */

typedef struct HvGicActive {
    uint16_t intid;
    uint8_t prio, group;
} HvGicActive;

/* One CPU's redistributor (its SGIs and PPIs) and CPU interface. */
typedef struct HvGicCpu {
    uint8_t group[32], grpmod[32], enabled[32], latch[32], level[32], active[32], priority[32], edge[32];
    uint32_t waker;
    uint64_t pmr, bpr0, bpr1, icc_ctlr, igrpen0, igrpen1, sre;
    uint64_t ap0r, ap1r;         /* active priority bits, one per priority level >> 3 */
    HvGicActive stack[32];       /* acknowledged, not yet priority-dropped */
    int depth;
} HvGicCpu;

typedef struct HvGic {
    HvMachine *m;
    pthread_mutex_t mu;            /* the GIC's own lock (see gicv3.c) */
    uint32_t ctlr;                 /* GICD_CTLR */
    /* SPIs (INTIDs 32 and up; entries below 32 are unused: see HvGicCpu) */
    uint8_t group[HV_GIC_NUM_IRQS];
    uint8_t grpmod[HV_GIC_NUM_IRQS];
    uint8_t enabled[HV_GIC_NUM_IRQS];
    uint8_t latch[HV_GIC_NUM_IRQS];  /* edge or software pending */
    uint8_t level[HV_GIC_NUM_IRQS];  /* input line */
    uint8_t active[HV_GIC_NUM_IRQS];
    uint8_t priority[HV_GIC_NUM_IRQS];
    uint8_t edge[HV_GIC_NUM_IRQS];   /* ICFGR: 1 = edge-triggered */
    uint64_t route[HV_GIC_NUM_IRQS];
    uint64_t spi_on[(HV_GIC_NUM_IRQS + 63) / 64]; /* SPIs that may be enabled (a superset: hppi checks each) */
    HvGicCpu cpu[HV_MAX_CPUS];
} HvGic;

HvGic *hv_gicv3_create(HvMachine *m, uint64_t dist_pa, uint64_t redist_pa);
/* Drive an SPI's input line (32+). */
void hv_gicv3_set_irq(HvGic *g, int intid, int level);
/* Drive one CPU's PPI (16-31). */
void hv_gicv3_set_ppi(HvGic *g, int cpu, int intid, int level);
/* Make an SPI pending, as an MSI write does. */
void hv_gicv3_pend(HvGic *g, int intid);
/* Recompute every CPU's IRQ and FIQ inputs (waking any that just got one). */
void hv_gicv3_update(HvGic *g);

/* An always-on ring trace of the interrupt controller and the devices that drive it (cheap: one atomic add and a 32-byte store).
   Events are (kind, a, b); the CPU is the calling thread's (255 = not a CPU thread). Timer PPI traffic is left out
   (see hv_trace_quiet) so the ring spans minutes, not milliseconds. */
enum {
    HVT_IAR1 = 1, HVT_IAR0, HVT_EOIR, HVT_DIR, HVT_PMR_W, HVT_SGI_W, HVT_RPR_R, HVT_AP1R_R, HVT_HPPIR_R, HVT_CTLR_R, HVT_LINE,
    HVT_BPR1_W, HVT_IGRPEN1_W, HVT_AP1R_W, HVT_CTLR_W, HVT_DISTW, HVT_REDISTW, HVT_SPI_LEVEL, HVT_IRQ_ENTRY, HVT_ERET,
    HVT_NVME_SQDB, HVT_NVME_CQDB, HVT_NVME_POST, HVT_NVME_INTMS, HVT_NVME_INTMC, HVT_NVME_INTX, HVT_PCI_INTX, HVT_PCI_CMD,
    HVT_WFI, HVT_USER0
};
void hv_trace(int kind, uint64_t a, uint64_t b);
void hv_trace_quiet(int on); /* this thread: drop events (timer interrupt handling) */
int hv_trace_dump(const char *path);

#endif
