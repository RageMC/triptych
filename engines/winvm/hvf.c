// SPDX-License-Identifier: GPL-2.0-or-later
// WINVM_HVF=1 (Mac only, one CPU): run the winarm board with the guest CPU on Hypervisor.framework
// instead of Henge's JIT. A test tool: the same RAM, devices, GIC (Henge's, in software: HVF traps
// the ICC_* registers) and firmware, so a guest bug that shows here is in the board, and one that
// doesn't is in the JIT. Triptych itself never uses a hypervisor (iOS has none).
#include "winarm.h"
#include "timer.h"
#include "sysreg.h"
#include "memop.h"
#include "mmu.h"
#include <Hypervisor/Hypervisor.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define R(op0, op1, crn, crm, op2) ((op0) << 14 | (op1) << 11 | (crn) << 7 | (crm) << 3 | (op2))
#define CHECK(x) do { hv_return_t r_ = (x); if (r_ != HV_SUCCESS) { fprintf(stderr, "winvm-hvf: %s failed: %x\n", #x, r_); exit(1); } } while (0)

static hv_vcpu_t vcpu;
static hv_vcpu_exit_t *vexit;
static atomic_int kick_on;

static void *kicker(void *arg) { /* timers and device polls run on exits: force one a millisecond */
    (void)arg;
    while (atomic_load(&kick_on)) { usleep(1000); hv_vcpus_exit(&vcpu, 1); }
    return NULL;
}

static uint64_t xreg(int r) { uint64_t v = 0; if (r < 31) CHECK(hv_vcpu_get_reg(vcpu, HV_REG_X0 + r, &v)); return v; }
static void set_xreg(int r, uint64_t v) { if (r < 31) CHECK(hv_vcpu_set_reg(vcpu, HV_REG_X0 + r, v)); }
static uint64_t sreg(hv_sys_reg_t r) { uint64_t v; CHECK(hv_vcpu_get_sys_reg(vcpu, r, &v)); return v; }
static void advance(void) { uint64_t pc; CHECK(hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc)); CHECK(hv_vcpu_set_reg(vcpu, HV_REG_PC, pc + 4)); }

extern void (*hv_gicv3_spi_hook)(int intid, int level);
static void spi_hook(int intid, int level) { hv_gic_set_spi((uint32_t)intid, level != 0); }

static int psci(HvMachine *m, uint64_t fn, uint64_t x1, uint64_t *ret) { /* 1: the machine halts */
    switch ((uint32_t)fn) {
    case 0x80000000: *ret = 0x10001; return 0;                 /* SMCCC_VERSION 1.1 */
    case 0x84000000: *ret = 0x10000; return 0;                 /* PSCI 1.0 */
    case 0x84000006: *ret = 2; return 0;                       /* MIGRATE_INFO_TYPE */
    case 0x8400000a: {
        uint32_t q = (uint32_t)x1;
        *ret = (q == 0x84000000 || q == 0x84000006 || q == 0x84000008 || q == 0x84000009 || q == 0x8400000a) ? 0 : (uint64_t)-1;
        return 0;
    }
    case 0x84000008: hv_machine_halt(m, HV_HALT_SHUTDOWN); *ret = 0; return 1;
    case 0x84000009: hv_machine_halt(m, HV_HALT_RESET); *ret = 0; return 1;
    case 0x84000003: case 0xc4000003: *ret = (uint64_t)-2; return 0; /* CPU_ON: one CPU only */
    default: *ret = (uint64_t)-1; return 0;
    }
}

static int sysreg(HvMachine *m, HvCpu *cpu, uint32_t iss) { /* EC 0x18 */
    uint32_t op0 = (iss >> 20) & 3, op2 = (iss >> 17) & 7, op1 = (iss >> 14) & 7, crn = (iss >> 10) & 15, rt = (iss >> 5) & 31,
             crm = (iss >> 1) & 15, rd = iss & 1;
    uint32_t reg = R(op0, op1, crn, crm, op2);
    uint64_t now = mach_absolute_time(), v = rd ? 0 : xreg((int)rt);
    if (reg == R(3, 0, 4, 6, 0) || (op0 == 3 && op1 == 0 && crn == 12 && crm >= 8)) { /* ICC_* */
        if (rd) v = m->icc_read ? m->icc_read(m, cpu, reg) : 0;
        else if (m->icc_write) m->icc_write(m, cpu, reg, v);
    } else if (reg == R(3, 3, 14, 2, 1)) { /* CNTP_CTL_EL0 */
        if (rd) v = (cpu->cntp_ctl & 3) | ((cpu->cntp_ctl & 1) && now >= cpu->cntp_cval ? 4 : 0);
        else cpu->cntp_ctl = v & 3;
    } else if (reg == R(3, 3, 14, 2, 2)) { /* CNTP_CVAL_EL0 */
        if (rd) v = cpu->cntp_cval; else cpu->cntp_cval = v;
    } else if (reg == R(3, 3, 14, 2, 0)) { /* CNTP_TVAL_EL0 */
        if (rd) v = (uint32_t)(cpu->cntp_cval - now); else cpu->cntp_cval = now + (uint64_t)(int64_t)(int32_t)v;
    } else if (reg == R(3, 3, 14, 0, 1) || reg == R(3, 3, 14, 0, 5)) { /* CNTPCT(SS)_EL0 */
        v = now;
    } else { /* debug, PMU, OS lock and the like: RAZ/WI */
        static int told;
        if (told++ < 16) fprintf(stderr, "winvm-hvf: %s S%u_%u_C%u_C%u_%u ignored\n", rd ? "mrs" : "msr", op0, op1, crn, crm, op2);
        v = 0;
    }
    if (rd) set_xreg((int)rt, v);
    advance();
    return 0;
}

