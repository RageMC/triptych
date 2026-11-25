#include "fuzz.h"

#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#ifndef HV_TLB_PAGE_BITS
#define HV_TLB_PAGE_BITS 14
#endif

static uint8_t init_scratch[SCRATCH_SIZE];
static uint8_t init_stack[STACK_SIZE];
static uint8_t ref_scratch[SCRATCH_SIZE];
static uint8_t ref_stack[STACK_SIZE];
static uint8_t henge_scratch[SCRATCH_SIZE];
static uint8_t henge_stack[STACK_SIZE];

typedef struct {
    int mismatch;
    const char *reason;
} DiffResult;

static DiffResult compare_results(const FuzzState *ref, const FuzzState *henge,
                                    const uint8_t *r_scr, const uint8_t *h_scr, int has_mem) {
    if (henge->fault_sig >= 1000) {
        return (DiffResult){1, "henge_host_crash"};
    }
    int ref_f = (ref->fault_sig != 0);
    int h_f = (henge->fault_sig != 0);
    if (ref_f != h_f) {
        return (DiffResult){1, ref_f ? "ref_faulted_henge_ok" : "henge_faulted_ref_ok"};
    }
    if (ref_f && h_f) {
        uint32_t ec = (uint32_t)(henge->fault_esr >> 26);
        if (ec == 0) return (DiffResult){1, "henge_undef_vs_ref_fault"};
        return (DiffResult){0, NULL};
    }
    for (int i = 0; i < 31; i++) {
        if (ref->x[i] != henge->x[i]) return (DiffResult){1, "gpr"};
    }
    if (ref->sp != henge->sp) return (DiffResult){1, "sp"};
    if ((ref->nzcv & 0xf0000000ull) != (henge->nzcv & 0xf0000000ull)) return (DiffResult){1, "nzcv"};
    if (ref->fpcr != henge->fpcr) return (DiffResult){1, "fpcr"};
    if (ref->fpsr != henge->fpsr) return (DiffResult){1, "fpsr"};
    for (int i = 0; i < 32; i++) {
        if (ref->v[i] != henge->v[i]) return (DiffResult){1, "vec"};
    }
    if (has_mem && memcmp(r_scr, h_scr, SCRATCH_SIZE) != 0) {
        return (DiffResult){1, "scratch_mem"};
    }
    return (DiffResult){0, NULL};
}

/* Returns 0 if executed and compared, 1 if host hit SIGILL (unsupported). */
static int eval_seq(uint64_t seed, const FuzzSeq *seq, const FuzzState *init,
                    FuzzState *ref_out, FuzzState *henge_out, DiffResult *diff) {
    if (ref_run(seq, init, init_scratch, init_stack, ref_out, ref_scratch, ref_stack) != 0) {
        return 1;
    }
    henge_run(seed, seq, init, init_scratch, init_stack, henge_out, henge_scratch, henge_stack);
    *diff = compare_results(ref_out, henge_out, ref_scratch, henge_scratch, seq->has_mem);
    return 0;
}

static void shrink_seq(uint64_t seed, FuzzSeq *seq, const FuzzState *init) {
    int changed = 1;
    while (changed && seq->ninsns > 1) {
        changed = 0;
        for (int i = (int)seq->ninsns - 1; i >= 0; i--) {
            FuzzSeq cand = *seq;
            for (uint32_t j = (uint32_t)i; j + 1 < cand.ninsns; j++) {
                cand.insns[j] = cand.insns[j + 1];
            }
            cand.ninsns--;
            FuzzState ro, ho;
            DiffResult d;
            if (eval_seq(seed, &cand, init, &ro, &ho, &d) == 0 && d.mismatch) {
                /* Verify once in case of transient host x18 preemption */
                if (eval_seq(seed, &cand, init, &ro, &ho, &d) == 0 && d.mismatch) {
                    *seq = cand;
                    changed = 1;
                    break;
                }
            }
        }
    }
}

