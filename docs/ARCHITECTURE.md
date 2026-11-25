# Triptych architecture

Triptych is one iPhone/iPad app that runs Windows, macOS and Linux software. Its parts
carry Triptych's own names; the open-source projects they come from
are credited below, in `CREDITS.md` and in the About screen, and each upstream licence stays
intact.

| Part | Name | Built from (upstream credit) | What it does |
|---|---|---|---|
| Shared VM + JIT core | **Gesso** (`engines/gesso`) | Henge (Leviidev), GPL-2.0-or-later | One CPU/JIT core, device models, snapshot, log and network stack for both full-system VMs |
| Windows 11 PC (full VM) | **Casement** (`engines/winvm`) | Gesso, QEMU `virt`/ACPI ideas, EDK2, libtpms | Windows 11 ARM64 installed from the user's own ISO; **full-system emulation** |
| Windows games/apps | **Pane** | Madeira, BCD, Wine (ARM64EC), FEX-Emu | x86/x64 `.exe` per app; CPU and API **translation** |
| macOS VM + Mac apps | **Atelier** (`engines/macos`, `engines/macapps`) | Gesso (Henge), MacAppsKit | A virtual Mac restored from Apple's own image, plus Mac apps; arm64→arm64 JIT |
| Linux | **Fresco** (`engines/linux`, `engines/linux-desktop`, `engines/x86pc`) | LinuxRunner (iSH lineage), QEMU, FEX | ARM64 Linux userspace on an interpreter (optional JIT), Linux syscalls → XNU; PC-style Linux VMs |
| Graphics translation | **Varnish** | DXMT, madeira-d3d12, vkd3d-proton, KosmicKrisp (Mesa), MoltenVK | D3D9–12 and Vulkan on Metal |
| Setup (JIT, storage, images) | **Easel** (`app/Triptych/JIT.swift`, `SetupView.swift`) | StikJIT / StikDebug setup flow | One guided setup |
| Logs bundle and export | **Provenance** (`app/Triptych/Logs.swift`) | Triptych | Log capture and export |
| On-device assistant | **Curator** (`app/Triptych/Curator`) | Triptych | Log triage, suggested fixes, GitHub reports |

Upstream submodules that remain under `upstreams/`: `madeira`, `bcd-games`, `linuxrunner`,
`qemu` (and `henge`, kept only as the import source for Gesso). Henge's code now lives in
`engines/gesso/` with its origin recorded in `engines/gesso/UPSTREAM.md`.

## Decision: one combined app, not a launcher of separate apps

The evidence for one app:

1. **Sideloading budget.** A free Apple ID allows 3 active sideloaded apps and 10 App
   IDs per 7 days. Henge, Madeira/BCD and LinuxRunner each need an app ID plus a JIT-helper
   extension ID. Three apps would use 6 IDs and all 3 slots, and StikDebug or SideStore
   take a slot too. One app needs 2 IDs and 1 slot. (BCD README; SideStore docs;
   `knowledge/ios-wine-port.md`.)
2. **JIT is per process and per app.** On iOS 26+ (TXM), only an attached debugger can
   grant executable memory, and StikJIT's rules say each app uses exactly **one**
   developer-defined script and **one** JIT method, with no silent fallback
   (StikJIT `INTEGRATION.md`). Separate apps would mean separate pairing, separate
   helpers and separate scripts. A launcher app can't share its JIT with another app,
   so a launcher adds a hop and solves nothing.
3. **The scripts are compatible.** Henge and Madeira both use the universal protocol:
   `brk #0xf00d` with `x16` set to 0 (detach) or 1 (prepare an RX region). Madeira's
   `madeira-jit.js` also adds `x16 = 2` (map page zero, needed for WOW64) and forwards
   signals. That makes it a superset of Henge's script. Triptych ships it once, as
   `triptych-jit.js` (`app/Triptych/JIT.swift`).
