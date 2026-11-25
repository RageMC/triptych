#include "gicv3.h"

#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdatomic.h>
#include <time.h>

/* Register layout follows the GICv3 architecture specification (IHI 0069);
   behaviour is checked against QEMU's hw/intc/arm_gicv3*. */

#define GICD_CTLR_EN_GRP0 1u
#define GICD_CTLR_EN_GRP1 2u
#define GICD_CTLR_ARE     (1u << 4)
#define GICD_CTLR_DS      (1u << 6)
#define SPURIOUS 1023
#define IDLE_PRIORITY 0x100

#define R(op0, op1, crn, crm, op2) ((op0) << 14 | (op1) << 11 | (crn) << 7 | (crm) << 3 | (op2))

/* ---- ring trace ---- */
#define TR_N (1u << 21)
typedef struct { uint64_t ns; uint64_t a, b, pc; uint16_t kind; uint8_t cpu, pad; uint32_t seq; } TrEv;
static TrEv tr_ring[TR_N];
static _Atomic uint64_t tr_head;
static __thread int tr_quiet;
void hv_trace_quiet(int on) { tr_quiet = on; }
static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
/* An interrupt acknowledged again and again by one CPU (a storm) would fill the ring in milliseconds: after 16 in a row
   within 5 ms of each other the cycle is left out, and HVT_USER0 events (intid, count) mark the run. */
static struct { int last; uint64_t run, t; } tr_storm[HV_MAX_CPUS];
static uint8_t tr_lastppi[HV_MAX_CPUS], tr_linetr[HV_MAX_CPUS], tr_storming[HV_MAX_CPUS];
void hv_trace(int kind, uint64_t a, uint64_t b) {
    if (tr_quiet) return;
    uint64_t i = atomic_fetch_add_explicit(&tr_head, 1, memory_order_relaxed);
    TrEv *e = &tr_ring[i % TR_N];
    e->ns = now_ns();
    e->a = a; e->b = b; e->kind = (uint16_t)kind; e->cpu = hv_self ? (uint8_t)hv_self->index : 255; e->seq = (uint32_t)i; e->pc = hv_self ? hv_self->pc : 0;
}
int hv_trace_dump(const char *path) {
    static const char *nm[] = {"?", "IAR1", "IAR0", "EOIR", "DIR", "PMR=", "SGI1R=", "RPR?", "AP1R?", "HPPIR?", "CTLR?", "LINE", "BPR1=", "IGRPEN1=", "AP1R=",
        "CTLR=", "DISTW", "REDISTW", "SPI", "IRQ_ENTRY", "ERET", "NVME_SQDB", "NVME_CQDB", "NVME_POST", "NVME_INTMS", "NVME_INTMC", "NVME_INTX", "PCI_INTX", "PCI_CMD", "WFI", "USER0"};
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    uint64_t head = atomic_load(&tr_head), n = head < TR_N ? head : TR_N, t0 = 0;
    for (uint64_t k = head - n; k < head; k++) {
        TrEv *e = &tr_ring[k % TR_N];
        if (!t0) t0 = e->ns;
        fprintf(f, "%llu.%06llu cpu%d %s %llx %llx pc=%llx\n", (unsigned long long)((e->ns - t0) / 1000000000ull), (unsigned long long)((e->ns - t0) / 1000 % 1000000),
                e->cpu, e->kind < sizeof nm / sizeof *nm ? nm[e->kind] : "?", (unsigned long long)e->a, (unsigned long long)e->b, (unsigned long long)e->pc);
    }
    fclose(f);
    return 0;
}

/* INTID i's state as CPU c sees it: banked below 32, shared above. */
void hv_gicv3_update(HvGic *g);

#define F(g, c, field, i) (*((i) < 32 ? &(g)->cpu[c].field[i] : &(g)->field[i]))

static int ncpus(HvGic *g) {
    return g->m->ncpus ? g->m->ncpus : 1;
}

static int pending(HvGic *g, int c, int i) {
    return F(g, c, latch, i) || (!F(g, c, edge, i) && F(g, c, level, i));
}

