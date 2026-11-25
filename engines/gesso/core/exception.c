#include "exception.h"

#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "machine.h"
#include "dispatch.h"
#include "mmu.h"

/* Only EL0 and EL1 exist for the guest; HengeVM plays EL2 (PSCI over HVC, as
   QEMU's vmapple machine sets up) and there is no EL3. */

#define PSTATE_EXTRA_MASK ((1ull << 22) | (1ull << 23) | (1ull << 12) | (1ull << 24) | (1ull << 25))

uint64_t hv_pstate_get(HvCpu *cpu) {
    return (cpu->nzcv & 0xf0000000) | (cpu->daif & HV_PSTATE_DAIF) | (cpu->pstate_extra & PSTATE_EXTRA_MASK) |
           (uint64_t)cpu->el << 2 | (cpu->el ? cpu->spsel : 0);
}

void hv_sp_switch(HvCpu *cpu, uint32_t el, uint32_t spsel) {
    if (cpu->el == 0 || cpu->spsel == 0) cpu->sp_el0 = cpu->sp;
    else cpu->sp_el1 = cpu->sp;
    cpu->el = el;
    cpu->spsel = el ? spsel : 0;
    cpu->sp = cpu->spsel ? cpu->sp_el1 : cpu->sp_el0;
}

static void set_extra(HvCpu *cpu, uint64_t extra) {
    /* PAN selects a different TLB table (hv_tlb_table), so nothing to flush. */
    cpu->pstate_extra = extra;
}

void hv_pstate_set(HvCpu *cpu, uint64_t spsr) {
    uint32_t m = spsr & 0x1f;
    uint32_t el = (m >> 2) & 3;
    if ((m & 0x10) || el > 1) el = 1; /* AArch32 and EL2/EL3 do not exist: an illegal return, kept at EL1 */
    cpu->nzcv = spsr & 0xf0000000;
    cpu->daif = spsr & HV_PSTATE_DAIF;
    set_extra(cpu, spsr & PSTATE_EXTRA_MASK);
    hv_sp_switch(cpu, el, m & 1);
}

