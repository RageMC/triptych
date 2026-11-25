// SPDX-License-Identifier: GPL-2.0-or-later
// Triptych: the JIT claim's low-room sizing (henge-ios-jit.c, patch triptych-jit-fit-low.patch). Built for the iOS
// Simulator and run with `simctl spawn` (scripts/test-jit-lowgap-ios.sh). Fills every free run below 0x7000000000
// with PROT_NONE reservations except one or two holes, reproducing an iPad's crowded address space (iPadOS 27.2:
// low gaps of 936, 394 and 264 MiB), then checks what the claim would ask the debugger for. The claim has to leave
// low room for the writable alias (same size as the code view, within adrp reach), so it never takes a whole gap.
#define HENGE_JIT_LOW_FLOOR (64ull << 20) /* the real floor is 256 MiB; lowered so the fixtures fit the simulator's small low gap */
#include "henge-ios-jit.c"
#include <stdio.h>

static int fails;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)

/* Reserve every free run in [0x100000000, LOW_LIMIT) except the parts inside one of the `nkeep` keep ranges. Repeats
   until nothing new can be reserved (first-fit can open smaller runs as it goes). */
static void reserve_low_except(const uint64_t keep[][2], int nkeep) {
    for (int pass = 0; pass < 64; pass++) {
        mach_vm_address_t addr = 0, prev = 0x100000000ull; int filled = 0;
        for (int i = 0; i < 8192; i++) {
            vm_size_t size = 0; vm_address_t a = (vm_address_t)addr; natural_t depth = 0;
            struct vm_region_submap_info_64 info; mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
            if (vm_region_recurse_64(mach_task_self(), &a, &size, &depth, (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS) { a = HENGE_JIT_LOW_LIMIT; size = 0; }
            uint64_t lo = prev, hi = a < HENGE_JIT_LOW_LIMIT ? a : HENGE_JIT_LOW_LIMIT;
            // Reserve [lo, hi) minus every keep range: walk sub-segments between keep boundaries.
            uint64_t s = lo;
            while (s < hi) {
                uint64_t e = hi; int inside = 0;
                for (int k = 0; k < nkeep; k++) {
                    if (s >= keep[k][0] && s < keep[k][1]) { inside = 1; e = keep[k][1] < hi ? keep[k][1] : hi; break; }
                    if (keep[k][0] > s && keep[k][0] < e) e = keep[k][0]; // next segment ends where a keep begins
                }
                if (!inside && e > s) { vm_address_t at = s; if (vm_allocate(mach_task_self(), &at, e - s, VM_FLAGS_FIXED) == KERN_SUCCESS) filled++; }
                s = e;
            }
            if (a >= HENGE_JIT_LOW_LIMIT || !size) break;
            if (a + size > prev) prev = a + size;
            addr = a + size;
        }
        if (!filled) return;
    }
}

/* The largest free run below the limit, with its start. */
static uint64_t largest(uint64_t *at) {
    mach_vm_address_t addr = 0, prev = 0x100000000ull; uint64_t best = 0;
    for (int i = 0; i < 8192; i++) {
        vm_size_t size = 0; vm_address_t a = (vm_address_t)addr; natural_t depth = 0;
        struct vm_region_submap_info_64 info; mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &a, &size, &depth, (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS) { a = HENGE_JIT_LOW_LIMIT; size = 0; }
        uint64_t hi = a < HENGE_JIT_LOW_LIMIT ? a : HENGE_JIT_LOW_LIMIT;
        if (hi > prev && hi - prev > best) { best = hi - prev; *at = prev; }
        if (a >= HENGE_JIT_LOW_LIMIT || !size) break;
        if (a + size > prev) prev = a + size;
        addr = a + size;
    }
    return best;
}

#define MiB (1ull << 20)

/* What fit_low must return for the given two largest low gaps: the larger of the second gap and half the largest,
   rounded to 16 MiB, or 0 below the floor. */
static uint64_t expect_fit(uint64_t largest, uint64_t second) {
    uint64_t cap = second > largest / 2 ? second : largest / 2;
    cap &= ~(16 * MiB - 1);
    return cap >= HENGE_JIT_LOW_FLOOR ? cap : 0;
}

/* The invariant that fixes the device bug: a huge request is sized so the code view AND its equal-size writable alias
   both still fit in low memory (either both in the largest gap, or one in each of the two largest), and it never takes
   a whole gap. Checked against whatever address space the fixture produced. */
static void check_fits_with_alias(const char *where) {
    uint64_t second = 0, largest = henge_ios_jit_two_largest_low_gaps(&second);
    uint64_t r = henge_ios_jit_fit_low(1536 * MiB);
    fprintf(stderr, "%s: largest %llu MiB, second %llu MiB -> fit %llu MiB\n", where,
            (unsigned long long)(largest >> 20), (unsigned long long)(second >> 20), (unsigned long long)(r >> 20));
    CHECK(r == expect_fit(largest, second));
    if (r) {
        CHECK(r <= largest);              // the code view fits the largest gap
        CHECK(2 * r <= largest + second); // the view and its same-size alias both fit in low memory
        CHECK(r < largest || second >= r);// never the whole largest gap unless a second gap can still hold the alias
    } else {
        CHECK(largest < 2 * HENGE_JIT_LOW_FLOOR && second < HENGE_JIT_LOW_FLOOR);
    }
}

int main(void) {
    uint64_t at = 0, g0 = largest(&at);
    fprintf(stderr, "largest low gap at start: %llu MiB at %#llx\n", (unsigned long long)(g0 >> 20), (unsigned long long)at);
    uint64_t second0 = 0;
    CHECK(henge_ios_jit_largest_low_gap() == g0);
    CHECK(henge_ios_jit_two_largest_low_gaps(&second0) == g0);
    CHECK(second0 <= g0);

    // Holes sized to the floor (64 MiB here), small enough to carve from the simulator's low gap. A >= 2*floor so its
    // half clears the floor; B is one floor, the second gap.
    const uint64_t FL = HENGE_JIT_LOW_FLOOR, A = 2 * FL, SPACER = 16 * MiB, B = FL, HUGE = 1536 * MiB;
    if (g0 < A + SPACER + B + SPACER) {
        fprintf(stderr, "jit_lowgap_test: need a low gap of at least %llu MiB to set up the fixture\n",
                (unsigned long long)((A + SPACER + B + SPACER) >> 20));
        return 1;
    }
    uint64_t aA = at, aB = at + A + SPACER;
    uint64_t keep2[2][2] = { { aA, aA + A }, { aB, aB + B } };

    // Fixture 1: largest gap A (2*floor) plus a second gap B (one floor). The invariant holds; crucially the claim is
    // not the whole largest gap (that device bug left no low room for the alias). fit_low of a small size is unchanged.
    reserve_low_except(keep2, 2);
    uint64_t lg = henge_ios_jit_two_largest_low_gaps(NULL);
    CHECK(lg == A); // the largest gap is the one we kept; stray smaller gaps may remain and the invariant still holds
    check_fits_with_alias("two-hole fixture");
    CHECK(henge_ios_jit_fit_low(FL) == FL); // asked for no more than the cap: unchanged

    // Fixture 2: reserve the second kept hole, so the largest gap A has no equal sibling and the alias must share it;
    // the claim is capped to half.
    uint64_t keep1[1][2] = { { aA, aA + A } };
    reserve_low_except(keep1, 1);
    check_fits_with_alias("one-hole fixture");

    // Fixture 3: shrink the largest gap below twice the floor, so the view plus its alias can't both fit low there.
    vm_address_t cut = aA; // leave 1.25 floors free (half is 0.6 floor < floor)
    CHECK(vm_allocate(mach_task_self(), &cut, A - (FL + FL / 4), VM_FLAGS_FIXED) == KERN_SUCCESS);
    check_fits_with_alias("shrunk fixture");
    (void)HUGE; (void)B;

    if (fails) { fprintf(stderr, "jit_lowgap_test: %d failures\n", fails); return 1; }
    printf("jit_lowgap_test: all passed\n");
    return 0;
}