static int group_enabled(HvGic *g, int c, int grp) {
    return grp ? (g->ctlr & GICD_CTLR_EN_GRP1) && (g->cpu[c].igrpen1 & 1) : (g->ctlr & GICD_CTLR_EN_GRP0) && (g->cpu[c].igrpen0 & 1);
}

static int running_priority(HvGic *g, int c) {
    return g->cpu[c].depth ? g->cpu[c].stack[g->cpu[c].depth - 1].prio : IDLE_PRIORITY;
}

/* Which CPU an SPI goes to: IROUTER's Aff0 (one cluster), or CPU 0 for "any" (IRM). */
static int target_of(HvGic *g, int i) {
    uint64_t r = g->route[i];
    if ((r >> 31) & 1) return 0;
    int c = (int)(r & 0xff);
    return c < ncpus(g) ? c : 0;
}

/* CPU c's highest-priority pending interrupt; with `masked`, only one PMR and the running priority let through. */
static int hppi(HvGic *g, int c, int masked) {
    int best = SPURIOUS, best_prio = 0x100;
    /* SGIs and PPIs, then only the SPIs that are enabled: there are 256 of them and a few are in use. */
    for (int i = 0; i < 32; i++) {
        if (!F(g, c, enabled, i) || F(g, c, active, i) || !pending(g, c, i)) continue;
        if (!group_enabled(g, c, F(g, c, group, i))) continue;
        if (F(g, c, priority, i) < best_prio) {
            best = i;
            best_prio = F(g, c, priority, i);
        }
    }
    for (int w = 0; w < (HV_GIC_NUM_IRQS + 63) / 64; w++)
        for (uint64_t bits = g->spi_on[w]; bits; bits &= bits - 1) {
            int i = w * 64 + __builtin_ctzll(bits);
            if (i < 32 || i >= HV_GIC_NUM_IRQS) continue;
            if (!g->enabled[i] || g->active[i] || !pending(g, c, i)) continue;
            if (target_of(g, i) != c) continue;
            if (!group_enabled(g, c, g->group[i])) continue;
            if (g->priority[i] < best_prio) {
                best = i;
                best_prio = g->priority[i];
            }
        }
    if (best == SPURIOUS) return SPURIOUS;
    if (masked && (best_prio >= (int)(g->cpu[c].pmr & 0xff) || best_prio >= running_priority(g, c))) return SPURIOUS;
    return best;
}

static void hv_gicv3_update_body(HvGic *g) {
    for (int c = 0; c < ncpus(g); c++) {
        int i = hppi(g, c, 1);
        HvPerCpu *p = &g->m->percpu[c];
        int irq = i != SPURIOUS && F(g, c, group, i) == 1, fiq = i != SPURIOUS && F(g, c, group, i) == 0;
        int raised = (irq && !p->irq_line) || (fiq && !p->fiq_line);
        if (irq != p->irq_line || fiq != p->fiq_line) { /* timer ticks stay out of the trace: the raise and the drop after it */
            int tr = (irq || fiq) ? !(i >= 16 && i < 32) && !(c < HV_MAX_CPUS && tr_storming[c] && i == tr_storm[c].last) : (c < HV_MAX_CPUS ? tr_linetr[c] : 1);
            if (tr) hv_trace(HVT_LINE, (uint64_t)c << 8 | (unsigned)irq << 1 | (unsigned)fiq, (uint64_t)i);
            if (c < HV_MAX_CPUS) tr_linetr[c] = (uint8_t)((irq || fiq) && tr);
        }
        p->irq_line = irq;
        p->fiq_line = fiq;
        if (raised && g->m->cpus[c] && g->m->ncpus > 1) hv_cpu_wake(g->m->cpus[c]); /* it may be asleep in WFI, or running */
    }
}

