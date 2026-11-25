# Credits

Triptych is a combined work built on other people's open-source projects. Each
project keeps its own licence and copyright, and the licence files in
`engines/gesso/`, `upstreams/` and `app/Vendor/` stay as their authors wrote them. The combined
work is distributed under GPL-3.0 (see docs/ARCHITECTURE.md, "Licences").

Each upstream project below appears once, with its author, licence, link, what
Triptych uses from it, and the upstream fixes applied to it. Each patch is the
author's own pull request or issue fix, applied as-is or ported.

## Henge

- **Author:** Leviidev and contributors
- **Licence:** GPL-2.0-or-later
- **Link:** https://github.com/Leviidev/Henge
- **What Triptych uses:** the macOS VM engine (ARM64 CPU core, devices, JIT,
  Metal display). Its CPU core also runs the "winarm" Windows VM board. Now
  maintained in-tree as `engines/gesso/` (imported from commit `9cf6d26`, see
  `engines/gesso/UPSTREAM.md`).

**Credited through it**
- [usbmuxd](https://github.com/libimobiledevice/usbmuxd),
  [libimobiledevice / idevicerestore](https://libimobiledevice.org/) (GPL/LGPL)
- [StikJIT / StikDebug](https://github.com/StephenDev0/StikDebug) (MPL-2.0 /
  AGPL-3.0)
- [idevice](https://github.com/jkcoxson/idevice) (MIT)

**Applied fixes** (`engines/macos/patches/`)

| # | Author | Change |
|---|---|---|
| [73](https://github.com/Leviidev/Henge/pull/73) | bradenriggins | vPMU SRAM header for macOS 27.2 install |
| [78](https://github.com/Leviidev/Henge/pull/78) | bradenriggins | engine code-cache fallback 1536 MB |
| [80](https://github.com/Leviidev/Henge/pull/80) | bradenriggins | vCPU threads at user-interactive QoS on iOS |
| [81](https://github.com/Leviidev/Henge/pull/81) | bradenriggins | faster cold boot |
| [92](https://github.com/Leviidev/Henge/pull/92) | bradenriggins | full-surface hashing for change detection |
| [109](https://github.com/Leviidev/Henge/pull/109) | itsAllexB | pointer drift at scaled resolutions |
| [110](https://github.com/Leviidev/Henge/pull/110) | itsAllexB | real chip name in About This Mac |
| [112](https://github.com/Leviidev/Henge/pull/112) | Gohro | pvg-metal busy-time logging |
| [121](https://github.com/Leviidev/Henge/pull/121) | liukaixiang817 | release Mac app address reservations before VM creation |
| [128](https://github.com/Leviidev/Henge/pull/128), [129](https://github.com/Leviidev/Henge/pull/129), [133](https://github.com/Leviidev/Henge/pull/133), [136](https://github.com/Leviidev/Henge/pull/136)–[138](https://github.com/Leviidev/Henge/pull/138), [140](https://github.com/Leviidev/Henge/pull/140), [142](https://github.com/Leviidev/Henge/pull/142)–[148](https://github.com/Leviidev/Henge/pull/148), [152](https://github.com/Leviidev/Henge/pull/152)–[154](https://github.com/Leviidev/Henge/pull/154) | oliverames | JIT script, TL bundle, task deletion, pointer size, textures, audio recovery, RemotePairing, panic store, multi-plane surfaces, aux tests, icache, LiveContainer JIT, TXM, JIT advice, Metal pipeline cache, StikDebug script, built-in panel |
| [130](https://github.com/Leviidev/Henge/pull/130) | DrRamm | JIT helper uses this device's RemotePairing port |
| [161](https://github.com/Leviidev/Henge/pull/161) | Tomba247 | display refresh time fix for WindowServer |

## Madeira

- **Author:** willfaust and contributors
- **Licence:** GPL-3.0-or-later + Madeira Converter Exception
- **Link:** https://github.com/willfaust/Madeira
- **What Triptych uses:** the Windows engine — Wine ARM64EC, FEX, DXMT,
  madeira-d3d12, game library and controls. Built as `MadeiraRuntime.framework`.

**Credited through it**
- [Wine](https://www.winehq.org/) (LGPL-2.1-or-later)
- [FEX-Emu](https://github.com/FEX-Emu/FEX) (MIT)
- [DXMT](https://github.com/3Shain/dxmt) (zlib)
- [vkd3d-proton](https://github.com/HansKristian-Work/vkd3d-proton) (LGPL-2.1)

**Applied fixes** (`engines/windows/patches/`)

| # | Author | Change |
|---|---|---|
| [585](https://github.com/willfaust/Madeira/pull/585) | Dragooon | DXIL cache scan on its own thread |
| [588](https://github.com/willfaust/Madeira/pull/588) | yufeiran | x86 denormal and Media Foundation compatibility modes |
| [595](https://github.com/willfaust/Madeira/pull/595) | JMRBDev | clean-build startup for 32-bit OpenGL games |
| [596](https://github.com/willfaust/Madeira/pull/596), [600](https://github.com/willfaust/Madeira/pull/600) | domainus | separate JIT code-buffer region; WinMM in child processes |
| [609](https://github.com/willfaust/Madeira/pull/609), [610](https://github.com/willfaust/Madeira/pull/610) | SirDank | master-socket slot reuse; window-tree dump off by default |
| [611](https://github.com/willfaust/Madeira/pull/611), [620](https://github.com/willfaust/Madeira/pull/620) | NevesHenry | WoW64 start-up failure isolation; Steam content-server rotation |
| [issue 329](https://github.com/willfaust/Madeira/issues/329) | TinusTK | Nexon launcher 64 GB reservation workaround |
| [issue 36](https://github.com/willfaust/Madeira/issues/36) | 125hz | start Steam games through Valve's client |

## BCD

- **Author:** thebcd69
- **Licence:** GPL-3.0-only + BCD §7 terms
- **Link:** https://github.com/thebcd69/bcd-games
- **What Triptych uses:** the D3D12 bundle work (issue-38 patch). Triptych shows
  "Includes work from BCD by thebcd69 (https://github.com/thebcd69/bcd-games)" on
  its About screen.

**Applied fixes**

| # | Author | Change |
|---|---|---|
| [issue 38](https://github.com/willfaust/Madeira/issues/38) | 125hz, with code from BCD by thebcd69 | D3D12 bundle support |

The issue-38 D3D12 bundle fix is applied through Madeira's patch series
(`engines/windows/patches/`); the changed file carries BCD Material, so BCD's
attribution line is kept (see LICENSE-BCD.md §4b).

## LinuxRunner / iSH

- **Author:** mxhm11cr, building on [iSH](https://github.com/ish-app/ish)
- **Licence:** GPL-3.0 (iSH licence)
- **Link:** https://github.com/mxhm11cr/LinuxRunner
- **What Triptych uses:** the Linux engine and `fakefs` root filesystem import.

## Built from source

- [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.0, by Miguel de
  Icaza (MIT): the Linux terminal.
- [EDK2 / TianoCore](https://github.com/tianocore/edk2) edk2-stable202608,
  ArmVirtQemu (BSD-2-Clause-Patent): UEFI firmware for the Windows VM board,
  built by `scripts/build-edk2.sh`.
- [libtpms](https://github.com/stefanberger/libtpms) v0.10.2 (BSD-3-Clause): the
  TPM 2.0 for the Windows VM board.
- [OpenSSL](https://www.openssl.org/) 3.5.9 (Apache-2.0): libcrypto, the TPM's
  cryptography (built by `scripts/build-libtpms-ios.sh`).
- [libarchive](https://www.libarchive.org/) (BSD-2-Clause): root filesystem
  import.
- [Zstandard](https://facebook.github.io/zstd/) 1.5.7 (BSD-3-Clause, via
  LinuxRunner): `.tar.zst` root filesystem decompression.
- [QEMU](https://www.qemu.org/) (GPL-2.0): the `virt` machine's memory map,
  fw_cfg and ACPI table-loader formats were followed from QEMU's documentation and
  used as the behaviour reference. Henge's `xhci.c` is the base of
  `engines/winvm/usb.c`.
- [Perl](https://www.perl.org/) 5.42.0, by Larry Wall and the Perl 5 Porters
  (Artistic-1.0 or GPL-1.0-or-later; Triptych takes it under the GPL): runs
  CrossOver Preview's own cx tools inside the app. `scripts/build-perl-ios.sh`
  builds libperl, its core XS modules and its library from the cpan.org source,
  unmodified; Triptych adds `engines/macapps/perl/` (Triptych::Process and the
  process-call guard) and `app/MacAppsKit/PerlCommand.c`.

- Mac installer reader (`engines/macapps/third_party/`): [zlib](https://zlib.net/) (zlib licence), [bzip2](https://sourceware.org/bzip2/) (bzip2 licence), [LZFSE](https://github.com/lzfse/lzfse) (BSD-3-Clause), [XZ Embedded](https://tukaani.org/xz/embedded.html) (0BSD).

## x86 PC engine (QEMU)

QEMU runs as `libqemu-x86_64-softmmu.dylib` inside the app (`scripts/build-x86pc.sh`),
so its licence terms cover the combined work. Triptych's patch
`engines/x86pc/patches/0002-license-gpl2-or-later-clean.patch` removes the three
GPL-2.0-only units (`hw/virtio/iothread-vq-mapping.c`, `util/crc-ccitt.c`,
`hw/net/igb_regs.h` with the Intel igb NIC), so the built QEMU is GPL-2.0-or-later.
Source: the build scripts and patches in this repository, `upstreams/qemu`.

- [QEMU](https://www.qemu.org/) v10.0.12-utm (GPL-2.0-or-later, with
  per-file permissive licences; the Linux UAPI headers are GPL-2.0-only WITH
  Linux-syscall-note): the x86 PC emulator. Copyright the QEMU contributors.
- [UTM](https://github.com/utmapp/UTM) QEMU fork and patches by osy and
  contributors (Apache-2.0 for UTM; QEMU patches under QEMU's licences): the iOS
  port of QEMU used as the base.
- [EDK2 / TianoCore OVMF](https://github.com/tianocore/edk2) (BSD-2-Clause-Patent,
  plus the third-party notices in `licenses/edk2-licenses.txt`): UEFI firmware
  for the x86 PC. Copyright (c) 2019, TianoCore and contributors. Redistribution
  and use in source and binary forms, with or without modification, are
  permitted under the BSD-2-Clause-Patent licence: source redistributions retain
  the copyright notice, conditions and disclaimer; binary redistributions
  reproduce them in the documentation or other materials provided. Each
  contributor grants a perpetual, worldwide, non-exclusive, royalty-free patent
  licence for their contribution, ended for anyone who sues over the software.
  The software is provided "AS IS" without warranty. Full text:
  `licenses/edk2-licenses.txt`.
- [GLib](https://gitlab.gnome.org/GNOME/glib) 2.83.0 (LGPL-2.1-or-later),
  linked statically; the matching source is the GLib 2.83.0 release and the
  object files can be relinked from the source of this repository.
- proxy-libintl by Tor Lillqvist (LGPL-2.0-or-later), a GLib subproject: a gettext stub.
- [libffi](https://github.com/libffi/libffi) (MIT). libffi - Copyright (c)
  1996-2014 Anthony Green, Red Hat, Inc and others. Permission is hereby granted,
  free of charge, to any person obtaining a copy of this software and associated
  documentation files (the "Software"), to deal in the Software without
  restriction, including without limitation the rights to use, copy, modify,
  merge, publish, distribute, sublicense, and/or sell copies of the Software,
  subject to the above copyright notice and this permission notice being
  included in all copies or substantial portions of the Software. THE SOFTWARE
  IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
  INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
  PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
  COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY.
- [PCRE2](https://github.com/PCRE2Project/pcre2) 10.44 (BSD-3-Clause, with the
  exemption for binary library-like packages). Copyright (c) 1997-2024
  University of Cambridge; (c) 2009-2024 and (c) 2010-2024 Zoltan Herczeg. All rights reserved.
  Redistribution and use in source and binary forms, with or without
  modification, are permitted provided that: source redistributions retain the
  above copyright notices, this list of conditions and the following
  disclaimer; binary redistributions reproduce the above copyright notices,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution; and neither the name of
  the University of Cambridge nor the names of any contributors may be used to
  endorse or promote products derived from this software without specific prior
  written permission. THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
  CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED; IN
  NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DAMAGES
  ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE.
- [pixman](https://www.pixman.org/) 0.38.0 (MIT). Copyright 1987-2010 The Open
  Group, Digital Equipment Corporation, Keith Packard, SuSE, Red Hat, Nicholas
  Miell, Trolltech, Luca Barbato, NVIDIA, Rodrigo Kumpera, Andre Tupinamba,
  Mozilla, Frederic Plourde, Oracle and Nokia, and others. Permission is hereby
  granted, free of charge, to any person obtaining a copy of this software and
  associated documentation files, to deal in the Software without restriction,
  provided that the above copyright notice and this permission notice
  (including the next paragraph) are included in all copies or substantial
  portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
  ANY KIND.
- [libslirp](https://gitlab.freedesktop.org/slirp/libslirp) 4.9.1 (BSD-3-Clause).
  Copyright (c) 1995,1996 Danny Gasparovski. All rights reserved. Redistribution
  and use in source and binary forms, with or without modification, are
  permitted provided that: source redistributions retain the above copyright
  notice, this list of conditions and the following disclaimer; binary
  redistributions reproduce the above copyright notice, this list of conditions
  and the following disclaimer in the documentation and/or other materials
  provided with the distribution; and neither the name of the copyright holder
  nor the names of its contributors may be used to endorse or promote products
  derived from this software without specific prior written permission. THIS
  SOFTWARE IS PROVIDED ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES ARE
  DISCLAIMED. IN NO EVENT SHALL DANNY GASPAROVSKI OR CONTRIBUTORS BE LIABLE FOR
  ANY DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE. Slirp also
  contains code copyrighted by Juha Pirkola, Gregory M. Christy, The Regents of
  the University of California, Carnegie Mellon University, The Australian
  National University and RSA Data Security, Inc.
- [libucontext](https://github.com/utmapp/libucontext) (ISC). Copyright (c)
  2018-2020 Ariadne Conill. Permission to use, copy, modify, and/or distribute
  this software for any purpose with or without fee is hereby granted, provided
  that the above copyright notice and this permission notice appear in all
  copies. This software is provided 'as is' and without any warranty, express or
  implied.

## Studied, no code taken

These were read for ideas and comparisons. None of their code is in Triptych
unless it is listed above.
- [Husk](https://github.com/Leviidev/Husk) by Leviidev (GPL-2.0-or-later): Android apps on iOS through a translation layer, with a QEMU fallback. The model for Triptych's Mac-app translation layer, and a QEMU-on-iOS reference ((private notes)).
- [MeloNX](https://starforgejo.dev/projects/MeloNX) (GPL-3.0, based on [Ryujinx](https://github.com/Ryubing/Ryujinx)): a Nintendo Switch emulator on iOS; a reference for JIT, memory entitlements and Vulkan-on-Metal techniques ((private notes)).
- [crate](https://github.com/oneamendez/crate-ios) and its [engine](https://github.com/oneamendez/crate) by oneamendez (MPL-2.0): full Linux VMs with GPU-accelerated desktops on iPhone and iPad (virglrenderer + ANGLE + MoltenVK); the reference for Triptych's Linux desktop GPU path and a candidate VM engine ((private notes)).
- [UTM](https://github.com/utmapp/UTM) (Apache-2.0): QEMU on iOS, and the model
  for the planned whole-x86 PC option.
- [box64](https://github.com/ptitSeb/box64) (MIT),
  [Winlator](https://github.com/brunodev85/winlator) (GPL-3.0): x86 translation
  on ARM.
- [DXVK](https://github.com/doitsujin/dxvk) (zlib),
  [MoltenVK](https://github.com/KhronosGroup/MoltenVK) (Apache-2.0),
  [virglrenderer](https://gitlab.freedesktop.org/virgl/virglrenderer) (MIT):
  graphics paths.
- [Gcenx](https://github.com/Gcenx)'s Wine builds and tooling,
  [Whisky](https://github.com/Whisky-App/Whisky) (GPL-3.0),
  [Sikarugir](https://github.com/Sikarugir-App/Sikarugir): Wine on macOS.
- [LiveContainer](https://github.com/LiveContainer/LiveContainer),
  [Darling](https://github.com/darlinghq/darling),
  [GNUstep](https://github.com/gnustep): research for running Mac apps directly
  (research notes kept in the private repository).
- The sources behind the research notes (kept in the private repository).

## Tools used to build it

Not part of Triptych, but used to write it (see [docs/HOW-IT-WAS-BUILT.md](docs/HOW-IT-WAS-BUILT.md)): Claude Code, Antigravity, and [TokenEconomizer](https://github.com/microsoft/TokenEconomizer) by Microsoft (Apache-2.0).

Nothing proprietary is included: no macOS, Apple firmware or IPSWs, no Windows
images or keys, no CodeWeavers or D3DMetal binaries, and no Valve binaries.

## Libraries inside the Mac VM engine (`engines/gesso/third_party/`)

Vendored with Henge for restoring and pairing; each keeps its licence file in its folder.

- [libimobiledevice](https://libimobiledevice.org/) (LGPL-2.1-or-later; tools GPL-2.0-or-later),
  [libimobiledevice-glue](https://github.com/libimobiledevice/libimobiledevice-glue) (LGPL-2.1-or-later),
  [libusbmuxd](https://github.com/libimobiledevice/libusbmuxd) (LGPL-2.1-or-later),
  [usbmuxd](https://github.com/libimobiledevice/usbmuxd) (GPL-2.0 or GPL-3.0),
  [libirecovery](https://github.com/libimobiledevice/libirecovery) (LGPL-2.1-or-later),
  [idevicerestore](https://github.com/libimobiledevice/idevicerestore) (LGPL-3.0-or-later),
  [libtatsu](https://github.com/libimobiledevice/libtatsu) (LGPL-2.1-or-later) and
  [libplist](https://github.com/libimobiledevice/libplist) (LGPL-2.1-or-later), by Nikias Bassen,
  Martin Szulecki and the libimobiledevice contributors; including ed25519 by Orson Peters (zlib)
  and libsrp6a-sha512 (BSD-style).
- [Mbed TLS](https://github.com/Mbed-TLS/mbedtls) (Apache-2.0 or GPL-2.0-or-later).
- [libzip](https://libzip.org/) by Dieter Baron and Thomas Klausner (BSD-3-Clause).
- [libusb](https://libusb.info/) 1.0 API header (`libusb-1.0/libusb.h`, LGPL-2.1-or-later), backed by
  Henge's own shim.
- `curl_include/` (a header following libcurl's easy API, implemented on NSURLSession) and
  `restore_config/` (build settings) are Henge's own files, not third-party code.

## Curator reporting relay (`tools/curator-relay/`)

- [fflate](https://github.com/101arrowz/fflate) 0.8.3 by Arjun Barrett (MIT): reads the optional log zip.
- Runs on [Cloudflare Workers](https://workers.cloudflare.com/); [Wrangler](https://github.com/cloudflare/workers-sdk),
  [Miniflare](https://github.com/cloudflare/workers-sdk), [Vitest](https://vitest.dev/) and
  [esbuild](https://esbuild.github.io/) are development tools only (MIT / Apache-2.0).

## Apple system frameworks

Curator uses Apple's [Foundation Models](https://developer.apple.com/documentation/foundationmodels) framework
when the device offers Apple Intelligence. It is part of iPadOS and iOS.

IPA builds bundle Apple's [Metal Shader Converter](https://developer.apple.com/metal/shader-converter/)
runtime library (`libmetalirconverter.dylib`, © Apple Inc., under Apple's licence) for DirectX 12 through
madeira-d3d12. It is fetched at build time and is not part of this source tree.

## Curator offline model

- **llama.cpp** by Georgi Gerganov and contributors (MIT). Triptych builds the
  pinned [b7600 source](https://github.com/ggml-org/llama.cpp/tree/b7600), with
  Metal enabled on devices.
- **Qwen3-0.6B** by the [Qwen Team](https://huggingface.co/Qwen/Qwen3-0.6B)
  (Apache-2.0). Easel can download the
  [Q4_K_M GGUF published by Unsloth](https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/tree/50968a4468ef4233ed78cd7c3de230dd1d61a56b).
