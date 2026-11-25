#include "fuzz.h"

#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

_Static_assert(offsetof(FuzzState, x) == 0x000, "x offset");
_Static_assert(offsetof(FuzzState, sp) == 0x0f8, "sp offset");
_Static_assert(offsetof(FuzzState, nzcv) == 0x100, "nzcv offset");
_Static_assert(offsetof(FuzzState, fpcr) == 0x108, "fpcr offset");
_Static_assert(offsetof(FuzzState, fpsr) == 0x110, "fpsr offset");
_Static_assert(offsetof(FuzzState, v) == 0x120, "v offset");

extern void ref_trampoline(FuzzState *st, void *jit_entry);
extern void ref_return(void);
extern FuzzState *ref_cur_state;

#define EPILOGUE_WORD 64

static uint32_t *jit_buf = NULL;
static size_t jit_bytes = 16384;
static sigjmp_buf sig_jb;
static sigjmp_buf * volatile active_jb = NULL;
static volatile sig_atomic_t sig_caught = 0;
static struct sigaction old_sa[5];
static const int caught_sigs[5] = {SIGILL, SIGBUS, SIGSEGV, SIGFPE, SIGTRAP};
static uint8_t *alt_stack_mem = NULL;
static stack_t old_ss;

void fuzz_sig_begin(sigjmp_buf *jb) {
    sig_caught = 0;
    active_jb = jb;
}

void fuzz_sig_end(void) {
    active_jb = NULL;
}

int fuzz_sig_caught(void) {
    return (int)sig_caught;
}