static void hv_gicv3_set_irq_body(HvGic *g, int intid, int level) {
    if (intid < 32 || intid >= HV_GIC_NUM_IRQS) return;
    level = level != 0;
    if (g->level[intid] == level) return; /* nothing changed: skip the rescan */
    if (g->edge[intid] && level) g->latch[intid] = 1;
    g->level[intid] = (uint8_t)level;
    hv_trace(HVT_SPI_LEVEL, (uint64_t)intid, (uint64_t)level);
    hv_gicv3_update(g);
}

static void hv_gicv3_set_ppi_body(HvGic *g, int c, int intid, int level) {
    if (intid < 16 || intid >= 32 || c >= HV_MAX_CPUS) return;
    HvGicCpu *k = &g->cpu[c];
    level = level != 0;
    if (k->level[intid] == level) return; /* the timer re-asserts every tick */
    if (k->edge[intid] && level) k->latch[intid] = 1;
    k->level[intid] = (uint8_t)level;
    hv_gicv3_update(g);
}

static void hv_gicv3_pend_body(HvGic *g, int intid) {
    if (intid < 32 || intid >= HV_GIC_NUM_IRQS) return;
    g->latch[intid] = 1;
    hv_gicv3_update(g);
}

/* ---- the CPU interface ---- */

static uint64_t acknowledge(HvGic *g, int c, int grp) {
    int i = hppi(g, c, 1);
    if (i == SPURIOUS || F(g, c, group, i) != grp) {
        if (c < HV_MAX_CPUS && tr_lastppi[c]) tr_lastppi[c] = 0; /* the read that ends a timer tick's handler loop */
        else hv_trace(grp ? HVT_IAR1 : HVT_IAR0, 1023, (uint64_t)g->cpu[c].depth << 16 | (uint64_t)(g->cpu[c].pmr & 0xff) << 8 | 0xff);
        return SPURIOUS;
    }
    int ppi = i >= 16 && i < 32; /* timers: kept out of the trace */
    if (c < HV_MAX_CPUS) tr_lastppi[c] = (uint8_t)ppi;
    {
        uint64_t t = now_ns();
        if (!ppi && c < HV_MAX_CPUS) {
            if (i == tr_storm[c].last && t - tr_storm[c].t < 5000000ull) tr_storm[c].run++;
            else { if (tr_storm[c].run > 16) hv_trace(HVT_USER0, (uint64_t)tr_storm[c].last, tr_storm[c].run); tr_storm[c].run = 1; tr_storm[c].last = i; }
            tr_storm[c].t = t;
            uint64_t r = tr_storm[c].run;
            if (r == 17 || r == 256 || r == 4096 || r == 65536 || r == 1048576) hv_trace(HVT_USER0, (uint64_t)i, r);
            tr_storming[c] = r > 16;
            if (r > 16) ppi = 1;
        }
    }
    if (ppi) hv_trace_quiet(1);
    F(g, c, active, i) = 1;
    F(g, c, latch, i) = 0;
    HvGicCpu *k = &g->cpu[c];
    if (k->depth < 32) k->stack[k->depth++] = (HvGicActive){(uint16_t)i, F(g, c, priority, i), (uint8_t)grp};
    hv_gicv3_update(g);
    if (ppi) hv_trace_quiet(0);
    if (!ppi) hv_trace(grp ? HVT_IAR1 : HVT_IAR0, (uint64_t)i, (uint64_t)k->depth << 16 | (uint64_t)(k->pmr & 0xff) << 8 | (uint64_t)F(g, c, priority, i));
    return (uint64_t)i;
}

static void end_of_interrupt(HvGic *g, int c, int intid) {
    if (intid >= HV_GIC_NUM_IRQS) return;
    HvGicCpu *k = &g->cpu[c];
    int ppi = (intid >= 16 && intid < 32) || (c < HV_MAX_CPUS && tr_storming[c] && intid == tr_storm[c].last);
    if (ppi) hv_trace_quiet(1);
    else hv_trace(HVT_EOIR, (uint64_t)intid, (uint64_t)k->depth << 16 | (k->depth ? k->stack[k->depth - 1].intid : 0xffff));
    if (k->depth) k->depth--; /* priority drop: the most recent acknowledge */
    if (!(k->icc_ctlr & 2)) F(g, c, active, intid) = 0; /* EOImode 0 also deactivates */
    hv_gicv3_update(g);
    if (ppi) hv_trace_quiet(0);
}