static void disassemble_seq(const FuzzSeq *seq) {
    char cmd[256], obj[128];
    snprintf(obj, sizeof obj, "/tmp/cpufuzz_dis_%d.o", (int)getpid());
    snprintf(cmd, sizeof cmd, "clang -arch arm64 -c -x assembler - -o %s && objdump -d %s", obj, obj);
    FILE *fp = popen(cmd, "w");
    if (!fp) {
        for (uint32_t i = 0; i < seq->ninsns; i++) printf("  [%2u] 0x%08x\n", i, seq->insns[i]);
        return;
    }
    fprintf(fp, ".text\n");
    for (uint32_t i = 0; i < seq->ninsns; i++) {
        fprintf(fp, ".long 0x%08x\n", seq->insns[i]);
    }
    fflush(fp);
    pclose(fp);
    remove(obj);
}

static void print_diff_details(const FuzzState *init, const FuzzState *ref, const FuzzState *henge,
                               const uint8_t *r_scr, const uint8_t *h_scr, int has_mem) {
    if ((ref->fault_sig != 0) || (henge->fault_sig != 0)) {
        printf("  fault: ref_sig=%d henge_sig=%d henge_esr=0x%08llx (EC=0x%02llx)\n",
               ref->fault_sig, henge->fault_sig, (unsigned long long)henge->fault_esr,
               (unsigned long long)(henge->fault_esr >> 26));
        if ((ref->fault_sig != 0) != (henge->fault_sig != 0) || henge->fault_sig >= 1000) return;
    }
    for (int i = 0; i < 31; i++) {
        if (ref->x[i] != henge->x[i]) {
            printf("  x%-2d: init=%016llx ref=%016llx henge=%016llx\n", i,
                   (unsigned long long)init->x[i], (unsigned long long)ref->x[i],
                   (unsigned long long)henge->x[i]);
        }
    }
    if (ref->sp != henge->sp) {
        printf("  sp : init=%016llx ref=%016llx henge=%016llx\n",
               (unsigned long long)init->sp, (unsigned long long)ref->sp,
               (unsigned long long)henge->sp);
    }
    if ((ref->nzcv & 0xf0000000ull) != (henge->nzcv & 0xf0000000ull)) {
        printf("  nzcv: init=%x ref=%x henge=%x\n",
               (unsigned)(init->nzcv >> 28), (unsigned)(ref->nzcv >> 28),
               (unsigned)(henge->nzcv >> 28));
    }
    if (ref->fpcr != henge->fpcr) {
        printf("  fpcr: init=%08llx ref=%08llx henge=%08llx\n",
               (unsigned long long)init->fpcr, (unsigned long long)ref->fpcr,
               (unsigned long long)henge->fpcr);
    }
    if (ref->fpsr != henge->fpsr) {
        printf("  fpsr: init=%08llx ref=%08llx henge=%08llx\n",
               (unsigned long long)init->fpsr, (unsigned long long)ref->fpsr,
               (unsigned long long)henge->fpsr);
    }
    for (int i = 0; i < 32; i++) {
        if (ref->v[i] != henge->v[i]) {
            uint64_t il = (uint64_t)init->v[i], ih = (uint64_t)(init->v[i] >> 64);
            uint64_t rl = (uint64_t)ref->v[i], rh = (uint64_t)(ref->v[i] >> 64);
            uint64_t hl = (uint64_t)henge->v[i], hh = (uint64_t)(henge->v[i] >> 64);
            printf("  v%-2d: init=%016llx_%016llx ref=%016llx_%016llx henge=%016llx_%016llx\n", i,
                   (unsigned long long)ih, (unsigned long long)il,
                   (unsigned long long)rh, (unsigned long long)rl,
                   (unsigned long long)hh, (unsigned long long)hl);
        }
    }
    if (has_mem) {
        int shown = 0;
        for (size_t i = 0; i < SCRATCH_SIZE && shown < 16; i++) {
            if (r_scr[i] != h_scr[i]) {
                printf("  mem[+0x%04zx]: init=%02x ref=%02x henge=%02x\n",
                       i, init_scratch[i], r_scr[i], h_scr[i]);
                shown++;
            }
        }
    }
}

