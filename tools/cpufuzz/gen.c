#include "fuzz.h"

#include <string.h>

static const char *class_names[FC_COUNT] = {
    [FC_ARITH_FLAGS] = "arith_flags",
    [FC_SHIFTS]      = "shifts",
    [FC_BITFIELD]    = "bitfield",
    [FC_CSEL_CCMP]   = "csel_ccmp",
    [FC_MUL_DIV]     = "mul_div",
    [FC_CRC32]       = "crc32",
    [FC_LDST]        = "ldst",
    [FC_LDST_PAIR]   = "ldst_pair",
    [FC_EXCL_ATOMIC] = "excl_atomic",
    [FC_ORDERED]     = "ordered",
    [FC_SIMD_FP]     = "simd_fp",
    [FC_FP_CMP]      = "fp_cmp",
};

const char *fuzz_class_name(FuzzClass cls) {
    if (cls < 0 || cls >= FC_COUNT) return "unknown";
    return class_names[cls];
}

int fuzz_class_from_name(const char *name) {
    for (int i = 0; i < FC_COUNT; i++) {
        if (strcmp(name, class_names[i]) == 0) return i;
    }
    return -1;
}

typedef struct {
    uint64_t s;
} Rng;

static inline uint64_t rng_u64(Rng *r) {
    uint64_t z = (r->s += 0x9e3779b97f4a7c15ull);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ull;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebull;
    return z ^ (z >> 31);
}

static inline uint32_t rng_u32(Rng *r) {
    return (uint32_t)rng_u64(r);
}

static inline uint32_t rng_range(Rng *r, uint32_t lo, uint32_t hi) {
    return lo + (rng_u32(r) % (hi - lo + 1));
}

static inline int32_t rng_srange(Rng *r, int32_t lo, int32_t hi) {
    return lo + (int32_t)(rng_u32(r) % (uint32_t)(hi - lo + 1));
}

static uint64_t interesting_u64(Rng *r) {
    static const uint64_t vals[] = {
        0ull, 1ull, 2ull, 3ull, 4ull, 7ull, 8ull, 15ull, 16ull, 31ull, 32ull, 63ull, 64ull,
        0x7full, 0x80ull, 0xffull, 0x100ull, 0x7fffull, 0x8000ull, 0xffffull,
        0x7fffffffull, 0x80000000ull, 0x80000001ull, 0xffffffffull,
        0xffffffff00000000ull, 0xffffffff80000000ull, 0xffffffffffffffffull,
        0xfffffffffffffffeull, 0x7fffffffffffffffull, 0x8000000000000000ull,
        0x8000000000000001ull, 0x0123456789abcdefull, 0xfedcba9876543210ull,
        0x5555555555555555ull, 0xaaaaaaaaaaaaaaaaull, 0x0001000200030004ull,
    };
    if ((rng_u32(r) % 3) != 0) return rng_u64(r);
    return vals[rng_u32(r) % (sizeof vals / sizeof vals[0])];
}

static uint64_t interesting_fp64(Rng *r) {
    static const uint64_t dvals[] = {
        0x0000000000000000ull, /* +0.0 */
        0x8000000000000000ull, /* -0.0 */
        0x3ff0000000000000ull, /* +1.0 */
        0xbff0000000000000ull, /* -1.0 */
        0x3fe0000000000000ull, /* +0.5 */
        0xbfe0000000000000ull, /* -0.5 */
        0x4000000000000000ull, /* +2.0 */
        0x41e0000000000000ull, /* 2^31 */
        0xc1e0000000000000ull, /* -2^31 */
        0x43e0000000000000ull, /* 2^63 */
        0xc3e0000000000000ull, /* -2^63 */
        0x7ff0000000000000ull, /* +Inf */
        0xfff0000000000000ull, /* -Inf */
        0x7ff8000000000001ull, /* qNaN */
        0xfff8000000000002ull, /* -qNaN */
        0x7ff0000000000001ull, /* sNaN */
        0x0000000000000001ull, /* subnormal */
        0x8000000000000001ull, /* -subnormal */
        0x7fefffffffffffffull, /* DBL_MAX */
    };
    static const uint32_t svals[] = {
        0x00000000u, 0x80000000u, 0x3f800000u, 0xbf800000u,
        0x3f000000u, 0xbf000000u, 0x40000000u, 0x4f000000u,
        0xcf000000u, 0x5f000000u, 0xdf000000u, 0x7f800000u,
        0xff800000u, 0x7fc00001u, 0xffc00002u, 0x7f800001u,
        0x00000001u, 0x80000001u, 0x7f7fffffu,
    };
    static const uint16_t hvals[] = {
        0x0000u, 0x8000u, 0x3c00u, 0xbc00u, 0x3800u, 0xb800u,
        0x4000u, 0x7c00u, 0xfc00u, 0x7e01u, 0xfe02u, 0x7c01u,
        0x0001u, 0x8001u, 0x7bffu,
    };
    uint32_t k = rng_u32(r) % 10;
    if (k < 4) return rng_u64(r);
    if (k < 6) return dvals[rng_u32(r) % (sizeof dvals / sizeof dvals[0])];
    if (k < 8) {
        uint64_t lo = svals[rng_u32(r) % (sizeof svals / sizeof svals[0])];
        uint64_t hi = svals[rng_u32(r) % (sizeof svals / sizeof svals[0])];
        return lo | (hi << 32);
    }
    if (k == 8) {
        uint64_t v = 0;
        for (int i = 0; i < 4; i++) {
            v |= (uint64_t)hvals[rng_u32(r) % (sizeof hvals / sizeof hvals[0])] << (i * 16);
        }
        return v;
    }
    /* Small byte indices 0..63 for TBL/TBX testing */
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= (uint64_t)(rng_u32(r) & 63u) << (i * 8);
    return v;
}

/* Helper to pick registers.
 * For non-mem classes, all 0..30 (and optionally 31=ZR) are allowed.
 * For mem classes:
 *   base_regs: x20..x23
 *   idx_regs:  x24..x25
 *   data_regs: x0..x19 (plus x26..x30 if not conflicting)
 */
static uint32_t pick_gpr_all(Rng *r, int allow_zr) {
    uint32_t n = rng_u32(r) % (allow_zr ? 32u : 31u);
    return n;
}

static uint32_t pick_data_gpr(Rng *r, int allow_zr) {
    if (allow_zr && (rng_u32(r) % 12) == 0) return 31;
    uint32_t v = rng_u32(r) % 25;
    if (v < 20) return v;         /* x0..x19 */
    if (v == 20) return 23;       /* x23 (free when x28 is base) */
    if (v == 21) return 26;
    if (v == 22) return 27;
    return 29 + (v - 23);         /* x29..x30 */
}

static uint32_t pick_data_gpr_no31(Rng *r) {
    return pick_data_gpr(r, 0);
}

static uint32_t pick_base_gpr(Rng *r) {
    static const uint32_t bases[4] = {20, 21, 22, 28}; /* includes stolen x28! */
    return bases[rng_u32(r) & 3];
}

static void encode_bitmask_imm(Rng *r, uint32_t sf, uint32_t *N, uint32_t *immr, uint32_t *imms) {
    static const uint32_t esizes[6] = {2, 4, 8, 16, 32, 64};
    uint32_t max_idx = sf ? 5 : 4;
    uint32_t e = esizes[rng_u32(r) % (max_idx + 1)];
    uint32_t s = rng_u32(r) % (e - 1); /* 0 .. e-2 => 1 .. e-1 ones */
    uint32_t rot = rng_u32(r) % e;
    *immr = rot;
    if (e == 64) {
        *N = 1;
        *imms = s;
    } else {
        *N = 0;
        uint32_t prefix = (~((e << 1) - 1)) & 0x3fu;
        *imms = prefix | s;
    }
}

/* ---- Instruction generators per class ---- */