static uint64_t icc_read_body2(HvMachine *m, HvCpu *cpu, uint32_t reg);
static uint64_t icc_read_body(HvMachine *m, HvCpu *cpu, uint32_t reg) {
    uint64_t v = icc_read_body2(m, cpu, reg);
    switch (reg) {
    case R(3, 0, 12, 11, 3): hv_trace(HVT_RPR_R, v, 0); break;
    case R(3, 0, 12, 9, 0): hv_trace(HVT_AP1R_R, v, 0); break;
    case R(3, 0, 12, 12, 2): case R(3, 0, 12, 8, 2): hv_trace(HVT_HPPIR_R, v, reg == R(3, 0, 12, 12, 2)); break;
    case R(3, 0, 12, 12, 4): hv_trace(HVT_CTLR_R, v, 0); break;
    default: break;
    }
    return v;
}
static uint64_t icc_read_body2(HvMachine *m, HvCpu *cpu, uint32_t reg) {
    HvGic *g = m->gic;
    int c = (int)cpu->index;
    HvGicCpu *k = &g->cpu[c];
    int h;
    switch (reg) {
    case R(3, 0, 4, 6, 0): return k->pmr;
    case R(3, 0, 12, 12, 0): return acknowledge(g, c, 1);              /* IAR1 */
    case R(3, 0, 12, 8, 0): return acknowledge(g, c, 0);               /* IAR0 */
    case R(3, 0, 12, 12, 2):                                           /* HPPIR1 */
        h = hppi(g, c, 0);
        return h != SPURIOUS && F(g, c, group, h) == 1 ? (uint64_t)h : SPURIOUS;
    case R(3, 0, 12, 8, 2):                                            /* HPPIR0 */
        h = hppi(g, c, 0);
        return h != SPURIOUS && F(g, c, group, h) == 0 ? (uint64_t)h : SPURIOUS;
    case R(3, 0, 12, 11, 3): return running_priority(g, c) == IDLE_PRIORITY ? 0xff : (uint64_t)running_priority(g, c); /* RPR */
    case R(3, 0, 12, 8, 3): return k->bpr0;
    case R(3, 0, 12, 12, 3): return k->bpr1;
    case R(3, 0, 12, 12, 4): return k->icc_ctlr | 7u << 8 | 1u << 14;  /* CTLR: 8 priority bits, 16-bit IDs, SEIS 0, RSS */
    case R(3, 0, 12, 12, 5): return 7;                                 /* SRE: system registers only */
    case R(3, 0, 12, 12, 6): return k->igrpen0;
    case R(3, 0, 12, 12, 7): return k->igrpen1;
    case R(3, 0, 12, 8, 4): return (uint32_t)k->ap0r;
    case R(3, 0, 12, 9, 0): return (uint32_t)k->ap1r;
    default: return 0;                                                 /* AP*R1-3 and the rest */
    }
}