/* Deduplicate shrunk findings by masking register operands (Rd/Rn/Rm/Rt) into an opcode signature. */
#define MAX_UNIQ 256
typedef struct {
    uint32_t ninsns;
    uint32_t sig[MAX_SEQ_INSNS];
    uint64_t hits;
    const char *reason;
} UniqBug;

static uint32_t opcode_signature(uint32_t insn) {
    return insn & 0xffe0fc00u;
}

static int find_or_add_uniq(UniqBug *uniqs, int *nuniq, const FuzzSeq *shrunk, const char *reason, int *is_new) {
    uint32_t sig[MAX_SEQ_INSNS];
    for (uint32_t i = 0; i < shrunk->ninsns; i++) sig[i] = opcode_signature(shrunk->insns[i]);
    for (int u = 0; u < *nuniq; u++) {
        if (uniqs[u].ninsns == shrunk->ninsns &&
            uniqs[u].reason == reason &&
            memcmp(uniqs[u].sig, sig, shrunk->ninsns * sizeof(uint32_t)) == 0) {
            uniqs[u].hits++;
            *is_new = 0;
            return u;
        }
    }
    if (*nuniq < MAX_UNIQ) {
        int idx = (*nuniq)++;
        uniqs[idx].ninsns = shrunk->ninsns;
        uniqs[idx].reason = reason;
        memcpy(uniqs[idx].sig, sig, shrunk->ninsns * sizeof(uint32_t));
        uniqs[idx].hits = 1;
        *is_new = 1;
        return idx;
    }
    *is_new = 0;
    return -1;
}