static uint32_t gen_arith_flags(Rng *r, int force_flags) {
    uint32_t kind = force_flags ? (rng_u32(r) % 6) : (rng_u32(r) % 8);
    uint32_t sf = rng_u32(r) & 1;
    switch (kind) {
    case 0: { /* Add/sub imm */
        uint32_t op = rng_u32(r) & 1;
        uint32_t S = force_flags ? 1 : (rng_u32(r) & 1);
        uint32_t sh = rng_u32(r) & 1;
        uint32_t imm12 = rng_u32(r) & 0xfffu;
        uint32_t rn = pick_gpr_all(r, 1); /* SP when S==0 or S==1 */
        uint32_t rd = S ? pick_gpr_all(r, 1) : pick_gpr_all(r, 0); /* never clobber SP */
        return 0x11000000u | (sf << 31) | (op << 30) | (S << 29) | (sh << 22) | (imm12 << 10) | (rn << 5) | rd;
    }
    case 1: { /* Add/sub shifted reg */
        uint32_t op = rng_u32(r) & 1;
        uint32_t S = force_flags ? 1 : (rng_u32(r) & 1);
        uint32_t shift = rng_u32(r) % 3; /* 0..2; 3 is UNDEF */
        uint32_t imm6 = rng_u32(r) % (sf ? 64u : 32u);
        uint32_t rm = pick_gpr_all(r, 1);
        uint32_t rn = pick_gpr_all(r, 1);
        uint32_t rd = pick_gpr_all(r, 1);
        return 0x0b000000u | (sf << 31) | (op << 30) | (S << 29) | (shift << 22) | (rm << 16) | (imm6 << 10) | (rn << 5) | rd;
    }
    case 2: { /* Add/sub extended reg */
        uint32_t op = rng_u32(r) & 1;
        uint32_t S = force_flags ? 1 : (rng_u32(r) & 1);
        uint32_t opt = rng_u32(r) & 7;
        uint32_t imm3 = rng_u32(r) % 5; /* 0..4 */
        uint32_t rm = pick_gpr_all(r, 1);
        uint32_t rn = pick_gpr_all(r, 1);
        uint32_t rd = S ? pick_gpr_all(r, 1) : pick_gpr_all(r, 0);
        return 0x0b200000u | (sf << 31) | (op << 30) | (S << 29) | (rm << 16) | (opt << 13) | (imm3 << 10) | (rn << 5) | rd;
    }
    case 3: { /* ADC/ADCS/SBC/SBCS */
        uint32_t op = rng_u32(r) & 1;
        uint32_t S = force_flags ? 1 : (rng_u32(r) & 1);
        uint32_t rm = pick_gpr_all(r, 1);
        uint32_t rn = pick_gpr_all(r, 1);
        uint32_t rd = pick_gpr_all(r, 1);
        return 0x1a000000u | (sf << 31) | (op << 30) | (S << 29) | (rm << 16) | (rn << 5) | rd;
    }
    case 4: { /* Logical shifted reg */
        uint32_t opc = force_flags ? 3u : (rng_u32(r) & 3u);
        uint32_t N = rng_u32(r) & 1;
        uint32_t shift = rng_u32(r) & 3;
        uint32_t imm6 = rng_u32(r) % (sf ? 64u : 32u);
        uint32_t rm = pick_gpr_all(r, 1);
        uint32_t rn = pick_gpr_all(r, 1);
        uint32_t rd = pick_gpr_all(r, 1);
        return 0x0a000000u | (sf << 31) | (opc << 29) | (shift << 22) | (N << 21) | (rm << 16) | (imm6 << 10) | (rn << 5) | rd;
    }
    case 5: { /* SETF8 / SETF16 / RMIF (FEAT_FlagM) */
        uint32_t rn = pick_gpr_all(r, 1);
        uint32_t sel = rng_u32(r) % 3;
        if (sel == 0) return 0x3a00080du | (rn << 5); /* SETF8 */
        if (sel == 1) return 0x3a00480du | (rn << 5); /* SETF16 */
        return 0xba000400u | ((rng_u32(r) & 63u) << 15) | (rn << 5) | (rng_u32(r) & 15u); /* RMIF */
    }
    case 6: { /* Logical imm */
        uint32_t opc = rng_u32(r) & 3;
        uint32_t N, immr, imms;
        encode_bitmask_imm(r, sf, &N, &immr, &imms);
        uint32_t rn = pick_gpr_all(r, 1);
        uint32_t rd = (opc == 3) ? pick_gpr_all(r, 1) : pick_gpr_all(r, 0);
        return 0x12000000u | (sf << 31) | (opc << 29) | (N << 22) | (immr << 16) | (imms << 10) | (rn << 5) | rd;
    }
    default: { /* MOVN / MOVZ / MOVK */
        static const uint32_t opcs[3] = {0, 2, 3};
        uint32_t opc = opcs[rng_u32(r) % 3];
        uint32_t hw = rng_u32(r) % (sf ? 4u : 2u);
        uint32_t imm16 = rng_u32(r) & 0xffffu;
        uint32_t rd = pick_gpr_all(r, 1);
        return 0x12800000u | (sf << 31) | (opc << 29) | (hw << 21) | (imm16 << 5) | rd;
    }
    }
}

static uint32_t gen_shifts(Rng *r) {
    uint32_t sf = rng_u32(r) & 1;
    uint32_t kind = rng_u32(r) % 4;
    switch (kind) {
    case 0: { /* LSLV, LSRV, ASRV, RORV */
        uint32_t op2 = rng_u32(r) & 3;
        uint32_t rm = pick_gpr_all(r, 1);
        uint32_t rn = pick_gpr_all(r, 1);
        uint32_t rd = pick_gpr_all(r, 1);
        return 0x1ac02000u | (sf << 31) | (rm << 16) | (op2 << 10) | (rn << 5) | rd;
    }
    case 1: { /* RBIT, REV16, REV32, REV, CLZ, CLS */
        static const uint32_t ops32[5] = {0, 1, 2, 4, 5};
        static const uint32_t ops64[6] = {0, 1, 2, 3, 4, 5};
        uint32_t opc = sf ? ops64[rng_u32(r) % 6] : ops32[rng_u32(r) % 5];
        uint32_t rn = pick_gpr_all(r, 1);
        uint32_t rd = pick_gpr_all(r, 1);
        return 0x5ac00000u | (sf << 31) | (opc << 10) | (rn << 5) | rd;
    }
    case 2: { /* EXTR */
        uint32_t imms = rng_u32(r) % (sf ? 64u : 32u);
        uint32_t rn = pick_gpr_all(r, 1);
        uint32_t rm = (rng_u32(r) & 1) ? rn : pick_gpr_all(r, 1); /* half are ROR */
        uint32_t rd = pick_gpr_all(r, 1);
        return 0x13800000u | (sf << 31) | (sf << 22) | (rm << 16) | (imms << 10) | (rn << 5) | rd;
    }
    default: { /* Logical shifted reg with shifts/rotates */
        uint32_t opc = rng_u32(r) & 3;
        uint32_t N = rng_u32(r) & 1;
        uint32_t shift = rng_u32(r) & 3;
        uint32_t imm6 = rng_u32(r) % (sf ? 64u : 32u);
        uint32_t rm = pick_gpr_all(r, 1);
        uint32_t rn = pick_gpr_all(r, 1);
        uint32_t rd = pick_gpr_all(r, 1);
        return 0x0a000000u | (sf << 31) | (opc << 29) | (shift << 22) | (N << 21) | (rm << 16) | (imm6 << 10) | (rn << 5) | rd;
    }
    }
}

static uint32_t gen_bitfield(Rng *r) {
    uint32_t sf = rng_u32(r) & 1;
    uint32_t opc = rng_u32(r) % 3; /* 0=SBFM, 1=BFM, 2=UBFM */
    uint32_t w = sf ? 64u : 32u;
    uint32_t immr = rng_u32(r) % w;
    uint32_t imms = rng_u32(r) % w;
    /* Bias toward common bitfield patterns too */
    uint32_t mode = rng_u32(r) % 4;
    if (mode == 0) {
        immr = 0;
        static const uint32_t edges[] = {0, 7, 15, 31, 63};
        imms = edges[rng_u32(r) % (sf ? 5 : 4)];
    } else if (mode == 1) {
        imms = w - 1;
    }
    uint32_t rn = pick_gpr_all(r, 1);
    uint32_t rd = pick_gpr_all(r, 1);
    return 0x13000000u | (sf << 31) | (opc << 29) | (sf << 22) | (immr << 16) | (imms << 10) | (rn << 5) | rd;
}

static uint32_t gen_csel_ccmp(Rng *r) {
    uint32_t k = rng_u32(r) % 10;
    if (k < 2) return gen_arith_flags(r, 1); /* mix flag setters */
    uint32_t sf = rng_u32(r) & 1;
    uint32_t cond = rng_u32(r) & 15;
    if (k < 7) { /* CSEL, CSINC, CSINV, CSNEG */
        uint32_t op = rng_u32(r) & 1;
        uint32_t o2 = rng_u32(r) & 1;
        uint32_t rm = pick_gpr_all(r, 1);
        uint32_t rn = pick_gpr_all(r, 1);
        uint32_t rd = pick_gpr_all(r, 1);
        return 0x1a800000u | (sf << 31) | (op << 30) | (rm << 16) | (cond << 12) | (o2 << 10) | (rn << 5) | rd;
    } else { /* CCMP / CCMN (reg or imm) */
        uint32_t op = rng_u32(r) & 1;
        uint32_t imm_bit = rng_u32(r) & 1;
        uint32_t rn = pick_gpr_all(r, 1);
        uint32_t rm_or_imm5 = imm_bit ? (rng_u32(r) & 31u) : pick_gpr_all(r, 1);
        uint32_t nzcv = rng_u32(r) & 15u;
        return 0x3a400000u | (sf << 31) | (op << 30) | (rm_or_imm5 << 16) | (cond << 12) | (imm_bit << 11) | (rn << 5) | nzcv;
    }
}

