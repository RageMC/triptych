#!/bin/bash
# Cross-builds LinuxRunner's ARM64 Linux userspace core (iSH-derived "asbestos"
# interpreter + kernel + fakefs) as static libraries for one Apple SDK.
# Usage: scripts/build-linux-engine.sh iphonesimulator|iphoneos [jit]
set -euo pipefail
SDK=${1:?sdk}; JIT=${2:-nojit}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
UP=$ROOT/upstreams/linuxrunner
OUT=$ROOT/build/linux/$SDK
command -v ld.lld >/dev/null || { echo "ld.lld is needed for the guest vDSO (brew install lld)"; exit 1; }
SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
case $SDK in
  iphonesimulator) MINFLAG=-mios-simulator-version-min=17.0 ;;
  iphoneos) MINFLAG=-miphoneos-version-min=17.0 ;;
  *) echo "unknown sdk $SDK" >&2; exit 1 ;;
esac
mkdir -p "$OUT"
# Build from a staged copy with the console and desktop (fakefs) patch series.
SRC=$OUT/src
PATCH_DIRS=("$ROOT/engines/linux/patches" "$ROOT/engines/linux-desktop/patches")
STAMP=$(
  {
    git -C "$UP" rev-parse HEAD
    git -C "$UP" diff
    for dir in "${PATCH_DIRS[@]}"; do
      while IFS= read -r p; do [ -n "$p" ] && cat "$dir/$p"; done < "$dir/series"
    done
  } | shasum | cut -d' ' -f1
)
if [ "$(cat "$SRC/.triptych-stamp" 2>/dev/null)" != "$STAMP" ]; then
  rm -rf "$SRC" "$OUT/meson"; mkdir -p "$SRC"
  rsync -a --exclude=.git --exclude=build "$UP/" "$SRC/"
  for dir in "${PATCH_DIRS[@]}"; do
    while IFS= read -r p; do [ -n "$p" ] && patch -p1 -s -N -d "$SRC" < "$dir/$p"; done < "$dir/series"
  done
  printf '%s\n' "$STAMP" > "$SRC/.triptych-stamp"
fi
# A build dir configured from another source tree (older script) is redone.
[ "$(cat "$OUT/meson/.triptych-src" 2>/dev/null)" = "$SRC" ] || rm -rf "$OUT/meson"
cat > "$OUT/cross.txt" <<CROSS
[binaries]
c = ['xcrun', '--sdk', '$SDK', 'clang']
ar = ['xcrun', '--sdk', '$SDK', 'ar']
strip = ['xcrun', '--sdk', '$SDK', 'strip']

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$SYSROOT', '$MINFLAG', '-fvisibility=default']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SYSROOT', '$MINFLAG']

[properties]
needs_exe_wrapper = true
CROSS
J=false; [ "$JIT" = jit ] && J=true
if [ ! -f "$OUT/meson/build.ninja" ]; then
  # CC_FOR_BUILD: host tools (vDSO, offsets) are built for the Mac.
  env -u SDKROOT meson setup "$OUT/meson" "$SRC" --cross-file "$OUT/cross.txt" \
    -Dengine=asbestos -Dguest_arch=arm64 -Djit=$J -Djit_emit=$J -Dcli_aot= -Dvdso_required=true \
    -Dbuildtype=release
elif [ "$(cat "$OUT/meson/.jit-mode" 2>/dev/null)" != "$J" ]; then
  env -u SDKROOT meson configure "$OUT/meson" -Djit=$J -Djit_emit=$J
fi
printf '%s\n' "$J" > "$OUT/meson/.jit-mode"
printf '%s\n' "$SRC" > "$OUT/meson/.triptych-src"
ninja -C "$OUT/meson" libish.a libish_emu.a libfakefs.a
# The CLI's main(), renamed, is the engine's entry point; exit() is routed to
# the host so a guest shutdown ends the engine thread instead of the app.
(cd "$OUT/meson" && xcrun --sdk "$SDK" clang -I. -I"$SRC" -Ivdso/arm64 -I"$SRC/vdso/arm64" -std=gnu11 -O3 \
  -D_XOPEN_SOURCE=700 -D_DARWIN_C_SOURCE -DLOG_HANDLER_DPRINTF=1 -DENGINE_ASBESTOS=1 -DGUEST_ARM64=1 \
  $( [ "$JIT" = jit ] && echo -DISH_JIT=1 ) -Wno-switch \
  -arch arm64 -isysroot "$SYSROOT" $MINFLAG -DTRIPTYCH_EMBEDDED_CLI=1 -Dmain=tp_linux_cli_main -Dexit=tp_linux_guest_exit \
  -c "$SRC/main.c" -o "$OUT/cli_main.o")
# Rootfs import (tar.gz/xz/zst → fakefs) for the in-app distro downloads; links the
# SDK's libarchive (-larchive); the API headers come from Homebrew's libarchive.
AINC=$(brew --prefix libarchive 2>/dev/null)/include
[ -f "$AINC/archive.h" ] || { echo "ERROR: brew install libarchive (headers only)"; exit 1; }
(cd "$OUT/meson" && xcrun --sdk "$SDK" clang -I. -I"$SRC" -I"$AINC" -std=gnu11 -O2 \
  -D_XOPEN_SOURCE=700 -D_DARWIN_C_SOURCE -DENGINE_ASBESTOS=1 -DGUEST_ARM64=1 -Wno-switch \
  -arch arm64 -isysroot "$SYSROOT" $MINFLAG -c "$SRC/tools/fakefs.c" -o "$OUT/fakefs_import.o")
# Apple's SDK libarchive omits zstd, so bundle LinuxRunner's BSD zstd decoder for .tar.zst / .wsl imports.
(cd "$OUT/meson" && xcrun --sdk "$SDK" clang -std=gnu11 -O2 \
  -arch arm64 -isysroot "$SYSROOT" $MINFLAG -c "$SRC/deps/zstd/lr_zstd_decompress.c" -o "$OUT/lr_zstd_decompress.o")
libtool -static -o "$OUT/libtriptych_linux.a" "$OUT/meson/libish.a" "$OUT/meson/libish_emu.a" \
  "$OUT/meson/libfakefs.a" "$OUT/cli_main.o" "$OUT/fakefs_import.o" "$OUT/lr_zstd_decompress.o" 2> >(grep -v "has no symbols" >&2 || true)
echo "built $OUT/libtriptych_linux.a"