void hv_take_exception(HvCpu *cpu, int type, uint32_t esr, uint64_t far, int set_far, uint64_t ret) {
    if (type == HV_EXC_SYNC) cpu->m->stats.exceptions++;
    else cpu->m->stats.interrupts++;
    uint64_t spsr = hv_pstate_get(cpu);
    {
        HvStats *st = &cpu->m->stats;
        uint32_t k = st->nelchg++ & 15;
        st->elchg[k].from = ret, st->elchg[k].spsr = spsr, st->elchg[k].kind = (uint32_t)type, st->elchg[k].el = cpu->el;
        st->elchg[k].to = esr;
    }
    if (type == HV_EXC_SYNC) { /* rare classes (likely emulator gaps): undefined, illegal state, sysreg, alignment */
        static int nrare;
        uint32_t ec = esr >> 26;
        int rare = ec == HV_EC_UNKNOWN || ec == HV_EC_ILLEGAL || ec == HV_EC_SYSREG || ec == HV_EC_PC_ALIGN ||
                   ec == HV_EC_SP_ALIGN || ((ec == HV_EC_DABT_SAME || ec == HV_EC_DABT_LOWER) && (esr & 0x3f) == 0x21);
        if (rare && cpu->el == 1 && nrare < 200) { /* kernel only: user code probes features this way all the time */
            nrare++;
            uint32_t insn = 0; uint64_t ipa;
            if (!hv_mmu_access(cpu, ret, HV_ACC_EXEC, 1, &ipa)) hv_phys_read(cpu->m, ipa, &insn, 4);
            fprintf(stderr, "henge: rare exception ec=%02x esr=%08x far=%llx pc=%llx el%u insn=%08x sctlr=%llx\n", ec, esr,
                    (unsigned long long)far, (unsigned long long)ret, cpu->el, insn, (unsigned long long)cpu->sctlr_el1);
        }
    }
    /* HV_WATCH_MOD (default "fbwf"): learn a driver's load range from Windows' symbol-load debug service, then log every
       kernel data/instruction abort taken inside it (a driver that crashes on a fault, to see the faulting access). */
    static uint64_t wbase, wsize; static int nwatch;
    if (type == HV_EXC_SYNC && esr >> 26 == HV_EC_BRK && (esr & 0xffff) == 0xf002 && cpu->el == 1 && cpu->x[16] == 3) {
        const char *want = getenv("HV_WATCH_MOD") ? getenv("HV_WATCH_MOD") : "fbwf";
        uint64_t pa, sp = 0, info[3] = {0}; char nm[128] = {0};
        if (!hv_mmu_access(cpu, cpu->x[0] + 8, HV_ACC_READ, 1, &pa) && !hv_phys_read(cpu->m, pa, &sp, 8) && sp &&
            !hv_mmu_access(cpu, sp, HV_ACC_READ, 1, &pa)) {
            unsigned len = 4096 - (unsigned)(pa & 0xfff); if (len > 127) len = 127;
            hv_phys_read(cpu->m, pa, nm, len);
        }
        if (*want && strstr(nm, want) && !hv_mmu_access(cpu, cpu->x[1], HV_ACC_READ, 1, &pa) && !hv_phys_read(cpu->m, pa, info, 24)) {
            wbase = info[0], wsize = (uint32_t)(info[2] >> 32);
            fprintf(stderr, "henge: watching %s at %llx size %llx\n", nm, (unsigned long long)wbase, (unsigned long long)wsize);
        }
    }
    static uint32_t woff[64], wcnt[64];
    int wslot = -1;
    if (type == HV_EXC_SYNC && wsize && cpu->el == 1 && ret - wbase < wsize && nwatch < 2000 &&
        ((esr >> 26) == HV_EC_DABT_SAME || (esr >> 26) == HV_EC_IABT_SAME)) {
        /* At most 3 lines per instruction: the demand faults of a big buffer repeat at one spot and would hide the rest. */
        uint32_t off = (uint32_t)(ret - wbase);
        for (int i = 0; i < 64; i++) if (wcnt[i] == 0 || woff[i] == off) { woff[i] = off; wslot = i; break; }
        if (wslot >= 0 && wcnt[wslot]++ >= 3) wslot = -1;
    }
    if (wslot >= 0) {
        nwatch++;
        uint32_t insn = 0; uint64_t ipa;
        if (!hv_mmu_access(cpu, ret, HV_ACC_EXEC, 1, &ipa)) hv_phys_read(cpu->m, ipa, &insn, 4);
        uint64_t fpa = 0;
        uint32_t rewalk = hv_mmu_access(cpu, far, (esr >> 6) & 1 ? HV_ACC_WRITE : HV_ACC_READ, 1, &fpa); /* 0: maps now */
        fprintf(stderr, "henge: watched abort esr=%08x far=%llx pc=+%llx insn=%08x rewalk=%x pa=%llx x0=%llx x1=%llx x19=%llx lr=+%llx\n", esr,
                (unsigned long long)far, (unsigned long long)(ret - wbase), insn, rewalk, (unsigned long long)fpa,
                (unsigned long long)cpu->x[0], (unsigned long long)cpu->x[1], (unsigned long long)cpu->x[19],
                (unsigned long long)(cpu->x[30] - wbase));
    }
    if (type == HV_EXC_SYNC && esr >> 26 == HV_EC_BRK && (esr & 0xffff) == 0xf002 && cpu->el == 1 && cpu->x[16] != 3) { /* 3: symbol loads */
        /* Windows' debug service (DbgPrint and friends): show its text, e.g. the bugcheck's "Fatal System Error". */
        static int nsvc;
        if (nsvc++ < 64) {
            char t[161] = {0}; uint64_t ptrs[3] = {cpu->x[0], cpu->x[1], 0}, pa, sp;
            if (!hv_mmu_access(cpu, cpu->x[0] + 8, HV_ACC_READ, 1, &pa) && !hv_phys_read(cpu->m, pa, &sp, 8)) ptrs[2] = sp;
            fprintf(stderr, "henge: debug service x0=%llx x1=%llx x2=%llx x16=%llx", (unsigned long long)cpu->x[0],
                    (unsigned long long)cpu->x[1], (unsigned long long)cpu->x[2], (unsigned long long)cpu->x[16]);
            for (int k = 0; k < 3; k++) {
                if (!ptrs[k] || hv_mmu_access(cpu, ptrs[k], HV_ACC_READ, 1, &pa)) continue;
                unsigned len = 160 - (unsigned)(pa & 0xfff) > 160 ? 160 : 4096 - (unsigned)(pa & 0xfff);
                if (len > 160) len = 160;
                memset(t, 0, sizeof t);
                if (hv_phys_read(cpu->m, pa, t, len)) continue;
                for (unsigned q = 0; q < len; q++) if (t[q] && (t[q] < 32 || t[q] > 126)) t[q] = '.';
                fprintf(stderr, " | s%d \"%s\"", k, t);
            }
            fprintf(stderr, "\n");
            if (cpu->x[16] == 4 && cpu->x[0] == 0) {
                /* The bugcheck path: its code and parameters are somewhere in the callee-saved registers or the
                   stack. Show both and the frame chain's return addresses. */
                fprintf(stderr, "henge: bugcheck regs");
                for (int r = 19; r <= 28; r++) fprintf(stderr, " x%d=%llx", r, (unsigned long long)cpu->x[r]);
                fprintf(stderr, "\nhenge: bugcheck frames");
                uint64_t fp = cpu->x[29], fr[2];
                for (int d = 0; d < 10 && fp; d++) {
                    if (hv_mmu_access(cpu, fp, HV_ACC_READ, 1, &pa) || hv_phys_read(cpu->m, pa, fr, 16)) break;
                    fprintf(stderr, " %llx", (unsigned long long)fr[1]);
                    fp = fr[0];
                }
                uint64_t stkp[9]; int nstkp = 0;
                fprintf(stderr, "\nhenge: bugcheck stack");
                for (int q = 0; q < 64; q++) {
                    uint64_t v;
                    if (hv_mmu_access(cpu, cpu->sp + 8 * q, HV_ACC_READ, 1, &pa) || hv_phys_read(cpu->m, pa, &v, 8)) break;
                    fprintf(stderr, " %llx", (unsigned long long)v);
                    if (q >= 14 && q <= 22 && (v >> 47) == 0x1ffff) stkp[nstkp < 9 ? nstkp++ : 8] = v;
                }
                fprintf(stderr, "\n");
                /* What the bugcheck's addresses hold (the corrupted block among them): who wrote it shows in the bytes. */
                for (int i = 0; i < nstkp; i++) {
                    fprintf(stderr, "henge: bugcheck mem %llx:", (unsigned long long)stkp[i]);
                    for (int q = -8; q < 40; q++) {
                        uint64_t v, a = stkp[i] + 8 * q;
                        if (hv_mmu_access(cpu, a, HV_ACC_READ, 1, &pa) || hv_phys_read(cpu->m, pa, &v, 8)) { fprintf(stderr, " -"); continue; }
                        fprintf(stderr, "%s%llx", q == 0 ? " | " : " ", (unsigned long long)v);
                    }
                    fprintf(stderr, "\n");
                }
            }
        }
    }
    if (cpu->m->trace || cpu->m->log >= 2)
        fprintf(stderr, "exception type %d esr %08x far %llx from pc %llx el%u\n", type, esr, (unsigned long long)far,
                (unsigned long long)ret, cpu->el);
    uint64_t offset = cpu->el == 0 ? 0x400 : cpu->spsel ? 0x200 : 0x000;
    cpu->spsr_el1 = spsr;
    cpu->elr_el1 = ret;
    if (type == HV_EXC_SYNC || type == HV_EXC_SERROR) cpu->esr_el1 = esr;
    if (set_far) cpu->far_el1 = far;
    hv_sp_switch(cpu, 1, 1);
    cpu->daif = HV_PSTATE_DAIF;
    uint64_t extra = cpu->pstate_extra;
    if (!((cpu->sctlr_el1 >> 23) & 1)) extra |= HV_PSTATE_PAN; /* SCTLR_EL1.SPAN == 0 */
    extra &= ~(1ull << 12);
    if ((cpu->sctlr_el1 >> 44) & 1) extra |= 1ull << 12;      /* SSBS from DSSBS */
    set_extra(cpu, extra);
    cpu->excl_addr = ~0ull;
    cpu->pc = (cpu->vbar_el1 & ~0x7ffull) + offset + (uint64_t)type * 0x80;
    cpu->exit_reason = HV_EXIT_EXCEPTION;
}