static uint32_t gen_mul_div(Rng *r) {
    uint32_t k = rng_u32(r) % 4;
    uint32_t sf = rng_u32(r) & 1;
    uint32_t rm = pick_gpr_all(r, 1);
    uint32_t rn = pick_gpr_all(r, 1);
    uint32_t rd = pick_gpr_all(r, 1);
    switch (k) {
    case 0: { /* MADD / MSUB */
        uint32_t o0 = rng_u32(r) & 1;
        uint32_t ra = (rng_u32(r) % 3 == 0) ? 31u : pick_gpr_all(r, 1);
        return 0x1b000000u | (sf << 31) | (rm << 16) | (o0 << 15) | (ra << 10) | (rn << 5) | rd;
    }
    case 1: { /* SMADDL / SMSUBL / UMADDL / UMSUBL */
        uint32_t U = rng_u32(r) & 1;
        uint32_t o0 = rng_u32(r) & 1;
        uint32_t ra = (rng_u32(r) % 3 == 0) ? 31u : pick_gpr_all(r, 1);
        return 0x9b200000u | (U << 23) | (rm << 16) | (o0 << 15) | (ra << 10) | (rn << 5) | rd;
    }
    case 2: { /* SMULH / UMULH */
        uint32_t U = rng_u32(r) & 1;
        return 0x9b407c00u | (U << 23) | (rm << 16) | (rn << 5) | rd;
    }
    default: { /* UDIV / SDIV */
        uint32_t S = rng_u32(r) & 1;
        return 0x1ac00800u | (sf << 31) | (rm << 16) | (S << 10) | (rn << 5) | rd;
    }
    }
}

static uint32_t gen_crc32(Rng *r) {
    uint32_t sz = rng_u32(r) & 3;
    uint32_t sf = (sz == 3) ? 1u : 0u;
    uint32_t C = rng_u32(r) & 1;
    uint32_t rm = pick_gpr_all(r, 1);
    uint32_t rn = pick_gpr_all(r, 1);
    uint32_t rd = pick_gpr_all(r, 1);
    return 0x1ac04000u | (sf << 31) | (rm << 16) | (C << 12) | (sz << 10) | (rn << 5) | rd;
}

static void pick_gpr_size_opc(Rng *r, uint32_t *size, uint32_t *opc) {
    static const uint8_t pairs[][2] = {
        {0, 0}, {0, 1}, {0, 2}, {0, 3},
        {1, 0}, {1, 1}, {1, 2}, {1, 3},
        {2, 0}, {2, 1}, {2, 2},
        {3, 0}, {3, 1},
    };
    uint32_t idx = rng_u32(r) % (sizeof pairs / sizeof pairs[0]);
    *size = pairs[idx][0];
    *opc = pairs[idx][1];
}

static uint32_t gen_ldst(Rng *r) {
    uint32_t rn = pick_base_gpr(r);
    uint32_t kind = rng_u32(r) % 10;

    if (kind < 5) {
        /* GPR load/store */
        uint32_t size, opc;
        pick_gpr_size_opc(r, &size, &opc);
        uint32_t rt = pick_data_gpr(r, 1);
        uint32_t sub = rng_u32(r) % 5;
        if (sub == 0) { /* unsigned imm12 */
            uint32_t uimm12 = rng_u32(r) % (256u >> size);
            return 0x39000000u | (size << 30) | (opc << 22) | (uimm12 << 10) | (rn << 5) | rt;
        } else if (sub == 1) { /* LDUR/STUR unscaled */
            int32_t simm9 = rng_srange(r, -64, 64);
            return 0x38000000u | (size << 30) | (opc << 22) | (((uint32_t)simm9 & 0x1ffu) << 12) | (0u << 10) | (rn << 5) | rt;
        } else if (sub == 2) { /* Pre/Post index (Rt != Rn guaranteed since rn=20..23, rt!=20..23) */
            int32_t simm9 = rng_srange(r, -32, 32);
            uint32_t mode = (rng_u32(r) & 1) ? 3u : 1u;
            return 0x38000000u | (size << 30) | (opc << 22) | (((uint32_t)simm9 & 0x1ffu) << 12) | (mode << 10) | (rn << 5) | rt;
        } else if (sub == 3) { /* LDTR/STTR unprivileged */
            int32_t simm9 = rng_srange(r, -64, 64);
            return 0x38000000u | (size << 30) | (opc << 22) | (((uint32_t)simm9 & 0x1ffu) << 12) | (2u << 10) | (rn << 5) | rt;
        } else { /* Register offset */
            static const uint32_t opts[4] = {2, 3, 6, 7};
            uint32_t opt = opts[rng_u32(r) & 3];
            uint32_t idx_reg = (opt == 2) ? 25u : (opt == 6 && (rng_u32(r) & 1)) ? 25u : 24u;
            uint32_t S = rng_u32(r) & 1;
            return 0x38200800u | (size << 30) | (opc << 22) | (idx_reg << 16) | (opt << 13) | (S << 12) | (rn << 5) | rt;
        }
    } else if (kind < 8) {
        /* SIMD/FP scalar B/H/S/D/Q load/store */
        uint32_t sz_sel = rng_u32(r) % 5; /* 0=B,1=H,2=S,3=D,4=Q */
        uint32_t is_load = rng_u32(r) & 1;
        uint32_t size = (sz_sel == 4) ? 0u : sz_sel;
        uint32_t opc = (sz_sel == 4) ? (2u + is_load) : is_load;
        uint32_t bytes = 1u << sz_sel;
        uint32_t vt = rng_u32(r) & 31u;
        uint32_t sub = rng_u32(r) % 4;
        if (sub == 0) {
            uint32_t uimm12 = rng_u32(r) % (256u / bytes);
            return 0x3d000000u | (size << 30) | (opc << 22) | (uimm12 << 10) | (rn << 5) | vt;
        } else if (sub == 1) {
            int32_t simm9 = rng_srange(r, -64, 64);
            return 0x3c000000u | (size << 30) | (opc << 22) | (((uint32_t)simm9 & 0x1ffu) << 12) | (0u << 10) | (rn << 5) | vt;
        } else if (sub == 2) {
            int32_t simm9 = rng_srange(r, -32, 32);
            uint32_t mode = (rng_u32(r) & 1) ? 3u : 1u;
            return 0x3c000000u | (size << 30) | (opc << 22) | (((uint32_t)simm9 & 0x1ffu) << 12) | (mode << 10) | (rn << 5) | vt;
        } else {
            static const uint32_t opts[4] = {2, 3, 6, 7};
            uint32_t opt = opts[rng_u32(r) & 3];
            uint32_t idx_reg = (opt == 2) ? 25u : (opt == 6 && (rng_u32(r) & 1)) ? 25u : 24u;
            uint32_t S = rng_u32(r) & 1;
            return 0x3c200800u | (size << 30) | (opc << 22) | (idx_reg << 16) | (opt << 13) | (S << 12) | (rn << 5) | vt;
        }
    } else {
        /* Advanced SIMD LD1/ST1/LD2/ST2/LD3/ST3/LD4/ST4 & LD1R */
        uint32_t vt = rng_u32(r) & 31u;
        uint32_t sub = rng_u32(r) % 3;
        if (sub == 0) {
            /* Multiple structures */
            static const uint32_t opcodes[7] = {0x7, 0xa, 0x6, 0x2, 0x8, 0x4, 0x0};
            uint32_t opcode = opcodes[rng_u32(r) % 7];
            uint32_t Q = rng_u32(r) & 1;
            uint32_t size = rng_u32(r) & 3;
            if (size == 3 && !Q && opcode != 0x7) Q = 1; /* 1D only valid for 1-reg LD1/ST1 */
            uint32_t L = rng_u32(r) & 1;
            uint32_t post = rng_u32(r) & 1;
            if (post) {
                return 0x0c800000u | (Q << 30) | (L << 22) | (31u << 16) | (opcode << 12) | (size << 10) | (rn << 5) | vt;
            } else {
                return 0x0c000000u | (Q << 30) | (L << 22) | (opcode << 12) | (size << 10) | (rn << 5) | vt;
            }
        } else if (sub == 1) {
            /* LD1R */
            uint32_t Q = rng_u32(r) & 1;
            uint32_t size = rng_u32(r) & 3;
            uint32_t post = rng_u32(r) & 1;
            return (post ? 0x0dc0c000u : 0x0d40c000u) | (Q << 30) | (post ? (31u << 16) : 0u) | (size << 10) | (rn << 5) | vt;
        } else {
            /* LD1 / ST1 single structure element: opcode=0(B),2(H),4(S),4(D with size=1) */
            uint32_t elem_sz = rng_u32(r) & 3;
            uint32_t L = rng_u32(r) & 1;
            uint32_t Q = 0, S = 0, size = 0, opc = 0;
            if (elem_sz == 0) { /* B: idx 0..15 */
                uint32_t idx = rng_u32(r) & 15u;
                Q = (idx >> 3) & 1; opc = 0; S = (idx >> 2) & 1; size = idx & 3;
            } else if (elem_sz == 1) { /* H: idx 0..7 */
                uint32_t idx = rng_u32(r) & 7u;
                Q = (idx >> 2) & 1; opc = 2; S = (idx >> 1) & 1; size = (idx & 1) << 1;
            } else if (elem_sz == 2) { /* S: idx 0..3 */
                uint32_t idx = rng_u32(r) & 3u;
                Q = (idx >> 1) & 1; opc = 4; S = idx & 1; size = 0;
            } else { /* D: idx 0..1 */
                uint32_t idx = rng_u32(r) & 1u;
                Q = idx; opc = 4; S = 0; size = 1;
            }
            return 0x0d000000u | (Q << 30) | (L << 22) | (opc << 13) | (S << 12) | (size << 10) | (rn << 5) | vt;
        }
    }
}

