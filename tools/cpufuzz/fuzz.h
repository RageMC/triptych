#ifndef CPUFUZZ_H
#define CPUFUZZ_H

#include <setjmp.h>
#include <stdint.h>
#include <stddef.h>

#define SCRATCH_SIZE   65536u
#define STACK_SIZE     65536u
#define MAX_SEQ_INSNS  32u
#define MIN_SEQ_INSNS  8u

typedef enum {
    FC_ARITH_FLAGS = 0,
    FC_SHIFTS,
    FC_BITFIELD,
    FC_CSEL_CCMP,
    FC_MUL_DIV,
    FC_CRC32,
    FC_LDST,
    FC_LDST_PAIR,
    FC_EXCL_ATOMIC,
    FC_ORDERED,
    FC_SIMD_FP,
    FC_FP_CMP,
    FC_COUNT
} FuzzClass;

/* Layout matches ref_trampoline.S. */
typedef struct {
    uint64_t x[31];       /* 0x000 */
    uint64_t sp;          /* 0x0f8 */
    uint64_t nzcv;        /* 0x100 */
    uint64_t fpcr;        /* 0x108 */
    uint64_t fpsr;        /* 0x110 */
    uint64_t _pad;        /* 0x118 */
    __uint128_t v[32];    /* 0x120 */
    int fault_sig;        /* 0x320: 0 if no fault, else signal/fault */
    uint64_t fault_esr;   /* 0x328: Henge ESR_EL1 when faulted */
} FuzzState;

typedef struct {
    FuzzClass cls;
    uint32_t insns[MAX_SEQ_INSNS];
    uint32_t ninsns;
    /* Base registers used for scratch/stack accesses (preserved across sequence unless writeback). */
    int has_mem;
} FuzzSeq;

const char *fuzz_class_name(FuzzClass cls);
int fuzz_class_from_name(const char *name);

/* gen.c */
void gen_set_aligned(int aligned);
void gen_sequence(uint64_t seed, FuzzClass cls, const uint8_t *scratch_base, const uint8_t *stack_base,
                  FuzzSeq *seq, FuzzState *init_state, uint8_t *init_scratch, uint8_t *init_stack);

/* ref_run.c */
int ref_init(void);
void ref_cleanup(void);
void fuzz_sig_begin(sigjmp_buf *jb);
void fuzz_sig_end(void);
int fuzz_sig_caught(void);
/* Returns 0 on normal completion or expected fault (fault_sig set), 1 if host hit SIGILL (unsupported insn). */
int ref_run(const FuzzSeq *seq, const FuzzState *init, const uint8_t *init_scratch, const uint8_t *init_stack,
            FuzzState *out, uint8_t *out_scratch, uint8_t *out_stack);

/* henge_run.c */
int henge_init(int tlb_page_bits, int slow_mem, int mmu_on);
void henge_cleanup(void);
uint8_t *henge_scratch_ptr(void);
uint8_t *henge_stack_ptr(void);
int henge_run(uint64_t seed, const FuzzSeq *seq, const FuzzState *init, const uint8_t *init_scratch,
              const uint8_t *init_stack, FuzzState *out, uint8_t *out_scratch, uint8_t *out_stack);

#endif
