#include "fuzz.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#include "cpu.h"
#include "dispatch.h"
#include "machine.h"
#include "mmu.h"

#define CODE_BUF_SIZE (4u * 1024u * 1024u)
#define SLOT_BYTES    256u
#define NUM_SLOTS     (CODE_BUF_SIZE / SLOT_BYTES)
#define PT_BUF_SIZE   (2u * 1024u * 1024u)
#define GUARD_SIZE    (64u * 1024u)

static HvMachine m;
static HvCpu cpu;

static uint8_t *code_buf = NULL;
static uint8_t *scratch_buf = NULL;
static uint8_t *stack_buf = NULL;
static uint8_t *scratch_mmap = NULL;
static uint8_t *stack_mmap = NULL;
static uint8_t *vbar_buf = NULL;
static uint8_t *pt_buf = NULL;

static uint8_t *alloc_guarded(size_t size, uint8_t **raw_out) {
    size_t total = GUARD_SIZE + size + GUARD_SIZE;
    uint8_t *p = mmap(NULL, total, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (p == MAP_FAILED) return NULL;
    if (mprotect(p + GUARD_SIZE, size, PROT_READ | PROT_WRITE) != 0) {
        munmap(p, total);
        return NULL;
    }
    *raw_out = p;
    return p + GUARD_SIZE;
}

static void free_guarded(uint8_t *raw, size_t size) {
    if (raw) munmap(raw, GUARD_SIZE + size + GUARD_SIZE);
}

static uint32_t slot_idx = 0;
static int opt_mmu_on = 0;
static uint64_t pt_next = 0;
static uint64_t ttbr0_val = 0;
static uint64_t base_sctlr = 0x30d00980ull;

uint8_t *henge_scratch_ptr(void) { return scratch_buf; }
uint8_t *henge_stack_ptr(void) { return stack_buf; }

static uint64_t pt_alloc(uint64_t gran) {
    uint64_t pa = (uint64_t)(uintptr_t)(pt_buf + pt_next);
    pt_next += gran;
    memset((void *)(uintptr_t)pa, 0, gran);
    return pa;
}

static void map_4k(uint64_t va, uint64_t pa, uint64_t ap) {
    uint64_t table = ttbr0_val;
    for (int level = 0; level < 3; level++) {
        int shift = 12 + 9 * (3 - level);
        uint64_t *e = &((uint64_t *)(uintptr_t)table)[(va >> shift) & 0x1ff];
        if (!(*e & 1)) *e = pt_alloc(4096) | 3;
        table = *e & 0x0000fffffffff000ull;
    }
    ((uint64_t *)(uintptr_t)table)[(va >> 12) & 0x1ff] = pa | 3 | (3u << 8) | (1u << 10) | ap;
}

static void map_16k(uint64_t va, uint64_t pa, uint64_t ap) {
    uint64_t table = ttbr0_val;
    for (int level = 0; level < 3; level++) {
        int shift = 14 + 11 * (3 - level);
        uint64_t *e = &((uint64_t *)(uintptr_t)table)[(va >> shift) & 0x7ff];
        if (!(*e & 1)) *e = pt_alloc(16384) | 3;
        table = *e & 0x0000ffffffffc000ull;
    }
    ((uint64_t *)(uintptr_t)table)[(va >> 14) & 0x7ff] = pa | 3 | (3u << 8) | (1u << 10) | ap;
}

static void map_identity_range(uint64_t start, uint64_t size, int use_4k, uint64_t ap) {
    uint64_t step = use_4k ? 4096 : 16384;
    for (uint64_t off = 0; off < size; off += step) {
        if (use_4k) map_4k(start + off, start + off, ap);
        else map_16k(start + off, start + off, ap);
    }
}

static void invalidate_tlb_range(uint64_t va, uint64_t size) {
    uint64_t step = 1ull << HV_TLB_PAGE_BITS;
    for (uint64_t off = 0; off < size; off += step) {
        uint32_t slot = (uint32_t)((va + off) >> HV_TLB_PAGE_BITS) & (HV_TLB_SIZE - 1);
        for (int t = 0; t < 3; t++) {
            HvTlbEntry *e = hv_tlb_ent(&cpu, slot, t);
            e->read_tag = HV_TLB_INVALID;
            e->write_tag = HV_TLB_INVALID;
            e->exec_tag = HV_TLB_INVALID;
        }
    }
}

int henge_init(int tlb_page_bits, int slow_mem, int mmu_on) {
    (void)tlb_page_bits;
    if (HV_TLB_PAGE_BITS != tlb_page_bits) {
        fprintf(stderr, "build mismatch: compiled with HV_TLB_PAGE_BITS=%d, expected %d\n",
                HV_TLB_PAGE_BITS, tlb_page_bits);
        return -1;
    }
    if (hv_machine_init(&m, 16u << 20) != 0) return -1;

    code_buf = aligned_alloc(16384, CODE_BUF_SIZE);
    scratch_buf = alloc_guarded(SCRATCH_SIZE, &scratch_mmap);
    stack_buf = alloc_guarded(STACK_SIZE, &stack_mmap);
    vbar_buf = aligned_alloc(16384, 16384);
    pt_buf = aligned_alloc(16384, PT_BUF_SIZE);
    if (!code_buf || !scratch_buf || !stack_buf || !vbar_buf || !pt_buf) return -1;

    memset(code_buf, 0, CODE_BUF_SIZE);
    for (uint32_t i = 0; i < 16384 / 4; i++) ((uint32_t *)vbar_buf)[i] = 0xd503201fu; /* nop */
    for (uint32_t off = 0; off < 0x800; off += 0x80) {
        int32_t rel = ((int32_t)0x200 - (int32_t)off) / 4;
        ((uint32_t *)vbar_buf)[off / 4] = 0x14000000u | ((uint32_t)rel & 0x3ffffffu);
    }

    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)code_buf, CODE_BUF_SIZE, code_buf, 1);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)scratch_buf, SCRATCH_SIZE, scratch_buf, 0);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)stack_buf, STACK_SIZE, stack_buf, 0);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)vbar_buf, 16384, vbar_buf, 1);
    hv_machine_add_ram(&m, (uint64_t)(uintptr_t)pt_buf, PT_BUF_SIZE, pt_buf, 0);

    m.lse2 = 1;
    m.slow_mem = slow_mem ? 1 : 0;
    m.stop_pc2 = (uint64_t)(uintptr_t)vbar_buf + 0x200;

    opt_mmu_on = mmu_on;
    if (mmu_on) {
        int use_4k = (HV_TLB_PAGE_BITS == 12);
        pt_next = 0;
        ttbr0_val = pt_alloc(use_4k ? 4096 : 16384);
        map_identity_range((uint64_t)(uintptr_t)code_buf, CODE_BUF_SIZE, use_4k, 0);
        map_identity_range((uint64_t)(uintptr_t)scratch_buf, SCRATCH_SIZE, use_4k, 1u << 6);
        map_identity_range((uint64_t)(uintptr_t)stack_buf, STACK_SIZE, use_4k, 1u << 6);
        map_identity_range((uint64_t)(uintptr_t)vbar_buf, 16384, use_4k, 0);
        base_sctlr |= 1u | (1u << 2) | (1u << 12);
    }

    hv_cpu_reset(&cpu, &m);
    cpu.vbar_el1 = (uint64_t)(uintptr_t)vbar_buf;
    cpu.cpacr_el1 = 3u << 20;
    cpu.sctlr_el1 = base_sctlr;
    if (mmu_on) {
        cpu.mair_el1 = 0xff;
        cpu.tcr_el1 = 16 | ((HV_TLB_PAGE_BITS == 12 ? 0u : 2u) << 14) | (1u << 23) | (5ull << 32);
        cpu.ttbr0_el1 = ttbr0_val;
    }
    hv_tlb_flush(&cpu);
    slot_idx = 0;
    return 0;
}