static uint32_t gen_ldst_pair(Rng *r) {
    uint32_t rn = pick_base_gpr(r);
    uint32_t is_simd = rng_u32(r) & 1;
    uint32_t L = rng_u32(r) & 1;
    uint32_t mode = rng_u32(r) & 3; /* 0=LDNP/STNP, 1=post, 2=offset, 3=pre */

    if (!is_simd) {
        static const uint32_t opcs[3] = {0, 1, 2};
        uint32_t opc = opcs[rng_u32(r) % 3];
        if (opc == 1) { /* LDPSW: L=1, mode in {1,2,3} */
            L = 1;
            if (mode == 0) mode = 2;
        }
        uint32_t rt = pick_data_gpr(r, 1);
        uint32_t rt2 = pick_data_gpr(r, 1);
        if (L && rt == rt2) rt2 = (rt + 1) % 20;
        int32_t imm7 = rng_srange(r, -8, 7);
        return 0x28000000u | (opc << 30) | (mode << 23) | (L << 22) | (((uint32_t)imm7 & 0x7fu) << 15) | (rt2 << 10) | (rn << 5) | rt;
    } else {
        uint32_t opc = rng_u32(r) % 3; /* 0=S, 1=D, 2=Q */
        uint32_t rt = rng_u32(r) & 31u;
        uint32_t rt2 = rng_u32(r) & 31u;
        if (L && rt == rt2) rt2 = (rt + 1) & 31u;
        int32_t imm7 = rng_srange(r, -4, 3);
        return 0x2c000000u | (opc << 30) | (mode << 23) | (L << 22) | (((uint32_t)imm7 & 0x7fu) << 15) | (rt2 << 10) | (rn << 5) | rt;
    }
}

static int opt_aligned_mem = 0;

void gen_set_aligned(int aligned) {
    opt_aligned_mem = aligned ? 1 : 0;
}

static void gen_excl_atomic_seq(Rng *r, FuzzSeq *seq, uint32_t n) {
    /* For exclusives, keep x20 (and x28 when aligned) 16B aligned. */
    while (seq->ninsns < n) {
        uint32_t rem = n - seq->ninsns;
        uint32_t k = rng_u32(r) % 7;
        uint32_t rn = pick_base_gpr(r);

        if (k == 0 && rem >= 2) {
            /* Matched LDXR/LDAXR -> (optional ALU) -> STXR/STLXR on aligned x20 or x28 */
            uint32_t excl_rn = (opt_aligned_mem && (rng_u32(r) & 1)) ? 28u : 20u;
            uint32_t sz = rng_u32(r) & 3;
            uint32_t o0_ld = rng_u32(r) & 1;
            uint32_t o0_st = rng_u32(r) & 1;
            uint32_t rt_ld = pick_data_gpr_no31(r);
            uint32_t rt_st = pick_data_gpr(r, 1);
            uint32_t rs = pick_data_gpr_no31(r);
            if (rs == rt_st) rs = (rt_st + 1) % 20;
            seq->insns[seq->ninsns++] = 0x085f7c00u | (sz << 30) | (o0_ld << 15) | (excl_rn << 5) | rt_ld;
            if (rem >= 3 && (rng_u32(r) & 1)) {
                uint32_t imm = rng_u32(r) & 0xfffu;
                if (rt_st != 31)
                    seq->insns[seq->ninsns++] = 0x91000000u | (imm << 10) | (rt_ld << 5) | rt_st;
            }
            seq->insns[seq->ninsns++] = 0x08007c00u | (sz << 30) | (rs << 16) | (o0_st << 15) | (excl_rn << 5) | rt_st;
        } else if (k == 1 && rem >= 2) {
            /* Matched LDXP/LDAXP -> STXP/STLXP */
            uint32_t excl_rn = (opt_aligned_mem && (rng_u32(r) & 1)) ? 28u : 20u;
            uint32_t sz = rng_u32(r) & 1; /* 0=W, 1=X */
            uint32_t o0_ld = rng_u32(r) & 1;
            uint32_t o0_st = rng_u32(r) & 1;
            uint32_t rt = pick_data_gpr_no31(r);
            uint32_t rt2 = (rt + 1) % 20;
            uint32_t rs = (rt + 2) % 20;
            seq->insns[seq->ninsns++] = 0x887f0000u | (sz << 30) | (o0_ld << 15) | (rt2 << 10) | (excl_rn << 5) | rt;
            seq->insns[seq->ninsns++] = 0x88200000u | (sz << 30) | (rs << 16) | (o0_st << 15) | (rt2 << 10) | (excl_rn << 5) | rt;
        } else if (k == 2) {
            /* Standalone STXR (clear monitor first with CLREX so deterministic!) or CLREX */
            if (rem >= 2 && (rng_u32(r) & 1)) {
                seq->insns[seq->ninsns++] = 0xd5033f5fu; /* CLREX */
                uint32_t sz = rng_u32(r) & 3;
                uint32_t rt = pick_data_gpr(r, 1);
                uint32_t rs = pick_data_gpr_no31(r);
                if (rs == rt) rs = (rt + 1) % 20;
                seq->insns[seq->ninsns++] = 0x08007c00u | (sz << 30) | (rs << 16) | (0u << 15) | (20u << 5) | rt;
            } else {
                seq->insns[seq->ninsns++] = 0xd503305fu | ((rng_u32(r) & 15u) << 8); /* CLREX #imm */
            }
        } else if (k == 3) {
            /* CAS / CASA / CASAL / CASL */
            uint32_t sz = rng_u32(r) & 3;
            uint32_t L = rng_u32(r) & 1;
            uint32_t o0 = rng_u32(r) & 1;
            uint32_t rs = pick_data_gpr(r, 1);
            uint32_t rt = pick_data_gpr(r, 1);
            seq->insns[seq->ninsns++] = 0x08a07c00u | (sz << 30) | (L << 22) | (rs << 16) | (o0 << 15) | (rn << 5) | rt;
        } else if (k == 4) {
            /* CASP / CASPA / CASPAL / CASPL (include stolen x18/x19; avoid x28 since x28 is a base reg!) */
            static const uint32_t evens[10] = {0, 2, 4, 6, 8, 10, 12, 14, 16, 18};
            uint32_t sz = rng_u32(r) & 1; /* 0=W, 1=X */
            uint32_t L = rng_u32(r) & 1;
            uint32_t o0 = rng_u32(r) & 1;
            uint32_t cas_rn = (opt_aligned_mem || (rng_u32(r) % 4 != 0)) ? 20u : rn;
            uint32_t rs = evens[rng_u32(r) % 10];
            uint32_t rt = evens[rng_u32(r) % 10];
            if (rs == rt) rt = evens[(rng_u32(r) % 9 + 1) % 10];
            if (rs == rt) rt = (rs == 0) ? 2 : 0;
            seq->insns[seq->ninsns++] = 0x08207c00u | (sz << 30) | (L << 22) | (rs << 16) | (o0 << 15) | (cas_rn << 5) | rt;
        } else if (k == 5) {
            /* SWP / SWPA / SWPAL / SWPL */
            uint32_t sz = rng_u32(r) & 3;
            uint32_t A = rng_u32(r) & 1;
            uint32_t R = rng_u32(r) & 1;
            uint32_t rs = pick_data_gpr(r, 1);
            uint32_t rt = pick_data_gpr(r, 1);
            seq->insns[seq->ninsns++] = 0x38208000u | (sz << 30) | (A << 23) | (R << 22) | (rs << 16) | (rn << 5) | rt;
        } else {
            /* LDADD / LDCLR / LDEOR / LDSET / LDSMAX / LDSMIN / LDUMAX / LDUMIN (+ ST* when Rt=31 && A=0) */
            uint32_t sz = rng_u32(r) & 3;
            uint32_t opc = rng_u32(r) & 7;
            uint32_t A = rng_u32(r) & 1;
            uint32_t R = rng_u32(r) & 1;
            uint32_t rs = pick_data_gpr(r, 1);
            uint32_t rt = (A == 0 && (rng_u32(r) % 5 == 0)) ? 31u : pick_data_gpr_no31(r);
            seq->insns[seq->ninsns++] = 0x38200000u | (sz << 30) | (A << 23) | (R << 22) | (rs << 16) | (opc << 12) | (rn << 5) | rt;
        }
    }
}