static void icc_write_body(HvMachine *m, HvCpu *cpu, uint32_t reg, uint64_t v) {
    HvGic *g = m->gic;
    int c = (int)cpu->index;
    HvGicCpu *k = &g->cpu[c];
    switch (reg) {
    case R(3, 0, 4, 6, 0): k->pmr = v & 0xff; hv_trace(HVT_PMR_W, v, 0); break;
    case R(3, 0, 12, 12, 1): case R(3, 0, 12, 8, 1): end_of_interrupt(g, c, (int)(v & 0xffffff)); break; /* EOIR1/0 */
    case R(3, 0, 12, 11, 1):                                           /* DIR */
        hv_trace(HVT_DIR, v & 0xffffff, 0);
        if ((v & 0xffffff) < HV_GIC_NUM_IRQS) F(g, c, active, (int)(v & 0xffffff)) = 0;
        break;
    case R(3, 0, 12, 8, 3): k->bpr0 = v & 7; break;
    case R(3, 0, 12, 12, 3): k->bpr1 = v & 7; hv_trace(HVT_BPR1_W, v, 0);
break;
    case R(3, 0, 12, 12, 4): k->icc_ctlr = v & 3; hv_trace(HVT_CTLR_W, v, 0); break;              /* CBPR, EOImode */
    case R(3, 0, 12, 12, 6): k->igrpen0 = v & 1; break;
    case R(3, 0, 12, 12, 7): k->igrpen1 = v & 1; hv_trace(HVT_IGRPEN1_W, v, 0); break;
    case R(3, 0, 12, 8, 4): k->ap0r = (uint32_t)v; break;
    case R(3, 0, 12, 9, 0): k->ap1r = (uint32_t)v; hv_trace(HVT_AP1R_W, v, 0); break;
    case R(3, 0, 12, 11, 5): case R(3, 0, 12, 11, 6): case R(3, 0, 12, 11, 7): { /* SGI1R, ASGI1R, SGI0R */
        int intid = (v >> 24) & 0xf;
        hv_trace(HVT_SGI_W, v, (uint64_t)reg);
        int irm = (v >> 40) & 1;
        uint64_t aff = (v >> 16 & 0xff) | (v >> 32 & 0xff) << 8 | (v >> 48 & 0xff) << 16; /* Aff1, Aff2, Aff3 */
        uint32_t rs = (v >> 44) & 0xf;
        for (int t = 0; t < ncpus(g); t++) {
            uint64_t mp = m->cpus[t] ? m->cpus[t]->mpidr & 0xffffff : (uint64_t)t;
            int hit = irm ? t != c : aff == (mp >> 8) && rs == (mp & 0xff) >> 4 && ((v >> (mp & 0xf)) & 1);
            if (hit) g->cpu[t].latch[intid] = 1;
        }
        break;
    }
    default: break;
    }
    hv_gicv3_update(g);
}

/* ---- MMIO: bitmap, byte and route registers shared by GICD and GICR ---- */

/* Registers indexed by INTID, starting at `first` for this frame, as CPU c sees them. */
static uint32_t bank_read(HvGic *g, int c, uint32_t off, int first, int count) {
    uint32_t v = 0;
    int base;
    if (off >= 0x400 && off < 0x800) { /* IPRIORITYR: one byte each */
        base = first + (int)(off - 0x400);
        for (int b = 0; b < 4; b++)
            if (base + b - first < count) v |= (uint32_t)F(g, c, priority, base + b) << (b * 8);
        return v;
    }
    if (off >= 0xc00 && off < 0xd00) { /* ICFGR: two bits each */
        base = first + (int)(off - 0xc00) * 4;
        for (int b = 0; b < 16; b++)
            if (base + b - first < count && F(g, c, edge, base + b)) v |= 2u << (b * 2);
        return v;
    }
    uint32_t reg = off & ~0x7fu, idx = (off & 0x7f) / 4;
    base = first + (int)idx * 32;
    for (int b = 0; b < 32; b++) {
        int i = base + b;
        if (i - first >= count) break;
        int bit = 0;
        switch (reg) {
        case 0x080: bit = F(g, c, group, i); break;
        case 0x100: case 0x180: bit = F(g, c, enabled, i); break;
        case 0x200: case 0x280: bit = pending(g, c, i); break;
        case 0x300: case 0x380: bit = F(g, c, active, i); break;
        case 0xd00: bit = F(g, c, grpmod, i); break;
        default: break;
        }
        v |= (uint32_t)bit << b;
    }
    return v;
}

