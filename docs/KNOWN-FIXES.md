# Known fixes and workarounds (from upstream issues)

Format: symptom -> fix. "confirmed" = a commenter other than the reporter says it worked.
Fixes that are code live in `engines/<engine>/patches/` (see `series`); nested-repo patches would go in
`engines/windows/patches/nested/<repo>/` (none needed so far). Windows patches were checked to apply
(`scripts/apply-upstream-fixes.sh` applies the whole series) but are NOT built or run.

## macOS engine (Henge) - https://github.com/Leviidev/Henge

Workarounds / settings
- Pointer drawn away from where it clicks after changing the Mac's resolution -> set macOS Displays back to Default; resize with Henge's Screen setting instead ([#10](https://github.com/Leviidev/Henge/issues/10); maintainer advice, not confirmed).
- "Not enough memory for the guest's RAM" (4 GB guest, no extra memory) -> sign the app so it keeps `increased-memory-limit` and `extended-virtual-addressing` (paid certificate; with SideStore it depends on the account), or give the Mac 2-3 GB; the install needs at least 2 GB ([#11](https://github.com/Leviidev/Henge/issues/11); reporter confirmed signing with the entitlements made Sequoia work).
- 6 GB iPad: guest killed by jetsam (2 GB) or stuck at the Apple logo (1 GB) -> run GetMoreRam (or iRam-plus.ipa), reinstall Henge, choose "bring in a Mac" from Files, 4 GB guest works but laggy; Ventura avoids the Setup Assistant hang ([#70](https://github.com/Leviidev/Henge/issues/70); two commenters on the same device, partly confirmed).
- Microphone / camera missing in the guest -> use the PR #100 build (liukaixiang817's fork) and enable Camera and Microphone from the running VM's "i" menu; PR #100 is not merged and not applied here ([#55](https://github.com/Leviidev/Henge/issues/55); the PR author tested on iPad Pro M4).
- File picker does not open on iOS 27 (cannot select the StikJIT pairing file) -> create the folder `StikJIT` in Files > On My iPhone > Henge and put the pairing file inside ([#159](https://github.com/Leviidev/Henge/issues/159); reporter confirmed).
- Slow first boot (Setup Assistant plus indexing storm) -> prepare the guest image: setup-done marker, pre-created admin account, disable first-boot indexing/software-update/photo-analysis jobs, comfort defaults (Dock autohide, Reduce Transparency/Motion, Siri off, auto updates off). Measured 39.9 s vs 43.9 s median boot. Warnings: a pre-created account has no secure token (no FileVault), never ship a real password verifier, re-verify the account record per macOS version. Outline only, no script ([#89](https://github.com/Leviidev/Henge/issues/89); reporter's measurement).
- Rosetta 2 in the guest: not supported by Henge's CPU; a comment says it may work with PR #51 (slow, small apps only) ([#16](https://github.com/Leviidev/Henge/issues/16); not applied).

Already included
- Washed-out display (colours sRGB-encoded twice) -> fixed upstream, listed in the checkout's CHANGELOG ([#16](https://github.com/Leviidev/Henge/issues/16)).
- Pointer drift at scaled resolutions -> PR #109 is in our series ([#10](https://github.com/Leviidev/Henge/issues/10)).

## Windows engine (Madeira / BCD) - https://github.com/willfaust/Madeira , https://github.com/thebcd69/bcd-games

Patches added (in `engines/windows/patches/`, appended to `series`; not built)
- issue-36: Metal texture, typed/extra views and resolve_tmp released after two more command buffers complete (crash in `IOGPUMetalCommandBufferStorageReset`); `tex-defer` cfg key (1 default, 0 = release at once); heap-return list drained in batches of 64 until empty ([bcd-games #36](https://github.com/thebcd69/bcd-games/issues/36); reporter tested 7 clean launches).
- issue-38: D3D12 BUNDLE allocators/lists accepted (queues still refuse them), `ExecuteBundle` appends the bundle's commands, rebases constant-data offsets, merges used resources and drops the CBV latch cache; a bundle's initial PSO is applied ([bcd-games #38](https://github.com/thebcd69/bcd-games/issues/38); reporter: launcher menu drew at ~60 fps). bcd-games already has this code.
- issue-329: `gdiplus` and `mlang` added to `build/wine-pe/farm-modules.txt` (MapleStory imports gdiplus; mlang is its delay import) ([Madeira #329](https://github.com/willfaust/Madeira/issues/329); reporter built and loaded them, wine submodule not built here).

Workarounds / settings
- Unity 6 IL2CPP crashes on a tagged pointer (Big Walk, Megabonk, BALL x PIT, probably No Rest for the Wicked) -> `env.MADEIRA_REAL_SUSPEND = 1` ([bcd-games #18](https://github.com/thebcd69/bcd-games/issues/18); confirmed by two commenters). Controller not seen in Unity+Rewired games -> `env.MADEIRA_WGI_HOST_PADS = 1`.
- Skyrim voice acting silent -> install the DirectX redistributable (missing DLLs) ([bcd-games #20](https://github.com/thebcd69/bcd-games/issues/20); commenter advice).
- Unity 6 white screen, window shrinks to 7x33, `[vdcfg-mismatch]` (Replaced) -> `env.MADEIRA_VDCFG_PATH = 1`; the code is already in both trees but is opt-in, and BCD recommendations set it from build 580 ([bcd-games #42](https://github.com/thebcd69/bcd-games/issues/42); reporter's case is the bug this key fixes).
- FF Resonance demo needs the ARM64 VC runtime -> open the game page, "reset to recommended" (build 0.1.576 or later) ([bcd-games #2](https://github.com/thebcd69/bcd-games/issues/2); maintainer; launching the Win64 shipping exe directly on a Steam install was not offered as a fix).
- Games that need extra Wine DLLs (Minecraft Dungeons II: `twinapi.appcore.dll`; D2R: `sfc.dll`, `sfc_os.dll`, `tbs.dll`; Trackmania: `avifil32`, `msvfw32`; network checks: `netprofm`, `sensapi`) -> these are in `farm-modules.txt` / `build-modules.sh`; rebuild the farm. Workaround before that: copy Wine 11.4's x64 DLL beside the exe or into `drive_c/windows/system32` ([Madeira #254](https://github.com/willfaust/Madeira/issues/254), [#354](https://github.com/willfaust/Madeira/issues/354), [#189](https://github.com/willfaust/Madeira/issues/189); load failures cleared by the reporters, the later crashes are unresolved).
- Steam "required app ... not ready" for a shared-depot game -> hand-write the owner's `appmanifest_<id>.acf`; DepotDownloader now writes the owner record ([#189](https://github.com/willfaust/Madeira/issues/189); reporter confirmed the manual record).
- `msvcr110.dll` / `msvcp110.dll` missing -> in `build-modules.sh` defaults; otherwise install the VC++ 2012 redistributable ([#189](https://github.com/willfaust/Madeira/issues/189)).
- No Internet in Windows programs while LocalDevVPN is up; "debugger could not allocate JIT memory" if you switch the VPN off by hand before Play -> use the JIT shortcut and press Play directly, do not turn the VPN off yourself ([#189](https://github.com/willfaust/Madeira/issues/189); reporter observation).
- Fixed-base 183 MB main image (MapleStory) does not fit the 128 MB executable window -> `exe-window-mb` override / automatic widening ([Madeira #329](https://github.com/willfaust/Madeira/issues/329)); the Nexon launcher's 64 GB reservation is still open.

Already included
- Launcher chose `arm64ec-windows` for a 0xaa64 target (0xC000007B, "could not load kernel32.dll"): `madeira_use_arm64ec_for_target` returns NO for ARM64 in Madeira ([bcd-games #44](https://github.com/thebcd69/bcd-games/issues/44), part 1; part 2, running ARM64 images from the JIT-pool copy, is undecided upstream).
- Executable window sized from the main image's PE headers (`fixedBaseWindowMB`) ([Madeira #329](https://github.com/willfaust/Madeira/issues/329)); STP and aliased-LSE store decoding ([#123](https://github.com/willfaust/Madeira/issues/123), merged upstream via #461 per a maintainer comment; present in the checkout's `signal_arm64_ios.c`).
- Steam library retry on failed load ([Madeira #262](https://github.com/willfaust/Madeira/issues/262), merged as #538 per a maintainer comment; not independently checked in the checkout).
- ExecuteBundle / BUNDLE lists already exist in bcd-games (not in Madeira, hence issue-38).

## Unmerged upstream PRs applied (series files)

Henge (`engines/macos/patches/series`)
- #73: Seed the 10-byte vPMU SRAM header in new auxiliary storage so macOS 27.2 installs instead of panicking in restore
- #78: Raise the engine code-cache fallback to 1536 MB: a cold boot at 1024 MB retranslates about 0.96M times, and flushes go to zero at 1536 MB
- #80: vCPU threads default to the user-interactive quality-of-service class on iOS: -1.6 s on cold boot to the hello screen (median 34.5 s against 36.1 s, three runs each), directional, not proven, at this size on a shared host
- #109: Fix the pointer drifting from where it clicks at scaled macOS resolutions
- #110: Show the device's chip in About This Mac instead of "Apple M1 (Virtual)"
- #121: Release unused Mac app address reservations before VM creation
- #128: JIT script: only a brk is a command, and other stops go back to the thread with their signal
- #130: JIT helper: use this device's RemotePairing port, not another device's
- #133: Delete task frees the task the guest named, so a new process no longer gets an ended one's GPU functions (#102)
- #143: Multi-plane surfaces draw into the guest's pages, so Safari's page tiles on macOS 27 aren't blank
- #137: A linear texture's last row needs only its width, so a macOS icon near its buffer's end is drawn
- #138: Sound comes back after a failed start, an interruption or an output change
- #142: Clear the guest's panic store: virtio-blk discard on the aux disk
- #144: Test that aux writes over bdif land past the file header
- #145: Engine: an eviction cleans the instruction cache once for every exit it undoes, and the stats line splits its time
- #146: LiveContainer JIT: claim the JIT region after a later attach, and use the built-in helper with Helper Process Support (#47)
- #147: Read TXM from the device tree instead of the model table
- #148: Plain advice for JIT helper errors about the device's state
- #161: Display refresh time at +0x68: fixes WindowServer's "Timer delayed by <uptime>s" and the interrupt storm
- #112: pvg-metal: the log line reports the GPU's real busy time

Madeira (`engines/windows/patches/series`)
- #585: madeira-d3d12: run the DXIL cache's startup scan on its own thread
- #588: Add reusable x86 denormal and Media Foundation compatibility modes
- #595: Fix clean-build startup for 32-bit OpenGL games
- #600: Fix WinMM sound initialization in child processes
- #609: Child processes: a master-socket slot is reused once its child has exited
- #610: Desktop: the window-tree dump is off unless asked for
- #611: WoW64 start-up: a failed parameter allocation ends only that process
- #620: Steam downloads: a content server leaves the chunk rotation only after repeated failures