static uint32_t gen_ordered(Rng *r) {
    uint32_t rn = pick_base_gpr(r);
    uint32_t rt = pick_data_gpr(r, 1);
    uint32_t sz = rng_u32(r) & 3;
    uint32_t k = rng_u32(r) % 5;
    switch (k) {
    case 0: /* STLRB/H/W/X */
        return 0x089ffc00u | (sz << 30) | (rn << 5) | rt;
    case 1: /* LDARB/H/W/X */
        return 0x08dffc00u | (sz << 30) | (rn << 5) | rt;
    case 2: /* LDAPRB/H/W/X */
        return 0x38bfc000u | (sz << 30) | (rn << 5) | rt;
    case 3: { /* STLUR / LDAPUR (ARMv8.4-RCPC2) */
        if (opt_aligned_mem) {
            /* Keep STLUR/LDAPUR aligned too when testing aligned semantics */
            int32_t simm9 = rng_srange(r, -2, 2) * 16;
            uint32_t opc = rng_u32(r) & 1;
            return 0x19000000u | (sz << 30) | (opc << 22) | (((uint32_t)simm9 & 0x1ffu) << 12) | (rn << 5) | rt;
        }
        int32_t simm9 = rng_srange(r, -32, 32);
        uint32_t opc = rng_u32(r) & 1; /* 0=STLUR, 1=LDAPUR */
        return 0x19000000u | (sz << 30) | (opc << 22) | (((uint32_t)simm9 & 0x1ffu) << 12) | (rn << 5) | rt;
    }
    default: { /* LDAPURSB/H/W (opc=2 for 64-bit, opc=3 for 32-bit; sz=2 only opc=2) */
        int32_t simm9 = opt_aligned_mem ? (rng_srange(r, -2, 2) * 16) : rng_srange(r, -32, 32);
        uint32_t s_sz = rng_u32(r) % 3;
        uint32_t opc = (s_sz == 2) ? 2u : (2u + (rng_u32(r) & 1));
        return 0x19000000u | (s_sz << 30) | (opc << 22) | (((uint32_t)simm9 & 0x1ffu) << 12) | (rn << 5) | rt;
    }
    }
}