/* mask has ones in the bytes that were written. */
static void bank_write(HvGic *g, int c, uint32_t off, uint32_t v, uint32_t mask, int first, int count, int sgi_ppi) {
    int base;
    if (off >= 0x400 && off < 0x800) {
        base = first + (int)(off - 0x400);
        for (int b = 0; b < 4; b++)
            if ((mask >> (b * 8)) & 0xff && base + b - first < count) F(g, c, priority, base + b) = (uint8_t)(v >> (b * 8));
        return;
    }
    if (off >= 0xc00 && off < 0xd00) {
        base = first + (int)(off - 0xc00) * 4;
        for (int b = 0; b < 16; b++) {
            int i = base + b;
            if (i - first >= count || !((mask >> (b * 2)) & 3)) continue;
            if (sgi_ppi && i < 16) continue; /* SGIs are always edge */
            F(g, c, edge, i) = (v >> (b * 2 + 1)) & 1;
        }
        return;
    }
    uint32_t reg = off & ~0x7fu, idx = (off & 0x7f) / 4;
    base = first + (int)idx * 32;
    for (int b = 0; b < 32; b++) {
        int i = base + b;
        if (i - first >= count) break;
        if (!((mask >> b) & 1)) continue;
        int bit = (v >> b) & 1;
        switch (reg) {
        case 0x080: F(g, c, group, i) = (uint8_t)bit; break;
        case 0x100:
            if (bit) {
                F(g, c, enabled, i) = 1;
                if (i >= 32) g->spi_on[i / 64] |= 1ull << (i % 64);
            }
            break;
        case 0x180:
            if (bit) {
                F(g, c, enabled, i) = 0;
                if (i >= 32) g->spi_on[i / 64] &= ~(1ull << (i % 64));
            }
            break;
        case 0x200: if (bit) F(g, c, latch, i) = 1; break;
        case 0x280: if (bit) F(g, c, latch, i) = 0; break;
        case 0x300: if (bit) F(g, c, active, i) = 1; break;
        case 0x380: if (bit) F(g, c, active, i) = 0; break;
        case 0xd00: F(g, c, grpmod, i) = (uint8_t)bit; break;
        default: break;
        }
    }
}

static uint32_t size_mask(uint64_t off, unsigned size) {
    uint32_t m = size >= 4 ? 0xffffffffu : (1u << (size * 8)) - 1;
    return m << ((off & 3) * 8);
}

/* Registers for INTIDs 0-31. In the distributor they are reserved (ARE is set);
   the redistributor's SGI frame has only these. */
static int bank0(uint32_t a) {
    if (a >= 0x400 && a < 0x800) return a < 0x420;
    if (a >= 0xc00 && a < 0xd00) return a < 0xc08;
    return (a & 0x7f) < 4;
}

static uint64_t dist_read_body(void *opaque, uint64_t off, unsigned size) {
    HvGic *g = opaque;
    if (off >= 0x6100 && off < 0x6100 + 8 * HV_GIC_NUM_IRQS) { /* IROUTER<n>, n >= 32 */
        uint64_t v = g->route[(off - 0x6000) / 8];
        return size == 8 ? v : (uint32_t)(v >> ((off & 4) * 8));
    }
    uint32_t word, a = (uint32_t)off & ~3u;
    switch (a) {
    case 0x0000: word = g->ctlr | GICD_CTLR_ARE | GICD_CTLR_DS; break;
    case 0x0004: word = (HV_GIC_NUM_IRQS / 32 - 1) | 15u << 19; break; /* ITLinesNumber, 16 ID bits */
    case 0x0008: word = 0x0300043b; break;                             /* IIDR: Arm, GICv3 */
    case 0xffe8: word = 0x3b; break;                                   /* PIDR2: ArchRev 3 */
    default:
        word = a >= 0x80 && a < 0x1000 && !bank0(a) ? bank_read(g, 0, a, 0, HV_GIC_NUM_IRQS) : 0;
        break;
    }
    return (word >> ((off & 3) * 8)) & (size >= 4 ? 0xffffffffu : (1u << (size * 8)) - 1);
}

