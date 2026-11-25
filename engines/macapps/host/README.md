# MacAppHost Prototype (`engines/macapps/host`)

Minimal feasibility prototype demonstrating an arm64 macOS AppKit + Metal binary loaded (`dlopen`) and executed directly inside an iOS app (`MacAppHost`) in the iOS Simulator, using a Mach-O retagging tool (`retag`) and a UIKit-backed AppKit shim (`libShim_AppKit.dylib`).

> **Scope note:** Everything for this spike is self-contained under [`engines/macapps/host/`](.) so the main Triptych app and other engine directories remain untouched.

## Directory Layout

- [`testapp/main.m`](testapp/main.m), [`testapp/triangle.metal`](testapp/triangle.metal) — Minimal macOS arm64 AppKit + Metal app (`TestMacApp`) built strictly against `MacOSX.sdk`. Creates an `NSWindow` titled `"TestMacApp"` containing a rotating/color-shifting Metal triangle (`CAMetalLayer` inside an `NSView`) and an `NSButton` (`"Click Me (0)"`). Logs lifecycle events, `mouseDown` coordinates/hue, and button clicks to `stderr`.
- [`retag/retag.c`](retag/retag.c) — Clean-room C Mach-O retagging utility built for the macOS host.
- [`shim/libShim_AppKit.h`](shim/libShim_AppKit.h), [`shim/libShim_AppKit.m`](shim/libShim_AppKit.m), [`shim/LICENSE.macos-on-ios`](shim/LICENSE.macos-on-ios) — Minimal UIKit-backed `AppKit` dylib (`@rpath/libShim_AppKit.dylib`) modeled on the MIT `macos-on-ios` pattern.
- [`MacAppHost/`](MacAppHost) — Minimal iOS UIKit host (`main.m`, `AppDelegate.m`, `SceneDelegate.m`, `HostViewController.m`, `Info.plist`, `MacAppHost.entitlements`).
- [`MacAppHostUITests/MacAppHostUITests.swift`](MacAppHostUITests/MacAppHostUITests.swift) — XCUITest verifying the hosted window, Metal container tap (`mouseDown`), and `NSButton` tap.
- [`project.yml`](project.yml) — XcodeGen specification that compiles `retag`, `TestMacApp`, `testapp.metallib`, and `libShim_AppKit.dylib`, retags `TestMacApp`, embeds the shim and guest into `MacAppHost.app`, and re-signs ad-hoc.
- [`build.sh`](build.sh) — End-to-end build, Simulator install/launch (`--console-pty`), screenshot capture, and XCUITest verification script.
- [`proof/`](proof) — Simulator screenshots (`01-launched.png`, `02-after-tap.png`).

## How It Works

1. **Build the macOS guest normally against `MacOSX.sdk`**
   - `TestMacApp` is compiled with `xcrun -sdk macosx clang -fobjc-arc -arch arm64 -mmacosx-version-min=14.0` linking `-framework AppKit -framework Metal -framework QuartzCore -framework Foundation`.
   - [`triangle.metal`](testapp/triangle.metal) is compiled with `xcrun -sdk macosx metal` into `MacGuest/Contents/Resources/testapp.metallib`.
   - Note: In the iOS Simulator Metal GPU (`Apple iOS simulator GPU`), loading a `macOS`-compiled `.metallib` via `newLibraryWithURL:` succeeds, but `newRenderPipelineStateWithDescriptor:` fails with `"Target OS is incompatible: library was not compiled for the simulator"`. `TriangleMetalView` automatically falls back to `[device newLibraryWithSource:kEmbeddedMSL ...]` at runtime, which compiles and renders cleanly.