/* A load or store with no syndrome (LDP, writeback forms: EDK2 reads the variable flash so): run the
   instruction through Henge's C memory path on a copy of the CPU state that matters for it. */
static int emulate_insn(HvMachine *m, HvCpu *cpu, uint64_t ipa, uint64_t esr) {
    uint64_t pc, cpsr;
    CHECK(hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc));
    CHECK(hv_vcpu_get_reg(vcpu, HV_REG_CPSR, &cpsr));
    for (int r = 0; r < 31; r++) cpu->x[r] = xreg(r);
    cpu->sctlr_el1 = sreg(HV_SYS_REG_SCTLR_EL1); cpu->tcr_el1 = sreg(HV_SYS_REG_TCR_EL1);
    cpu->ttbr0_el1 = sreg(HV_SYS_REG_TTBR0_EL1); cpu->ttbr1_el1 = sreg(HV_SYS_REG_TTBR1_EL1);
    cpu->mair_el1 = sreg(HV_SYS_REG_MAIR_EL1);
    cpu->el = (uint32_t)(cpsr >> 2) & 3;
    cpu->spsel = (uint32_t)cpsr & 1;
    cpu->sp = cpu->el && cpu->spsel ? sreg(HV_SYS_REG_SP_EL1) : sreg(HV_SYS_REG_SP_EL0);
    hv_tlb_flush(cpu);
    uint64_t ipc = 0; uint32_t insn = 0;
    if (hv_mmu_access(cpu, pc, HV_ACC_EXEC, cpu->el, &ipc) || hv_phys_read(m, ipc, &insn, 4) ||
        hv_mem_emulate(cpu, insn, pc) != 0) {
        fprintf(stderr, "winvm-hvf: cannot emulate insn %08x at pc %llx (ipa %llx esr %llx)\n", insn, (unsigned long long)pc,
                (unsigned long long)ipa, (unsigned long long)esr);
        return -1;
    }
    for (int r = 0; r < 31; r++) set_xreg(r, cpu->x[r]);
    if (cpu->el && cpu->spsel) CHECK(hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_SP_EL1, cpu->sp));
    else CHECK(hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_SP_EL0, cpu->sp));
    advance();
    return 0;
}

static int dabt(HvMachine *m, HvCpu *cpu, uint64_t esr, uint64_t ipa) { /* EC 0x24: MMIO */
    if (!((esr >> 24) & 1)) return emulate_insn(m, cpu, ipa, esr);
    unsigned len = 1u << ((esr >> 22) & 3), rt = (esr >> 16) & 31;
    int sse = (esr >> 21) & 1, sf = (esr >> 15) & 1, wr = (esr >> 6) & 1;
    if (wr) {
        uint64_t v = rt == 31 ? 0 : xreg((int)rt);
        hv_phys_write(m, ipa, &v, len);
    } else {
        uint64_t v = 0;
        hv_phys_read(m, ipa, &v, len);
        if (sse && len < 8) { int sh = 64 - 8 * (int)len; v = (uint64_t)((int64_t)(v << sh) >> sh); }
        if (!sf) v = (uint32_t)v;
        set_xreg((int)rt, v);
    }
    advance();
    return 0;
}