static void dist_write_body(void *opaque, uint64_t off, uint64_t v, unsigned size) {
    HvGic *g = opaque;
    if (off >= 0x6100 && off < 0x6100 + 8 * HV_GIC_NUM_IRQS) {
        uint64_t *r = &g->route[(off - 0x6000) / 8];
        if (size == 8) *r = v;
        else if (off & 4) *r = (*r & 0xffffffffull) | v << 32;
        else *r = (*r & ~0xffffffffull) | (uint32_t)v;
        return;
    }
    uint32_t a = (uint32_t)off & ~3u, mask = size_mask(off, size);
    uint32_t word = (uint32_t)(v << ((off & 3) * 8));
    hv_trace(HVT_DISTW, off, v);
    if (a == 0) {
        g->ctlr = (g->ctlr & ~mask) | (word & mask & (GICD_CTLR_EN_GRP0 | GICD_CTLR_EN_GRP1));
    } else if (a >= 0x80 && a < 0x1000) {
        if (!bank0(a)) bank_write(g, 0, a, word, mask, 0, HV_GIC_NUM_IRQS, 0);
    }
    hv_gicv3_update(g);
}

/* One redistributor per CPU, 128 KB apart: RD_base at 0, SGI_base at 0x10000. */
static uint64_t redist_read_body(void *opaque, uint64_t off, unsigned size) {
    HvGic *g = opaque;
    uint64_t v = 0;
    int c = (int)(off >> 17);
    off &= 0x1ffff;
    if (c >= ncpus(g)) return 0;
    if (off < 0x10000) {
        uint64_t mp = g->m->cpus[c] ? g->m->cpus[c]->mpidr : (uint64_t)c;
        switch (off & ~7ull) {
        case 0x0000: v = (uint64_t)0x0300043b << 32; break;            /* CTLR 0, IIDR */
        case 0x0008: /* TYPER: affinity, processor number, Last on the final frame */
            v = (mp & 0xffffff) << 32 | (uint64_t)c << 8 | (c == ncpus(g) - 1 ? 1u << 4 : 0);
            break;
        case 0x0010: v = (uint64_t)g->cpu[c].waker << 32; break;        /* STATUSR, WAKER */
        case 0xffe8: v = 0x3b; break;
        default: break;
        }
        v >>= (off & 7) * 8;
    } else {
        uint32_t a = (uint32_t)(off - 0x10000) & ~3u;
        if (a >= 0x80 && a < 0x1000 && bank0(a))
            v = bank_read(g, c, a, 0, 32) >> ((off & 3) * 8);
    }
    return size == 8 ? v : v & ((1ull << (size * 8)) - 1);
}

static void redist_write_body(void *opaque, uint64_t off, uint64_t v, unsigned size) {
    HvGic *g = opaque;
    int c = (int)(off >> 17);
    off &= 0x1ffff;
    if (c >= ncpus(g)) return;
    if (off < 0x10000) {
        if ((off & ~3ull) == 0x14) {
            /* WAKER: clearing ProcessorSleep wakes it; ChildrenAsleep follows at once. */
            uint32_t sleep = (v >> (8 * (off & 3))) & 2;
            g->cpu[c].waker = sleep ? 6 : 0;
        }
        return;
    }
    uint32_t a = (uint32_t)(off - 0x10000) & ~3u, mask = size_mask(off, size);
    uint32_t word = (uint32_t)(v << ((off & 3) * 8));
    hv_trace(HVT_REDISTW, (uint64_t)c << 20 | off, v);
    if (a >= 0x80 && a < 0x1000 && bank0(a)) bank_write(g, c, a, word, mask, 0, 32, 1);
    hv_gicv3_update(g);
}

/* Every way in takes the GIC's own lock (recursive: the bodies call hv_gicv3_update).
   Devices call in holding the device lock; the CPUs' ICC registers and timers do not need it. */
void hv_gicv3_update(HvGic *g) {
    pthread_mutex_lock(&g->mu);
    hv_gicv3_update_body(g);
    pthread_mutex_unlock(&g->mu);
}

/* A test tool's in-kernel GIC (winvm's WINVM_HVF): when set, SPIs go there instead. */
void (*hv_gicv3_spi_hook)(int intid, int level);

void hv_gicv3_set_irq(HvGic *g, int intid, int level) {
    if (hv_gicv3_spi_hook) { hv_gicv3_spi_hook(intid, level); return; }
    pthread_mutex_lock(&g->mu);
    hv_gicv3_set_irq_body(g, intid, level);
    pthread_mutex_unlock(&g->mu);
}

