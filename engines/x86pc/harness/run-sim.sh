#!/bin/bash
# Build the x86pc Simulator harness, install it on its own headless simulator ("Triptych x86pc", never opens
# Simulator.app), boot an x86-64 ISO through libqemu-x86_64-softmmu.dylib and screenshot once "login:" is on serial.
# usage: engines/x86pc/harness/run-sim.sh <iso> <out.png> [extra qemu args...]
# Needs: scripts/build-x86pc.sh ios_simulator. Env: LIB=<other dylib> (e.g. the ios_simulator-tci build),
# UEFI=1 boots with edk2 pflash (q35; needs qemu-img + bzip2) and RAM_MIB (default 3072) instead of watching for "login:":
# it screenshots every SHOT_INT s (default 60) for UEFI_DUR s (default 900) into <out.png minus .png>-frames/, sends Return
# at ENTER_AT s (GRUB menu), and copies the last frame to <out.png>. EXTRA qemu args follow as usual.
# BENCH=1 runs engines/x86pc/bench/guest-bench.py over a TCP serial port instead of watching the serial file (NET=1 adds
# the slirp network tests). SMP (default 4) = vCPUs; NIC (default none) = -nic value, e.g. NIC=user,model=virtio-net-pci.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"; H="$ROOT/engines/x86pc/harness"
ISO="${1:?iso}"; PNG="${2:?out.png}"; shift 2
LIB="${LIB:-$ROOT/build/x86pc/ios_simulator/qemu-build/libqemu-x86_64-softmmu.dylib}"
OUT="$ROOT/build/x86pc/harness-sim"; APP="$OUT/X86PCHarness.app"; BID=dev.triptych.x86pc-harness
SDK=iphonesimulator; SYSROOT=$(xcrun --sdk $SDK --show-sdk-path)
rm -rf "$APP"; mkdir -p "$APP/Frameworks" "$APP/pc-bios"
xcrun --sdk $SDK clang -target arm64-apple-ios17.0-simulator -isysroot "$SYSROOT" -fobjc-arc -O2 \
  "$H/main.m" "$LIB" -framework UIKit -framework CoreGraphics -framework QuartzCore -Wl,-rpath,@executable_path/Frameworks -o "$APP/X86PCHarness"
cp "$H/Info.plist" "$APP/"; cp "$LIB" "$APP/Frameworks/"
for f in bios-256k.bin vgabios-stdvga.bin vgabios.bin kvmvapic.bin linuxboot_dma.bin multiboot_dma.bin efi-e1000e.rom efi-virtio.rom; do
  cp "$ROOT/upstreams/qemu/pc-bios/$f" "$APP/pc-bios/"; done
codesign -f -s - "$APP/Frameworks/$(basename "$LIB")" >/dev/null 2>&1
codesign -f -s - --entitlements "$H/sim.entitlements" "$APP" >/dev/null 2>&1
DEV=$(xcrun simctl list devices | sed -n 's/^ *Triptych x86pc (\([0-9A-F-]*\)).*/\1/p' | head -1)
[ -n "$DEV" ] || DEV=$(xcrun simctl create "Triptych x86pc" com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M5-12GB com.apple.CoreSimulator.SimRuntime.iOS-27-2)
xcrun simctl bootstatus "$DEV" -b >/dev/null
xcrun simctl terminate "$DEV" $BID 2>/dev/null || true
xcrun simctl install "$DEV" "$APP"
DOC="$(xcrun simctl get_app_container "$DEV" $BID data)/Documents"; mkdir -p "$DOC"
[ "$(stat -f %z "$DOC/boot.iso" 2>/dev/null)" = "$(stat -f %z "$ISO")" ] || cp "$ISO" "$DOC/boot.iso"
rm -f "$DOC/serial.log" "$DOC/screen.ppm"; : > "$DOC/serial.log"
if [ -n "${UEFI:-}" ]; then
  FW="$DOC/fw"; mkdir -p "$FW"; bzip2 -dc "$ROOT/upstreams/qemu/pc-bios/edk2-x86_64-code.fd.bz2" > "$FW/code.fd"
  bzip2 -dc "$ROOT/upstreams/qemu/pc-bios/edk2-i386-vars.fd.bz2" > "$FW/vars.qcow2"; qemu-img convert -O raw "$FW/vars.qcow2" "$FW/vars.fd"
  set -- -m "${RAM_MIB:-3072}" -drive if=pflash,format=raw,unit=0,readonly=on,file=@DOC/fw/code.fd -drive if=pflash,format=raw,unit=1,file=@DOC/fw/vars.fd "$@"
fi
SERIAL=file:@DOC/serial.log; [ -n "${BENCH:-}" ] && SERIAL=tcp:127.0.0.1:44445,server,nowait
t0=$(date +%s)
xcrun simctl launch "$DEV" $BID -- -L @RES/pc-bios -M q35 -accel tcg,thread=multi -cpu max -smp "${SMP:-4}" -m 1024 \
  -cdrom @DOC/boot.iso -boot d -display none -vga std -nic "${NIC:-none}" -serial $SERIAL \
  -monitor tcp:127.0.0.1:44444,server,nowait "$@" >/dev/null
if [ -n "${BENCH:-}" ]; then
  python3 "$ROOT/engines/x86pc/bench/guest-bench.py" 44445 ${TIMEOUT:-900}
  xcrun simctl io "$DEV" screenshot "$PNG" >/dev/null; sleep 5; xcrun simctl terminate "$DEV" $BID 2>/dev/null || true
  exit 0
fi
if [ -n "${UEFI:-}" ]; then
  FR="${PNG%.png}-frames"; mkdir -p "$FR"; sent=
  while [ $(( $(date +%s) - t0 )) -lt ${UEFI_DUR:-900} ]; do
    sleep ${SHOT_INT:-60}; el=$(( $(date +%s) - t0 ))
    if [ -n "${ENTER_AT:-}" ] && [ -z "$sent" ] && [ "$el" -ge "$ENTER_AT" ]; then echo "sendkey ret" | nc -w2 127.0.0.1 44444 >/dev/null; sent=1; echo "enter at ${el}s"; fi
    xcrun simctl io "$DEV" screenshot "$FR/t$(printf %04d $el).png" >/dev/null 2>&1; echo "t=${el}s"
  done
  cp "$FR/$(ls "$FR" | tail -1)" "$PNG"; xcrun simctl terminate "$DEV" $BID 2>/dev/null || true; exit 0
fi
until grep -q 'login:' "$DOC/serial.log" || [ $(( $(date +%s) - t0 )) -gt ${TIMEOUT:-900} ]; do sleep 2; done
el=$(( $(date +%s) - t0 ))
grep -q 'login:' "$DOC/serial.log" && echo "login after ${el}s" || { echo "no login after ${el}s"; tail -5 "$DOC/serial.log"; }
sleep 5   # let the harness pull a fresh screendump
xcrun simctl io "$DEV" screenshot "$PNG" >/dev/null
echo "serial: $DOC/serial.log  screenshot: $PNG"
