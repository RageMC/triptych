#!/bin/bash
# Builds Triptych Core's macOS-emulation engine (libhengevm.a, libhengetl.a, henge-agent.gz, tl-samples.dmg) for one Apple SDK.
# Usage: scripts/build-macos-engine.sh iphoneos|iphonesimulator
# Needs build/henge-deps/<sdk> (scripts/build-henge-deps.sh).
set -euo pipefail
SDK=${1:?sdk}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
SRC=$ROOT/engines/gesso
DEPS=$ROOT/build/henge-deps/$SDK
OUT=$ROOT/build/macos/$SDK
[ -f "$DEPS/include/slirp/libslirp.h" ] || "$ROOT/scripts/build-henge-deps.sh" "$SDK"
SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
case $SDK in
  iphoneos) CC="xcrun --sdk iphoneos clang -arch arm64 -miphoneos-version-min=17.0 -isysroot $SYSROOT" ;;
  iphonesimulator) CC="xcrun --sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=17.0 -isysroot $SYSROOT" ;;
  *) echo "unknown sdk $SDK"; exit 1 ;;
esac
IB=build/ios-$SDK
# libtool lines in the Makefile hardcode --sdk iphoneos; libtool only archives, but pass sdk through anyway.
make -C "$SRC" -j"$(/usr/sbin/sysctl -n hw.ncpu 2>/dev/null || echo 4)" ios-lib IB="$IB" IOS_DEPS="$DEPS" IOS_SDK="$SYSROOT" IOS_CC="$CC"
make -C "$SRC" build/henge-agent.gz build/tl-samples.dmg >/dev/null
mkdir -p "$OUT"
cp "$SRC/$IB/libhengevm.a" "$OUT/"
[ -f "$SRC/$IB/libhengetl.a" ] && cp "$SRC/$IB/libhengetl.a" "$OUT/"
ls -la "$OUT"
