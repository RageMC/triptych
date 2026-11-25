Triptych patches for Husk (https://github.com/Leviidev/Husk, pinned eval commit 29abb51 / v3.4).

- triptych-embed.patch:
  Adds `HuskRuntime.framework` embedding entry points (`husk_embed_make_root`,
  `husk_embed_open_url`), guards `@main` on `HuskApp` behind `#if !TRIPTYCH_EMBED`
  so `MACH_O_TYPE=mh_dylib` produces a clean framework, and routes Husk's
  bundle resource lookups (`java-runtime/`, `android-system/`, `cacert.pem`,
  `husk-jit.js`, `default.metallib`, QEMU seed/BIOS paths) through
  `Bundle.husk` with a `Bundle.main` fallback.

- triptych-simulator.patch:
  Enables Husk's dual-mapped (`vm_remap` RW + RX) JIT arena path
  (`husk-jit-arena.c`, `husk-tl-xmem.c`) on `TARGET_OS_SIMULATOR` so ARM64 ELF
  translation and Dalvik apps run directly in the iOS Simulator without an
  external StikDebug/StikJIT attachment.

Licensing note:
  Husk's translation layer (`src/translation-layer/`,
  `src/translation-layer-next/`) and Swift UI (`src/app/Husk/`) are licensed
  under GPL-2.0-or-later, which upgrades cleanly to Triptych's GPL-3.0-or-later
  license. However, Husk's optional QEMU fallback (`libqemu-aarch64-softmmu.dylib`)
  is GPL-2.0-only and is NOT compatible with combining into the same binary as
  GPL-3.0 Triptych/Madeira/LinuxRunner/BCD code. Keep QEMU disabled unless
  isolated behind a separate process boundary or license-compatible build.
