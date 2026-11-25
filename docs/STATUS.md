# Status (2026-11-25)

## Release

**0.1.0 is a preview**, published as an unsigned IPA on the
[Releases page](https://github.com/RageMC/triptych/releases) for people who sideload and can enable JIT.
It is not finished: what works, what was only checked in the Simulator and what is still missing is listed
below. Nothing proprietary ships in it (no Windows, macOS or Apple firmware images, keys, CodeWeavers or Valve
binaries); you supply your own ISOs and installers.

No real iPhone or iPad was available. Everything below was checked on an M1 Max Mac
with Xcode 27.2 and the iOS 27.2 Simulator (iPhone 17 Pro). "Verified" means a command
or test was run here and passed.

## Verified

**Curator GitHub reporting (2026-11-24).** The report sheet offers GitHub device sign-in and account submission. Anonymous submission appears when an HTTPS `TriptychReportRelayURL` is configured. Settings shows the account and offers sign-out. Device-flow credentials rotate in Keychain before expiration or after a GitHub 401. `TriptychIssueRepo` defaults to `RageMC/triptych-issues`. All 52 unit tests and three Curator UI tests passed on iOS 27.2 Simulator, with GitHub and relay requests stubbed.
**Curator offline fallback (2026-11-24).** Easel offers a SHA-256-verified Qwen3-0.6B Q4_K_M download. Curator prefers Apple Intelligence, then uses llama.cpp at 1.25 GiB of available app memory or more, with rules when neither model is available. The fallback releases weights after each request and stops before any system starts, remaining off until Triptych relaunches. Verified the pinned download, Simulator inference, all 52 Simulator unit tests, and the iOS device build with Metal. Physical-device inference remains unverified.

**Curator integrated (2026-11-22).** Curator checks current and previous Provenance logs from
Home and the system pages. Known failures get a diagnosis and, where supported, an
Apply action for an existing setting or a restart into the requested system. On iOS
26 and later, available Apple Intelligence can summarize unmatched failures and
word the issue draft on device. Curator shows the draft and diagnostic attachment
before asking the user to submit. The GitHub upload bridge scrubs the report and
its attachment text before sending.

All 30 `TriptychTests` and 22 offline `TriptychUITests` passed on the iPhone 17
Simulator (iOS 27.2). The Xfce case passed on an isolated rerun after a simulator
host termination interrupted its first run. The UI suite excluded network
downloads, the long Xfce installation and optional media cases. GitHub requests
were mocked in the reporter tests. The device Release build passed and
`scripts/package-ipa.sh` produced `dist/Triptych-unsigned.ipa`.
**Full screen everywhere (2026-11-22).** Running systems use the current iOS window
bounds, including safe areas. Navigation and status bars hide during the session.
An overlay restores the session controls and Provenance log export. Casement's
guest key bar can be hidden independently. For the in-process Pane, Fresco and
Mac app runtimes, Stop requests a Triptych restart.

- Casement passes a capped window-sized mode through fw_cfg to EDK2 GOP.
  Firmware drew at 884 × 1920 on iPhone 17 and 1440 × 1920 on iPad Pro 13-inch
  (M5). Windows 11 Setup drew at 1440 × 1920 on iPad. Windows Basic Display
  uses the boot framebuffer, so Casement fits that image
  if the window changes shape after boot.
  Windows Setup (not published)
- Atelier requests a window-sized virtual display at boot and sends new modes
  through Gesso's display protocol on resize. The native device test covers the
  initial mode, guest acknowledgement and change event. AppKit windows take
  the full host bounds and update on rotation. The CrossOver Preview license
  window and bundled Mac app drew in the Simulator.
- Fresco updates both host pty and guest tty sizes. The socket console rotation
  check reads the new rows and columns with `stty size`. Xfce started at
  960 × 1280 on iPad. Xvfb keeps its startup dimensions for the life of the
  X server, and the host fits that image after a window resize.
- The x86 PC advertises the preferred mode in VGA's EDID. Alpine used
  1200 × 1600 on iPad. Legacy guest modes scale to the available window.

The Simulator checks cover the display view's origin and size against the app
window on iPhone 17 and iPad Pro 13-inch (M5). Atelier and Pane use the real session
hosts with a display preview because their guest runtimes require device
verification. Stage Manager and Split View sizing use the same window bounds.
Physical-device Stage Manager and Split View, the Windows desktop, and the macOS
guest's response to live mode changes remain pending.
On iPhone, 10 unit tests and 30 UI tests passed, including the five distro
download tests and the x86 Alpine and Linux Mint guests. The iPad passed nine
fullscreen UI tests and the Windows installer test. The gated Xfce package
installation test was skipped. Gesso and winvm native test suites passed.
Simulator screenshots (not published).
**Architecture doc renamed (2026-11-24).** `docs/ARCHITECTURE.md` uses the revamp names (Gesso, Casement, Pane, Atelier, Fresco, Varnish, Easel, Provenance, Curator), the `engines/gesso`/`engines/winvm`/`app/Triptych/Curator` layout, and the `canShareLaunch` + `Relaunch` rules, with upstream credits kept. Docs only.

**Revamp integrated (2026-11-21).** Gesso serves Casement and the Atelier macOS VM from
`engines/gesso/`. The redesigned Home and system screens use Casement, Pane, Atelier and
Fresco, with shared Easel setup and Provenance log export. Home distinguishes Windows 11
installation and desktop boot on the Mac, with libtpms and networking, from the Casement
firmware preview verified in the Simulator. Windows installation in the iOS app remains
untested.

- `make -C engines/gesso test` and `make -C engines/winvm test` passed.
- The Gesso and winvm Simulator builds passed, with libtpms and libslirp in winvm.
- The app built on Xcode 27.2. On the iPhone 17 Pro Simulator, all 8 `TriptychTests`
  and 16 offline `TriptychUITests` passed. EDK2 issued 34 TPM commands during the
  Casement firmware test. After the final Home copy changes, the Simulator build,
  all 8 unit tests and the 3 Home and navigation UI tests passed again.
- Home screenshot (not published)

| What | How |
|---|---|
| **Triptych UI redesign (revamp step 3)**: new `app/Triptych/Design/` tokens from `docs/brand/triptych-icon.svg` (blue Windows, violet Mac, amber Linux, dark navy backdrop) and shared components (`TriptychPanelCard`, `TriptychSectionHeader`, `TriptychStatusPill`, `TriptychPrimaryButtonStyle`); three-hinged-panel `TriptychHomeView` with Windows/Mac/Linux hubs; Henge-derived UI (`HengeRoot`, `MacView`, JIT sheets, Settings) replaced by Triptych's `MacSystemView` / `MacInstallView` / `MacDetailView`, shared `SetupView` (JIT, storage, user-supplied images) and shared `TriptychSettingsView`, keeping Export logs and all `CREDITS.md` entries | Simulator build + 24/24 tests passed (`TriptychTests` 8/8, `TriptychUITests` 16/16 offline/local suites incl. `TriptychHomeAboutTests`, `TriptychHengeUITests`, `TriptychMacTests`, `TriptychLogExportTests`, `TriptychWinPCTests`, `TriptychX86PCTests`, `TriptychMacAppsTests`, `TriptychLinuxDesktopTests`, `testLinuxBootsAlpineAndRunsCommands`, `testLinuxImportsCustomZstdRootfsAndBootsIt`; live-network `testLinuxDownloads*`, long Xfce apt install, and local-zip `testCrossOverPreviewImportsAndLaunches` / `testX86PCBootsLinuxMintUEFI` / `testWindowsPCBootsInstallerISOToSetup` not run). Screenshots: (unpublished screenshot) |
| The app builds for the **Simulator** and for **devices** (unsigned) with the Linux and macOS engines linked, no duplicate symbols | `xcodebuild` iphonesimulator / iphoneos `CODE_SIGNING_ALLOWED=NO` |
| Unsigned device IPA | `scripts/package-ipa.sh` → `dist/Triptych-unsigned.ipa` (4.4 MB with the Linux engine; rebuild for the current one) |
| **Linux engine runs in the Simulator**: Alpine 3.22 ARM64 boots to a shell; `cat /etc/alpine-release` → 3.22.2, `uname -m` → aarch64, `$((6*7))` → 42, pipes and fork/exec work | UI test `testLinuxBootsAlpineAndRunsCommands` (screenshot `docs/screenshots/linux-terminal.png`) |
| **Linux socket console fallback (2026-11-22)**: When iOS denies access to a host pty, the bridge requests a guest controlling tty from LinuxRunner and carries its input and output over a socket pair. The socket console starts at 80 columns by 40 rows and adopts the terminal view’s dimensions when it lays out. | UI test `testLinuxBootsWithSocketConsole` on the iPad Pro 11-inch (M5) Simulator with `TRIPTYCH_LINUX_NO_PTY=1`. The test covers the Alpine prompt, commands, `/dev/tty`, and shell exit. Physical iPad verification is pending. |
| **Neutral Linux host name (2026-11-25)**: Fresco no longer copies the host’s name (the Mac’s in the Simulator, the device’s on iOS) into the guest. `engines/linux/patches/triptych-neutral-hostname.patch` makes `uname`, `gethostname`, `hostname` and `/proc/sys/kernel/hostname` report `triptych`, so the shell prompt and Xfce terminal titles show `triptych`. `/etc/hostname` comes from the distribution image (Alpine: `localhost`), never from the host. | UI test `testLinuxBootsAlpineAndRunsCommands` on the iPad Pro 11-inch (M5) Simulator checks `uname -n`, `/proc/sys/kernel/hostname`, `hostname` and the prompt, and that the host’s name does not appear. |
| The Home screen lists all three systems | UI test `testHomeListsAllThreeSystems` |
| **Home screen lists every system** with its readiness and verified progress. Android has no runtime in the app. The x86 PC page is ready when the QEMU frameworks are bundled. **About** shows every section of `CREDITS.md` plus the BCD, iSH and Alpine notices | UI test `testHomeListsEverySystemAndAboutShowsCredits` |
| **Linux desktop in the app**: on the Linux page's Desktop tab, Xfce 4.20 (Ubuntu 26.04, llvmpipe) starts on Xvfb; its shared-memory framebuffer shows in the Metal canvas at 1280x720 and a tap opens the Applications menu through the XTest agent. The iOS engine is now built with the fakefs case-alias patch | UI test `testXfceDesktopShows` (iPad Pro 11-inch Simulator; the Xfce rootfs is cloned in from `build/linux/ubuntu-fs`), screenshots (unpublished screenshot) |
| **macOS engine (Henge) links and runs in the app** (`henge_make_aux`); its MAP_JIT probe passes in the Simulator | UI test `testMacEngineLinksAndProbesJIT` |
| Gesso tests on the Mac include 117 MMU checks, 52 exception checks and 143 device checks | `make -C engines/gesso test` |
| **Gesso in-tree (`engines/gesso/`)**. Henge source at `9cf6d26` includes all 37 patches in `engines/macos/patches/series` and retains GPL-2.0-or-later. See `engines/gesso/UPSTREAM.md` for the import and upstream maintenance history. | `make -C engines/gesso test`, `make -C engines/winvm test`, `scripts/build-winvm.sh iphonesimulator`, `scripts/build-macos-engine.sh iphonesimulator` |
| Henge engine + iOS dependencies (glib 2.83, libslirp 4.9.1, pcre2 with JIT off, proxy-libintl) build for iphoneos and iphonesimulator; restore stack for iphoneos | `scripts/build-henge-deps.sh`, `scripts/build-macos-engine.sh` |
| LinuxRunner core builds for iphoneos and iphonesimulator | `scripts/build-linux-engine.sh` |
| Fixed: the guest vDSO isn't built without `ld.lld`, so forked programs crash on signal return | `brew install lld`; the script now refuses to build without it |
| **Linux distro downloads & custom import**: Alpine latest (3.24.4, `apk update`), Ubuntu Base 26.04.1 (`apt`), Debian 13 Trixie (`apt`, `PAM.7.gz`/`pam.7.gz` case alias), Fedora 45 WSL (`dnf5`, `terminfo/A`/`a` and `_Exit.2.gz`/`_exit.2.gz` case aliases), Arch Linux ARM (`pacman` 7.1.0), and a custom `.tar.zst` rootfs (streamed via LinuxRunner's vendored Zstandard 1.5.7 decoder) all verify checksums/import into fakefs with host DNS in `/etc/resolv.conf` and boot to a shell | UI tests `testLinuxDownloads*`, `testLinuxImportsCustomZstdRootfsAndBootsIt` |
| **Windows engine in the app**: Madeira (with the fix series) rebuilt as `MadeiraRuntime.framework` (a dylib exporting `madeira_embed_make_root`), embedded with its Wine/FEX/DXMT files, JIT helper and memory host; the device app builds | `scripts/build-windows-engine.sh`, `scripts/package-ipa.sh` |
| Device IPA with all three engines: `dist/Triptych-unsigned.ipa` (205 MB), ad-hoc signed with Madeira's sideload entitlements | `scripts/package-ipa.sh` |

## Not possible in the Simulator (needs a real device)

- **JIT through a debugger** (StikDebug / built-in StikJIT). The Simulator runs apps as
  Mac processes and has no TXM.
- **Henge's JIT and the Mac loader.** The Simulator allows MAP_JIT but refuses the
  writable alias Henge's split-mode JIT needs (`vm_remap` → protection failure). Henge's
  fallback route hung the app when tried. Booting a Mac, installing macOS (about 43 GB
  free, Apple's restore image) and running Mac programs need a device with an A14 or
  M1 or newer.
- **Windows engine.** FEX, Wine and DXMT are built for iphoneos only, and the engine
  needs JIT.
- **Performance and frame rates** of any kind. There are no numbers in this repo:
  measure on a device. Compare against the same software on a Mac (CrossOver Preview,
  NotProton, UTM) using the same settings.

## Not done yet (in order; the research swarm follows this list)

The user wants **no IPA handed over until every item below is done**; `dist/` builds are for testing here only.

1. **Windows engine on a device** (built, never run): Madeira's whole app (library,
   game pages, JIT setup, controllers, touch controls, Steam/GOG/Epic/itch stores) runs
   inside Triptych from `MadeiraRuntime.framework`. Separate dylib = separate Rust
   runtime and no `current` clash. Its `madeira_early_va_claim` constructor now runs at
   dlopen; it uses `VM_FLAGS_FIXED` without overwrite, so it fails safely if
   0x140000000 is taken. Open questions: is that range still free at dlopen on iOS
   26/27 (it must be: Windows has to be the first engine started)? Memory with Wine +
   FEX pools under the app's limit? Does Madeira's built-in JIT helper work under
   Triptych's bundle ID?
2. **BCD's extra layer** on top of Madeira (BCD §7 terms).
3. **Linux** (the user requires all of this before the IPA):
   - Done (2026-11-16, Simulator): Alpine-latest, Ubuntu, Debian 13 (Trixie), Fedora 45 (WSL), Arch Linux ARM downloads and a custom `.tar.zst` archive import all pass end-to-end UI tests (real iOS Files picker UI is not driven by XCUITest; `importFile` tested via `TRIPTYCH_IMPORT_ARCHIVE` on the Simulator).
   - Graphical desktops (GNOME, KDE, Xfce, Cinnamon) on the GPU path, virglrenderer + ANGLE on Metal, with touch, keyboard and mouse. Reference: crate (oneamendez, MPL-2.0) already runs GPU-accelerated GNOME/KDE VMs on iOS; evaluate embedding it ((private notes)).
     Xfce is in the app (Desktop tab: Install Xfce types the package install into the console, Start Xfce runs `/opt/triptych/triptych-desktop`, an engine bind mount with the input agent; software rendering). Still to do: the in-app Install path run end to end (only the Mac host install has run; apk/pacman package lists untested), screen size following the view, GNOME/KDE/Cinnamon, the GPU path.
   - A "Mint-style" option: Ubuntu ARM64 with the Cinnamon desktop. Linux Mint itself is x86-only.
   - Boot ARM64 installer ISOs (Ubuntu, Fedora, Debian) on the winarm board.
   - The optional ARM64 JIT build.
   - x86 Linux programs (and Steam for Linux) inside the ARM64 Linux engine through FEX-Emu, as on Valve's ARM hardware.
   - Done: the real terminal (SwiftTerm on the engine's pty).
4. **Windows full VM ("winarm" board, `engines/winvm/`)**, Mac-first with `make -C engines/winvm`:
   - Done and verified on the Mac:
     - The board runs on Henge's CPU core with a QEMU `virt` memory map, CFI flash, fw_cfg (with DMA), a device tree, ramfb and PSCI over SMC (`triptych-psci-smc.patch`).
     - It has ACPI 6.3 tables: DSDT from `dsdt.asl`, a CPU SSDT, FADT, MADT, GTDT, MCFG and SPCR.
     - EDK2 edk2-stable202608 builds from source (`scripts/build-edk2.sh`, also `BUILD_TYPE=DEBUG`). It boots to the boot manager on winarm, installs the ACPI tables and sets up the 800×600 ramfb.
     - Storage, USB and Linux (2026-11-13):
       - NVMe (`nvme.c`): EDK2 boots GRUB from it.
       - xHCI USB (`usb.c`) with a HID keyboard, a HID tablet and BOT/SCSI mass storage (`--cdrom`, `--usbdisk`).
       - The Alpine 3.24 aarch64 ISO boots from the USB CD-ROM in ACPI mode, with 2 CPUs and 2 GB, to the login prompt (kernel 6.18).
       - The USB keyboard works in EDK2 and Linux.
     - Known gaps:
       - DT mode (`acpi=off`) doesn't boot, because EDK2 publishes no DTB while ACPI is installed. Windows only uses ACPI.
       - The tablet has no EDK2 driver (Linux binds it).
       - PL011 drops characters when a whole line arrives at once.
   - Casement in the iOS app runs the board with a ramfb display, touch and keyboard input, using Gesso's JIT region and helper.
        - Done 2026-11-15 (Simulator): `scripts/build-winvm.sh <sdk>` builds `libwinvm.a` (board + its own 4 KB-TLB Henge core, all symbols private except `winvm_host_*`, so it links beside `libhengevm`); host API in `app/WinVMHost/winvm_host.c`; page `WinPCView.swift` (ISO picker from Files, sparse 64 GB NVMe, UEFI vars, ramfb on a CALayer at the guest's size, touch to the USB tablet, hardware and soft keyboard to the USB keyboard, "Needs JIT" label). UI tests `TriptychWinPCTests` pass: EDK2's firmware draws its boot screen on the page (screenshot `20261115-0650-winpc-edk2-on-ios-simulator.png`; it says "No bootable option" because no ISO was picked).
        - Simulator JIT: the app's MAP_JIT writes fault there even with `pthread_jit_write_protect_np(0)`, but Henge's split mode (RW alias + RX original) works, so the Simulator build sets `HV_JIT_SPLIT`. The Simulator entitlements file leaves out `dynamic-codesigning`.
        - TPM 2.0 on iOS (2026-11-21): `scripts/build-libtpms-ios.sh <sdk>` cross-builds OpenSSL 3.5.9 libcrypto (sha256-pinned) and libtpms v0.10.2; `scripts/build-winvm.sh` links both into `libwinvm.a` with every symbol hidden; the page passes a TPM state file when `winvm_host_has_tpm()`. Test `engines/winvm/tests/tpm_test.c` drives the TIS registers like a guest driver (localities, DATA_FIFO and XDATA_FIFO with 1/4/8-byte accesses, Startup, GetRandom, SHA-256 known answer, ECC P-256 and RSA-2048 primaries, NV define/write/read, state restored across a restart, board reset). Passes on the Mac (`make -C engines/winvm test`) and in the iOS Simulator (`scripts/test-tpm-ios.sh`, `simctl spawn`); the device binary builds (`scripts/test-tpm-ios.sh iphoneos`) but no device is available to run it. In the app (Simulator), UI test `testWindowsPCBootsFirmwareAndShowsDisplay` checks that EDK2 sends the TPM commands (34 at its boot manager). Fixed while testing: XDATA_FIFO (0x80-0xbf) read as 0 and dropped writes; 8-byte FIFO reads overflowed a 32-bit value; libtpms could realloc() a non-heap response buffer; with no NVRAM callbacks libtpms also kept its state in an `NVChip` file in the current directory, which asserted in the app (cwd `/`) and left stray files on the Mac: the board now registers libtpms' NVRAM callbacks, so the state file is the only storage.
        - The picked ISO is kept across launches as a security-scoped bookmark (`PickedFile` in `WinPCView.swift`, also used by the x86 PC page). UI test `testWindowsPCRemembersISOAcrossLaunches` (pick, relaunch, still there).
        - Memory and CPU pickers on the Windows page (default 4 GB, 2 CPUs; Windows 11 Setup refuses less), the TPM row shows the real build. Installer boot without a keyboard: on a blank disk the board presses Space until the installer has read 32 MB from the ISO (`usb_autoboot_cd`, Mac and app; `engines/winvm/tests/blank_test.c`). Verified on the Mac: the ISO boots to "Select language settings" with no key presses. `WINVM_SERIAL_LOG=1` sends the guest serial console to `WindowsPC/serial.log`.
        - EDK2 installer crash (2026-11-22): `scripts/build-winvm.sh` omitted Henge's `-mgeneral-regs-only` for `mmu.c`. Clang used v0 to zero an `HvWalk` in `hv_mmu_walk`. The JIT's light TLB refill calls that code with the guest SIMD registers live, so it clobbered guest v0. The device and Simulator library builds now use the same flag as Henge's Makefile. `scripts/test-winvm-refill-ios.sh` checks that a translated load takes one light refill and preserves all 32 guest SIMD registers. The same test linked against an MMU object built without the flag reports v0 corruption.
          - Simulator ISO boot with TLBI block invalidation enabled reproduced EDK2's exception at `0x46519EF8` after about 1 MiB of reads with the old compiler flags. It reproduced with the normal split mapping and with the device startup path given a 512 MiB slice at the top of an 896 MiB JIT region whose aliases were about 476 GB apart. The fixed build read 612 MiB and passed EDK2 in both layouts. On the Mac, `winvm` with block invalidation enabled reached Windows 11 Setup's language screen. Disabling block invalidation also let the old build pass EDK2 in the Simulator. The TLBI workaround stays on by default pending a physical iPad retest. The earlier bisection is in WINVM-EDK2-CDBOOT-BUG.md in the side-session notes.
        - Network (2026-11-21): `usb.c` has a USB CDC NCM Ethernet adapter on Henge's libslirp NAT (`hv_net_attach_rx`, patch `triptych-net-attach-rx.patch`); `winvm --net`, always on in the app. Windows 11's inbox UsbNcm driver binds it with no driver install, gets 10.0.2.15 by DHCP and passes OOBE's network check (screenshot (unpublished screenshot)). Test: `tests/ncm_test.c` (NTB builder/parser incl. malformed blocks; DHCP OFFER and ARP through net_slirp) in `make -C engines/winvm test`. Not yet: throughput numbers, the adapter on a device.
        - Windows 11 (build 26300) desktop reached on the Mac (2026-11-21): OOBE done with a local account (Shift+F10, `start ms-cxh:localonly`), privacy options off. Screenshot (unpublished screenshot). `winvm`'s typing (WINVM_TYPE / ctl `type`) now covers all printable US-layout ASCII (it dropped `:`, `\\` and shifted symbols), and ctl has `key MOD USAGE` for chords.
        - Pending verification: Windows installation from an ISO in the iOS app and the device path with Gesso's debugger-supplied JIT region.
   - **Windows 11 install progress (2026-11-15, Mac):** Windows 11 Setup's UI runs on 1 and 4 CPUs ((unpublished screenshot)).
     - Fixed:
       - FEAT_LSE2 (`triptych-winarm-lse2.patch`): the clock's unaligned STLR looped forever in the TLB refill.
       - 16 KB masks left in the 4 KB TLB build (`triptych-winarm-pagemask4k.patch`).
       - User-mode PMU access now traps through PMUSERENR instead of being UNDEFINED (`triptych-winarm-pmu-el0.patch`). The old behaviour killed csrss.
       - The GIC resets with the board.
     - Was: Setup said "Install driver to show hardware", because it saw neither disk.
       - NVMe: Windows' stornvme never touched the controller. The PCIe capability said "endpoint" on the root bus. It is now a root-complex integrated endpoint, like QEMU's (in test).
       - USB: fixed. Windows chains an Event Data TRB after a control transfer's Status stage, and the xHCI ended the TD at the Status TRB, so every device timed out after 5 s. Setup now reaches "Select language settings" (`20261115-1430-windows11-setup-language.png`). Next: click through (Next, Install now), let Setup list the NVMe disk, and start the install.
     - Debug switches in `winvm_main.c`: WINVM_GICDBG, WINVM_DUMP_AT, WINVM_RESET_SHOTS, WINVM_LOG, WINVM_USB_LOG=2, WINVM_NVME_LOG.
     - Run recipe: the side-session note WINDOWS-HANDOFF-2026-11-15.md.
   - Open questions: does Windows 11 ARM need any other ID-register or CPU features Henge doesn't emulate? Which virtio-win ARM64 driver versions are signed (for later virtio-net/gpu)?
4b. **Whole x86-64 systems (user asked 2026-11-13):** an x86 PC emulator for x86 ISOs (Linux Mint, SteamOS, x86 Windows).
   - Base it on QEMU's x86 system emulation, the way UTM / UTM SE do on iOS: TCG with JIT when JIT is available, the TCG interpreter without.
   - The app labels it slow: fine for desktops and apps, not for games.
   - Verify Linux Mint's ISO boots on the Mac build, then in the Simulator.
   - Progress 2026-11-15: QEMU shared lib builds for iOS Simulator / iOS / iOS TCTI (`scripts/build-x86pc.sh`); Alpine x86_64 boots to login on the Mac (25 s) and in the Simulator harness `engines/x86pc/harness` (23 s; TCTI without JIT 232 s). Numbers and the app integration plan are in (private notes). Next: the app page (integrate chain), then Linux Mint's UEFI ISO.
   - Progress 2026-11-16: slirp networking verified in the Simulator (JIT and TCTI dylibs: DHCP, wget from host and internet); TCTI runs multi-threaded, 4 vCPUs beat 1 (boot 184 s vs 257 s). Next: QEMU UI backend patch (display surface callback + input) for the app page.
   - Progress 2026-11-17: **x86 PC app page in Triptych** (`app/Triptych/X86PCView.swift`, `app/Triptych/Bridge/x86pc_host.{h,m}`). Loads the JIT framework in the Simulator and the TCTI framework on devices without a debugger; ISO picker, qcow2 disk via bundled qemu-img, RAM/vCPU/BIOS-UEFI/NAT controls, "very slow, not for games" banner, screendump display, key row and typing via HMP sendkey, QMP quit. `TriptychX86PCTests` pass in the Simulator: Alpine 3.22.2 x86_64 reaches `localhost login:` on serial with `-nic user,model=virtio-net-pci`. iphoneos Release builds (`CODE_SIGNING_ALLOWED=NO`). Not done: touch/pointer input (needs an absolute pointing device), the QEMU display callback, and an on-device TCTI boot test. Screenshots: (unpublished screenshot).
   - Progress 2026-11-20: **display, touch and keyboard wired** (`engines/x86pc/patches/0001-ui-triptych-display-backend.patch` + `triptych_ui.h`, `-display triptych`, `virtio-tablet-pci`, `x86pc_host_{fb,tablet,key,stop}`; Quit stops QEMU through `x86pc_host_stop()`). Verified in the Simulator: `TriptychHomeAboutTests`, `TriptychX86PCTests` (page, Alpine login, keyboard reaches the guest, Linux Mint UEFI frames + tablet tap/drag + Quit), iphoneos Release build; ios and ios --tci rebuilt with no GPL-2.0-only code linked (only `Linux-syscall-note` UAPI headers; stale igb depfiles are not linked). EDK2 licence text bundled, PCRE2 credit completed. Not verified: real device, a real-finger touch feel.
4c. **Mac apps translated, without a macOS VM (user asked 2026-11-14):** run individual Mac apps directly in Triptych, the way Madeira runs Windows apps.
   - Approach: load Mach-O directly, since iOS shares dyld, XNU, libSystem, Foundation and Metal; reimplement AppKit on UIKit; translate x86-64 Mac apps.
   - Never bundle Apple binaries. Research is in (private notes).
   - Plan from the research, in phases:
     - spike: "MacAppHost", which retags a tiny arm64 AppKit+Metal app to iOS, signs it, dlopens it with get-task-allow, and gives it a minimal AppKit shim on UIKit, using the pattern of macos-on-ios (MIT) and LiveContainer (AGPL-3.0);
     - simple open-source AppKit apps;
     - broader AppKit (darling-cocotron, MIT) and CoreServices;
     - closed-source arm64 apps;
     - x86-64 last (FEX).
   - Install from the user's own files, never downloaded by Triptych:
     - `.dmg` disk images (UDIF with zlib/bzip2/LZFSE/ADC chunks, HFS+ or APFS inside; candidate readers: 7-Zip's DMG/HFS/APFS code (LGPL), darling-dmg (GPL-3.0), apfs-fuse (GPL-2.0+));
     - `.pkg` installers (xar + pbzx/cpio payloads);
     - `.zip` files with an `.app` inside.
     The `.app` goes into Triptych's Mac app library as an icon. Picked from Files, the share sheet or AirDrop.
   - Milestone tests (the user's own copies, read in place from /Applications and ~/Downloads, never bundled):
     - **CrossOver Preview**: arm64, PyObjC UI. It needs process creation (wine, wineserver) faked inside one app, as Madeira does.
     - **Steam Mac client**: universal; `steam.dmg` is only the bootstrapper. Its UI is Chromium (steamwebhelper).
     - **Heroic 2.22** and **CurseForge**: Electron. They need Chromium/Electron support, i.e. multi-process, JIT and GPU.
   - Estimate: 2-5% of Mac apps in phase 1, 10-20% with a mature AppKit layer. Electron apps are out of reach.
   - Done in the app (2026-11-15): "Mac apps" page (`MacAppLibraryView`, framework `app/MacAppsKit`, `scripts/build-macapps.sh`). Imports a .dmg/.pkg/.zip with macpkg built for iOS, keeps the `.app` bundles in Application Support/MacApps, lists them with their icons, and launches a retagged app through the loader ported from MacAppHost plus the AppKit shim dylibs embedded in `Triptych.app/Frameworks`. Simulator UI test `TriptychMacAppsTests`: the bundled sample zip goes through macpkg, TestMacApp is listed, tapping it shows its NSWindow and the button counts taps.
   - Done (2026-11-15): in-app retag + ad-hoc signer (`app/MacAppsKit/MacRetag.c`, retag.c compiled in, in-process CodeDirectory signature); a Mac-built, not-retagged sample imports, launches in the Simulator and passes `testMacBuiltAppIsRetaggedOnImportAndLaunches`. This import and launch path is now Simulator-only. The file picker path is untested in UI tests (XCUITest can't drive Files). The guest's `main` keeps the run loop, so only one app can run per session. The page uses the engine lane's shim sources as they are in the working tree (read-only, built by script).
   - CrossOver Preview in the Mac apps page (2026-11-21, Simulator, the user's own 20261111 zip read in place from ~/Downloads, never bundled):
     - Done: import retags and signs every arm64 Mach-O in the bundle (`MacRetagBundle`: 196 files, including Python.framework, PyObjC's extension modules, Sparkle, ArcadeKit, wineserver/wine; 113 x86_64-only files left alone). `@executable_path` in guest load paths and rpaths becomes `@loader_path/<rel>` (`retag --exe-rel`), since the dlopened guest's executable path is Triptych's. Import runs off the main thread.
     - Done: `tools/macapps/linkcheck.py` resolves every import of every Mach-O against the shims and the iOS Simulator SDK, the way dyld will. The startup set (main executable, Python, ArcadeKit, Sparkle) links with 0 missing symbols after adding the SwiftUI and swiftCore shims to `scripts/build-macapps.sh` and stubbing Sparkle's Security-transform, AppKit-binding and colour-space symbols. Test: `tools/macapps/test-retag-bundle.sh` (unit tests for the path maths and the fat/Java-class check, then the whole CrossOver bundle).
     - Done: launch (UI test `testCrossOverPreviewImportsAndLaunches`, skips without the zip). CrossOver's `main` runs, Python and PyObjC start, its nib loads, and `applicationWillFinishLaunching` reaches its Rosetta check. Shim fixes: `NSWindowController` loads its nib once, from the owner's bundle (Sparkle's recursion crash); `+sharedApplication` creates the Info.plist principal class (CXApplication); `runModalForWindow:` shows the window and runs the run loop until `stopModal`; the guest's stdout/stderr go to `MacApps/<app>.log`.
     - Done: one AppKit per process. Henge's translation layer (`libhengetl` with its own NSWindow, NSView, ..., plus `henge-tl.c`/`henge-tl-app.m`) is now `HengeTL.framework`, embedded but not linked, and dlopened on first use (`app/Triptych/Henge/HengeTLLazy.c`). Linked into Triptych, its classes won the Objective-C name table, so nib loading and PyObjC in a Mac-apps guest got Henge's classes. Whichever of the two runs first in a launch blocks the other with a "reopen Triptych" message. `testMacEngineLinksAndProbesJIT` (Henge TL via the lazy loader) still passes.
     - Result (2026-11-21): CrossOver's windows attach to the screen (Rosetta prompt, then Sparkle's update prompt in front).
     - Done (2026-11-22): the first window draws its contents and its buttons are laid out. `CFBundleIsArchitectureLoadable(x86_64)` answers yes (Triptych supplies x86 translation; iOS has no Rosetta to install), so `rosettaCheck` no longer opens its modal "Install Rosetta" prompt. For apps with `SUFeedURL`, `MacAppsQuietSparkle` turns Sparkle's automatic checks off in the guest's defaults, so its update prompt no longer opens. CrossOver now reaches its own license window ("CrossOver Trial": text, Buy…, Unlock with Purchase Info…, Quit), drawn from its nib with bindings applied. The UI test asserts the window with its buttons is shown and that neither prompt opens. Screenshot: (unpublished screenshot).
     - Found (2026-11-22): the window says the trial has expired, even with the user's own license file in the guest's `Library/Preferences`. CrossOver finds the license but checks its signature by running `openssl … -verify` as a subprocess (`fileupdate.is_signed`, seen from the strings of the shipped .pyc, not decompiled), and a guest can't start processes on iOS. "Unlock with Purchase Info…" will hit the same check. So the next blocker is a guest process layer: Python's `fork`/`execve`/`posix_spawn`/`waitpid` (bound in Python.framework through `LC_DYLD_INFO` binds) have to reach Triptych, which runs known tools in-process (an `openssl` signature check through the Security framework first, then wine and wineserver).
     - Device: no device-only blocker found in the code. The guest log (`Application Support/MacApps/<app>.log`) is included in Export logs; the device run that "stopped after attaching the window" was the Rosetta modal, which is gone now. Not run on a device by this session.
     - Simulator (2026-11-23, iOS 27.2, CrossOver Preview 20261111): `testCrossOverPreviewReachesLicensedMainWindow` passed with an existing Simulator license. A local probe called the imported helpers through Triptych's process shim with a unique prefix under the Simulator app's temporary directory. The bundled Perl wrappers `bin/cxbottle` and `bin/wine` both returned `ENOENT` because the shim has no Perl interpreter.
     - The native arm64 `wineserver --version` printed `Wine 11.21` and exited Triptych before `waitpid` could collect its status. After containing the helper's exit on its worker thread, the same command returned exit 0 through the shim. The arm64 Wine loader started, then returned exit 1 for both `--version` and a locally compiled x86-64 Windows console fixture. In both cases dyld failed to load `aarch64-unix/ntdll.so` because `libShim_CoreServices.dylib` lacks `_MPCurrentTaskID`. The fresh bottle did not initialize and the program did not reach its entry point.
     - Runtime follow-up (2026-11-23, iOS 27.2 Simulator, CrossOver Preview 20261111). The Carbon task APIs map to POSIX threads. The next loader error was the missing `___clear_cache` import from libSystem. New imports route binaries that need it through a libSystem re-export that calls `sys_icache_invalidate`. The shim returns `ENOTSUP` for the shipped Perl wrappers and does not fall through to the native Wine loader. It also rejects `POSIX_SPAWN_SETEXEC`, which prevents Wine's request to relaunch with 4 KiB pages from recursively starting worker threads.
     - With those imports resolved, Wine reached `ntdll` and aborted at `set_mem_area_state` on an unaligned reservation size. Loading the native helper with local symbol visibility cleared that assertion. Both the ARM64 and x86-64 console probes then reached `virtual_alloc_first_thread_data`, where Wine reported `c0000017` (`STATUS_NO_MEMORY`) mapping Windows shared user data at `0x7ffe0000`. A separate Simulator executable measured 16 KiB host pages and got `KERN_INVALID_ADDRESS` from a fixed `vm_allocate` at that address. The Simulator refused to launch a Triptych build with a smaller `__PAGEZERO`, including a build whose normal Simulator signature verified. The experimental linker settings were reverted. The licensed main window and `wineserver --version` still worked. Neither probe printed `TRIPTYCH_WINE_SMOKE_OK` or returned a completed child status, so Windows execution and bottle initialization remain unverified.
     - Guest address-space probe (2026-11-23). Gesso executed a synthetic EL0 read at `0x7ffe0000` through guest page tables. The in-process Mac loader still uses host data addresses. A full macOS guest is the candidate for the original signed CrossOver bundle. Pane and Linux Wine are separate fallback runtimes. [Backend assessment and test commands](research/CROSSOVER-GUEST-ADDRESS-SPACE.md)
     - Device, JIT region sizing (2026-11-22): on the iPad the writable alias of the JIT region landed ~24 GiB from the code view (rw=0x7000b0c000, rx=0x10a078000), out of the TL loader's adrp reach (±4 GiB), because the claim took the whole largest low gap and left no low room for the alias. Fixed in `henge_ios_jit_fit_low` (`engines/gesso/ios/Henge/Native/henge-ios-jit.c`): the claim is now capped to `max(second-largest low gap, half the largest)` so the code view and its same-size alias both fit below 0x7000000000 and within adrp reach. Test `scripts/test-jit-lowgap-ios.sh` (`engines/macos/tests/jit_lowgap_test.c`) builds for the Simulator and asserts the invariant `2*claim ≤ largest+second` and that the claim is never a whole gap; all fixtures pass. Tradeoff: on a crowded device this roughly halves the guest's JIT memory (iPad 936→~468 MiB); a far alias is simply unusable for the Mac/TL path, so correctness wins. Not yet run on a device.
     - Device loader (2026-11-24). Atelier imports arm64 Mac bundles without retagging or re-signing and runs the executable and its bundled dependencies via Gesso's translation loader using the device JIT mapping. The Simulator defaults to retagging and `dlopen`. With `TRIPTYCH_FORCE_TL=1`, the Simulator exercises the translation loader with a Mac-built sample and reaches CrossOver Preview's startup window from the original local archive. Physical-device launch still needs verification.
4d. **Android apps (user asked 2026-11-14):** add Android as a system, based on Husk (Leviidev, GPL-2.0-or-later, https://github.com/Leviidev/Husk).
   - The translation layer builds via `engines/android/build.sh`. Runtime integration in the app is pending.
   - Two modes:
     - translation layer: the APK's own arm64 code runs natively, with Android's libc, Java, GL, Vulkan, audio and input supplied around it;
     - full LineageOS under QEMU, as the fallback.
   - The user supplies the APKs. No Play Store bypass and no paid-app piracy.
   - Verify a free open-source APK (e.g. from F-Droid) in the Simulator, then on device.
   - Credit in CREDITS.md (already listed); show a Husk notice on the About screen if its licence asks for one.
5. **Metal Shader Converter**: bundled in IPA builds and releases (owner's decision, 2026-11-25).
   Optional: ask the Henge author for the same exception Madeira grants.
6. **Device-only checks** for whoever has an iPad:
   - the JIT script alias;
   - built-in StikJIT pairing;
   - a Henge install and boot;
   - Madeira game launches;
   - performance, compared with the same software on a Mac (CrossOver Preview,
     NotProton, UTM).

## Windows engine build (Pane)

`scripts/build-windows-engine.sh iphoneos` builds Madeira (Wine ARM64EC, FEX, DXMT, madeira-d3d12) and turns its
app target into `MadeiraRuntime.framework`, which Triptych dlopens only when Pane starts. That keeps Madeira's
early address-space claim (about 1.1 GB at 0x140000000) and its signal handlers out of other systems' launches and
keeps the two Rust runtimes apart. Pane must start before anything else takes that range; Triptych offers a restart
when it is not free. Apple's libmetalirconverter is bundled for DirectX 12. The engine is iOS-device only and has not run on a
device yet.

## Upstream fixes applied (2026-11-13)

`scripts/apply-upstream-fixes.sh` applies `engines/<engine>/patches/series` on a local
`triptych-fixes` branch in each submodule:
- **Henge:** 20 unmerged fix PRs. Built and tested: `make test` passes (devices 143
  checks), the 4 Simulator UI tests pass, and the device build succeeds.
- **Madeira:** 8 unmerged fix PRs plus 3 fixes from issues (bcd-games #36 deferred
  texture release, #38 D3D12 bundles, Madeira #329 gdiplus/mlang). Checked to apply,
  **not built yet**. The #38 patch is ported from BCD code, so the changed file carries
  BCD Material: keep BCD's attribution line (LICENSE-BCD.md §4b).
- Workarounds and settings found in issue comments are listed in
  [KNOWN-FIXES.md](KNOWN-FIXES.md).
- Left out on purpose: patching a game executable to get past Steam DRM (bcd-games
  #116), and SteamStub/DRM handling (Madeira #234).

## Testing on your iPad

1. Download `Triptych-0.1.0-unsigned.ipa` from the [Releases page](https://github.com/RageMC/triptych/releases),
   or build your own with `scripts/package-ipa.sh` → `dist/Triptych-unsigned.ipa`.
2. Sign it with your own Apple ID (Sideloadly / AltStore / SideStore). Keep
   `get-task-allow`, and add Increased Memory Limit if you can.
3. Linux works without JIT: open Linux → Start, then type commands.
4. For macOS and Windows: install StikDebug with a pairing file, connect LocalDevVPN,
   then tap Enable with StikDebug in Triptych. Pane also offers its built-in StikJIT
   pairing inside its screens.
5. Some systems cannot share one launch of the app (Pane reserves address space at a fixed place). Triptych
   says so and offers a one-tap restart into the system you picked (see "Restart in place" below).
6. A free Apple ID signs at most 3 apps; this IPA uses 4 App IDs (app + JIT helper +
   Madeira JIT helper + memory host) of the 10 allowed per week.
7. **Sending logs:** tap **Export logs** (Home → Help, About, the toolbar of every
   system page, the strip above the macOS page). It zips every log of this run and
   the previous one (Triptych's own `Logs/triptych.log` and `Logs/stderr.log`, Henge's
   `henge*.log`, Madeira's `madeira-*.txt`, Windows PC and x86 PC `serial.log`, Mac
   apps / Android `*.log`) with `00-device-and-app.txt` (device, iOS, build commit,
   LiveContainer, JIT flags, engines) and opens the share sheet. Files over 16 MB keep
   their last 16 MB. The Windows PC serial console is now always logged
   (`WINVM_SERIAL_LOG=0` turns it off).

## JIT status (fixed 2026-11-21)

The macOS setup sheet said "JIT is on. a Mac can start." while Settings → JIT → Status
said Off. Cause: two predicates. The sheet counted any debugger tracing Henge
(`debuggerUsable`); Status used `ready`, which on a TXM device (iPadOS 26+, the
user's iPad16,6) is true only once the JIT region is held. Inside LiveContainer a
debugger traces Henge from launch, and the region claim then failed (trap not
answered / region placed above 0x7000000000), so the sheet was wrong. Now both read
`JITBootstrap.state` (on / claiming / failed(reason) / off); the sheet claims the
region itself when a debugger attached outside Henge's watch, and shows the failure.
Patch: `engines/macos/patches/triptych-jit-state.patch`; tests:
`app/TriptychTests/JITStateTests.swift`. Inside LiveContainer the built-in StikJIT
helper (an app extension) is not registered with iOS, so it reports "could not be
found"; the message now says to launch with JIT from LiveContainer/StikDebug or
install directly. The `canOpenURL ... stikjit://` lines in the log are LiveContainer's
own Info.plist query list (the guest's LSApplicationQueriesSchemes is not used) and are
harmless.
- Not yet verified on the device. Known Simulator quirk: on the iPad Pro 13" Simulator
  (iOS 27.2) the macOS row does not open its full-screen page in UI tests (the
  existing `testMacOSPageShowsHengeInstall` fails there too); it passes on iPhone.

- JIT on device under LiveContainer (2026-11-21, iPad16,6 / iPadOS 27.2 logs): the JIT claim failed on every try because Henge's 1.5 GB reserved block is mapped at 0x7000b04000 when LiveContainer loads the app, so releasing it handed the debugger a region above 0x7000000000, where generated code does not run. The in-tree Gesso JIT allocator asks for what fits the largest free room below the limit (16 MiB steps, 256 MiB minimum; about 900 MiB on that iPad), and if a region still lands high it holds it and asks for less. Clear messages for that case and for LiveContainer's missing JIT helper extension. Test `scripts/test-jit-lowgap-ios.sh` (Simulator). Not yet confirmed on the iPad. Windows PC page now says why Start is off (one system per launch). Log export: fixed file names under LiveContainer and the header's bundle ID (was the running Mac app's).
- Windows PC on device takes the app's JIT region (2026-11-22): `winvm_host_start` used to map its own executable memory (`hv_machine_init` → split mode), which iOS 26+ (TXM) refuses, so the Windows PC could not run on a device even with JIT on. It now takes 512 MiB (or 384/256) from the top of the region claimed at launch (`henge_ios_jit_allocate`), and Mac apps' translation layer writes from the bottom, so Windows PC and Mac apps can run in one launch (`SessionState.canShareLaunch`); other systems still need a relaunch. Simulator keeps split mode. Tests: TriptychWinPCTests, TriptychMacAppsTests (CrossOver import test fixed: its import was skipped when other tests had left apps in the library). Not yet run on a device.
- One-tap system switching (2026-11-22): opening a system that can't share this launch offers "Restart Triptych into X"; Triptych remembers the target, asks LiveContainer (`livecontainer://livecontainer-launch?bundle-name=…`, with JIT if the app's "Launch with JIT" is on) or StikDebug (`stikdebug://enable-jit?bundle-id=…`) to start it again, quits, and the new launch opens X (`app/Triptych/Relaunch.swift`). Home rows are whole-row buttons. Not yet verified on a device (whether LiveContainer relaunches its running guest from that URL); if nothing relaunches, tapping Triptych's icon still lands on X. Next (Codex lane): stop/start the same system in place, more pairs sharing a launch.
- Device run 2026-11-22 (iPad16,6, iPadOS 27.2, LiveContainer, build 4f6a7c2): JIT works (512 MiB region at 0x115c00000, self-test passed) and the Windows PC booted the installer to Windows' kernel, which bugchecked (0xC000007B in the frame; print_bugcheck still to fix); another run stopped at EDK2's "Synchronous Exception at 0x46509EF8" (the TLBI/coherency bug) despite HV_NO_TLBI_BLOCK. Fixes after that run: the JIT region is claimed when Triptych opens (Home), not only on the Mac VM screens, so Mac apps opened first (CrossOver) have it; the Windows PC display retakes keyboard focus on every tap, logs the first hardware keys, and has a "Press a key" button for "Press any key to boot from CD or DVD".
- One-tap system switching (2026-11-22): opening a system that can't share this launch offers "Restart Triptych into X"; Triptych remembers the target, asks LiveContainer (`livecontainer://livecontainer-launch?bundle-name=…`, with JIT if the app's "Launch with JIT" is on) or StikDebug (`stikdebug://enable-jit?bundle-id=…`) to start it again, quits, and the new launch opens X (`app/Triptych/Relaunch.swift`). Home rows are whole-row buttons. Not yet verified on a device (whether LiveContainer relaunches its running guest from that URL); if nothing relaunches, tapping Triptych's icon still lands on X.
- Device run 2026-11-22 (iPad16,6, iPadOS 27.2, LiveContainer, build 4f6a7c2): JIT works (512 MiB region at 0x115c00000, self-test passed) and the Windows PC booted the installer to Windows' kernel, which bugchecked (0xC000007B in the frame; print_bugcheck still to fix); another run stopped at EDK2's "Synchronous Exception at 0x46509EF8" despite HV_NO_TLBI_BLOCK. Fixes after that run: the JIT region is claimed when Triptych opens (Home), not only on the Mac VM screens, so Mac apps opened first (CrossOver) have it; the Windows PC display retakes keyboard focus on every tap, logs the first hardware keys, and has a "Press a key" button for "Press any key to boot from CD or DVD".


## Restart in place (2026-11-22)

- **Windows PC** has a Stop button and can start again in the same launch. The host joins the vCPUs and helper threads, detaches NAT, closes the disks, and releases the devices, RAM and JIT share. Guest power-off and partial startup failures also release their resources. The Windows serial log uses a board-owned file. On device, Windows PC borrows from the app's prewarmed region and returns the reservation without unmapping the region. Verified on the Mac with `make -C engines/winvm all test` and in the iPhone Simulator with `TriptychWinPCTests` and the JIT reservation checks in `jit_lowgap_test.c`. The debugger-backed device path still needs a device run.
- **Mac VM** already supports starting an installed Mac after a normal stop. `henge-vm.c` publishes the stopped state after destroying the machine, and the next boot reuses the app's JIT region. The Mac-host `make -C upstreams/henge test-vm-lifecycle` exercised the app's native bridge through 12 power cycles with synthetic firmware. Booting an actual installed macOS guest twice on iOS still needs a device run. A restore session keeps `installer_session` set because the detached usbmuxd and restore threads use its virtual USB device. There is no restore teardown API and `begin_start` rejects a second boot in that process. Running a program through Henge's translation layer also blocks the VM through `henge_tl_ran` because the loader may have remapped the JIT region.
- **Shared launches** in the Simulator were tested in both start orders for Linux with Windows PC, the bundled Mac app, and x86 PC. LinuxRunner gets a private PTY for its console and uses a fixed argument layout in the app, so starting it leaves libc's `getopt` state free for `qemu-img`. `TriptychSharedLaunchTests` runs shell commands and checks each second engine's display or sample button. The existing Windows PC + Mac apps pairing is also allowed. Other combinations use one-tap Relaunch. Henge's VM consumes the full JIT region, and Henge's translation layer and Mac apps install competing AppKit classes.

## Curator triage fixtures (2026-11-24)

- `TriageTests.testDeviceBundleFindings` runs Triage over scrubbed excerpts of the device log bundles l3–l9 (`app/TriptychTests/Fixtures/lN-*.txt`) and asserts the finding ids. It also asserts each fixture is unchanged by `LogScrubber`.
- **Missing signatures:** (1) "StikDebug is not servicing traps" (l3–l5) only reaches the generic `jit-prewarm` rule, so Curator cannot tell the user to start or pair the JIT helper. (2) Windows bugchecks seen in l6–l9 (`0xC000007B` and `0x50` in the register dump) share one `windows-bugcheck` finding with no stop code. (3) No rule covers the `DriverEntry failed ... uiomap` line in l8 and l9.
- 2026-11-24 LogScrubber hardened: 29 realistic leak samples; fixed bare UDID (8hex-16hex), 'udid/ecid <value>', user@IPv4 leaks (run via standalone harness; Xcode project not generable in worktree: engines/gesso/build missing).
- **Windows PC input** has a C unit test (engines/winvm/tests/hid_test.c, in make -C engines/winvm test) for usb.c's HID reports: keyboard modifier bits 0xe0-0xe7, six-key rollover, release compaction, queue overflow, GET_REPORT, and tablet x/y clamp, buttons, wheel. It passes with no usb.c change.
- **Curator anonymous reporting** has a Worker relay and iOS Hashcash submission. GitHub App and Cloudflare setup are documented in [the relay README](../tools/curator-relay/README.md).

## Accessibility pass (2026-11-24)

- Home: hinged panel cards, Easel and Settings cards read as one VoiceOver element with a hint, section headers carry the header trait, decorative chevrons are hidden, and the Windows/Linux hub rows have identifiers. Status text, pills and stat tiles wrap instead of truncating. `testHomeControlsAreLabelledAndIdentified` covers it (Simulator).
- **Compiler warnings** in `app/Triptych` are cleared for the Simulator build: DNS server cast in `triptych_bridge.c`, two-parameter `onChange` in `MacView.swift`, and an explicit frame pointer in `WinPCView.swift`. Unit tests pass.

**Curator signed fix packs (2026-11-24).** `app/Triptych/Resources/curator-fixpack.json` is a Curve25519-signed envelope (source `tools/curator-fixpack-source.json`, tool `tools/curator-fixpack.swift keygen|pubkey|sign`; the private key lives in `~/.config/triptych/`, never the repo). `CuratorFixPack` verifies the signature against the key compiled into the app, allowlists every setting and value, and applies or reverts a fix with a saved backup. Curator's finding card shows the fix, its changes and Apply / Revert for `jit-region` and `jit-required`. Unit tests cover signature reject, allowlist reject, apply and revert (Simulator). Not yet on a device.
- **UI tests after full screen:** the Casement keyboard toggle no longer changes first responder inside the SwiftUI update pass (it spun an AttributeGraph cycle that froze the app and timed out `WinPCKeyBarUITests`); the framebuffer view updates its accessibility value about once a second and skips unchanged frames. `WinPCKeyBarUITests`, `TriptychFullscreenTests` and `testLinuxAndMacAppsShareLaunch` pass in the Simulator.
- **UI tests verified (fix-integrate-uitests):** TriptychSharedLaunchTests.testLinuxAndMacAppsShareLaunch, WinPCKeyBarUITests.testKeyBarAndKeyboardToggle and TriptychFullscreenTests all pass on an iPad Pro 11 simulator.
**Curator device context (2026-11-24).** Curator reports and the log zip (`00-device-and-app.txt`) start with the Triptych build (the `TriptychCommit` Info.plist key written by `scripts/package-ipa.sh`), device model, iPadOS version, JIT source (LiveContainer/StikDebug/none) and the systems run this launch (`DeviceInfo.contextLines`). `DeviceContextTests` and `LogScrubberTests` pass (Simulator).
- **Curator report flow** is tested end to end with a stubbed URLSession (no network): the review sheet previews the scrubbed text and states the send mode, anonymous reports never carry a token, signed-in reports use the stored token, and a failed send offers "Try again". Fixed: the sheet always sent anonymously and previewed unscrubbed text.
- Curator triage signatures (2026-11-24): added jit-debugger-idle (StikDebug not servicing traps, lever: enable JIT at launch), windows-driver-load (uiomap DriverEntry 0xc00000bb), firmware-boot-timeout and firmware-no-boot-disk (BdsDxe) from device runs l3–l9, with fixture `boot-and-helper-device.txt` and a TriageTests case. Verified with a standalone swiftc harness; the Xcode project could not be generated in this worktree (missing engine build artifacts).
- **Curator FoundationModels & MLX Swift fallback research (2026-11-24)**: the Curator model research documents the iOS/iPadOS 27 `FoundationModels` SDK API (`SystemLanguageModel.Availability`, `.Variant.core3` vs `.coreAdvanced3`, `@Generable` / `@Guide` / `DynamicGenerationSchema`, `Tool` protocol & `DynamicProfile`, 8,192-token context budgeting, `.fmadapter` obsoletion in iOS 27, M4 iPad Pro vs iPhone 15 Pro performance, failure modes) and the `<= 1.5B` 4-bit MLX Swift fallback (`Qwen3-0.6B-4bit` default, `Qwen2.5-1.5B-Instruct-4bit` 6 GB opt-in, 20 MB Metal buffer cache cap, `os_proc_available_memory()` gating and pre-engine eviction); verified in the iOS 27.2 Simulator with `CuratorFoundationModelsTests` in `TriptychTests`.

**Full suite (2026-11-25).** On the iPad Pro 11-inch (M5) Simulator (iOS 27.2): 128 tests passed, 0 failed, 11 opt-in tests skipped.

**Curator ready to go public (2026-11-25).** The on-device model reads the error lines no rule matched on every check and suggests one fix from a fixed remedy list (`CuratorModel.remedies`): Apple Foundation Models with permissive content transformations and one retry, else the downloaded Qwen3-0.6B (Summary/Fix answer). Both ran on a real device log in the iPad Simulator (`CuratorModelUITests`, opt-in). Anonymous reporting runs end to end through the relay Worker under `wrangler dev` (`tools/curator-relay/e2e-local.sh`, mock GitHub API, throwaway App key). Curator screens are full screen. `tools/export-public.py` builds the scrubbed public tree with `RELEASE-CHECKLIST.md`; the owner's account steps are in (private notes).