void hv_raise_sync(HvCpu *cpu, uint32_t ec, uint32_t iss, uint64_t far, uint64_t pc) {
    int set_far = ec == HV_EC_PC_ALIGN || ec == HV_EC_IABT_LOWER || ec == HV_EC_IABT_SAME ||
                  ec == HV_EC_DABT_LOWER || ec == HV_EC_DABT_SAME;
    hv_take_exception(cpu, HV_EXC_SYNC, ec << 26 | 1u << 25 | (iss & 0x1ffffff), far, set_far, pc);
}

void hv_raise_undef(HvCpu *cpu, uint64_t pc) {
    static int reported;
    if (cpu->el == 0 && ((pc >> 55) & 1) && reported++ < 3) hv_debug_el0_in_kernel(cpu, "undef");
    if (cpu->m->log) {
        uint32_t insn = 0;
        uint64_t pa;
        if (!hv_mmu_access(cpu, pc, HV_ACC_EXEC, cpu->el, &pa)) hv_phys_read(cpu->m, pa, &insn, 4);
        fprintf(stderr, "undefined: pc %llx insn %08x el%u\n", (unsigned long long)pc, insn, cpu->el);
        if (cpu->el == 1) { /* a kernel assert: its backtrace, from the frame pointers (lr first) */
            fprintf(stderr, "  backtrace: lr %llx", (unsigned long long)(cpu->x[30] | 0xffffff8000000000ull));
            uint64_t fp = cpu->x[29];
            for (int i = 0; i < 24 && fp; i++) {
                uint64_t fr[2], fpa;
                if (hv_mmu_access(cpu, fp, HV_ACC_READ, 1, &fpa) || hv_phys_read(cpu->m, fpa, fr, 16)) break;
                uint64_t ret = fr[1] | 0xffffff8000000000ull; /* strip the PAC bits */
                fprintf(stderr, " %llx", (unsigned long long)ret);
                if (fr[0] <= fp) break;
                fp = fr[0];
            }
            fprintf(stderr, "\n  vbar %llx\n", (unsigned long long)cpu->vbar_el1);
        }
    }
    hv_raise_sync(cpu, HV_EC_UNKNOWN, 0, 0, pc);
}

