#!/bin/bash
# Builds the winarm board (engines/winvm) with its own copy of Henge's CPU core as one static library for an Apple SDK.
# Usage: scripts/build-winvm.sh iphonesimulator|iphoneos     -> build/winvm/<sdk>/libwinvm.a
# The core is built with 4 KB TLB pages (Windows/EDK2 map 4 KB), unlike libhengevm (the macOS engine), so every
# symbol except the winvm_host_* API is made private (ld -r -exported_symbols_list): both libraries link into one app.
# TPM 2.0: if scripts/build-libtpms-ios.sh <sdk> has run, libtpms + OpenSSL's libcrypto are linked in (hidden like the rest);
# otherwise the board builds without a TPM (tpm.c's WINVM_LIBTPMS is off).
set -euo pipefail
SDK=${1:?sdk: iphonesimulator|iphoneos}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
H=$ROOT/engines/gesso; W=$ROOT/engines/winvm; HOST=$ROOT/app/WinVMHost
OUT=$ROOT/build/winvm/$SDK; mkdir -p "$OUT/obj"
SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
case $SDK in
  iphonesimulator) MIN=-mios-simulator-version-min=17.0; EXTRA="-DWINVM_SIM_SPLIT=1" ;;
  iphoneos) MIN=-miphoneos-version-min=17.0; EXTRA="" ;;
  *) echo "unknown sdk $SDK" >&2; exit 1 ;;
esac
CC="xcrun --sdk $SDK clang -arch arm64 -isysroot $SYSROOT $MIN"
CFLAGS="-std=c11 -O2 -g -w -fno-common -I$W -I$H/core -I$H/host -I$H/devices -I$H/ios/Henge/Native -DHV_TLB_PAGE_BITS=12 $EXTRA"
TPM=$ROOT/build/libtpms-ios/$SDK/install; TPMLIBS=()
if [ -f "$TPM/lib/libtpms.a" ] && [ -f "$TPM/lib/libcrypto.a" ]; then
  CFLAGS="$CFLAGS -DWINVM_LIBTPMS -I$TPM/include"; TPMLIBS=("$TPM/lib/libtpms.a" "$TPM/lib/libcrypto.a"); echo "TPM: libtpms + libcrypto ($TPM)"
else echo "TPM: none (run scripts/build-libtpms-ios.sh $SDK)"; fi
# Network: Henge's libslirp NAT behind usb.c's NCM adapter. libslirp and glib come from build-henge-deps.sh (the app links them).
DEPS=$ROOT/build/henge-deps/$SDK
if [ -f "$DEPS/lib/libslirp.a" ]; then
  CFLAGS="$CFLAGS -DWINVM_NET -I$DEPS/include/slirp -I$DEPS/include/glib-2.0 -I$DEPS/lib/glib-2.0/include"; NET=(net_slirp dns_proxy); echo "network: libslirp ($DEPS)"
else NET=(); echo "network: none (run scripts/build-henge-deps.sh $SDK)"; fi
OBJS=()
for n in classify operands translate dispatch mmu memop exception sysreg machine; do
  CORE_FLAGS=()
  # Match Henge's Makefile: the light TLB refill and branch-cache lookup run with guest SIMD registers live.
  if [ "$n" = mmu ]; then CORE_FLAGS=(-mgeneral-regs-only); fi
  $CC $CFLAGS "${CORE_FLAGS[@]+"${CORE_FLAGS[@]}"}" -c "$H/core/$n.c" -o "$OUT/obj/$n.o"
  OBJS+=("$OUT/obj/$n.o")
done
for n in jit_region disk ${NET[@]+"${NET[@]}"}; do
  src=$H/host/$n.c
  $CC $CFLAGS -c "$src" -o "$OUT/obj/$n.o"; OBJS+=("$OUT/obj/$n.o"); done
for n in gicv3 timer pl011 pl031 pl061 pcie xhci virtio virtio_net; do
  $CC $CFLAGS -c "$H/devices/$n.c" -o "$OUT/obj/$n.o"; OBJS+=("$OUT/obj/$n.o"); done
$CC $CFLAGS -c "$H/host/enter.S" -o "$OUT/obj/enter.o"; OBJS+=("$OUT/obj/enter.o")
for n in winarm fwcfg pflash fdt acpi stubs nvme usb tpm; do
  [ -f "$W/$n.c" ] || continue
  $CC $CFLAGS -c "$W/$n.c" -o "$OUT/obj/w_$n.o"; OBJS+=("$OUT/obj/w_$n.o"); done
$CC $CFLAGS -c "$HOST/winvm_host.c" -o "$OUT/obj/winvm_host.o"; OBJS+=("$OUT/obj/winvm_host.o")
printf '_winvm_host_*\n' > "$OUT/exports.txt"
xcrun --sdk "$SDK" ld -r -arch arm64 -exported_symbols_list "$OUT/exports.txt" "${OBJS[@]}" ${TPMLIBS[@]+"${TPMLIBS[@]}"} -o "$OUT/winvm_all.o"
rm -f "$OUT/libwinvm.a"; xcrun --sdk "$SDK" ar rcs "$OUT/libwinvm.a" "$OUT/winvm_all.o"
echo "built $OUT/libwinvm.a"
