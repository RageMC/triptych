#!/usr/bin/env python3
"""Builds triptych-jit.js, the one StikJIT script for the whole app (StikJIT allows one per app).

Base: Madeira's madeira-jit.js (brk #0xf00d with x16 = 0 detach, 1 prepare region, 2 map page zero).
Change: brk #0x69. Madeira's script treats it as the old "prepare the region at x0" call, which Madeira's
own code never makes; Henge uses brk #0x69 as its "is a debugger attached?" probe and expects x0 =
0xE0000069 back (henge-jit.js JIT26HandleBrk0x69). Without this, Henge's probe would make the debugger
map memory at whatever x0 held and Henge would conclude JIT is off.
Usage: make-jit-script.py madeira-jit.js out.js
"""
import sys
src, out = sys.argv[1], sys.argv[2]
s = open(src).read()
old = """        if (x0 !== 0n) {
            prepare_memory_region(x0, x0);
        }
        send_command(`P0=${numberToLittleEndianHexString(x0)};thread:${tid};`);"""
new = """        // Triptych: Henge's attach probe (henge-jit.js JIT26HandleBrk0x69); Madeira never uses brk #0x69.
        send_command(`P0=${numberToLittleEndianHexString(0xE0000069n)};thread:${tid};`);"""
if s.count(old) != 1:
    sys.exit("make-jit-script: madeira-jit.js changed upstream; re-check the brk #0x69 merge")
s = s.replace(old, new)
for need in ("brkImm === 0xf00d", "CMD_DETACH", "CMD_PREPARE_REGION", "CMD_MAP_PAGE_ZERO"):
    if need not in s:
        sys.exit(f"make-jit-script: expected '{need}' in madeira-jit.js")
open(out, "w").write(s)