void hv_raise_abort(HvCpu *cpu, int insn, uint64_t va, uint32_t fsc, int wnr, int s1ptw, uint64_t pc) {
    uint32_t ec = insn ? (cpu->el ? HV_EC_IABT_SAME : HV_EC_IABT_LOWER)
                       : (cpu->el ? HV_EC_DABT_SAME : HV_EC_DABT_LOWER);
    uint32_t iss = fsc | (uint32_t)(wnr && !insn) << 6 | (uint32_t)s1ptw << 7;
    if (cpu->m->log && fsc == HV_FSC_ALIGNMENT) {
        uint32_t word = 0;
        uint64_t pa;
        if (!hv_mmu_access(cpu, pc, HV_ACC_EXEC, cpu->el, &pa)) hv_phys_read(cpu->m, pa, &word, 4);
        fprintf(stderr, "alignment fault: pc %llx insn %08x va %llx el%u\n", (unsigned long long)pc, word, (unsigned long long)va, cpu->el);
    }
    hv_raise_sync(cpu, ec, iss, va, pc);
}

void hv_eret(HvCpu *cpu) {
    if (cpu->m) {
        HvStats *st = &cpu->m->stats;
        uint32_t k = st->nelchg++ & 15;
        st->elchg[k].from = cpu->pc, st->elchg[k].to = cpu->elr_el1, st->elchg[k].spsr = cpu->spsr_el1;
        st->elchg[k].kind = 9, st->elchg[k].el = cpu->el;
    }
    cpu->pc = cpu->elr_el1;
    hv_pstate_set(cpu, cpu->spsr_el1);
    cpu->excl_addr = ~0ull;
}

static HvCpu *cpu_by_mpidr(HvMachine *m, uint64_t mpidr) {
    for (int i = 0; i < m->ncpus; i++)
        if (m->cpus[i] && (m->cpus[i]->mpidr & 0xff00ffffffull) == (mpidr & 0xff00ffffffull)) return m->cpus[i];
    return NULL;
}

