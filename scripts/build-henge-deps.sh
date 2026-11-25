#!/bin/bash
# Cross-builds libslirp + glib (+ pcre2, libffi, libintl via glib's meson wraps) for one Apple SDK.
# Usage: scripts/build-henge-deps.sh iphoneos|iphonesimulator
# Sources: set SRCDIR (default ~/src/emu-research-out/deps) holding glib-2.83.0, libslirp-v4.9.1 unpacked.
set -euo pipefail
SDK=${1:?sdk}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
SRCDIR=${SRCDIR:-$HOME/src/emu-research-out/deps}
PREFIX=$ROOT/build/henge-deps/$SDK
W=$ROOT/build/henge-deps/_work/$SDK
SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
case $SDK in
  iphonesimulator) MIN=-mios-simulator-version-min=17.0 ;;
  iphoneos) MIN=-miphoneos-version-min=17.0 ;;
  *) echo "unknown sdk $SDK" >&2; exit 1 ;;
esac
mkdir -p "$PREFIX" "$W"
cat > "$W/cross.txt" <<CROSS
[binaries]
c = ['xcrun', '--sdk', '$SDK', 'clang']
ar = ['xcrun', '--sdk', '$SDK', 'ar']
strip = ['xcrun', '--sdk', '$SDK', 'strip']
pkg-config = ['pkg-config']
[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[built-in options]
c_args = ['-arch','arm64','-isysroot','$SYSROOT','$MIN','-I$PREFIX/include','-O2']
c_link_args = ['-arch','arm64','-isysroot','$SYSROOT','$MIN','-L$PREFIX/lib']
[properties]
needs_exe_wrapper = true
CROSS
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig
unset PKG_CONFIG_PATH SDKROOT
export PATH=/opt/local/bin:$PATH
if [ ! -f "$W/.glib" ]; then
  rm -rf "$W/glib"
  meson setup "$W/glib" "$SRCDIR/glib-2.83.0" --cross-file "$W/cross.txt" --prefix="$PREFIX" \
    --buildtype=release --default-library=static --wrap-mode=forcefallback \
    -Dtests=false -Dnls=disabled -Dintrospection=disabled -Dselinux=disabled -Dlibmount=disabled \
    -Ddtrace=disabled -Dman-pages=disabled -Dglib_debug=disabled -Dxattr=false -Dsysprof=disabled -Dpcre2:jit=disabled
  meson compile -C "$W/glib"
  meson install -C "$W/glib"
  touch "$W/.glib"
fi
if [ ! -f "$W/.slirp" ]; then
  rm -rf "$W/slirp"
  meson setup "$W/slirp" "$SRCDIR/libslirp-v4.9.1" --cross-file "$W/cross.txt" --prefix="$PREFIX" \
    --buildtype=release --default-library=static
  meson compile -C "$W/slirp"
  meson install -C "$W/slirp"
  touch "$W/.slirp"
fi
# Subproject static libs (pcre2, intl, ffi) are not installed by meson: copy any missing.
for l in libpcre2-8 libintl libffi; do
  [ -f "$PREFIX/lib/$l.a" ] || find "$W/glib" -name "$l.a" -exec cp {} "$PREFIX/lib/" \; -quit
done
ls "$PREFIX/lib"/*.a; ls "$PREFIX/include"