4. **Engine sharing depends on process-wide resources.** LinuxRunner uses a
   private PTY for its console and keeps one environment per launch. Windows PC
   can release and borrow the top of the app's JIT region again after stopping.
   Gesso's Mac VM (Atelier) can reuse the region after a normal stop. Madeira holds a fixed
   address range and runs wineserver and its pseudo-processes in Triptych.
   `SessionState.canShareLaunch` (`app/Triptych/TriptychApp.swift`) lists the verified
   engine combinations: Casement + Mac apps, Fresco + Casement, Fresco + Mac apps, and
   Fresco + x86 PC. A single system always starts; any other combination is blocked from
   sharing the launch. Instead, `Relaunch.restart(into:)` (`app/Triptych/Relaunch.swift`)
   records the wanted system, asks LiveContainer (`livecontainer://livecontainer-launch`)
   or StikDebug (`stikdebug://enable-jit`, with Triptych's script) to start the app again
   with JIT, and quits; the new launch opens that system via `Relaunch.takePending()`.
5. **It links.** All three engines link into one binary with **no duplicate symbols**
   on either the device or the Simulator SDK (verified, see STATUS.md).

The costs, and how Triptych handles them:

- **Size.** Madeira's IPA is under 200 MB. Henge's install stack and LinuxRunner's
  rootfs add little; macOS and the Linux distros are downloaded at run time.
- **Licences.** See below. Apple's Metal Shader Converter is the one real conflict.
- **Build complexity.** Each engine keeps its upstream build system. Triptych's
  scripts (`scripts/build-*-engine.sh`) wrap them and output static libraries per SDK.

## Licences (checked)

- Henge: **GPL-2.0-or-later**. It contains usbmuxd (GPL-2/3), Husk code (GPL-2.0+),
  LGPL libimobiledevice/idevicerestore, StikJIT (MPL-2.0) and idevice (MIT).
- Madeira: **GPL-3.0-or-later** plus the *Madeira Converter Exception* (permission to
  combine with `libmetalirconverter.dylib` and Apple's system frameworks). Wine on the
  LGPL branch; FEX under MIT.
- BCD: the BCD Material is **GPL-3.0-only** with GPL §7 terms. Those terms require
  attribution in the About screen, which Triptych shows; forbid presenting a fork as
  "the official BCD"; and grant no rights to the BCD name or logo. BCD repeats Madeira's
  converter exception for its own code.
- LinuxRunner: GitHub lists it as **NOASSERTION** only because the licence file is
  non-standard. It is iSH's **GPL-3.0**: contributions after commit 0e3a414 are also
  GPL-2.0, and `LICENSE.IOS` adds an App Store non-enforcement notice. It is compatible.
- **Combined work: GPL-3.0.** Henge's "or later" clause allows the combination.
- **Metal Shader Converter (MSC) conflict.** Madeira's exception covers only code by
  the Madeira (and BCD) authors. Henge's and LinuxRunner's authors grant no such
  permission. MSC is not a system library on iOS. Madeira's own `LICENSING.md` says
  loading a library with dlopen is still a combined work. So **a Triptych build that
  bundles `libmetalirconverter` carries that licensing question**. The rules that follow:
  - Owner's decision (2026-11-25): IPA builds and releases bundle MSC, so DirectX 12 runs
    through madeira-d3d12 + MSC. The dylib is never committed to source; it is fetched at
    build time and credited in CREDITS.md under Apple's licence.
  - The open route (vkd3d-proton → Vulkan → KosmicKrisp → Metal, iOS 26, A14 or newer)
    stays available as an alternative.
  - To settle the question cleanly, ask the Henge author (Leviidev) for the same exception
    Madeira grants. That is the owner's call.
- Nothing proprietary is bundled: no macOS, no AVPBooter ROM (Henge fetches it from
  Apple on the device), no Windows, no Valve binaries, no MS VC++ runtime.

## How the app is put together

```
app/Triptych            SwiftUI host: Home (the triptych), Easel setup, JIT, About/licences
  TriptychApp.swift          app entry, SessionState (activeEngine, started, canShareLaunch)
  Relaunch.swift             restart into another system with JIT (LiveContainer / StikDebug)
  Engines.swift              EngineKind: Pane, Casement, Atelier (macOS, Mac apps), Fresco, x86 PC
  Bridge/triptych_bridge.c   C surface: CS_DEBUGGED check, Linux pty+thread, Gesso checks
  Henge/                     Swift/C glue for Gesso's iOS entry points
  Curator/                   on-device assistant (landing from the Curator branches)
  Logs.swift                 Provenance
  LinuxView / MacView / WinPCView / WindowsView / X86PCView   per-system pages
engines/gesso            shared VM + JIT core (from Henge; UPSTREAM.md records the origin)
engines/winvm            Casement: "winarm" machine (ACPI, FDT, fw_cfg, NVMe, TPM, xHCI, pflash)
engines/macos, macapps   Atelier patches/tests and Mac app host
engines/linux, linux-desktop, x86pc   Fresco patches, desktop design, x86 PC harness
engines/windows, android Pane/Android patches and build
upstreams/{madeira,bcd-games,linuxrunner,qemu}   untouched submodules (henge: import source)
scripts/build-linux-engine.sh   meson cross-build of LinuxRunner's core -> libtriptych_linux.a
scripts/build-henge-deps.sh     glib, libslirp, pcre2, proxy-libintl for iOS (meson)
scripts/build-macos-engine.sh   Gesso `make ios-lib` per SDK -> libhengevm.a, libhengetl.a
scripts/build-winvm.sh, build-edk2.sh, build-libtpms*.sh   Casement engine, firmware, TPM
scripts/build-macapps.sh, build-x86pc.sh, build-windows-engine.sh
scripts/fetch-starter-rootfs.sh Alpine minirootfs (sha256-checked) -> fakefs
scripts/package-ipa.sh          unsigned Release IPA
```

- **Linux (Fresco).** LinuxRunner's CLI `main()` is compiled with `-Dmain=tp_linux_cli_main`
  and `-Dexit=tp_linux_guest_exit`. When the guest shuts down, only the engine thread
  ends, not the app. The console driver (`fs/tty-real.c`) uses the host's fd 0/1, so
  the bridge opens a pty, makes its slave fd 0/1, and the UI talks to the master.
  The guest vDSO **must** be built with `ld.lld`. Without it, the sigreturn trampoline
  is missing and any program that forks crashes after a signal (found and fixed here).
- **macOS (Atelier).** The app compiles Gesso's (Henge-derived) app-side glue (`henge-vm.c`,
  `henge-ios-jit.c`, `henge-brk.S`, `henge-tl.c`) against `libhengevm.a`. On the
  Simulator, a stub replaces the USB restore stack (`hv_install_start`), which is
  device-only. Next step: port Henge's Swift UI (Install, Macs, SessionView, trackpad,
  external display) into the macOS page. The entry points are `henge_vm_install`,
  `henge_vm_boot`, `henge_vm_state` and `henge_vm_stop`, plus `henge_vm_set_display_layer`
  and the input calls.