void henge_cleanup(void) {
    hv_machine_free(&m);
    free(code_buf);
    free_guarded(scratch_mmap, SCRATCH_SIZE);
    free_guarded(stack_mmap, STACK_SIZE);
    free(vbar_buf);
    free(pt_buf);
    code_buf = scratch_buf = stack_buf = scratch_mmap = stack_mmap = vbar_buf = pt_buf = NULL;
}

int henge_run(uint64_t seed, const FuzzSeq *seq, const FuzzState *init, const uint8_t *init_scratch,
              const uint8_t *init_stack, FuzzState *out, uint8_t *out_scratch, uint8_t *out_stack) {
    if (slot_idx >= NUM_SLOTS) {
        hv_flush_blocks(&m);
        slot_idx = 0;
    }
    uint8_t *slot_ptr = code_buf + (size_t)slot_idx * SLOT_BYTES;
    slot_idx++;

    memcpy(slot_ptr, seq->insns, seq->ninsns * 4);
    uint32_t nop = 0xd503201fu;
    memcpy(slot_ptr + seq->ninsns * 4, &nop, 4);

    memcpy(scratch_buf, init_scratch, SCRATCH_SIZE);
    memcpy(stack_buf, init_stack, STACK_SIZE);

    memcpy(cpu.x, init->x, sizeof cpu.x);
    memcpy(cpu.v, init->v, sizeof cpu.v);
    cpu.sp = init->sp;
    cpu.nzcv = init->nzcv;
    cpu.fpcr = init->fpcr;
    cpu.fpsr = init->fpsr;

    cpu.el = 1;
    cpu.spsel = 1;
    cpu.daif = HV_PSTATE_DAIF;
    cpu.pstate_extra = 0;
    cpu.sctlr_el1 = base_sctlr;
    cpu.cpacr_el1 = 3u << 20;
    cpu.vbar_el1 = (uint64_t)(uintptr_t)vbar_buf;
    cpu.excl_addr = ~0ull;
    cpu.excl_size = 0;
    cpu.excl_val[0] = 0;
    cpu.excl_val[1] = 0;
    cpu.esr_el1 = 0;
    cpu.far_el1 = 0;
    cpu.elr_el1 = 0;
    cpu.exit_reason = 0;
    cpu.halted = 0;
    cpu.exit_req = 0;

    if (seed & 1) {
        invalidate_tlb_range((uint64_t)(uintptr_t)scratch_buf, SCRATCH_SIZE);
        invalidate_tlb_range((uint64_t)(uintptr_t)stack_buf, STACK_SIZE);
    }

    uint64_t seq_va = (uint64_t)(uintptr_t)slot_ptr;
    cpu.pc = seq_va;
    m.stop_pc = seq_va + (uint64_t)seq->ninsns * 4;

    sigjmp_buf h_jb;
    fuzz_sig_begin(&h_jb);
    if (sigsetjmp(h_jb, 1) != 0) {
        fuzz_sig_end();
        uint64_t zero = 0;
        __asm__ volatile("msr fpcr, %0\n\tmsr fpsr, %0" :: "r"(zero));
        memset(out, 0, sizeof *out);
        out->fault_sig = 1000 + fuzz_sig_caught();
        out->fault_esr = cpu.esr_el1;
        memcpy(out_scratch, scratch_buf, SCRATCH_SIZE);
        memcpy(out_stack, stack_buf, STACK_SIZE);
        return 0;
    }

    int r = hv_run(&cpu);
    fuzz_sig_end();

    memcpy(out->x, cpu.x, sizeof out->x);
    memcpy(out->v, cpu.v, sizeof out->v);
    out->sp = cpu.sp;
    out->nzcv = cpu.nzcv & 0xf0000000ull;
    out->fpcr = cpu.fpcr;
    out->fpsr = cpu.fpsr;
    out->fault_esr = cpu.esr_el1;

    if (r == HV_EXIT_HALT && cpu.pc == m.stop_pc) {
        out->fault_sig = 0;
    } else if (r == HV_EXIT_HALT && cpu.pc == m.stop_pc2) {
        out->fault_sig = 1;
    } else {
        out->fault_sig = r ? -r : -99;
    }

    memcpy(out_scratch, scratch_buf, SCRATCH_SIZE);
    memcpy(out_stack, stack_buf, STACK_SIZE);
    return 0;
}
