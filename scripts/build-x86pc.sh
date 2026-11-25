#!/bin/bash
# Build QEMU (utmapp v10.0.12-utm: upstream QEMU + UTM iOS patches) for x86-64 system emulation.
# usage: scripts/build-x86pc.sh <macos|ios_simulator|ios> [--tci]
#   macos           host build (Homebrew glib/pixman), also produces a runnable qemu-system-x86_64 for testing
#   ios_simulator   iphonesimulator arm64, shared-lib (libqemu-x86_64-softmmu.dylib), TCG JIT
#   ios             iphoneos arm64, shared-lib; with --tci the interpreter (no JIT needed)
# Output: build/x86pc/<platform>[-tci]/{prefix,qemu-build}; ios/ios_simulator also <out>/frameworks/ (stripped, ad-hoc signed
#   qemu-x86_64-softmmu[-tcti].framework + qemu-img.framework for in-app qcow2 creation) and, for every platform,
#   build/x86pc/fw/ (raw edk2-x86_64-code.fd, raw edk2-i386-vars.fd, pc-bios subset)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
PLATFORM="${1:?platform}"; shift || true
TCI=0; SUF=""
if [ "${1:-}" = "--tci" ]; then TCI=1; SUF="-tci"; fi
OUT="$ROOT/build/x86pc/$PLATFORM$SUF"
SRC="$ROOT/upstreams/qemu"
MINVER=17.0; MACMIN=13.0
NCPU=$(sysctl -n hw.ncpu)
mkdir -p "$OUT/qemu-build"
# patches: when engines/x86pc/patches/series lists any, build from a scratch copy build/x86pc/qemu-src (rsync of
# upstreams/qemu without .git, re-synced and re-patched with `patch -p1` only when the upstream commit or a patch changes;
# stamp in qemu-src/.triptych-stamp). upstreams/qemu itself is never modified.
PSER="$ROOT/engines/x86pc/patches/series"
if grep -qv '^#' "$PSER" 2>/dev/null; then
  PSRC="$ROOT/build/x86pc/qemu-src"
  STAMP="$(git -C "$SRC" rev-parse HEAD) $(cat "$PSER" | grep -v '^#' | while read -r p; do [ -n "$p" ] && shasum -a 256 "$ROOT/engines/x86pc/patches/$p"; done | shasum -a 256)"
  if [ "$(cat "$PSRC/.triptych-stamp" 2>/dev/null)" != "$STAMP" ]; then
    mkdir -p "$PSRC"; rsync -a --delete --exclude .git "$SRC/" "$PSRC/"
    grep -v '^#' "$PSER" | while read -r p; do
      [ -n "$p" ] || continue
      echo "applying $p"; patch -p1 -s -d "$PSRC" < "$ROOT/engines/x86pc/patches/$p"
    done
    echo "$STAMP" > "$PSRC/.triptych-stamp"
  fi
  SRC="$PSRC"
  # a qemu-build configured against another source dir must be reconfigured
  if [ -f "$OUT/qemu-build/build.ninja" ] && ! grep -q "$SRC/" "$OUT/qemu-build/build.ninja"; then rm -f "$OUT/qemu-build/build.ninja"; fi
