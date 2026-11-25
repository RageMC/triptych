#!/bin/bash
# Run engines/macos/tests/jit_lowgap_test.c (the JIT claim's low-room sizing) on a booted iOS Simulator.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); N=$ROOT/engines/gesso/ios/Henge/Native; OUT=$ROOT/build/jit-lowgap-test
mkdir -p "$ROOT/build"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
xcrun --sdk iphonesimulator clang -arch arm64 -isysroot "$SDK" -mios-simulator-version-min=17.0 -std=gnu11 -O1 -g -w \
  -I"$N" -o "$OUT" "$ROOT/engines/macos/tests/jit_lowgap_test.c" "$N/henge-brk.S"
DEVICE=${1:-booted}
if [[ "$DEVICE" == booted ]] && ! xcrun simctl list devices booted | grep -q Booted; then
    DEVICE="iPhone 17 Pro"
    xcrun simctl boot "$DEVICE"
fi
xcrun simctl bootstatus "$DEVICE"
xcrun simctl spawn "$DEVICE" "$OUT"