/* PSCI 1.0. */
static uint64_t psci(HvCpu *cpu, uint64_t fn) {
    static int log = -1;
    if (log < 0) log = getenv("HV_PSCI_LOG") != NULL;
    if (log && ((uint32_t)fn >> 24 == 0x84 || (uint32_t)fn >> 24 == 0xc4))
        fprintf(stderr, "psci %#llx x1 %#llx x2 %#llx x3 %#llx pc %llx\n", (unsigned long long)fn, (unsigned long long)cpu->x[1],
                (unsigned long long)cpu->x[2], (unsigned long long)cpu->x[3], (unsigned long long)cpu->pc);
    switch ((uint32_t)fn) {
    case 0x84000000: return 0x10000;                         /* PSCI_VERSION: 1.0 */
    case 0x84000006: return 2;                               /* MIGRATE_INFO_TYPE: no trusted OS */
    case 0x84000008:                                         /* SYSTEM_OFF */
    case 0x84000009:                                         /* SYSTEM_RESET */
        if (cpu->m->log)
            fprintf(stderr, "hengevm: guest requested %s on cpu %u\n",
                    (uint32_t)fn == 0x84000008 ? "shutdown" : "restart", cpu->index);
        hv_machine_halt(cpu->m, (uint32_t)fn == 0x84000008 ? HV_HALT_SHUTDOWN : HV_HALT_RESET);
        return 0;
    case 0x8400000a: {                                       /* PSCI_FEATURES */
        uint32_t q = (uint32_t)cpu->x[1];
        if (q == 0x84000000 || q == 0x84000002 || q == 0x84000006 || q == 0x84000008 || q == 0x84000009 ||
            q == 0x8400000a || q == 0xc4000003 || q == 0x84000003 || q == 0xc4000004 || q == 0x84000004)
            return 0;
        return (uint64_t)-1;
    }
    case 0x84000002:                                         /* CPU_OFF: until another CPU_ON */
        cpu->off = 1;
        return 0;
    case 0x84000003: case 0xc4000003: {                      /* CPU_ON: target, entry point, context id */
        HvCpu *t = cpu_by_mpidr(cpu->m, cpu->x[1]);
        if (!t) return (uint64_t)-2;                         /* INVALID_PARAMETERS */
        if (!t->off) return (uint64_t)-4;                    /* ALREADY_ON */
        while (!__atomic_load_n(&t->parked_off, __ATOMIC_SEQ_CST)) {
            if (cpu->halted || t->halted) return (uint64_t)-3; /* DENIED: machine is stopping */
            sched_yield(); /* still on its way out of CPU_OFF */
        }
        uint64_t mpidr = t->mpidr, entry = cpu->x[2], context = cpu->x[3];
        if ((uint32_t)fn == 0x84000003) entry = (uint32_t)entry, context = (uint32_t)context;
        /* As at reset: EL1h, MMU and caches off, everything masked. Its thread
           waits on wake_mu, so it cannot see the CPU half reset. */
        pthread_mutex_lock(&t->pc_state->wake_mu);
        HvPerCpu *pcs = t->pc_state;
        if (cpu->halted || t->halted) {
            pthread_mutex_unlock(&pcs->wake_mu);
            return (uint64_t)-3;
        }
        hv_cpu_reset_index(t, cpu->m, t->index);
        t->mpidr = mpidr;
        t->pc = entry;
        t->x[0] = context;
        t->parked_off = 1;
        __atomic_store_n(&t->off, 0, __ATOMIC_RELEASE);
        pcs->wake_pending = 1;
        pthread_cond_signal(&pcs->wake_cv);
        pthread_mutex_unlock(&pcs->wake_mu);
        return 0;
    }
    case 0x84000004: case 0xc4000004: {                      /* AFFINITY_INFO: 0 on, 1 off */
        HvCpu *t = cpu_by_mpidr(cpu->m, cpu->x[1]);
        if (!t) return (uint64_t)-2;
        return t->off ? 1 : 0;
    }
    /* vmapple's paravirtualized PAC (XNU osfmk/arm64/hv_hvc.h): the guest
       cannot program PAC keys itself, so the hypervisor does. HengeVM never
       signs pointers, so there is nothing to program; each call only has to
       succeed (XNU spins on a nonzero x0). */
    case 0xc1000000: /* VMAPPLE_PAC_SET_INITIAL_STATE */
    case 0xc1000002: /* VMAPPLE_PAC_SET_A_KEYS */
    case 0xc1000003: /* VMAPPLE_PAC_SET_B_KEYS */
    case 0xc1000004: /* VMAPPLE_PAC_SET_EL0_DIVERSIFIER */
    case 0xc1000005: /* VMAPPLE_PAC_SET_EL0_DIVERSIFIER_AT_EL1 */
    case 0xc1000006: /* VMAPPLE_PAC_SET_G_KEY */
    case 0xc10000f0: /* VMAPPLE_PAC_NOP */
        return 0;
    case 0xc1000001: /* VMAPPLE_PAC_GET_DEFAULT_KEYS: x2 = default ROP id, x3 = default JOP id */
        cpu->x[2] = 0x524f50; /* the values only name keys, and no key is ever used */
        cpu->x[3] = 0x4a4f50;
        return 0;
    default:
        if (cpu->m->log) fprintf(stderr, "hengevm: unknown hypervisor call %#llx (x1 %#llx) at el%u\n",
                                 (unsigned long long)fn, (unsigned long long)cpu->x[1], cpu->el);
        return (uint64_t)-1;                                 /* NOT_SUPPORTED */
    }
}