int winvm_hvf_run(HvMachine *m, HvCpu *cpu) {
    static int made;
    if (!made) {
        hv_vm_config_t cfg = hv_vm_config_create();
        uint32_t ipa = 0;
        if (hv_vm_config_get_max_ipa_size(&ipa) == HV_SUCCESS) hv_vm_config_set_ipa_size(cfg, ipa);
        { bool el2 = 0; hv_vm_config_get_el2_enabled(cfg, &el2); fprintf(stderr, "winvm-hvf: EL2 was %d, now off (PMU accesses trap)\n", el2); }
        if (getenv("WINVM_HVF_EL2")) hv_vm_config_set_el2_enabled(cfg, true);
        CHECK(hv_vm_create(cfg));
        /* HVF's own GICv3 at the board's addresses: the guest's ICC_* registers don't trap, so Henge's
           software GIC can't be used. Device SPIs reach it through hv_gicv3_spi_hook. */
        size_t da = 0, ra = 0, rs = 0;
        hv_gic_get_distributor_base_alignment(&da); hv_gic_get_redistributor_base_alignment(&ra);
        hv_gic_get_redistributor_region_size(&rs);
        fprintf(stderr, "winvm-hvf: GIC alignment dist %zx redist %zx, redist region %zx\n", da, ra, rs);
        hv_gic_config_t gc = hv_gic_config_create();
        CHECK(hv_gic_config_set_distributor_base(gc, WA_GIC_DIST));
        CHECK(hv_gic_config_set_redistributor_base(gc, WA_GIC_REDIST));
        CHECK(hv_gic_create(gc));
        hv_gicv3_spi_hook = spi_hook;
        for (int i = 0; i < m->nram; i++)
            CHECK(hv_vm_map(m->ram[i].host, m->ram[i].pa, m->ram[i].size,
                            HV_MEMORY_READ | HV_MEMORY_EXEC | (m->ram[i].readonly ? 0 : HV_MEMORY_WRITE)));
        CHECK(hv_vcpu_create(&vcpu, &vexit, NULL));
        fprintf(stderr, "winvm-hvf: guest CPU on Hypervisor.framework (ipa %u bits, %d RAM regions)\n", ipa, m->nram);
        made = 1;
    }
    for (int r = 0; r < 31; r++) set_xreg(r, cpu->x[r]);
    CHECK(hv_vcpu_set_reg(vcpu, HV_REG_PC, cpu->pc));
    CHECK(hv_vcpu_set_reg(vcpu, HV_REG_CPSR, 0x3c5)); /* EL1h, DAIF masked */
    CHECK(hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_MPIDR_EL1, cpu->mpidr));
    CHECK(hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_SCTLR_EL1, 0x30d00800));
    { /* no PMU under HVF (its registers UNDEF without a trap): say so in ID_AA64DFR0_EL1.PMUVer */
        uint64_t d = sreg(HV_SYS_REG_ID_AA64DFR0_EL1);
        hv_return_t r = hv_vcpu_set_sys_reg(vcpu, HV_SYS_REG_ID_AA64DFR0_EL1, (d & ~(0xfull << 8)) | (1ull << 8));
        static int told; if (!told++) fprintf(stderr, "winvm-hvf: ID_AA64DFR0 %llx -> PMUVer 1 (%s)\n", (unsigned long long)d, r == HV_SUCCESS ? "ok" : "refused");
    }
    CHECK(hv_vcpu_set_vtimer_offset(vcpu, 0)); /* CNTVCT == CNTPCT (winarm_reset: cntvoff 0) */
    CHECK(hv_vcpu_set_vtimer_mask(vcpu, false)); /* the in-kernel GIC takes the timer PPIs */
    cpu->cntv_ctl = cpu->cntp_ctl = 0;
    atomic_store(&kick_on, 1);
    pthread_t k; pthread_create(&k, NULL, kicker, NULL);
    int rc = 0;
    for (;;) {
        if (atomic_load(&cpu->halted)) break;
        cpu->cntv_ctl = sreg(HV_SYS_REG_CNTV_CTL_EL0);
        cpu->cntv_cval = sreg(HV_SYS_REG_CNTV_CVAL_EL0);
        if (m->tick) m->tick(m, cpu);
        CHECK(hv_vcpu_run(vcpu));
        {   /* WINVM_HVF_LOG: every 5 s, the exits by kind and where the guest is */
            static uint64_t last, nexit[64], ncanc;
            static int lg = -1;
            if (lg < 0) lg = getenv("WINVM_HVF_LOG") != NULL;
            if (lg) {
                if (vexit->reason == HV_EXIT_REASON_EXCEPTION) nexit[(vexit->exception.syndrome >> 26) & 63]++; else ncanc++;
                uint64_t t = mach_absolute_time();
                if (t - last > 120000000ull) {
                    uint64_t pc, cpsr; hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc); hv_vcpu_get_reg(vcpu, HV_REG_CPSR, &cpsr);
                    fprintf(stderr, "winvm-hvf: pc %llx cpsr %llx irq %d kick %llu wfi %llu hvc/smc %llu sys %llu dabt %llu last ipa %llx\n",
                            (unsigned long long)pc, (unsigned long long)cpsr, m->percpu[0].irq_line, (unsigned long long)ncanc,
                            (unsigned long long)nexit[1], (unsigned long long)(nexit[0x16] + nexit[0x17]), (unsigned long long)nexit[0x18],
                            (unsigned long long)nexit[0x24], (unsigned long long)vexit->exception.physical_address);
                    fprintf(stderr, "winvm-hvf:   esr_el1 %llx elr_el1 %llx far_el1 %llx vbar %llx\n", (unsigned long long)sreg(HV_SYS_REG_ESR_EL1),
                            (unsigned long long)sreg(HV_SYS_REG_ELR_EL1), (unsigned long long)sreg(HV_SYS_REG_FAR_EL1), (unsigned long long)sreg(HV_SYS_REG_VBAR_EL1));
                    { uint32_t w = 0; hv_phys_read(m, sreg(HV_SYS_REG_ELR_EL1), &w, 4); fprintf(stderr, "winvm-hvf:   insn at elr %08x\n", w); }
                    last = t;
                }
            }
        }
        {   /* PMU registers UNDEF under HVF and the firmware reads them anyway: when the guest sits at its
               synchronous vector for an unknown-instruction exception on one, finish the access (RAZ/WI) for it. */
            uint64_t pc, vbar = sreg(HV_SYS_REG_VBAR_EL1);
            CHECK(hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc));
            if ((pc == vbar + 0x200 || pc == vbar) && (sreg(HV_SYS_REG_ESR_EL1) >> 26) == 0) {
                uint64_t elr = sreg(HV_SYS_REG_ELR_EL1), ipa = 0; uint32_t w = 0;
                cpu->sctlr_el1 = sreg(HV_SYS_REG_SCTLR_EL1); cpu->tcr_el1 = sreg(HV_SYS_REG_TCR_EL1);
                cpu->ttbr0_el1 = sreg(HV_SYS_REG_TTBR0_EL1); cpu->ttbr1_el1 = sreg(HV_SYS_REG_TTBR1_EL1); cpu->el = 1;
                hv_tlb_flush(cpu);
                if (!hv_mmu_access(cpu, elr, HV_ACC_EXEC, 1, &ipa)) hv_phys_read(m, ipa, &w, 4);
                uint32_t crn = (w >> 12) & 15;
                if ((w & 0xffd00000u) == 0xd5100000u && ((w >> 19) & 3) == 3 && ((((w >> 16) & 7) == 3 && (crn == 9 || crn == 14)) || (((w >> 16) & 7) == 0 && crn == 9 && ((w >> 8) & 15) == 14))) {
                    if ((w >> 21) & 1) set_xreg((int)(w & 31), 0);
                    CHECK(hv_vcpu_set_reg(vcpu, HV_REG_PC, elr + 4));
                    CHECK(hv_vcpu_set_reg(vcpu, HV_REG_CPSR, sreg(HV_SYS_REG_SPSR_EL1)));
                    static int told; if (told++ < 4) fprintf(stderr, "winvm-hvf: PMU access %08x at %llx emulated (RAZ/WI)\n", w, (unsigned long long)elr);
                    continue;
                }
            }
        }
        if (vexit->reason == HV_EXIT_REASON_VTIMER_ACTIVATED) { hv_vcpu_set_vtimer_mask(vcpu, false); continue; }
        if (vexit->reason == HV_EXIT_REASON_CANCELED) continue;
        if (vexit->reason != HV_EXIT_REASON_EXCEPTION) { fprintf(stderr, "winvm-hvf: exit reason %d\n", vexit->reason); rc = -1; break; }
        uint64_t esr = vexit->exception.syndrome;
        uint32_t ec = (uint32_t)(esr >> 26);
        if (ec == 0x01) { /* WFI/WFE: wait for an interrupt (the kicker ends it within a millisecond) */
            advance();
            if (!(esr & 1)) usleep(200);
        } else if (ec == 0x16 || ec == 0x17) { /* HVC, SMC: PSCI */
            uint64_t ret;
            int halt = psci(m, xreg(0), xreg(1), &ret);
            set_xreg(0, ret);
            if (ec == 0x17) advance();
            if (halt) break;
        } else if (ec == 0x18) {
            sysreg(m, cpu, (uint32_t)esr & 0x1ffffff);
        } else if (ec == 0x24) {
            if (dabt(m, cpu, esr, vexit->exception.physical_address) != 0) { rc = -1; break; }
        } else {
            uint64_t pc; CHECK(hv_vcpu_get_reg(vcpu, HV_REG_PC, &pc));
            fprintf(stderr, "winvm-hvf: unhandled exception ec %#x esr %llx pc %llx far %llx\n", ec, (unsigned long long)esr,
                    (unsigned long long)pc, (unsigned long long)vexit->exception.virtual_address);
            rc = -1;
            break;
        }
    }
    atomic_store(&kick_on, 0);
    pthread_join(k, NULL);
    CHECK(hv_vcpu_get_reg(vcpu, HV_REG_PC, &cpu->pc));
    if (rc && !atomic_load(&cpu->halted)) hv_machine_halt(m, HV_HALT_HOST);
    return rc;
}