fi
# Firmware: decompress edk2 code, convert the QCOW2 vars template to a raw pflash image, stage the pc-bios subset.
FW="$ROOT/build/x86pc/fw"; PCB="$ROOT/upstreams/qemu/pc-bios"
stage_fw() {
  mkdir -p "$FW"
  [ -s "$FW/edk2-x86_64-code.fd" ] && [ "$FW/edk2-x86_64-code.fd" -nt "$PCB/edk2-x86_64-code.fd.bz2" ] || \
    bzip2 -dc "$PCB/edk2-x86_64-code.fd.bz2" > "$FW/edk2-x86_64-code.fd"
  if [ ! -s "$FW/edk2-i386-vars.fd" ] || [ "$PCB/edk2-i386-vars.fd.bz2" -nt "$FW/edk2-i386-vars.fd" ]; then
    local qi; qi=$(command -v qemu-img || true); [ -n "$qi" ] || qi=$(ls "$ROOT"/build/x86pc/macos/qemu-build/qemu-img 2>/dev/null || true)
    [ -n "$qi" ] || { echo "need a host qemu-img (brew install qemu) to convert edk2-i386-vars.fd"; exit 1; }
    bzip2 -dc "$PCB/edk2-i386-vars.fd.bz2" > "$FW/.vars.qcow2"
    "$qi" convert -f qcow2 -O raw "$FW/.vars.qcow2" "$FW/edk2-i386-vars.fd"; rm -f "$FW/.vars.qcow2"
  fi
  for f in bios-256k.bin vgabios-stdvga.bin vgabios.bin kvmvapic.bin linuxboot_dma.bin multiboot_dma.bin efi-e1000e.rom efi-virtio.rom; do
    cp -f "$PCB/$f" "$FW/$f"
  done
  echo "firmware staged in $FW (vars $(stat -f%z "$FW/edk2-i386-vars.fd") B raw, code $(stat -f%z "$FW/edk2-x86_64-code.fd") B)"
}
stage_fw
# frame <dylib> <FrameworkName> <bundle id>: strip, flat iOS framework with @rpath install name + Info.plist, ad-hoc sign
frame() {
  local lib="$1" name="$2" id="$3" fd="$OUT/frameworks/$2.framework"
  rm -rf "$fd"; mkdir -p "$fd"; cp "$lib" "$fd/$name"
  strip -x -S "$fd/$name"
  install_name_tool -id "@rpath/$name.framework/$name" "$fd/$name"
  local plat=iPhoneOS; [ "$PLATFORM" = ios ] || plat=iPhoneSimulator
  cat > "$fd/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$name</string>
<key>CFBundleIdentifier</key><string>$id</string>
<key>CFBundleName</key><string>$name</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleShortVersionString</key><string>10.0.12</string>
<key>CFBundleVersion</key><string>10.0.12</string>
<key>CFBundleSupportedPlatforms</key><array><string>$plat</string></array>
<key>MinimumOSVersion</key><string>$MINVER</string>
</dict></plist>
PL
  plutil -lint "$fd/Info.plist" >/dev/null
  codesign -f -s - "$fd"
  echo "framework $fd ($(stat -f%z "$fd/$name") B)"
}
case "$PLATFORM" in
macos)
  export PKG_CONFIG_PATH="$(brew --prefix glib)/lib/pkgconfig:$(brew --prefix pixman)/lib/pkgconfig:$(brew --prefix gettext)/lib/pkgconfig:$(brew --prefix pcre2)/lib/pkgconfig:$(brew --prefix libffi 2>/dev/null)/lib/pkgconfig"
  export PATH="$(brew --prefix)/bin:$PATH"
  cd "$OUT/qemu-build"
  "$SRC/configure" --target-list=x86_64-softmmu --disable-cocoa --disable-sdl --disable-gtk \
    --disable-docs --disable-guest-agent --disable-tools --disable-werror --disable-user \
    --enable-hvf --disable-opengl --disable-virglrenderer --disable-libusb --disable-usb-redir --disable-libssh --disable-curses --disable-capstone --prefix="$OUT/prefix" ${QEMU_EXTRA:-}
  make -j"$NCPU"
  ;;