- **Windows (Pane).** Madeira builds its runtime as static libraries
  (`Madeira.debug.dylib`) and a set of PE DLLs, plus the `MadeiraJITHelper` appex.
  Integration plan: link the runtime static libs, embed the DLL tree and Wine prefix
  template as resources, and reuse Madeira's launch path. BCD's launcher layer (Steam,
  GOG, Epic, Dock) sits on top. BCD is a superset fork, but Madeira is where engine
  fixes land first, so the engine follows Madeira and BCD's launcher code is ported
  on top of it.
- **JIT.** One method at a time: StikDebug URL or built-in StikJIT, never silently
  switched. There is one script, and the app waits for `CS_DEBUGGED` before any `brk`
  (a `brk` sent before the debugger attaches kills the process). All RX regions are
  prepared before detaching. Henge takes one region per launch; Madeira takes its pool.
  The one engine running is the only one that asks. Linux needs no JIT, so it also
  works inside LiveContainer and on devices where JIT can't be had.

## Casement: Windows as a full VM (Parallels/VMware-style)

Neither iOS nor iPadOS gives apps a hypervisor, so Parallels/VMware/UTM-HVF performance
(near-native, using Hypervisor.framework) can't be reached on them. The best route
available is **Gesso (Henge's engine) with a second machine model**, now in `engines/winvm`:

- **Why Henge rather than QEMU TCG (UTM).** Windows 11 on ARM is arm64, the same ISA
  as the host. Henge's translator copies most guest instructions unchanged and
  rewrites only memory ops, branches, system registers and PAC. QEMU TCG decodes every
  instruction into IR and generates new code. UTM with JIT already boots Windows 11 ARM
  on an M2 iPad and is described as "usable but limited" (Windows Latest, heise, April 2025).
  Henge brings macOS to the lock screen in about 15 s on an iPhone 17 Pro.
- **What Henge already has**, matching QEMU's `virt` machine: GICv3, the Arm generic
  timer, PL011 UART, PL031 RTC, PL061, PCIe with virtio-blk/net/input/snd/balloon, xHCI
  USB, and a software MMU with 16 KB pages.
- **What a "winarm" machine still needs:**
  1. A device tree that EDK2 **ArmVirtQemu** firmware accepts, plus a `fw_cfg` device so
     EDK2 can install **ACPI** tables. Windows on ARM needs ACPI; the table builder is
     ported from QEMU `hw/arm/virt-acpi-build.c` (GPL-2.0+, compatible). EDK2 is
     BSD-2-Clause-Patent and can be built from source and bundled.
  2. PSCI (power on/off, CPU_ON for SMP) — probably shared with the vmapple model.
  3. Display: start with **ramfb** (GOP framebuffer: fixed resolution, slow). Then move
     to virtio-gpu 2D, which needs the **viogpudo** ARM64 WDDM display-only driver from
     virtio-win. The display is drawn with Metal, reusing Henge's `CAMetalLayer` path.
     There is **no working 3D path for Windows-ARM guests yet**: viogpu3d is an unmerged
     virtio-win PR, and reports say ARM64 crashes.
  4. Storage: virtio-blk plus the virtio-win **viostor** ARM64 driver, which is loaded
     during setup. Alternatively an NVMe model so Windows' inbox driver works without
     extra drivers (simpler for users).
  5. Windows 11 setup requires **TPM 2.0**: a virtual TPM (libtpms, BSD) behind a
     `tpm-tis` device, as UTM does with swtpm. Do not ship requirement-bypass hacks.
  6. **The "needs EL2" reports are resolved: what Windows needs is SMC.** Guides say the
     installer needs `virtualization=true` under QEMU TCG (Linaro wiki). The reason is
     that Windows' boot loader calls PSCI through `smc #0`. QEMU without EL2 offers PSCI
     over HVC only, and treats SMC as undefined. Henge does the same: it "plays EL2
     (PSCI over HVC)", and an SMC with no EL3 is undefined (`core/exception.c:12, 255`).
     So the winarm machine accepts SMC #0 as a PSCI call too, and the ACPI FADT sets
     PSCI_COMPLIANT without PSCI_USE_HVC. Guest EL2 isn't needed. Note that WSL2/Hyper-V
     inside the guest needs nested EL2/EL3 and fails even on QEMU (Vogtinator's gist),
     so that stays out of scope.
  7. **Develop on the Mac first.** Henge's engine also builds for the Mac
     (`build/hengevm`, `make test`), so the winarm machine can be brought up and checked
     on a Mac with the user's own Windows 11 ARM64 ISO before any iPad is involved.
  7. Integration tools, the Parallels Tools / VMware Tools equivalents: dynamic
     resolution (virtio-gpu), clipboard and shared folders (a WebDAV share as in Henge,
     or virtiofs), and Coherence-style single windows (not feasible without a guest agent).
- **x86 apps inside the Windows VM** run through Windows' own **Prism** emulator, so
  x86-on-ARM translation comes from Microsoft at no cost to Triptych.
- **The user supplies the ISO and licence.** Triptych never downloads or bundles
  Windows, keys or activation workarounds.
- **Performance ceiling.** It will be well below Parallels on a Mac. The JIT costs some
  CPU, there is no GPU acceleration (software rendering in the guest), and iOS caps
  memory. The per-game path (Madeira/BCD) is the one for games; the VM is for desktop
  Windows apps.

## How close each layer gets to its macOS equivalent

| Layer | Best on macOS | On iOS in Triptych | What keeps it below |
|---|---|---|---|
| x86→ARM64 CPU | Rosetta 2 (AOT+JIT, TSO hardware bit) in CrossOver; FEX in NotProton | FEX JIT (ARM64EC: Wine itself native) | No TSO mode on iOS user processes (FEX emulates ordering with barriers); JIT only via debugger; 16 KB-page SMC tracking needed |
| Win32 API | CrossOver 26/27 Wine | Madeira Wine 11.4 fork, single process | no fork/exec → pseudo-processes; 4 GB `__PAGEZERO` → WOW64 relocation tricks |
| D3D11 | D3DMetal / DXMT | DXMT (iOS fork) | iOS Metal feature set; stream-out/GS emulated |
| D3D12 | D3DMetal (Apple, proprietary) | madeira-d3d12 + MSC (bundled) or vkd3d-proton+KosmicKrisp | MSC licence; KK lacks int64 atomics on Apple7 (A14/M1), unofficial on iOS |
| Vulkan | MoltenVK / KosmicKrisp | same, cross-compiled | KK needs Metal 4 (iOS 26, A14+) |
| macOS VM | Virtualization.framework (hardware) | Atelier (Gesso JIT + Metal-replayed paravirtual GPU) | no hypervisor; GPU commands replayed, not passed through |
| Windows VM | Parallels/VMware/UTM-HVF | Casement (Gesso-based machine, `engines/winvm`) | no hypervisor, no guest 3D driver |
| Linux userspace | Lima/OrbStack (VMs) | Fresco (LinuxRunner interpreter (+JIT)) | interpreter by default; no kernel; a bounded syscall set |

Lessons from earlier emulation work that carry over:
- FEX self-modifying-code tracking must use the host's 16 KB page size, or stale code
  runs (seen on M4).
- `FEX_HOT_SMC_PAGES=2` and Madeira's DXMT fixes (SRV MipLevels −1, builtin xinput1_3)
  carry over in both directions.
- KosmicKrisp gaps: depthBounds/fillModeNonSolid aborts (fix with a clamp layer);
  oversized descriptor ranges assert in Mesa; no int64 atomics on Apple7, which blocks
  vkd3d-proton titles such as DD2. The only fix is lock-based emulation (as Mullion does).
- MoltenVK with argument buffers costs about 12 µs per barrier against about 1.2 µs
  without. Turning them off speeds this up but breaks DX12-style descriptor indexing.
- In KosmicKrisp, merging render passes into one command buffer took heavy scenes from
  20 to 45–50 FPS.
