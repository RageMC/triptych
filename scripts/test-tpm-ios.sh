#!/bin/bash
# Run engines/winvm/tests/tpm_test.c against the iOS build of libtpms + OpenSSL (scripts/build-libtpms-ios.sh).
#   scripts/test-tpm-ios.sh                 iOS Simulator: builds for iphonesimulator and runs it with `simctl spawn`
#                                           on a booted simulator (boots "iPhone 17 Pro" if none is).
#   scripts/test-tpm-ios.sh iphoneos        builds the device binary only (build/libtpms-ios/iphoneos/tpm_test);
#                                           running it needs a device (not available here).
set -euo pipefail
SDK=${1:-iphonesimulator}
ROOT=$(cd "$(dirname "$0")/.." && pwd); W=$ROOT/engines/winvm; H=$ROOT/engines/gesso
P=$ROOT/build/libtpms-ios/$SDK/install
[ -f "$P/lib/libtpms.a" ] || "$ROOT/scripts/build-libtpms-ios.sh" "$SDK"
case $SDK in
  iphonesimulator) MIN=-mios-simulator-version-min=17.0 ;;
  iphoneos) MIN=-miphoneos-version-min=17.0 ;;
esac
OUT=$ROOT/build/libtpms-ios/$SDK/tpm_test
xcrun --sdk "$SDK" clang -arch arm64 -isysroot "$(xcrun --sdk "$SDK" --show-sdk-path)" $MIN -std=c11 -O2 -g -Wall -Wno-unused-function \
  -I"$W" -I"$H/core" -I"$H/host" -I"$H/devices" -I"$P/include" -o "$OUT" "$W/tests/tpm_test.c" "$P/lib/libtpms.a" "$P/lib/libcrypto.a"
[ "$SDK" = iphoneos ] && { codesign -s - -f "$OUT" >/dev/null 2>&1 || true; echo "built $OUT"; exit 0; }
if ! xcrun simctl list devices booted | grep -q Booted; then xcrun simctl boot "iPhone 17 Pro"; fi
xcrun simctl spawn booted "$OUT" "$(dirname "$OUT")"
