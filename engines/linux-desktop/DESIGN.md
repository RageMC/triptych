# Graphical Linux Desktops on Triptych (`LinuxRunner`) — Architecture & Roadmap

## 1. Constraints & Baseline

Triptych embeds **LinuxRunner** (`upstreams/linuxrunner/`), an iSH/Asbestos-derived ARM64 Linux userspace syscall emulator compiled on iOS without JIT (`-Dengine=asbestos -Dguest_arch=arm64 -Djit=false -Dvdso_required=true` per [scripts/build-linux-engine.sh](../../scripts/build-linux-engine.sh)). Key architectural boundaries directly shape the desktop stack:

- **No Linux kernel or virtio hardware:** All Linux syscalls execute in-process on iOS/macOS host threads (`tp_linux_start` in [triptych_bridge.h](../../app/Triptych/Bridge/triptych_bridge.h)). Guest virtual memory and `/dev/shm` / `memfd` mappings (`platform_create_shared_memory_fd` in `upstreams/linuxrunner/kernel/fs.c` and `kernel/ipc.c`) share host virtual memory pages inside the same process.
- **ARM64 interpreter CPU budget:** On stock iOS (`-Djit=false`), guest CPU execution is interpreted, making extra pixel copies, software image compression (e.g., RFB Tight/ZRLE encoding), or in-guest compositing expensive.
- **Single-guest-per-launch & case-insensitive host FS:** `tp_linux_start` runs one guest instance per app launch, and host storage on macOS APFS and the iOS Simulator is case-insensitive (`fpathconf(root_fd, _PC_CASE_SENSITIVE) == 0`).
- **Distro reality (Ubuntu 26.04 `resolute` ARM64):** Verified via `apt-cache` inside the prototype rootfs:
  - `xfce4` `4.20.1`, `xvfb` `2:21.1.22-1ubuntu1.3`, `tigervnc-standalone-server` `1.15.0+dfsg-2build1`
  - `cinnamon-desktop-environment` `6.4.2` / `cinnamon` `6.4.13-2ubuntu0.2` ("Mint-style" target per [docs/STATUS.md](../../docs/STATUS.md) — Linux Mint itself is x86-only)
  - `plasma-desktop` `4:6.6.6-0ubuntu0.1`, `kwin-x11` `4:6.6.4-0ubuntu1`, `kwin-wayland` `4:6.6.6-0ubuntu0.1`
  - `gnome-shell` `50.1-0ubuntu1.5`, `gnome-session` `50.1-0ubuntu0.1` (**`gnome-session-xsession` does not exist** — GNOME 50 is Wayland-only)
  - `mesa-libgallium` `26.0.8-1ubuntu0.3` (`llvmpipe` LLVM 21.1.8, 128-bit NEON), `mesa-vulkan-drivers` `26.0.8-1ubuntu0.3`

[LinuxView.swift](../../app/Triptych/LinuxView.swift) shows the PTY console (`SwiftTerm` reading `master_fd`) and, on its Desktop tab, the Xvfb desktop ([LinuxDesktop.swift](../../app/Triptych/LinuxDesktop.swift)).

---

## 2. Display Architecture Selection

Three architectures were evaluated against LinuxRunner's source code and empirical probes on macOS:

| Option | Pixel Path | Resize / Multi-DE Fit | Guest Interpreter Overhead | Verdict |
|---|---|---|---|---|
| **A. In-guest server -> Host-mapped SHM -> Metal** *(Selected)* | Guest server renders into `/dev/shm` (`Xvfb -fbdir`) or `memfd`/KMS (`card0`/`card1`); Swift maps exact same host file/pages and draws via `MTLTexture` + minimal shader | Phase 1 `Xvfb` is fixed geometry; Phase 1b `Xorg` (`dummy`/`modesetting` on `card0`) adds RandR; Phase 3 adds PipeWire `ScreenCast` -> `memfd` for Wayland GNOME/KDE | **Lowest:** zero compression, zero RFB polling/diffing thread in interpreter | **Primary architecture** |
| **B. RFB / VNC loopback (`Xtigervnc` / `wayvnc`) + Swift `RFBClient`** | Server encodes dirty rects into TCP/loopback RFB stream; host `RFBClient.m` decodes BGRA & uploads `MTLTexture` | Dynamic RandR `SetDesktopSize` works out of the box (`Xtigervnc` probed `32x32`..`32768x32768`) | **Medium–High:** in-guest comparing tracker + RFB encoding/socket serialization steals interpreter cycles | **Fallback / optional remote transport** |
| **C. Host-side X11 or Wayland server in Swift** | Host acts as X server or Wayland compositor over UNIX/TCP socket | X11 requires ~100 KLOC in Swift and **still fails GNOME 50**; host Wayland collides with DEs that *are* compositors (`mutter`, `kwin`, `muffin`) | High IPC marshaling; breaks desktop WM/compositor architecture | **Rejected** |