void hv_gicv3_set_ppi(HvGic *g, int c, int intid, int level) {
    /* The timer re-asserts its level at every tick, and only CPU c sets its own
       PPIs: an unchanged level needs no lock (the GIC's is shared by all). */
    if (intid >= 16 && intid < 32 && c < HV_MAX_CPUS &&
        __atomic_load_n(&g->cpu[c].level[intid], __ATOMIC_RELAXED) == (level != 0))
        return;
    pthread_mutex_lock(&g->mu);
    hv_gicv3_set_ppi_body(g, c, intid, level);
    pthread_mutex_unlock(&g->mu);
}

void hv_gicv3_pend(HvGic *g, int intid) {
    if (hv_gicv3_spi_hook) { hv_gicv3_spi_hook(intid, 1); return; }
    pthread_mutex_lock(&g->mu);
    hv_gicv3_pend_body(g, intid);
    pthread_mutex_unlock(&g->mu);
}

static uint64_t icc_read(HvMachine *m, HvCpu *cpu, uint32_t reg) {
    pthread_mutex_lock(&((HvGic *)m->gic)->mu);
    uint64_t v_ = icc_read_body(m, cpu, reg);
    pthread_mutex_unlock(&((HvGic *)m->gic)->mu);
    return v_;
}

static void icc_write(HvMachine *m, HvCpu *cpu, uint32_t reg, uint64_t v) {
    pthread_mutex_lock(&((HvGic *)m->gic)->mu);
    icc_write_body(m, cpu, reg, v);
    pthread_mutex_unlock(&((HvGic *)m->gic)->mu);
}

static uint64_t dist_read(void *opaque, uint64_t off, unsigned size) {
    pthread_mutex_lock(&((HvGic *)opaque)->mu);
    uint64_t v_ = dist_read_body(opaque, off, size);
    pthread_mutex_unlock(&((HvGic *)opaque)->mu);
    return v_;
}

static void dist_write(void *opaque, uint64_t off, uint64_t v, unsigned size) {
    pthread_mutex_lock(&((HvGic *)opaque)->mu);
    dist_write_body(opaque, off, v, size);
    pthread_mutex_unlock(&((HvGic *)opaque)->mu);
}

static uint64_t redist_read(void *opaque, uint64_t off, unsigned size) {
    pthread_mutex_lock(&((HvGic *)opaque)->mu);
    uint64_t v_ = redist_read_body(opaque, off, size);
    pthread_mutex_unlock(&((HvGic *)opaque)->mu);
    return v_;
}

static void redist_write(void *opaque, uint64_t off, uint64_t v, unsigned size) {
    pthread_mutex_lock(&((HvGic *)opaque)->mu);
    redist_write_body(opaque, off, v, size);
    pthread_mutex_unlock(&((HvGic *)opaque)->mu);
}

HvGic *hv_gicv3_create(HvMachine *m, uint64_t dist_pa, uint64_t redist_pa) {
    HvGic *g = calloc(1, sizeof *g);
    pthread_mutexattr_t ra;
    pthread_mutexattr_init(&ra);
    pthread_mutexattr_settype(&ra, PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&g->mu, &ra);
    g->m = m;
    for (int c = 0; c < HV_MAX_CPUS; c++) {
        g->cpu[c].waker = 6; /* ProcessorSleep and ChildrenAsleep until the guest wakes it */
        for (int i = 0; i < 16; i++) g->cpu[c].edge[i] = 1;
    }
    m->gic = g;
    m->icc_read = icc_read;
    m->icc_write = icc_write;
    hv_machine_add_mmio(m, dist_pa, 0x10000, g, dist_read, dist_write, "gicv3-dist");
    m->mmio[m->nmmio - 1].self_locked = 1;
    hv_machine_add_mmio(m, redist_pa, 0x400000, g, redist_read, redist_write, "gicv3-redist");
    m->mmio[m->nmmio - 1].self_locked = 1;
    return g;
}
