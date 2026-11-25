// Native execution trampoline for Apple Silicon.
// void ref_trampoline(FuzzState *st, void *jit_entry);

    .text
    .p2align 2
    .globl _ref_trampoline
    .globl _ref_return
    .globl _ref_cur_state
    .globl _ref_host_sp

_ref_trampoline:
    stp x29, x30, [sp, #-192]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    mrs x9, fpcr
    mrs x10, fpsr
    stp x9, x10, [sp, #160]
    str x18, [sp, #176]

    adrp x9, _ref_cur_state@PAGE
    add x9, x9, _ref_cur_state@PAGEOFF
    str x0, [x9]
    adrp x9, _ref_host_sp@PAGE
    add x9, x9, _ref_host_sp@PAGEOFF
    mov x10, sp
    str x10, [x9]

    mov x28, x0
    mov x15, x1

    // Load v0..v31 from [x28, #0x120]. Use x9 as base for v since 0x120+480 > 512 immediate range of ldp q.
    add x9, x28, #0x120
    ldp q0, q1, [x9, #0]
    ldp q2, q3, [x9, #32]
    ldp q4, q5, [x9, #64]
    ldp q6, q7, [x9, #96]
    ldp q8, q9, [x9, #128]
    ldp q10, q11, [x9, #160]
    ldp q12, q13, [x9, #192]
    ldp q14, q15, [x9, #224]
    ldp q16, q17, [x9, #256]
    ldp q18, q19, [x9, #288]
    ldp q20, q21, [x9, #320]
    ldp q22, q23, [x9, #352]
    ldp q24, q25, [x9, #384]
    ldp q26, q27, [x9, #416]
    ldp q28, q29, [x9, #448]
    ldp q30, q31, [x9, #480]

    ldr x0, [x28, #0x108]
    msr fpcr, x0
    ldr x0, [x28, #0x110]
    msr fpsr, x0
    ldr x0, [x28, #0x0f8]
    mov sp, x0
    ldr x0, [x28, #0x100]
    msr nzcv, x0

    // Load GPRs except x15 (target) and x28 (st). jit_entry loads x15 and x28.
    ldp x0, x1, [x28, #0]
    ldp x2, x3, [x28, #16]
    ldp x4, x5, [x28, #32]
    ldp x6, x7, [x28, #48]
    ldp x8, x9, [x28, #64]
    ldp x10, x11, [x28, #80]
    ldp x12, x13, [x28, #96]
    ldr x14, [x28, #112]
    ldp x16, x17, [x28, #128]
    ldp x18, x19, [x28, #144]
    ldp x20, x21, [x28, #160]
    ldp x22, x23, [x28, #176]
    ldp x24, x25, [x28, #192]
    ldp x26, x27, [x28, #208]
    ldp x29, x30, [x28, #232]

    br x15

_ref_return:
    adrp x9, _ref_host_sp@PAGE
    add x9, x9, _ref_host_sp@PAGEOFF
    ldr x10, [x9]
    mov sp, x10

    ldr x18, [sp, #176]
    ldp x9, x10, [sp, #160]
    msr fpcr, x9
    msr fpsr, x10
    ldp d14, d15, [sp, #144]
    ldp d12, d13, [sp, #128]
    ldp d10, d11, [sp, #112]
    ldp d8, d9, [sp, #96]
    ldp x27, x28, [sp, #80]
    ldp x25, x26, [sp, #64]
    ldp x23, x24, [sp, #48]
    ldp x21, x22, [sp, #32]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #192
    ret

    .data
    .p2align 3
_ref_cur_state:
    .quad 0
_ref_host_sp:
    .quad 0