static void run_class(FuzzClass cls, uint64_t seed0, uint64_t nseeds, int max_shrinks) {
    uint64_t skipped_sigill = 0;
    uint64_t mismatches = 0;
    uint64_t shrinks_done = 0;
    UniqBug uniqs[MAX_UNIQ];
    int nuniq = 0;

    struct timespec t0, t1;
    clock_gettime(CLOCK_MONOTONIC, &t0);

    uint8_t *scratch_ptr = henge_scratch_ptr();
    uint8_t *stack_ptr = henge_stack_ptr();

    for (uint64_t i = 0; i < nseeds; i++) {
        uint64_t seed = seed0 + i;
        FuzzSeq seq;
        FuzzState init, ref_out, henge_out;
        DiffResult diff;

        gen_sequence(seed, cls, scratch_ptr, stack_ptr, &seq, &init, init_scratch, init_stack);
        if (eval_seq(seed, &seq, &init, &ref_out, &henge_out, &diff) != 0) {
            skipped_sigill++;
            continue;
        }
        if (diff.mismatch) {
            /* Re-evaluate once to filter transient host x18 context-switch glitches. */
            if (eval_seq(seed, &seq, &init, &ref_out, &henge_out, &diff) != 0 || !diff.mismatch) {
                continue;
            }
            mismatches++;
            int is_val = (strcmp(diff.reason, "gpr") == 0 || strcmp(diff.reason, "sp") == 0 ||
                          strcmp(diff.reason, "nzcv") == 0 || strcmp(diff.reason, "fpcr") == 0 ||
                          strcmp(diff.reason, "fpsr") == 0 || strcmp(diff.reason, "vec") == 0 ||
                          strcmp(diff.reason, "scratch_mem") == 0);
            if (is_val || shrinks_done < (uint64_t)max_shrinks || (mismatches % 50) == 0) {
                shrinks_done++;
                FuzzSeq orig = seq;
                shrink_seq(seed, &seq, &init);
                int is_new = 0;
                find_or_add_uniq(uniqs, &nuniq, &seq, diff.reason, &is_new);
                if (is_new) {
                    eval_seq(seed, &seq, &init, &ref_out, &henge_out, &diff);
                    printf("\n[MISMATCH] class=%s seed=%" PRIu64 " reason=%s (shrunk %u -> %u insns)\n",
                           fuzz_class_name(cls), seed, diff.reason ? diff.reason : "?",
                           orig.ninsns, seq.ninsns);
                    printf("  init base regs: x20=%016llx x21=%016llx x22=%016llx x28=%016llx x24=%016llx x25=%016llx (scratch=%016llx)\n",
                           (unsigned long long)init.x[20], (unsigned long long)init.x[21],
                           (unsigned long long)init.x[22], (unsigned long long)init.x[28],
                           (unsigned long long)init.x[24], (unsigned long long)init.x[25],
                           (unsigned long long)(uintptr_t)scratch_ptr);
                    fflush(stdout);
                    disassemble_seq(&seq);
                    print_diff_details(&init, &ref_out, &henge_out, ref_scratch, henge_scratch, seq.has_mem);
                    fflush(stdout);
                }
            }
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &t1);
    double elapsed = (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) * 1e-9;
    printf("[SUMMARY] class=%-12s tlb=%dKB seeds=%" PRIu64 " skipped_sigill=%" PRIu64
           " mismatches=%" PRIu64 " uniq_shrunk=%d time=%.2fs\n",
           fuzz_class_name(cls), (1 << HV_TLB_PAGE_BITS) / 1024, nseeds, skipped_sigill,
           mismatches, nuniq, elapsed);
    fflush(stdout);
}

int main(int argc, char **argv) {
    uint64_t nseeds = 200000;
    uint64_t seed0 = 1;
    int target_cls = -1;
    int mmu_on = 1;
    int slow_mem = 0;
    int max_shrinks = 2000;

    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "--seeds=", 8) == 0) nseeds = strtoull(argv[i] + 8, NULL, 0);
        else if (strncmp(argv[i], "--seed0=", 8) == 0) seed0 = strtoull(argv[i] + 8, NULL, 0);
        else if (strncmp(argv[i], "--class=", 8) == 0) {
            if (strcmp(argv[i] + 8, "all") == 0) target_cls = -1;
            else {
                target_cls = fuzz_class_from_name(argv[i] + 8);
                if (target_cls < 0) {
                    fprintf(stderr, "unknown class: %s\n", argv[i] + 8);
                    return 1;
                }
            }
        }
        else if (strncmp(argv[i], "--mmu=", 6) == 0) mmu_on = atoi(argv[i] + 6);
        else if (strncmp(argv[i], "--slow=", 7) == 0) slow_mem = atoi(argv[i] + 7);
        else if (strncmp(argv[i], "--aligned=", 10) == 0) gen_set_aligned(atoi(argv[i] + 10));
        else if (strncmp(argv[i], "--max-shrinks=", 14) == 0) max_shrinks = atoi(argv[i] + 14);
        else {
            fprintf(stderr, "usage: %s [--seeds=N] [--seed0=S] [--class=NAME|all] [--mmu=0|1] [--slow=0|1] [--max-shrinks=K]\n", argv[0]);
            return 1;
        }
    }

    if (henge_init(HV_TLB_PAGE_BITS, slow_mem, mmu_on) != 0) {
        fprintf(stderr, "henge_init failed\n");
        return 1;
    }
    if (ref_init() != 0) {
        fprintf(stderr, "ref_init failed\n");
        henge_cleanup();
        return 1;
    }

    printf("cpufuzz: HV_TLB_PAGE_BITS=%d (%dKB) mmu=%d slow_mem=%d seeds=%" PRIu64 " seed0=%" PRIu64 "\n",
           HV_TLB_PAGE_BITS, (1 << HV_TLB_PAGE_BITS) / 1024, mmu_on, slow_mem, nseeds, seed0);
    fflush(stdout);

    if (target_cls >= 0) {
        run_class((FuzzClass)target_cls, seed0, nseeds, max_shrinks);
    } else {
        for (int c = 0; c < FC_COUNT; c++) {
            run_class((FuzzClass)c, seed0, nseeds, max_shrinks);
        }
    }

    ref_cleanup();
    henge_cleanup();
    return 0;
}