static uint32_t gen_simd_fp(Rng *r) {
    uint32_t vn = rng_u32(r) & 31u;
    uint32_t vm = rng_u32(r) & 31u;
    uint32_t va = rng_u32(r) & 31u;
    uint32_t vd = rng_u32(r) & 31u;
    uint32_t kind = rng_u32(r) % 16;

    switch (kind) {
    case 0: { /* Scalar FP 2-source (FMUL, FDIV, FADD, FSUB, FMAX, FMIN, FMAXNM, FMINNM, FNMUL) */
        static const uint32_t ftypes[3] = {0, 1, 3}; /* S, D, H */
        uint32_t ftype = ftypes[rng_u32(r) % 3];
        uint32_t op = rng_u32(r) % 9;
        return 0x1e200800u | (ftype << 22) | (vm << 16) | (op << 12) | (vn << 5) | vd;
    }
    case 1: { /* Scalar FP 3-source (FMADD, FMSUB, FNMADD, FNMSUB) */
        static const uint32_t ftypes[3] = {0, 1, 3};
        uint32_t ftype = ftypes[rng_u32(r) % 3];
        uint32_t o1 = rng_u32(r) & 1;
        uint32_t o0 = rng_u32(r) & 1;
        return 0x1f000000u | (ftype << 22) | (o1 << 21) | (vm << 16) | (o0 << 15) | (va << 10) | (vn << 5) | vd;
    }
    case 2: { /* Scalar FP 1-source & FCVT */
        static const uint32_t ftypes[3] = {0, 1, 3};
        uint32_t ftype = ftypes[rng_u32(r) % 3];
        if (rng_u32(r) % 4 == 0) {
            uint32_t dst = ftypes[rng_u32(r) % 3];
            if (dst == ftype) dst = (ftype == 0) ? 1 : 0;
            return 0x1e224000u | (ftype << 22) | (dst << 15) | (vn << 5) | vd; /* FCVT */
        } else {
            static const uint32_t ops[12] = {0, 1, 2, 3, 8, 9, 10, 11, 12, 14, 15};
            uint32_t op = ops[rng_u32(r) % 11];
            return 0x1e204000u | (ftype << 22) | (op << 15) | (vn << 5) | vd;
        }
    }
    case 3: { /* Scalar FP <-> Int conversions & FMOV */
        static const uint32_t ftypes[3] = {0, 1, 3};
        uint32_t ftype = ftypes[rng_u32(r) % 3];
        uint32_t sf = rng_u32(r) & 1;
        uint32_t sub = rng_u32(r) % 3;
        if (sub == 0) { /* FCVT{N,P,M,Z,A}{S,U} Vn -> Rd, or FJCVTZS */
            if (ftype == 1 && (rng_u32(r) % 8) == 0) {
                uint32_t rd = pick_gpr_all(r, 1);
                return 0x1e7e0000u | (vn << 5) | rd; /* FJCVTZS Wd, Dn */
            }
            uint32_t is_a = (rng_u32(r) % 5 == 0);
            uint32_t rmode = is_a ? 0u : (rng_u32(r) & 3u);
            uint32_t u = rng_u32(r) & 1;
            uint32_t opc = is_a ? (4u + u) : u;
            uint32_t rd = pick_gpr_all(r, 1);
            return 0x1e200000u | (sf << 31) | (ftype << 22) | (rmode << 19) | (opc << 16) | (vn << 5) | rd;
        } else if (sub == 1) { /* SCVTF / UCVTF Rn -> Vd (int or fixed-point) */
            uint32_t opc = 2u + (rng_u32(r) & 1);
            uint32_t rn = pick_gpr_all(r, 1);
            if (ftype != 3 && (rng_u32(r) % 3) == 0) {
                /* Fixed-point SCVTF/UCVTF: 0x1e000000 | (sf<<31) | (ftype<<22) | (opc<<16) | (scale<<10) */
                uint32_t scale = sf ? rng_range(r, 1, 64) : rng_range(r, 33, 64);
                return 0x1e000000u | (sf << 31) | (ftype << 22) | (opc << 16) | ((scale & 63u) << 10) | (rn << 5) | vd;
            }
            return 0x1e200000u | (sf << 31) | (ftype << 22) | (opc << 16) | (rn << 5) | vd;
        } else { /* FMOV GPR <-> FPR (including D[1] top 64 bits!) */
            uint32_t to_gpr = rng_u32(r) & 1;
            uint32_t rmode = 0, opc = to_gpr ? 6u : 7u, ft = sf ? 1u : 0u, gpr_sf = sf;
            if (rng_u32(r) % 3 == 0) { /* D[1] <-> Xn */
                rmode = 1; ft = 2; gpr_sf = 1;
            } else if (ftype == 3) { /* H <-> Wn/Xn */
                ft = 3;
            }
            if (to_gpr) {
                uint32_t rd = pick_gpr_all(r, 1);
                return 0x1e200000u | (gpr_sf << 31) | (ft << 22) | (rmode << 19) | (opc << 16) | (vn << 5) | rd;
            } else {
                uint32_t rn = pick_gpr_all(r, 1);
                return 0x1e200000u | (gpr_sf << 31) | (ft << 22) | (rmode << 19) | (opc << 16) | (rn << 5) | vd;
            }
        }
    }
    case 4: { /* FCSEL */
        static const uint32_t ftypes[3] = {0, 1, 3};
        uint32_t ftype = ftypes[rng_u32(r) % 3];
        uint32_t cond = rng_u32(r) & 15;
        return 0x1e200c00u | (ftype << 22) | (vm << 16) | (cond << 12) | (vn << 5) | vd;
    }
    case 5: { /* Vector 3-same integer & logical */
        uint32_t Q = rng_u32(r) & 1;
        uint32_t size = rng_u32(r) & 3;
        uint32_t sub = rng_u32(r) % 10;
        if (sub < 3) { /* Logical AND/BIC/ORR/ORN/EOR/BSL/BIT/BIF (size encodes op, U=0/1) */
            uint32_t U = rng_u32(r) & 1;
            return 0x0e201c00u | (Q << 30) | (U << 29) | (size << 22) | (vm << 16) | (vn << 5) | vd;
        } else {
            static const struct { uint8_t U, opc; } ops[] = {
                {0, 0x10}, /* ADD */   {1, 0x10}, /* SUB */
                {0, 0x13}, /* MUL */   {0, 0x12}, /* MLA */   {1, 0x12}, /* MLS */
                {0, 0x0c}, /* SMAX */  {1, 0x0c}, /* UMAX */
                {0, 0x0d}, /* SMIN */  {1, 0x0d}, /* UMIN */
                {0, 0x0e}, /* SABD */  {1, 0x0e}, /* UABD */
                {0, 0x0f}, /* SABA */  {1, 0x0f}, /* UABA */
                {1, 0x11}, /* CMEQ */  {0, 0x06}, /* CMGT */  {0, 0x07}, /* CMGE */
                {1, 0x06}, /* CMHI */  {1, 0x07}, /* CMHS */  {0, 0x11}, /* CMTST */
                {0, 0x01}, /* SQADD */ {1, 0x01}, /* UQADD */
                {0, 0x05}, /* SQSUB */ {1, 0x05}, /* UQSUB */
                {0, 0x16}, /* SQDMULH */ {1, 0x16}, /* SQRDMULH */
                {0, 0x08}, /* SSHL */  {1, 0x08}, /* USHL */
                {0, 0x0a}, /* SRSHL */ {1, 0x0a}, /* URSHL */
                {0, 0x09}, /* SQSHL */ {1, 0x09}, /* UQSHL */
                {0, 0x0b}, /* SQRSHL */{1, 0x0b}, /* UQRSHL */
                {0, 0x17}, /* ADDP */
            };
            uint32_t idx = rng_u32(r) % (sizeof ops / sizeof ops[0]);
            uint32_t opc = ops[idx].opc;
            uint32_t U = ops[idx].U;
            if (size == 3 && (opc == 0x13 || opc == 0x12 || opc == 0x16 ||
                              opc == 0x0c || opc == 0x0d || opc == 0x0e || opc == 0x0f)) {
                size = 2; /* MUL/MLA/MLS/SQDMULH/SMAX/UMAX/SMIN/UMIN/SABD/UABD/SABA/UABA have no .2D */
            }
            if (size == 3 && !Q) Q = 1; /* 64-bit elem ops require Q=1 */
            return 0x0e200400u | (Q << 30) | (U << 29) | (size << 22) | (vm << 16) | (opc << 11) | (vn << 5) | vd;
        }
    }
    case 6: { /* Vector TBL / TBX */
        uint32_t Q = rng_u32(r) & 1;
        uint32_t len = rng_u32(r) & 3; /* 0..3 => 1..4 regs */
        uint32_t op = rng_u32(r) & 1;  /* 0=TBL, 1=TBX */
        return 0x0e000000u | (Q << 30) | (vm << 16) | (len << 13) | (op << 12) | (vn << 5) | vd;
    }
    case 7: { /* Vector EXT & Permutes (ZIP1, ZIP2, UZP1, UZP2, TRN1, TRN2) */
        uint32_t Q = rng_u32(r) & 1;
        if (rng_u32(r) & 1) {
            uint32_t imm4 = rng_u32(r) % (Q ? 16u : 8u);
            return 0x2e000000u | (Q << 30) | (vm << 16) | (imm4 << 11) | (vn << 5) | vd; /* EXT */
        } else {
            static const uint32_t popc[6] = {1, 2, 3, 5, 6, 7}; /* UZP1,TRN1,ZIP1,UZP2,TRN2,ZIP2 */
            uint32_t opc = popc[rng_u32(r) % 6];
            uint32_t size = rng_u32(r) % (Q ? 4u : 3u);
            return 0x0e001800u | (Q << 30) | (size << 22) | (vm << 16) | (opc << 12) | (vn << 5) | vd;
        }
    }
    case 8: { /* Vector Copy: DUP (elem/GPR), INS (elem/GPR), UMOV, SMOV */
        uint32_t Q = rng_u32(r) & 1;
        uint32_t sub = rng_u32(r) % 4;
        uint32_t esz = rng_u32(r) % (Q ? 4u : 3u);
        uint32_t idx = rng_u32(r) % (16u >> esz);
        uint32_t imm5 = ((idx << 1) | 1u) << esz;
        if (sub == 0) { /* DUP Vd, Vn[idx] */
            return 0x0e000400u | (Q << 30) | (imm5 << 16) | (vn << 5) | vd;
        } else if (sub == 1) { /* DUP Vd, Rn */
            uint32_t rn = pick_gpr_all(r, 1);
            imm5 = 1u << esz;
            return 0x0e000c00u | (Q << 30) | (imm5 << 16) | (rn << 5) | vd;
        } else if (sub == 2) { /* INS Vd[idx], Rn or INS Vd[idx], Vn[idx2] */
            uint32_t esz2 = rng_u32(r) & 3;
            uint32_t idx_d = rng_u32(r) % (16u >> esz2);
            uint32_t imm5_d = ((idx_d << 1) | 1u) << esz2;
            if (rng_u32(r) & 1) {
                uint32_t rn = pick_gpr_all(r, 1);
                return 0x4e001c00u | (imm5_d << 16) | (rn << 5) | vd;
            } else {
                uint32_t idx_s = rng_u32(r) % (16u >> esz2);
                uint32_t imm4 = idx_s << esz2;
                return 0x6e000400u | (imm5_d << 16) | (imm4 << 11) | (vn << 5) | vd;
            }
        } else { /* UMOV (0x0e003c00) / SMOV (0x0e002c00) */
            uint32_t esz2 = rng_u32(r) & 3;
            uint32_t is_smov = (esz2 < 3) && (rng_u32(r) & 1);
            uint32_t qbit = (esz2 == 3 || (is_smov && (esz2 == 2 || (rng_u32(r) & 1)))) ? 1u : 0u;
            uint32_t idx_s = rng_u32(r) % (16u >> esz2);
            uint32_t imm5_s = ((idx_s << 1) | 1u) << esz2;
            uint32_t rd = pick_gpr_all(r, 1);
            uint32_t base_op = is_smov ? 0x0e002c00u : 0x0e003c00u;
            return base_op | (qbit << 30) | (imm5_s << 16) | (vn << 5) | rd;
        }
    }
    case 9: { /* Vector 2-reg misc (REV64/32/16, CNT, CLS, CLZ, NOT, ABS, NEG, SQABS, SQNEG, FABS, FNEG, FSQRT, FRINT*, FCVTZS/U, SCVTF/UCVTF) */
        uint32_t Q = rng_u32(r) & 1;
        uint32_t sub = rng_u32(r) % 3;
        if (sub == 0) { /* REV64/32/16, CNT, NOT, RBIT */
            uint32_t op = rng_u32(r) % 5;
            if (op == 0) return 0x0e200800u | (Q << 30) | ((rng_u32(r) % 3) << 22) | (vn << 5) | vd; /* REV64 */
            if (op == 1) return 0x2e200800u | (Q << 30) | ((rng_u32(r) & 1) << 22) | (vn << 5) | vd; /* REV32 */
            if (op == 2) return 0x0e201800u | (Q << 30) | (vn << 5) | vd; /* REV16 (.8B/.16B) */
            if (op == 3) return 0x0e205800u | (Q << 30) | (vn << 5) | vd; /* CNT */
            return 0x2e205800u | (Q << 30) | (vn << 5) | vd; /* NOT / RBIT */
        } else if (sub == 1) { /* CLS, CLZ, ABS, NEG, SQABS, SQNEG */
            uint32_t size = rng_u32(r) & 3;
            uint32_t op = rng_u32(r) % 6;
            if (op < 2) { /* CLS(U=0), CLZ(U=1), no 64-bit */
                if (size == 3) size = 2;
                return 0x0e204800u | (Q << 30) | (op << 29) | (size << 22) | (vn << 5) | vd;
            } else if (op < 4) { /* ABS(U=0), NEG(U=1) */
                if (size == 3 && !Q) Q = 1;
                return 0x0e20b800u | (Q << 30) | ((op - 2) << 29) | (size << 22) | (vn << 5) | vd;
            } else { /* SQABS(U=0), SQNEG(U=1) */
                if (size == 3 && !Q) Q = 1;
                return 0x0e207800u | (Q << 30) | ((op - 4) << 29) | (size << 22) | (vn << 5) | vd;
            }
        } else { /* Vector FP 2-reg misc: FABS, FNEG, FSQRT, FRINT*, FCVTZS/U, SCVTF/UCVTF */
            uint32_t sz = rng_u32(r) & 1; /* 0=S, 1=D */
            if (sz == 1 && !Q) Q = 1;
            uint32_t op = rng_u32(r) % 8;
            if (op == 0) return 0x0ea0f800u | (Q << 30) | (sz << 22) | (vn << 5) | vd; /* FABS */
            if (op == 1) return 0x2ea0f800u | (Q << 30) | (sz << 22) | (vn << 5) | vd; /* FNEG */
            if (op == 2) return 0x2ea1f800u | (Q << 30) | (sz << 22) | (vn << 5) | vd; /* FSQRT */
            if (op == 3) return 0x0e219800u | (Q << 30) | ((rng_u32(r) & 1) << 29) | (sz << 22) | (vn << 5) | vd; /* FRINTN/P */
            if (op == 4) return 0x0ea19800u | (Q << 30) | ((rng_u32(r) & 1) << 29) | (sz << 22) | (vn << 5) | vd; /* FRINTM/Z */
            if (op == 5) return 0x2e218800u | (Q << 30) | (sz << 22) | (vn << 5) | vd; /* FRINTA */
            if (op == 6) return 0x0ea1b800u | (Q << 30) | ((rng_u32(r) & 1) << 29) | (sz << 22) | (vn << 5) | vd; /* FCVTZS/U */
            return 0x0e21d800u | (Q << 30) | ((rng_u32(r) & 1) << 29) | (sz << 22) | (vn << 5) | vd; /* SCVTF/UCVTF */
        }
    }
    case 10: { /* Vector widening / narrowing (SADDL, UADDL, SSUBL, USUBL, SMULL, UMULL, XTN, SQXTN, UQXTN, SQXTUN) */
        uint32_t Q = rng_u32(r) & 1;
        uint32_t size = rng_u32(r) % 3; /* 0..2 => B->H, H->S, S->D */
        if (rng_u32(r) & 1) {
            /* Widening 3-diff: SADDL(0), SADDW(1), SSUBL(2), SSUBW(3), SMLAL(8), SMLSL(10), SMULL(12), SQDMULL(13,size>0) + U bit */
            static const uint32_t opcs[8] = {0x0, 0x1, 0x2, 0x3, 0x8, 0xa, 0xc, 0xd};
            uint32_t opc = opcs[rng_u32(r) % 8];
            uint32_t U = (opc == 0xd) ? 0u : (rng_u32(r) & 1);
            if (opc == 0xd && size == 0) size = 1; /* SQDMULL has H->S and S->D only */
            return 0x0e200000u | (Q << 30) | (U << 29) | (size << 22) | (vm << 16) | (opc << 12) | (vn << 5) | vd;
        } else {
            /* Narrowing 2-reg: XTN(U=0,op=0x12), SQXTUN(U=1,op=0x12), SQXTN(U=0,op=0x14), UQXTN(U=1,op=0x14) */
            uint32_t U = rng_u32(r) & 1;
            uint32_t op = (rng_u32(r) & 1) ? 0x12u : 0x14u;
            return 0x0e200800u | (Q << 30) | (U << 29) | (size << 22) | (op << 12) | (vn << 5) | vd;
        }
    }
    case 11: { /* Vector shift by imm (SSHR, USHR, SRSHR, URSHR, SHL, SLI, SRI) */
        uint32_t Q = rng_u32(r) & 1;
        uint32_t esz = rng_u32(r) & 3;
        if (esz == 3 && !Q) Q = 1;
        uint32_t width = 8u << esz;
        uint32_t is_left = rng_u32(r) & 1;
        uint32_t sh = is_left ? (rng_u32(r) % width) : rng_range(r, 1, width);
        uint32_t immh = (1u << esz) | (is_left ? (sh >> 3) : ((width - sh) >> 3));
        uint32_t immb = is_left ? (sh & 7u) : ((width - sh) & 7u);
        if (is_left) {
            uint32_t U = rng_u32(r) & 1;
            uint32_t op = 0xau; /* SHL(U=0,0xa) or SLI(U=1,0xa) */
            return 0x0f000400u | (Q << 30) | (U << 29) | (immh << 19) | (immb << 16) | (op << 11) | (vn << 5) | vd;
        } else {
            uint32_t U = rng_u32(r) & 1;
            static const uint32_t rops[3] = {0x0, 0x4, 0x8}; /* SSHR/USHR(0), SRSHR/URSHR(4), SRI(8,U=1) */
            uint32_t op = rops[rng_u32(r) % 3];
            if (op == 0x8) U = 1;
            return 0x0f000400u | (Q << 30) | (U << 29) | (immh << 19) | (immb << 16) | (op << 11) | (vn << 5) | vd;
        }
    }
    case 12: { /* Vector across-lanes reductions (ADDV, SMAXV, UMAXV, SMINV, UMINV) */
        uint32_t Q = rng_u32(r) & 1;
        uint32_t size = rng_u32(r) % 3; /* B, H, S (no D except S/Umaxv? actually ADDV.4S needs Q=1, size=2) */
        if (size == 2 && !Q) Q = 1;
        static const struct { uint8_t U, op; } rps[] = {
            {0, 0x1b}, /* ADDV */ {0, 0x0a}, /* SMAXV */ {1, 0x0a}, /* UMAXV */
            {0, 0x1a}, /* SMINV */ {1, 0x1a}, /* UMINV */
        };
        uint32_t idx = rng_u32(r) % 5;
        return 0x0e300800u | (Q << 30) | (rps[idx].U << 29) | (size << 22) | (rps[idx].op << 12) | (vn << 5) | vd;
    }
    case 13: { /* Vector FP 3-same (FADD, FSUB, FMUL, FDIV, FMLA, FMLS, FCMEQ, FCMGT, FCMGE, FACGT, FACGE, FMIN, FMAX, FMINNM, FMAXNM, FADDP, FMAXP, FMINP) */
        uint32_t Q = rng_u32(r) & 1;
        uint32_t sz = rng_u32(r) & 1;
        if (sz == 1 && !Q) Q = 1;
        static const struct { uint8_t U, bit23, opc; } fops[] = {
            {0, 0, 0x1a}, /* FADD */   {0, 1, 0x1a}, /* FSUB */
            {1, 0, 0x1b}, /* FMUL */   {1, 0, 0x1f}, /* FDIV */
            {0, 0, 0x19}, /* FMLA */   {0, 1, 0x19}, /* FMLS */
            {0, 0, 0x1c}, /* FCMEQ */  {1, 0, 0x1c}, /* FCMGE */  {1, 1, 0x1c}, /* FCMGT */
            {1, 0, 0x1d}, /* FACGE */  {1, 1, 0x1d}, /* FACGT */
            {0, 0, 0x1e}, /* FMAX */   {0, 1, 0x1e}, /* FMIN */
            {0, 0, 0x18}, /* FMAXNM */ {0, 1, 0x18}, /* FMINNM */
            {1, 0, 0x1a}, /* FADDP */
        };
        uint32_t idx = rng_u32(r) % (sizeof fops / sizeof fops[0]);
        return 0x0e200400u | (Q << 30) | (fops[idx].U << 29) | (fops[idx].bit23 << 23) | (sz << 22) |
               (vm << 16) | (fops[idx].opc << 11) | (vn << 5) | vd;
    }
    case 14: { /* Vector modified immediate (MOVI, MVNI, ORR imm, BIC imm) */
        uint32_t Q = rng_u32(r) & 1;
        uint32_t op = rng_u32(r) & 1;
        uint32_t cmode = rng_u32(r) & 15;
        /* Ensure valid (op, cmode) combinations */
        if (op == 1 && (cmode == 0xe || (cmode & 1) == 1) && cmode != 0xe && (cmode & 0x9) == 0x9) {
            cmode = 0xe; /* MOVI 64-bit or FMOV */
        }
        if (op == 1 && cmode == 0xf) {
            /* op=1, cmode=0xf is FMOV.2D (only valid when Q=1!) or UNDEF when Q=0! */
            Q = 1;
        }
        /* Restrict to always-valid cmode subset: 0,2,4,6,8,10,12,13,14 (with op=0 or op=1 for 14) */
        static const struct { uint8_t op, cmode; } mops[] = {
            {0, 0}, {0, 2}, {0, 4}, {0, 6}, {0, 8}, {0, 10}, {0, 12}, {0, 13}, {0, 14}, {0, 15},
            {1, 0}, {1, 2}, {1, 4}, {1, 6}, {1, 8}, {1, 10}, {1, 12}, {1, 13}, {1, 14},
            {0, 1}, {0, 3}, {0, 5}, {0, 7}, {0, 9}, {0, 11}, /* ORR/MVNI */
        };
        uint32_t idx = rng_u32(r) % (sizeof mops / sizeof mops[0]);
        uint32_t imm8 = rng_u32(r) & 0xffu;
        uint32_t abc = (imm8 >> 5) & 7u;
        uint32_t defgh = imm8 & 0x1fu;
        return 0x0f000400u | (Q << 30) | (mops[idx].op << 29) | (abc << 16) | (mops[idx].cmode << 12) | (defgh << 5) | vd;
    }
    default: { /* Vector indexed multiply: MUL (U=0,opc=8) / MLA (U=1,opc=0) / MLS (U=1,opc=4) */
        uint32_t Q = rng_u32(r) & 1;
        uint32_t sz = (rng_u32(r) & 1) ? 2u : 1u; /* H=1, S=2 */
        uint32_t idx = rng_u32(r) % (sz == 1 ? 8u : 4u);
        uint32_t vm_lo = vm & (sz == 1 ? 15u : 31u);
        uint32_t H = (sz == 1) ? ((idx >> 2) & 1u) : ((idx >> 1) & 1u);
        uint32_t L = (sz == 1) ? ((idx >> 1) & 1u) : (idx & 1u);
        uint32_t M = (sz == 1) ? (idx & 1u) : 0u;
        uint32_t sel = rng_u32(r) % 3;
        uint32_t U = (sel == 0) ? 0u : 1u;
        uint32_t opc = (sel == 0) ? 0x8u : (sel == 1 ? 0x0u : 0x4u);
        return 0x0f000000u | (Q << 30) | (U << 29) | (sz << 22) | (L << 21) | (M << 20) | (vm_lo << 16) | (opc << 12) | (H << 11) | (vn << 5) | vd;
    }
    }
}

