# Contributing to Triptych

Triptych combines Windows, macOS, Mac app translation, Linux, and x86 PC emulation into a single iOS/iPadOS application. The combined work is licensed under **GPL-3.0-or-later** ([LICENSE](LICENSE)), while individual upstream engines and vendored libraries retain their own licenses ([CREDITS.md](CREDITS.md)).

## Reporting Issues

- **In-App Curator Reports (Recommended):** Use Triptych's built-in **Curator** assistant to inspect logs, preview the scrubbed diagnostic report, and file an issue to the public tracker (`RageMC/triptych-issues`) either signed in with GitHub (OAuth device flow) or anonymously via the Cloudflare relay.
- **Manual Issue Reports:** If you cannot file from inside the app, open an issue using the repository issue templates. Include your device model (e.g., iPad16,6), iOS/iPadOS version, JIT attachment method (StikDebug or Built-in StikJIT), and which engine (Pane, Casement, Atelier, Fresco, or x86 PC) you were running.
- **Scrubbing Personal Information:** Always make sure exported logs or pasted snippets do not contain personal host paths (`/Users/<name>`), Apple IDs, IP addresses, or serial numbers. Triptych's `LogScrubber` removes these automatically when exporting through Provenance or Curator.

## Hard Rules for Contributions

1. **No Proprietary Code, Firmware, or Binaries:**
   - Never commit Apple firmware, IPSWs, `AVPBooter` ROMs, macOS system files, or Apple private framework binaries.
   - Never commit Windows ISOs, disk images, product keys, activation workarounds, or Microsoft redistributable binaries.
   - Never commit or decompile CodeWeavers CrossOver binaries, Apple D3DMetal / Game Porting Toolkit binaries, or Valve binaries. Apple's Metal Shader Converter (`libmetalirconverter.dylib`) is never committed to source; it is fetched at build time and bundled in IPA builds and releases (owner's decision, 2026-11-25).
   - Never includeDRM or license bypasses or game file patches.
2. **License Compatibility & Attribution:**
   - All new Triptych source files must carry `// SPDX-License-Identifier: GPL-3.0-or-later` (or the appropriate upstream license header when editing an in-tree engine like `engines/gesso/`, which is `GPL-2.0-or-later`).
   - Any new third-party code or upstream patch must be GPL-3.0-compatible and credited in [CREDITS.md](CREDITS.md) with author, license, link, and exact scope.
3. **Full-Screen & Dynamic Storage Rules:**
   - Every guest display view must fill the screen at the device's native aspect ratio across orientations without letterboxing.
   - Guest disks must use sparse/dynamic storage by default (with TRIM/discard returning space to the host), with fixed preallocation offered only as an optional toggle.

## Building and Verifying Changes

Before opening a pull request, verify your changes on macOS and the iOS Simulator:

1. **Engine Unit Tests:**
   ```sh
   make -C engines/gesso test
   make -C engines/winvm test
   ```
2. **Simulator Builds & Tests:**
   - Build the affected engine (`scripts/build-macos-engine.sh iphonesimulator`, `scripts/build-linux-engine.sh iphonesimulator`, `scripts/build-winvm.sh iphonesimulator`, etc.).
   - Regenerate the Xcode project (`cd app && xcodegen generate`).
   - Run `TriptychTests` and relevant `TriptychUITests` on an iPad Simulator.
3. **Privacy & Hygiene Check:**
   - Do not commit local absolute paths (`/Users/...`), personal email addresses, or submodule symlink workarounds (`upstreams/*` must remain gitlink commit pointers, mode `160000`).