ios_simulator|ios)
  # Cross deps into build/x86pc/deps/<sdk> (static), the same set UTM's scripts/build_dependencies.sh builds for
  # QEMU minus the GUI/audio/USB/SPICE ones: glib 2.83.0 (meson; its wraps give libffi, pcre2, proxy-libintl, zlib;
  # iconv comes from the SDK), pixman 0.38.0 (autotools), libslirp 4.9.1 (meson). Versions = UTM patches/sources.
  [ "$PLATFORM" = ios ] && SDK=iphoneos || SDK=iphonesimulator
  [ "$PLATFORM" = ios ] && MIN="-miphoneos-version-min=$MINVER" || MIN="-mios-simulator-version-min=$MINVER"
  [ "$PLATFORM" = ios ] && TRIPLE="arm64-apple-ios$MINVER" || TRIPLE="arm64-apple-ios$MINVER-simulator"
  SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
  DEPS="$ROOT/build/x86pc/deps/$SDK"; W="$DEPS/_work"; DL="$ROOT/build/x86pc/downloads"
  SRCDIR=${SRCDIR:-$HOME/src/emu-research-out/deps}
  mkdir -p "$DEPS" "$W" "$DL"
  fetch() { # url sha
    local f="$DL/$(basename "$1")"
    [ -f "$f" ] || curl -fsSL "$1" -o "$f"
    echo "$2  $f" | shasum -a "${3:-256}" -c - >/dev/null || { echo "checksum mismatch $f"; exit 1; }
  }
  unpack() { [ -d "$W/src/$2" ] || { mkdir -p "$W/src"; tar -xf "$DL/$1" -C "$W/src"; }; }
  for f in glib-2.83.0.tar.xz libslirp-v4.9.1.tar.gz; do [ -f "$DL/$f" ] || cp "$SRCDIR/$f" "$DL/" 2>/dev/null || true; done
  fetch https://download.gnome.org/sources/glib/2.83/glib-2.83.0.tar.xz a07d9e1a57a4279c5ece71c26dc44eea12bd518ea9ff695d53e722997032b614
  fetch https://github.com/utmapp/libslirp/releases/download/v4.9.1-release-mirror/libslirp-v4.9.1.tar.gz 3970542143b7c11e6a09a4d2b50f30a133473c41f15ed0bdcc3b7a1c450d9a5c
  fetch https://www.cairographics.org/releases/pixman-0.38.0.tar.gz 1068cc4633c39d527a5d607c418fbc0979f80b2a 1
  unpack glib-2.83.0.tar.xz glib-2.83.0; unpack libslirp-v4.9.1.tar.gz libslirp-v4.9.1; unpack pixman-0.38.0.tar.gz pixman-0.38.0
  CFL="-arch arm64 -isysroot $SYSROOT $MIN"
  cat > "$W/cross.txt" <<CROSS