### Why Option A (`SHM-Metal`) Wins

1. **Zero guest-side encoding overhead:** On iOS `-Djit=false`, every cycle spent in `Xtigervnc` comparing scanlines and formatting RFB rectangles runs in the CPU interpreter. With `Xvfb :0 -screen 0 1280x720x24 -fbdir /dev/shm`, `Xvfb` maintains a live XWD v7 backing file directly in `/dev/shm/Xvfb_screen0` (`3,689,632` bytes for `1280x720`), which `realfs` stores in `<rootfs>/data/dev/shm/Xvfb_screen0` and LinuxRunner maps via `MAP_SHARED` (`fs/real.c`). The host reads the exact same unified-memory pages directly via `mmap`.
2. **Native Metal pixel layout with zero color conversion:** Empirical header inspection of `/dev/shm/Xvfb_screen0` shows:
   - `hdr_size = 160`, `ncolors = 256` (256 × 12-byte `XColor` = `3072` B) -> pixel offset **`3232`** (`3232 % 32 == 0`).
   - `file_version = 7`, `pixmap_format = 2` (`ZPixmap`), `pixmap_depth = 24`, `bits_per_pixel = 32`, `bytes_per_line = 5120`, `byte_order = 0` (`LSBFirst`), masks `R=0xff0000`, `G=0xff00`, `B=0x0000ff`.
   - In little-endian memory this is **`BGRX8888`**, matching `MTLPixelFormat.bgra8Unorm` directly when paired with the opaque-alpha fragment shader already proven in LinuxRunner's [FramebufferMetalPipeline.h](../../upstreams/linuxrunner/app/LinuxRunner/FramebufferMetalPipeline.h) (`return float4(image.sample(s, v.uv).rgb, 1);`).
3. **Clean path to zero-copy & hardware scanout:**
   - **Phase 1 (`Xvfb` XWD):** `3232` is not guaranteed to meet `device.minimumLinearTextureAlignment(for: .bgra8Unorm)` (often 64/256 B on Apple GPUs), so [LinuxDesktopView.swift](../../app/Triptych/LinuxDesktopView.swift) maps `/dev/shm/Xvfb_screen0` with `mmap(PROT_READ, MAP_SHARED)` and uploads changed scanlines/bounds into a triple-buffered `MTLStorageModeShared` `MTLTexture` (`paused = true`, `enableSetNeedsDisplay = true` mirroring [MetalFramebufferView.m](../../upstreams/linuxrunner/app/LinuxRunner/MetalFramebufferView.m)) only when frame hashes change.
   - **Phase 1b (`Xorg` over `/dev/dri/card0`):** `upstreams/linuxrunner/fs/drm.c` already backs dumb buffers with `memfd_new` -> `platform_create_shared_memory_fd` at offset `0` (`16384`-byte aligned), allowing zero-copy `MTLDevice.makeBuffer(bytesNoCopy:)` + linear `makeTexture` and dynamic RandR modes.
   - **Phase 2 (`virglrenderer` on `/dev/dri/card1`):** `upstreams/linuxrunner/graphics/virgl_host.c:261` exposes `resource_texture()` returning the ANGLE/Metal-backed GL texture directly inside the host process, enabling zero-readback GPU presentation once DRM scanout wiring is hooked up.

---

## 3. Input Pipeline (`Touch -> Pointer` & Keyboard)

### Transport Channel

- **Observed LinuxRunner behavior:** `upstreams/linuxrunner/fs/sock.c:574-591` maps guest `AF_UNIX` paths to internal `/tmp/ishsock<base36(pid)>.<base36(id)>` host sockets so Darwin's 104-byte `sun_path` limit isn't exceeded. Therefore, an in-process or cross-process host client connects most cleanly via **loopback TCP (`127.0.0.1:5950`)** using newline-delimited JSON messages (or, in a later optimization, a lock-free SPSC ring inside `/dev/shm` for 120 Hz pointer drags without syscall overhead).
- **Phase-1 X11 Injector (`guest_input_agent.py`):** Loads `libX11.so.6` and `libXtst.so.6` via `ctypes` and invokes `XTestFakeMotionEvent`, `XTestFakeButtonEvent`, and `XTestFakeKeyEvent` + `XFlush` with zero per-event subprocess `fork()` overhead. Measured host-to-guest round-trip across the process boundary was **17.0–24.7 ms** for pointer clicks/combos and **152.5 ms** for full terminal command strings.

