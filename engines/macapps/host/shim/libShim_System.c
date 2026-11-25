// SPDX-License-Identifier: GPL-3.0-or-later
#include <libkern/OSCacheControl.h>
#include <stdint.h>

// macOS libSystem exports the compiler runtime's start/end interface.
// iOS exposes the same instruction-cache operation as a start/length API.
void shim_clear_cache(void *start, void *end) __asm__("___clear_cache");

void shim_clear_cache(void *start, void *end) {
    uintptr_t first = (uintptr_t)start;
    uintptr_t last = (uintptr_t)end;
    if (last > first) sys_icache_invalidate(start, last - first);
}