2. **Retag the macOS Mach-O with `retag`**
   `retag` rewrites `TestMacApp` in a single pass:
   - Extracts the `arm64` slice if the input is a FAT/universal Mach-O.
   - Rewrites `LC_BUILD_VERSION` (or converts `LC_VERSION_MIN_*`) to iOS (`--platform ios` / `2`) or iOS Simulator (`--platform iossim` / `7`), with `--minos 17.0 --sdk 27.2`.
   - Shrinks `__PAGEZERO` (`vmaddr = __TEXT.vmaddr - 0x4000`, `vmsize = 0x4000`, LiveContainer pattern) so `dlopen` can map the image into the host address space.
   - Converts `MH_EXECUTE` -> `MH_DYLIB` by dropping `LC_LOAD_DYLINKER`, clearing `MH_PIE`, preserving `LC_MAIN` (so `HostViewController` can still invoke unexported `entryoff`), and appending `LC_ID_DYLIB` (`@rpath/TestMacApp.dylib`), with an `MH_BUNDLE` fallback if header padding is tight.
   - Rewrites `LC_LOAD_DYLIB` (including `DYLIB_USE_MARKER = 0x1a741800`) dependencies with `--rewrite-deps`: `AppKit.framework` / `Cocoa.framework` -> `@rpath/libShim_AppKit.dylib`, and flattens macOS `/System/Library/Frameworks/<Fw>.framework/Versions/<X>/<Fw>` paths to `/System/Library/Frameworks/<Fw>.framework/<Fw>` (preserving `IOKit`'s `Versions/A/IOKit` layout). Adds `@executable_path/Frameworks` via `--add-rpath`.
   - Strips any trailing `LC_CODE_SIGNATURE` and re-signs ad-hoc with `codesign` (or via Xcode's build phase).

3. **Provide AppKit APIs via `libShim_AppKit.dylib`**
   - Exported symbols (`nm -gU`): `ShimHostRegister`, `NSApplicationMain`, `NSApp`, `NSApplication`, `NSWindow`, `NSView`, `NSControl`, `NSButton`, `NSEvent`, `NSColor`, `NSScreen`, `NSResponder`, `NSViewController`, and AppKit lifecycle/window/workspace notification constants.
   - `HostViewController` calls `ShimHostRegister(window, self, _guestContainer, macGuestRoot)` before `dlopen`ing `TestMacApp`.
   - `NSWindow` builds a UIKit container with a simulated macOS title bar (traffic-light dots + title label `"NSWindowTitle"`) inside `_guestContainer`; `NSView` wraps a `UIView` supporting `wantsLayer` / `CALayer` replacement (used by `CAMetalLayer`) and forwards UIKit touches to AppKit `mouseDown:` / `mouseUp:` via `NSEvent`; `NSBundle` resource lookup resolves inside `MacGuest/Contents/Resources`.

4. **Boot the guest from `MacAppHost`**
   - [`HostViewController.m`](MacAppHost/HostViewController.m) runs from an `NSTimer` (avoiding main dispatch-queue starvation during guest `CFRunLoopRun()`), `dlopen`s `Frameworks/libShim_AppKit.dylib` (`RTLD_GLOBAL | RTLD_NOW`), registers the UIKit host view, `dlopen`s `MacGuest/Contents/MacOS/TestMacApp`, finds `LC_MAIN` (`entryoff`) via `_dyld_image_header` (falling back to `dlsym(..., "main")`), and calls guest `main(1, argv)`.

## Running

With Xcode, `xcodegen`, and the target simulator booted:

```bash
cd engines/macapps/host
./build.sh
```

It uses the first booted Simulator; to pick another, set `UDID=<simulator-udid> ./build.sh`.

## Verification Results (iOS Simulator `Triptych iPhone`)

Verified on iOS Simulator runtime 27.2:

- **Mach-O transformation (`otool -hv`, `otool -l`, `vtool -show-build`, `codesign -dvvv`)**:
  - Embedded guest `MacAppHost.app/MacGuest/Contents/MacOS/TestMacApp`: `MH_MAGIC_64`, `ARM64`, `DYLIB`, `platform 7` (iOS Simulator), `minos 17.0`, `sdk 27.2`, `__PAGEZERO` (`vmaddr 0x00000000ffffc000`, `vmsize 0x0000000000004000`), `LC_MAIN`, `LC_ID_DYLIB @rpath/TestMacApp.dylib`, `LC_RPATH @executable_path/Frameworks`, dependency `@rpath/libShim_AppKit.dylib`, signed `adhoc`.
  - Also verified `retag --platform ios --minos 17.0 --sdk 18.0` emits a valid ad-hoc signed `MH_DYLIB` (`LC_BUILD_VERSION platform IOS (2)`).
- **UI & XCUITest (`testTapRunningMacAppHost`)**: Passed (`Executed 1 test, with 0 failures in 7.857 seconds`).
  - Verified window title `"TestMacApp"`, host status `"Running TestMacApp (dlopen + LC_MAIN)"`, Metal triangle rendering, `NSButton` tap updating `"Click Me (0)"` -> `"Click Me (1)"`, and Metal view tap triggering `mouseDown:`.
- **Captured `stderr` ([`build/sim-console.log`](build/sim-console.log))**:
  - `MacAppHost: invoking guest entry at ...`
  - `TestMacApp main() entered (argc=1)`
  - `TestMacApp applicationDidFinishLaunching`
  - `TestMacApp: precompiled metallib unusable (Target OS is incompatible: library was not compiled for the simulator), falling back to runtime MSL`
  - `TestMacApp: runtime MSL pipeline -> OK`
  - `NSButton mouseDown (Click Me (0))`
  - `NSButton click (Click Me (0))`
  - `TestMacApp buttonClicked count=1`
  - `TestMacApp mouseDown at (173.0, 329.0) hue=0.50`
- **Screenshots**:
  - Before tap: [`proof/01-launched.png`](proof/01-launched.png)
  - After button + Metal view taps: [`proof/02-after-tap.png`](proof/02-after-tap.png)

## Known Limitations / Caveats

- **Precompiled `.metallib` target mismatch on Simulator:** macOS `.metallib` files fail pipeline creation on Simulator Metal GPU and require runtime MSL compilation (or dual/simulator-targeted shader artifacts).
- **Duplicate `NSColor` class warning:** `UIKitCore` defines a private `NSColor` class internally, so loading `libShim_AppKit.dylib` logs an Objective-C duplicate class warning (`Class NSColor is implemented in both ... UIKitCore ... and ... libShim_AppKit.dylib`). All color calls in this prototype worked properly, though aliasing or selective class registration would avoid the warning.
- **Unimplemented AppKit selectors:** Unimplemented selectors fall through to the dynamic missing-method logger (observed harmlessly during XCUITest accessibility tree inspection: `SHIM MISSING +[NSWindow _classShouldAlwaysRegisterSelectorNamed:]`).
- **Cached scene sessions during dev iteration:** `build.sh` uninstalls only `app.triptych.MacAppHost` before reinstalling so `UIApplicationSceneManifest` changes take effect cleanly without reusing stale cached UIKit scene state.

## Licenses

- `MacAppHost`, `retag`, `libShim_AppKit`, and `TestMacApp`: **GPL-3.0-or-later** (`SPDX-License-Identifier: GPL-3.0-or-later`), matching Triptych.
- [`shim/LICENSE.macos-on-ios`](shim/LICENSE.macos-on-ios): **MIT License** (`Copyright (c) 2026 Ross Fisher`), attributed for the `macos-on-ios` (`github.com/zorrobyte/macos-on-ios`) architectural pattern and runtime hook conventions used in `libShim_AppKit`.
- **LiveContainer** (AGPL-3.0) was consulted strictly as a design reference for the `__PAGEZERO` / `dlopen` loader technique; `retag.c` is a clean-room implementation.
- No Apple proprietary frameworks or binaries are bundled.