static void sig_handler(int sig) {
    sig_caught = sig;
    sigjmp_buf *jb = active_jb;
    if (jb) siglongjmp(*jb, 1);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void emit_epilogue(uint32_t *buf, uint32_t at) {
    uint32_t n = at;
    /* stp x0, x1, [sp, #-16]! */
    buf[n++] = 0xa9bf07e0u;
    /* ldr x0, lit_cur_state_ptr (patched below) */
    uint32_t fix_state = n;
    buf[n++] = 0x58000000u;
    /* ldr x0, [x0] */
    buf[n++] = 0xf9400000u;
    /* stp x2..x29 */
    for (uint32_t r = 2; r <= 28; r += 2) {
        uint32_t imm7 = (r * 8) / 8;
        buf[n++] = 0xa9000000u | (imm7 << 15) | ((r + 1) << 10) | (0 << 5) | r;
    }
    /* str x30, [x0, #240] */
    buf[n++] = 0xf9000000u | (240u / 8) << 10 | 0 << 5 | 30;
    /* mrs x2, nzcv; str x2, [x0, #0x100] */
    buf[n++] = 0xd53b4202u;
    buf[n++] = 0xf9000000u | (0x100u / 8) << 10 | 0 << 5 | 2;
    /* ldp x2, x3, [sp], #16; stp x2, x3, [x0, #0] */
    buf[n++] = 0xa8c10fe2u;
    buf[n++] = 0xa9000c02u;
    /* add x2, sp, #0; str x2, [x0, #0x0f8] */
    buf[n++] = 0x910003e2u;
    buf[n++] = 0xf9000000u | (0x0f8u / 8) << 10 | 0 << 5 | 2;
    /* mrs x2, fpcr; str x2, [x0, #0x108] */
    buf[n++] = 0xd53b4402u;
    buf[n++] = 0xf9000000u | (0x108u / 8) << 10 | 0 << 5 | 2;
    /* mrs x2, fpsr; str x2, [x0, #0x110] */
    buf[n++] = 0xd53b4422u;
    buf[n++] = 0xf9000000u | (0x110u / 8) << 10 | 0 << 5 | 2;
    /* add x9, x0, #0x120 */
    buf[n++] = 0x91048009u;
    /* stp q0..q31 */
    for (uint32_t q = 0; q < 32; q += 2) {
        uint32_t imm7 = (q * 16) / 16;
        buf[n++] = 0xad000000u | (imm7 << 15) | ((q + 1) << 10) | (9 << 5) | q;
    }
    /* ldr x1, lit_ref_return (patched below) */
    uint32_t fix_ret = n;
    buf[n++] = 0x58000001u;
    /* br x1 */
    buf[n++] = 0xd61f0020u;

    /* 8-byte align literal pool */
    if (n & 1) buf[n++] = 0xd503201fu;
    uint32_t pool0 = n;
    uint64_t state_ptr_addr = (uint64_t)(uintptr_t)&ref_cur_state;
    buf[n++] = (uint32_t)state_ptr_addr;
    buf[n++] = (uint32_t)(state_ptr_addr >> 32);
    uint32_t pool1 = n;
    uint64_t ret_addr = (uint64_t)(uintptr_t)ref_return;
    buf[n++] = (uint32_t)ret_addr;
    buf[n++] = (uint32_t)(ret_addr >> 32);

    buf[fix_state] |= (((pool0 - fix_state) & 0x7ffffu) << 5);
    buf[fix_ret] |= (((pool1 - fix_ret) & 0x7ffffu) << 5);
}

int ref_init(void) {
    jit_buf = mmap(NULL, jit_bytes, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (jit_buf == MAP_FAILED) {
        jit_buf = NULL;
        return -1;
    }
    pthread_jit_write_protect_np(0);
    jit_buf[0] = 0xf9403f8fu; /* ldr x15, [x28, #120] */
    jit_buf[1] = 0xf940739cu; /* ldr x28, [x28, #224] */
    emit_epilogue(jit_buf, EPILOGUE_WORD);
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(jit_buf, jit_bytes);

    alt_stack_mem = malloc(SIGSTKSZ);
    if (!alt_stack_mem) return -1;
    stack_t ss = {.ss_sp = alt_stack_mem, .ss_size = SIGSTKSZ, .ss_flags = 0};
    sigaltstack(&ss, &old_ss);

    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = sig_handler;
    sa.sa_flags = SA_NODEFER | SA_ONSTACK;
    for (int i = 0; i < 5; i++) sigaction(caught_sigs[i], &sa, &old_sa[i]);
    return 0;
}

void ref_cleanup(void) {
    for (int i = 0; i < 5; i++) sigaction(caught_sigs[i], &old_sa[i], NULL);
    sigaltstack(&old_ss, NULL);
    free(alt_stack_mem);
    alt_stack_mem = NULL;
    if (jit_buf) {
        munmap(jit_buf, jit_bytes);
        jit_buf = NULL;
    }
}

static int run_once(const FuzzState *init, const uint8_t *init_scratch, const uint8_t *init_stack,
                    FuzzState *out) {
    uint8_t *scratch = henge_scratch_ptr();
    uint8_t *stack = henge_stack_ptr();
    memcpy(scratch, init_scratch, SCRATCH_SIZE);
    memcpy(stack, init_stack, STACK_SIZE);
    *out = *init;
    out->fault_sig = 0;
    out->fault_esr = 0;

    fuzz_sig_begin(&sig_jb);
    if (sigsetjmp(sig_jb, 1) == 0) {
        ref_trampoline(out, jit_buf);
        fuzz_sig_end();
        return 0;
    } else {
        fuzz_sig_end();
        /* Restore host FPCR/FPSR in case guest modified them before faulting. */
        uint64_t zero = 0;
        __asm__ volatile("msr fpcr, %0\n\tmsr fpsr, %0" :: "r"(zero));
        out->fault_sig = (int)sig_caught;
        return (int)sig_caught;
    }
}

int ref_run(const FuzzSeq *seq, const FuzzState *init, const uint8_t *init_scratch, const uint8_t *init_stack,
            FuzzState *out, uint8_t *out_scratch, uint8_t *out_stack) {
    pthread_jit_write_protect_np(0);
    for (uint32_t i = 0; i < seq->ninsns; i++) jit_buf[2 + i] = seq->insns[i];
    int32_t off = (int32_t)EPILOGUE_WORD - (int32_t)(2 + seq->ninsns);
    jit_buf[2 + seq->ninsns] = 0x14000000u | ((uint32_t)off & 0x3ffffffu);
    pthread_jit_write_protect_np(1);
    sys_icache_invalidate(jit_buf + 2, (seq->ninsns + 1) * 4);

    FuzzState a, b;
    int s1 = run_once(init, init_scratch, init_stack, &a);
    if (s1 == SIGILL) return 1; /* host does not support an instruction in this sequence */
    if (s1 != 0) {
        *out = a;
        memcpy(out_scratch, henge_scratch_ptr(), SCRATCH_SIZE);
        memcpy(out_stack, henge_stack_ptr(), STACK_SIZE);
        return 0;
    }
    /* Darwin may clobber x18 on context switch, or an exclusive may spuriously fail once;
       retry until two runs agree on x18 (and all registers). */
    for (int tries = 0; tries < 8; tries++) {
        int s2 = run_once(init, init_scratch, init_stack, &b);
        if (s2 == SIGILL) return 1;
        if (s2 == 0 && memcmp(&a, &b, sizeof a) == 0) {
            *out = a;
            memcpy(out_scratch, henge_scratch_ptr(), SCRATCH_SIZE);
            memcpy(out_stack, henge_stack_ptr(), STACK_SIZE);
            return 0;
        }
        a = b;
    }
    *out = a;
    memcpy(out_scratch, henge_scratch_ptr(), SCRATCH_SIZE);
    memcpy(out_stack, henge_stack_ptr(), STACK_SIZE);
    return 0;
}
