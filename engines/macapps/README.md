# `macpkg` — Portable macOS Installer `.app` Extractor

`engines/macapps/dmg/` provides a portable C11 static library (`libmacpkg.a`) and a macOS CLI test tool (`build/macpkg`) for extracting `.app` bundles from user-owned macOS installer containers without invoking `hdiutil`, `xar`, `unzip`, or other macOS-only tools, so Triptych can unpack Mac apps directly on iOS/iPadOS.

## Supported Formats

- **UDIF `.dmg`**:
  - `koly` trailer, XML plist resource-fork `blkx` / `mish` chunk tables, GPT and Apple Partition Map (APM) partition tables, LRU chunk cache
  - Chunk codecs: zero-fill (`0x00000000`), raw (`0x00000001`), ignore (`0x00000002`), ADC (`0x80000004`), zlib (`0x80000005`), bzip2 (`0x80000006`), LZFSE (`0x80000007`), and LZMA/XZ (`0x80000008`)
- **HFS+ / HFSX**:
  - Case-insensitive HFS+ and case-sensitive HFSX
  - Extents overflow B-tree, catalog B-tree, attributes B-tree
  - `com.apple.decmpfs` transparent file compression (types 3, 4, 7, 8, 11, 12)
  - File and directory hard links, symlinks, POSIX permissions, and executable bits
- **APFS**:
  - Single-volume unencrypted APFS containers (checkpoint superblock discovery, container & volume object maps, filesystem B-tree, sparse/zero extents, `com.apple.fs.symlink`, `com.apple.decmpfs` / `com.apple.ResourceFork`, hard links, permissions)
- **`.pkg` (XAR)**:
  - XAR header + zlib-compressed XML TOC (component and distribution packages)
  - `Payload` streams in `pbzx` (XZ/LZMA2 + raw chunks), `gzip`, `xz`, or raw `cpio` (`odc` `070707`, `newc`/`crc` `070701`/`070702`), including hard links and symlinks
- **`.zip` (PKZIP / Zip64)**:
  - Central Directory + Zip64 EOCD/extra fields, Stored (`0`) and Deflate (`8`) with CRC-32 verification, Unix mode/symlink restoration, skips `__MACOSX` shadow metadata

## Build

```sh
make -C engines/macapps
```

Outputs:
- `engines/macapps/build/libmacpkg.a` — portable C11 library (public API in [macpkg.h](dmg/macpkg.h))
- `engines/macapps/build/macpkg` — macOS CLI tool (`macpkg [-v] [-a] [-n Name.app] <installer> <output_dir>`)

Also verified cross-compiling `build/libmacpkg.a` against the iOS arm64 SDK (`iphoneos`).

## Third-Party Libraries & Licences

All code in `engines/macapps/` is GPL-3.0-compatible, with original LICENSE files included in `engines/macapps/third_party/`:

| Library | Source | Licence |
|---|---|---|
| `zlib` (v1.3.1) | https://github.com/madler/zlib | zlib License (`third_party/zlib/LICENSE`) |
| `bzip2` (1.1.0) | https://gitlab.com/bzip2/bzip2 | bzip2 / BSD-like License (`third_party/bzip2/LICENSE`) |
| `lzfse` | https://github.com/lzfse/lzfse | BSD-3-Clause (`third_party/lzfse/LICENSE`) |
| `xz-embedded` | https://github.com/tukaani-project/xz-embedded | 0BSD / Public Domain (`third_party/xz-embedded/LICENSE`) |

All other modules (`dmg/*.c`, `dmg/*.h`) are newly written in plain C11.

## Verification

Verified against read-only user-owned installers in `~/Downloads/` (output written to `/tmp/macpkg-test`):

1. `~/Downloads/steam.dmg` (UDIF LZFSE, Apple_HFS -> `Steam.app`):
   - `diff -r --no-dereference` against `hdiutil attach -readonly -nobrowse` mount: identical (112 entries, 0 mode/symlink/type mismatches)
   - `codesign --verify --deep --strict`: passed
2. a Heroic macOS arm64 `.dmg` (UDIF zlib, Apple_HFS -> `Heroic.app`):
   - `diff -r --no-dereference` against `hdiutil attach -readonly -nobrowse` mount: identical (620 entries, 0 mode/symlink/type mismatches)
   - `codesign --verify --deep --strict`: passed
3. a CurseForge macOS `.dmg` (UDIF zlib, Apple_APFS -> `CurseForge.app`):
   - `diff -r --no-dereference` against `hdiutil attach -readonly -nobrowse` mount: identical (284 entries, 0 mode/symlink/type mismatches)
   - `codesign --verify --deep --strict`: passed
4. a CrossOver Preview arm64 `.zip` (ZIP Stored+Deflate -> `CrossOver Preview.app`):
   - `diff -r --no-dereference` against `ditto -xk` reference: identical (13,982 entries, 0 mode/symlink/type mismatches)
   - `codesign --verify --deep --strict`: passed

Additional synthetic tests (generated in `/tmp/macpkg-test` via `hdiutil`, `ditto --hfsCompression`, `pkgbuild`, and `productbuild`):
- UDIF `UDRO` (raw), `UDCO` (ADC), `UDBZ` (bzip2), `ULMO` (LZMA/XZ)
- Case-sensitive HFSX with hard links, symlinks, executable bits, and `decmpfs` compressed files
- APFS with hard links, symlinks, and `decmpfs` compressed files
- `.pkg` with gzip cpio, `pbzx` cpio, and `productbuild` distribution archive