/* Bring-up aid: x0-x3, and any string they point to (read with the current EL's mapping). */
void hv_debug_args(HvCpu *cpu) {
    for (int i = 0; i < 4; i++) fprintf(stderr, " x%d=%llx", i, (unsigned long long)cpu->x[i]);
    fprintf(stderr, "\n");
    for (int i = 0; i < 4; i++) {
        char str[161];
        int n = 0;
        for (; n < 160; n++) {
            uint64_t pa;
            if (hv_mmu_access(cpu, cpu->x[i] + n, HV_ACC_READ, cpu->el, &pa) || hv_phys_read(cpu->m, pa, &str[n], 1) ||
                str[n] < 9 || (unsigned char)str[n] > 126)
                break;
        }
        str[n] = 0;
        if (n >= 4) fprintf(stderr, "    x%d -> \"%s\"\n", i, str);
    }
}

int hv_exception_insn(HvCpu *cpu, uint32_t insn, uint64_t pc) {
    uint32_t imm16 = (insn >> 5) & 0xffff;
    uint32_t opc = (insn >> 21) & 7, ll = insn & 3;
    if (opc == 0 && ll == 1 && cpu->m->log >= 3) {
        fprintf(stderr, "svc #%x at %llx el%u:", imm16, (unsigned long long)pc, cpu->el);
        hv_debug_args(cpu);
    }
    if (opc == 0 && ll == 1) { /* SVC: ELR is the next instruction */
        hv_take_exception(cpu, HV_EXC_SYNC, HV_EC_SVC64 << 26 | 1u << 25 | imm16, 0, 0, pc + 4);
        return 1;
    }
    if (((opc == 0 && ll == 2) || (opc == 0 && ll == 3 && cpu->m->psci_smc)) && cpu->el == 1) { /* HVC (or SMC on boards with psci_smc): PSCI and vmapple's PAC calls */
        cpu->x[0] = psci(cpu, cpu->x[0]);
        if (!cpu->halted && !cpu->off) return 0; /* like a call: the block carries on (xnu makes one per context switch) */
        cpu->pc = pc + 4;
        cpu->exit_reason = cpu->halted ? HV_EXIT_HALT : HV_EXIT_BRANCH; /* CPU_OFF: the dispatcher parks it */
        return 1;
    }
    if (opc == 1 && ll == 0) { /* BRK */
        hv_take_exception(cpu, HV_EXC_SYNC, HV_EC_BRK << 26 | 1u << 25 | imm16, 0, 0, pc);
        return 1;
    }
    /* SMC with no EL3, HVC from EL0, HLT without halting debug, DCPS: undefined. */
    hv_raise_undef(cpu, pc);
    return 1;
}

int hv_check_interrupts(HvCpu *cpu) {
    HvMachine *m = cpu->m;
    HvPerCpu *p = cpu->pc_state;
    (void)m;
    if (p->fiq_line && !(cpu->daif & HV_PSTATE_F)) {
        hv_take_exception(cpu, HV_EXC_FIQ, 0, 0, 0, cpu->pc);
        return 1;
    }
    if (p->irq_line && !(cpu->daif & HV_PSTATE_I)) {
        hv_take_exception(cpu, HV_EXC_IRQ, 0, 0, 0, cpu->pc);
        return 1;
    }
    return 0;
}
