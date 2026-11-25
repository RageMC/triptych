#!/bin/bash
# Verify guest SIMD preservation with the actual Windows PC Simulator build objects.
# Usage: scripts/test-winvm-refill-ios.sh [booted simulator UDID]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK=iphonesimulator
OUT=$ROOT/build/winvm/$SDK
H=$ROOT/upstreams/henge
"$ROOT/scripts/build-winvm.sh" "$SDK"
xcrun --sdk "$SDK" clang -arch arm64 -isysroot "$(xcrun --sdk "$SDK" --show-sdk-path)" \
  -mios-simulator-version-min=17.0 -std=c11 -O2 -Wall -Wextra -DHV_TLB_PAGE_BITS=12 \
  -I"$H/core" -I"$H/host" "$ROOT/engines/winvm/tests/refill_test.c" \
  "$OUT"/obj/{classify,operands,translate,dispatch,mmu,memop,exception,sysreg,machine,jit_region,enter}.o \
  -o "$OUT/refill_test"
xcrun simctl spawn "${1:-booted}" "$OUT/refill_test"