### iOS / iPadOS Interaction Mapping

| iOS / iPadOS Input | Guest Event | Notes |
|---|---|---|
| Single-finger tap / drag | `move(x, y)` + `button(1, down/up)` | Mapped from view coordinates (`CGRect` aspect-fit letterbox) to guest `0..width-1`, `0..height-1` (identical math to `PointerPolicy.h`) |
| Long press (~450 ms) or two-finger tap | `click(button: 3)` | Context / desktop right-click menu |
| Two-finger vertical/horizontal pan | `click(button: 4/5)` (scroll wheel) | Adjustable tick accumulator per 24 pt delta |
| Hardware trackpad / Apple Pencil hover (`UIHoverGestureRecognizer`, `.indirectPointer`) | `move(x, y)` + real primary/secondary button (`button 1/3`) | Supports hover menus without clicking |
| Hardware keyboard (`UIKey` in `pressesBegan`/`pressesEnded`) & soft keyboard toolbar | `key(keysym, down)` / `text` | Maps `UIKeyboardHIDUsage` -> X11 `KeySym` (Ctrl/Alt/Super/Esc/Tab/Fn/Arrows/F1–F12) |

### Phase 3 Wayland Input (`GNOME` & `kwin_wayland`)

XTest only works inside X11 / rootful `Xwayland`. For pure Wayland compositors (`mutter`, `kwin_wayland`):
1. **Preferred — `libei` / XDG RemoteDesktop EIS:** Both Mutter (GNOME) and KWin (KDE 6) natively implement [libei](https://libinput.pages.freedesktop.org/libei/) (`EI_INTERFACE_POINTER_ABSOLUTE`, `EI_INTERFACE_KEYBOARD`). An in-guest bridge forwards the host JSON/ring input stream to the compositor's EIS socket.
2. **Alternative — Synthetic `/dev/input/event*` (`uinput`):** Adding a lightweight `evdev`/`uinput` device to `LinuxRunner` lets `libinput`-based compositors consume hardware-identical pointer/touch/keyboard events.

---

## 4. Desktop Environment Bring-Up Roadmap

| Phase | Target Desktop | Ubuntu 26.04 Package(s) | Display Server | OpenGL / Compositor Needs | Status |
|---|---|---|---|---|---|
| **1** | **Xfce 4.20** | `xfce4`, `xfce4-terminal`, `dbus-x11` | `Xvfb` (`-fbdir /dev/shm`) | Pure X11; `xfwm4` compositing disabled (`use_compositing=false`) -> runs briskly on `llvmpipe` | **Working & screenshotted** |
| **1.5** | **Cinnamon 6.4 ("Mint-style")** | `cinnamon-desktop-environment` / `cinnamon` `6.4.13` | `Xvfb` -> `Xorg` (`card0`/`card1`) | **Mandatory OpenGL** (`muffin` / Clutter / Cogl); works on `llvmpipe` (Mesa GL 4.5 verified), practical framerate needs Phase 2 GPU | Packages verified in apt |
| **2** | **KDE Plasma 6.6** | `plasma-desktop`, `kwin-x11`, `kwin-wayland` | `Xorg` (`kwin-x11`) -> `kwin_wayland --virtual` | Plasma Quick / KWin shader effects require `llvmpipe` (slow) or `virgl`; `kwin_wayland` on `/dev/dri/card0` needs atomic KMS (`fs/drm.c:985`) or `--virtual` + PipeWire ScreenCast | Packages verified in apt |
| **3** | **GNOME 50** | `gnome-shell` `50.1`, `gnome-session` `50.1` | **Wayland-only** (`gnome-session-xsession` removed in 26.04) | Run `gnome-shell --headless --virtual-monitor` (or `mutter`) + PipeWire `ScreenCast` -> `memfd`/SHM + `libei`; or add atomic KMS + blob resources to `fs/drm.c` | Packages verified in apt |

---

## 5. GPU Acceleration Roadmap

1. **Stage 1 — Software Mesa (`llvmpipe` + `lavapipe`, working now):**
   - Verified inside Ubuntu 26.04 `Xvfb :0`: `glxinfo -B` reports **`Mesa 26.0.8-1ubuntu0.3`**, **`llvmpipe (LLVM 21.1.8, 128 bits)`**, OpenGL **4.5** (Core & Compatibility), OpenGL ES **3.2**. `mesa-vulkan-drivers` provides `lavapipe` (`VK_ICD_FILENAMES`). Zero host GPU coupling; sufficient for Xfce and bring-up.
2. **Stage 2 — Hardware OpenGL/GLES via `virglrenderer` + ANGLE Metal (`/dev/dri/card1`):**
   - LinuxRunner already includes `fs/drm.c` (`/dev/dri/card1`, `virtio_gpu`) and `graphics/virgl_host.c` (`virglrenderer` embedder callbacks backed by ANGLE's Metal backend).
   - Guest uses stock Ubuntu `libgl1-mesa-dri` (`virgl` Gallium driver — [docs.mesa3d.org/drivers/virgl.html](https://docs.mesa3d.org/drivers/virgl.html)) cleanly without fragile `LD_PRELOAD` hooking (`mesa_metal_dispatch.c`).
   - Required next step for desktop compositors (`muffin`, `kwin`, `Xorg` Glamor): expose a `/dev/dri/card1` KMS connector or wire `resource_texture()` (`virgl_host.c:261`) directly to the Swift/Metal `MTKView` scanout texture on iOS, plus build `virglrenderer` + `ANGLE` into Triptych's iOS `xcframework` pipeline.
3. **Stage 3 — Hardware Vulkan (`Venus` -> `MoltenVK` first, then `KosmicKrisp`):**
   - **Guest DRM gap in `fs/drm.c:906-907`:** `virgl_ioctl` currently returns `_EINVAL` for every `VIRTGPU_GETPARAM` except `3D_FEATURES` and `CAPSET_QUERY_FIX`. Per Mesa's Venus requirements ([docs.mesa3d.org/drivers/venus.html](https://docs.mesa3d.org/drivers/venus.html)), `fs/drm.c` must add `VIRTGPU_PARAM_RESOURCE_BLOB`, `VIRTGPU_PARAM_CONTEXT_INIT`, `VIRTGPU_PARAM_HOST_VISIBLE`, blob resource ioctls (`DRM_IOCTL_VIRTGPU_RESOURCE_CREATE_BLOB` backed by `memfd` host-shared pages), and `DRM_SYNCOBJ_*` timeline syncobj support so `virglrenderer -Dvenus=true` can run stock `libvulkan_virtio.so`.
   - **Host Vulkan-over-Metal backend:**
     - **[MoltenVK](https://github.com/KhronosGroup/MoltenVK) (Apache-2.0) — Recommended first for iOS:** Proven on both iOS and macOS Metal 2/3 devices; wire external-memory (`VK_EXT_external_memory_host` / `IOSurface` Metal heap) for zero-copy Venus blob sharing.
     - **[KosmicKrisp](https://docs.mesa3d.org/drivers/kosmickrisp.html) (MIT):** Mesa's native NIR-to-Metal Vulkan 1.4 driver eliminates SPIRV-Cross overhead, but targets macOS 26+ (Metal 4 features) on Apple Silicon Macs without general iOS rollout today. Treat as the follow-on macOS / Metal 4 optimization once iOS Metal 4 support stabilizes.
   - **Licensing compatibility:** Triptych is `GPL-3.0-or-later`; `LinuxRunner`/`iSH` (`GPL-3.0`), `Mesa`/`virglrenderer`/`KosmicKrisp` (`MIT`), `ANGLE` (`BSD-3-Clause`), `MoltenVK` (`Apache-2.0`), and `Xorg`/`Xvfb` (`MIT`) are all compatible.

---

## 6. Engine Gaps Discovered & Patches

### Fixed in [`patches/0001-fakefs-case-insensitive-host.patch`](./patches/0001-fakefs-case-insensitive-host.patch)

- **Failure:** Installing `xfce4` + `perl` on macOS APFS (`_PC_CASE_SENSITIVE == 0`) failed in `dpkg` unpack on `perl-modules-5.40` (`Pod/` vs `pod/`), `libperl5.40` (`Sys/` vs `sys/`), and `thunar` (`/usr/bin/Thunar` symlink vs `/usr/bin/thunar` binary) because `fakefs` passed unmangled paths directly to `realfs`. Additionally, unpatched `fakefs_open` did not check `meta.db` before calling `realfs.open` for non-`O_CREAT` opens, allowing lookups for a missing lowercase path to open/unlink its existing uppercase sibling.
- **Fix:** Added SQLite `case_aliases (guest_path, host_path)` in `fs/fake-db.c`/`fake-db.h` + path collision detection and `.#ish#<seq>` host disambiguation across `open`, `mkdir`, `symlink`, `mknod`, `link`, `rename`, `unlink`, `rmdir`, `stat`, `setattr`, `readlink`, `readdir`, `getpath`, and `utime` in `fs/fake.c`. All 243+ packages (including `perl-modules-5.40`, `libperl5.40`, `thunar`, `xfce4`, `xvfb`, `tigervnc-standalone-server`, and Mesa `llvmpipe`) unpacked and configured with exit code `0`.

### Remaining Engine Observations (`/proc/ish/compat` during live Xfce session)

During full Xfce 4.20 boot + terminal + panel + menu execution, `/proc/ish/compat` recorded `entries=27 dropped=0` with **zero fatal syscall errors**:
- Non-blocking `stub_syscall` entries: `277` (`seccomp` from `bwrap`/`glycin-svg`/`glycin-image-rs`, which gracefully prints `WARNING: Glycin running without sandbox` and still decodes desktop icons/SVGs/wallpapers), and `151`/`152` (`setfsuid`/`setfsgid` from `bash`).
- Harmless `ioctl_enotty` probes: `0x802c542a` (`TCGETS2`), `0x5413` (`TIOCGWINSZ`), `0x5441` (`TIOCGSERIAL`), `0xc020660b` (`FS_IOC_FIEMAP`), and `0x40049409` (`FICLONE`).
- **Two Phase-2/3 gaps noted in `upstreams/linuxrunner` for future patches:**
  1. `fs/drm.c:985` rejects `DRM_CLIENT_CAP_ATOMIC` (`EINVAL`), blocking atomic KMS Wayland compositors (`mutter`, `kwin_wayland --drm`) until implemented or bypassed via headless PipeWire capture.
  2. `fs/drm.c:906-907` rejects `VIRTGPU_PARAM_RESOURCE_BLOB`, `CONTEXT_INIT`, and `HOST_VISIBLE`, blocking Mesa `Venus`.

---

## 7. Primary Sources & Citations

- Triptych engine & UI integration: [docs/STATUS.md](../../docs/STATUS.md), [app/Triptych/LinuxView.swift](../../app/Triptych/LinuxView.swift), [app/Triptych/Bridge/triptych_bridge.h](../../app/Triptych/Bridge/triptych_bridge.h), [scripts/build-linux-engine.sh](../../scripts/build-linux-engine.sh)
- LinuxRunner kernel, DRM/virgl, RFB/Metal reference code: [upstreams/linuxrunner/fs/drm.c](../../upstreams/linuxrunner/fs/drm.c), [upstreams/linuxrunner/fs/sock.c](../../upstreams/linuxrunner/fs/sock.c), [upstreams/linuxrunner/graphics/virgl_host.c](../../upstreams/linuxrunner/graphics/virgl_host.c), [upstreams/linuxrunner/app/LinuxRunner/FramebufferMetalPipeline.h](../../upstreams/linuxrunner/app/LinuxRunner/FramebufferMetalPipeline.h), [upstreams/linuxrunner/app/LinuxRunner/MetalFramebufferView.m](../../upstreams/linuxrunner/app/LinuxRunner/MetalFramebufferView.m)
- Xvfb & XWD virtual framebuffer specification: <https://xorg.freedesktop.org/archive/current/doc/man/man1/Xvfb.1.xhtml>
- Xorg server & modesetting DDX: <https://xorg.freedesktop.org/archive/current/doc/man/man1/Xorg.1.xhtml>
- Xfce session startup: <https://docs.xfce.org/xfce/xfce4-session/start>
- RFB protocol specification (compared alternative): <https://www.rfc-editor.org/rfc/rfc6143>
- Wayland & libei emulated input architecture: <https://wayland.freedesktop.org/docs/html/> and <https://libinput.pages.freedesktop.org/libei/>
- GNOME Mutter & Linux Mint Cinnamon repositories: <https://gitlab.gnome.org/GNOME/mutter> and <https://github.com/linuxmint/cinnamon>
- Mesa `llvmpipe`, `virgl`, `Venus`, `KosmicKrisp`, `virglrenderer`, `MoltenVK`: <https://docs.mesa3d.org/drivers/llvmpipe.html>, <https://docs.mesa3d.org/drivers/virgl.html>, <https://docs.mesa3d.org/drivers/venus.html>, <https://docs.mesa3d.org/drivers/kosmickrisp.html>, <https://gitlab.freedesktop.org/virgl/virglrenderer>, <https://github.com/KhronosGroup/MoltenVK>