static uint32_t gen_fp_cmp(Rng *r) {
    uint32_t k = rng_u32(r) % 10;
    if (k == 0) return gen_csel_ccmp(r); /* occasional flag consumer */
    static const uint32_t ftypes[3] = {0, 1, 3}; /* S, D, H */
    uint32_t ftype = ftypes[rng_u32(r) % 3];
    uint32_t vn = rng_u32(r) & 31u;
    uint32_t vm = rng_u32(r) & 31u;
    uint32_t E = rng_u32(r) & 1;
    if (k < 6) {
        /* FCMP / FCMPE (reg or #0.0) */
        uint32_t is_zero = rng_u32(r) & 1;
        uint32_t opc = (is_zero ? 8u : 0u) | (E ? 16u : 0u);
        if (is_zero) vm = 0;
        return 0x1e202000u | (ftype << 22) | (vm << 16) | (vn << 5) | opc;
    } else {
        /* FCCMP / FCCMPE */
        uint32_t cond = rng_u32(r) & 15u;
        uint32_t nzcv = rng_u32(r) & 15u;
        return 0x1e200400u | (ftype << 22) | (vm << 16) | (cond << 12) | (vn << 5) | (E << 4) | nzcv;
    }
}

void gen_sequence(uint64_t seed, FuzzClass cls, const uint8_t *scratch_base, const uint8_t *stack_base,
                  FuzzSeq *seq, FuzzState *init_state, uint8_t *init_scratch, uint8_t *init_stack) {
    Rng r = { .s = seed ^ ((uint64_t)cls * 0x9e3779b97f4a7c15ull) ^ 0x123456789abcdef0ull };

    memset(seq, 0, sizeof *seq);
    memset(init_state, 0, sizeof *init_state);
    seq->cls = cls;

    for (uint32_t i = 0; i < 31; i++) init_state->x[i] = interesting_u64(&r);
    init_state->sp = (uint64_t)(uintptr_t)(stack_base + STACK_SIZE / 2);
    init_state->nzcv = (uint64_t)(rng_u32(&r) & 0xfu) << 28;
    /* Valid FPCR bits: RMode[23:22], FZ[24], DN[25], FZ16[19] (mostly 0 or random valid rounding/FTZ/DN) */
    if ((cls == FC_SIMD_FP || cls == FC_FP_CMP) && (rng_u32(&r) % 3) == 0) {
        uint64_t fpcr = 0;
        fpcr |= (uint64_t)(rng_u32(&r) & 3u) << 22;
        if (rng_u32(&r) & 1) fpcr |= (1ull << 24);
        if (rng_u32(&r) & 1) fpcr |= (1ull << 25);
        if (rng_u32(&r) & 1) fpcr |= (1ull << 19);
        init_state->fpcr = fpcr;
    } else {
        init_state->fpcr = 0;
    }
    init_state->fpsr = 0;

    for (uint32_t i = 0; i < 32; i++) {
        uint64_t lo = interesting_fp64(&r);
        uint64_t hi = interesting_fp64(&r);
        init_state->v[i] = ((__uint128_t)hi << 64) | lo;
    }

    for (size_t i = 0; i < SCRATCH_SIZE; i += 8) {
        uint64_t v = rng_u64(&r);
        memcpy(init_scratch + i, &v, 8);
    }
    for (size_t i = 0; i < STACK_SIZE; i += 8) {
        uint64_t v = rng_u64(&r);
        memcpy(init_stack + i, &v, 8);
    }

    int is_mem = (cls == FC_LDST || cls == FC_LDST_PAIR || cls == FC_EXCL_ATOMIC || cls == FC_ORDERED);
    seq->has_mem = is_mem;
    if (is_mem) {
        uint64_t sb = (uint64_t)(uintptr_t)scratch_base;
        static const uint32_t bases[4] = {20, 21, 22, 28};
        /* Place x20, x21, x22, x28 at page boundaries, unaligned offsets, and random interior points, >= 0x1000 from ends. */
        static const int32_t page_offs[8] = {0, -1, -3, -4, -7, -8, -12, -15};
        for (int b = 0; b < 4; b++) {
            uint64_t base_off;
            uint32_t mode = rng_u32(&r) % 5;
            if (opt_aligned_mem || (cls == FC_EXCL_ATOMIC && b == 0)) {
                /* 16-byte aligned */
                base_off = 0x2000u + (rng_u32(&r) % 512u) * 16u;
            } else if (mode == 0) {
                /* Near 16 KB boundary (0x4000, 0x8000, 0xc000) */
                uint64_t pg = 0x4000u * (1u + (rng_u32(&r) % 3u));
                base_off = (uint64_t)((int64_t)pg + page_offs[rng_u32(&r) & 7]);
            } else if (mode == 1) {
                /* Near 4 KB boundary inside [0x1000, 0xf000) */
                uint64_t pg = 0x1000u * rng_range(&r, 2, 14);
                base_off = (uint64_t)((int64_t)pg + page_offs[rng_u32(&r) & 7]);
            } else if (mode == 2) {
                /* Unaligned within 16B block */
                base_off = rng_range(&r, 0x2000, 0xd000);
                base_off = (base_off & ~15ull) + rng_range(&r, 1, 15);
            } else {
                base_off = rng_range(&r, 0x2000, 0xd000);
            }
            init_state->x[bases[b]] = sb + base_off;
        }
        /* x24: small signed offset [-64, 64] for LSL/UXTX/SXTX/SXTW.
         * x25: small non-negative [0, 64] with optional dirty upper 32 bits for UXTW/SXTW. */
        init_state->x[24] = (uint64_t)(int64_t)rng_srange(&r, -64, 64);
        init_state->x[25] = ((rng_u32(&r) & 1) ? ((uint64_t)rng_u32(&r) << 32) : 0ull) | (uint32_t)rng_range(&r, 0, 64);
    }

    uint32_t n = rng_range(&r, MIN_SEQ_INSNS, MAX_SEQ_INSNS);
    if (cls == FC_EXCL_ATOMIC) {
        gen_excl_atomic_seq(&r, seq, n);
        return;
    }

    for (uint32_t i = 0; i < n; i++) {
        uint32_t insn = 0xd503201fu;
        switch (cls) {
        case FC_ARITH_FLAGS: insn = gen_arith_flags(&r, 0); break;
        case FC_SHIFTS:      insn = gen_shifts(&r); break;
        case FC_BITFIELD:    insn = gen_bitfield(&r); break;
        case FC_CSEL_CCMP:   insn = gen_csel_ccmp(&r); break;
        case FC_MUL_DIV:     insn = gen_mul_div(&r); break;
        case FC_CRC32:       insn = gen_crc32(&r); break;
        case FC_LDST:        insn = gen_ldst(&r); break;
        case FC_LDST_PAIR:   insn = gen_ldst_pair(&r); break;
        case FC_ORDERED:     insn = gen_ordered(&r); break;
        case FC_SIMD_FP:     insn = gen_simd_fp(&r); break;
        case FC_FP_CMP:      insn = gen_fp_cmp(&r); break;
        default: break;
        }
        seq->insns[seq->ninsns++] = insn;
    }
}
