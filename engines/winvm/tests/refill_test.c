// SPDX-License-Identifier: GPL-2.0-or-later
#include "dispatch.h"

#include <stdio.h>
#include <string.h>

enum { GUEST_PAGE_SIZE = 1 << HV_TLB_PAGE_BITS };

int main(void) {
    static HvMachine machine;
    static HvCpu cpu;
    static _Alignas(GUEST_PAGE_SIZE) uint8_t ram[2 * GUEST_PAGE_SIZE];
    static const uint32_t code[] = {
        0xf9400020, /* ldr x0, [x1] */
        0x14000001, /* b to the dispatcher stop PC */
    };
    const uint64_t base = 0x40000000;
    const uint64_t data = 0x123456789abcdef0;
    __uint128_t saved[32];

    memcpy(ram, code, sizeof code);
    memcpy(ram + GUEST_PAGE_SIZE, &data, sizeof data);
    if (hv_machine_init(&machine, 1 << 20) != 0) {
        fprintf(stderr, "cannot initialize the refill test VM\n");
        return 1;
    }
    if (hv_machine_add_ram(&machine, base, sizeof ram, ram, 0) != 0) {
        fprintf(stderr, "cannot add guest RAM for the refill test\n");
        hv_machine_free(&machine);
        return 1;
    }
    machine.stop_pc = base + sizeof code;
    machine.stats_interval = 1; /* count light refills */
    hv_cpu_reset(&cpu, &machine);
    cpu.pc = base;
    cpu.x[1] = base + GUEST_PAGE_SIZE; /* first access to this TLB page */
    cpu.cpacr_el1 = 3u << 20;
    for (size_t i = 0; i < sizeof saved / sizeof saved[0]; i++)
        saved[i] = ((__uint128_t)(data + i) << 64) | (data - i);
    memcpy(cpu.v, saved, sizeof saved);

    int result = hv_run(&cpu);
    int failed = result != HV_EXIT_HALT || cpu.pc != machine.stop_pc ||
                 cpu.x[0] != data || machine.stats.refills != 1;
    if (failed)
        fprintf(stderr, "guest load did not complete through one light TLB refill\n");
    for (size_t i = 0; i < sizeof saved / sizeof saved[0]; i++) {
        if (cpu.v[i] != saved[i]) {
            fprintf(stderr, "light TLB refill clobbered guest v%zu\n", i);
            failed = 1;
        }
    }
    hv_machine_free(&machine);
    if (!failed) puts("light TLB refill preserved guest SIMD registers");
    return failed;
}