[binaries]
c = ['xcrun', '--sdk', '$SDK', 'clang']
objc = ['xcrun', '--sdk', '$SDK', 'clang']
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
c_args = ['-arch','arm64','-isysroot','$SYSROOT','$MIN','-I$DEPS/include','-O2']
c_link_args = ['-arch','arm64','-isysroot','$SYSROOT','$MIN','-L$DEPS/lib']
[properties]
needs_exe_wrapper = true
CROSS
  export PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig:$DEPS/share/pkgconfig"; unset PKG_CONFIG_PATH SDKROOT
  if [ ! -f "$W/.glib" ]; then
    rm -rf "$W/glib"
    meson setup "$W/glib" "$W/src/glib-2.83.0" --cross-file "$W/cross.txt" --prefix="$DEPS" \
      --buildtype=release --default-library=static --wrap-mode=forcefallback \
      -Dtests=false -Dnls=disabled -Dintrospection=disabled -Dselinux=disabled -Dlibmount=disabled \
      -Ddtrace=disabled -Dman-pages=disabled -Dglib_debug=disabled -Dxattr=false -Dsysprof=disabled -Dpcre2:jit=disabled
    meson compile -C "$W/glib" && meson install -C "$W/glib"
    for l in libpcre2-8 libintl libffi libz; do
      [ -f "$DEPS/lib/$l.a" ] || find "$W/glib" -name "$l.a" -exec cp {} "$DEPS/lib/" \; -quit; done
    touch "$W/.glib"
  fi
  if [ ! -f "$W/.pixman" ]; then
    ( cd "$W/src/pixman-0.38.0" && make distclean >/dev/null 2>&1 || true
      CC="xcrun --sdk $SDK clang" CFLAGS="$CFL -O2" LDFLAGS="$CFL" ./configure --host=aarch64-apple-darwin \
        --prefix="$DEPS" --disable-shared --enable-static --disable-gtk --disable-libpng --disable-arm-iwmmxt \
        --disable-arm-simd --disable-arm-neon && make -j"$NCPU" -C pixman && make -C pixman install && make install-pkgconfigDATA )
    touch "$W/.pixman"
  fi
  if [ ! -f "$W/.slirp" ]; then
    rm -rf "$W/slirp"
    meson setup "$W/slirp" "$W/src/libslirp-v4.9.1" --cross-file "$W/cross.txt" --prefix="$DEPS" \
      --buildtype=release --default-library=static
    meson compile -C "$W/slirp" && meson install -C "$W/slirp"
    touch "$W/.slirp"
  fi
  # QEMU: shared lib (libqemu-x86_64-softmmu.dylib exporting qemu_main), libucontext coroutines (meson wrap), static deps.
  TCIF=""; [ $TCI = 1 ] && TCIF="--enable-tcg-threaded-interpreter --extra-ldflags=-Wl,-no_deduplicate --extra-ldflags=-Wl,-no_compact_unwind"
  export CC="xcrun --sdk $SDK clang -target $TRIPLE -isysroot $SYSROOT"; export OBJC="$CC" CXX="xcrun --sdk $SDK clang++ -target $TRIPLE -isysroot $SYSROOT"
  export AR="xcrun --sdk $SDK ar" STRIP="xcrun --sdk $SDK strip" PKG_CONFIG=pkg-config
  cd "$OUT/qemu-build"
  # tools are on only for libqemu-img (in-app qcow2 creation); the other tool executables are never built (targets below).
  # a build configured earlier with --disable-tools has no libqemu-img target: reconfigure.
  if [ -f build.ninja ] && ! grep -q 'libqemu-img' build.ninja; then rm -f build.ninja; fi
  [ -f build.ninja ] || "$SRC/configure" --cross-prefix="" --cpu=aarch64 --target-list=x86_64-softmmu \
    --enable-shared-lib --disable-cocoa --disable-sdl --disable-coreaudio --disable-slirp-smbd \
    --enable-ucontext --with-coroutine=libucontext $TCIF \
    --disable-hvf --disable-docs --disable-guest-agent --enable-tools --disable-werror --disable-user \
    --disable-gtk --disable-opengl --disable-virglrenderer --disable-libusb --disable-usb-redir --disable-libssh \
    --disable-curses --disable-capstone --disable-plugins --disable-gnutls --disable-nettle --disable-gcrypt \
    --disable-vnc-sasl --disable-vnc-jpeg --disable-png --disable-zstd --disable-lzo --disable-snappy --disable-bzip2 \
    --disable-libvduse --disable-vduse-blk-export --disable-vhost-user-blk-server --disable-spice --disable-spice-protocol \
    --extra-cflags="-I$DEPS/include" \
    --extra-ldflags="-L$DEPS/lib -lintl -liconv -lpcre2-8 -lffi -lz -lresolv -framework CoreFoundation -framework Foundation" \
    --prefix="$OUT/prefix" ${QEMU_EXTRA:-}
  make -j"$NCPU" libqemu-x86_64-softmmu.dylib libqemu-img.dylib
  ls -la "$OUT/qemu-build"/libqemu-*.dylib
  [ $TCI = 1 ] && FWK=qemu-x86_64-softmmu-tcti || FWK=qemu-x86_64-softmmu
  mkdir -p "$OUT/frameworks"
  frame "$OUT/qemu-build/libqemu-x86_64-softmmu.dylib" "$FWK" "org.qemu.$FWK"
  frame "$OUT/qemu-build/libqemu-img.dylib" qemu-img org.qemu.qemu-img
  ;;
*) echo "unknown platform $PLATFORM"; exit 2;;
esac
