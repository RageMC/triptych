#!/bin/bash
# Boot an x86-64 UEFI ISO (Linux Mint etc.) headless on the macOS qemu build (TCG) with edk2 pflash, taking a
# screendump PNG every INTERVAL s into <outdir> until DURATION s have passed.
# usage: [CPU=max] [ENTER_AT=<s>] boot-uefi-mac.sh <iso> <outdir> [duration=600] [interval=30] [ram_mib=3072]
# ENTER_AT: send Return once at that second (accepts the GRUB menu). Needs qemu-img (Homebrew qemu) for the vars file.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
Q="$ROOT/build/x86pc/macos/qemu-build/qemu-system-x86_64-unsigned"; FW="$ROOT/build/x86pc/fw"
ISO="$1"; OUT="$2"; DUR="${3:-600}"; INT="${4:-30}"; RAM="${5:-3072}"
mkdir -p "$OUT" "$FW"; W=$(mktemp -d)
# edk2-x86_64-code.fd.bz2 is raw; edk2-i386-vars.fd.bz2 is a qcow2 (540672 B virtual): convert to a raw pflash image.
[ -f "$FW/edk2-x86_64-code.fd" ] || bzip2 -dc "$ROOT/upstreams/qemu/pc-bios/edk2-x86_64-code.fd.bz2" > "$FW/edk2-x86_64-code.fd"
bzip2 -dc "$ROOT/upstreams/qemu/pc-bios/edk2-i386-vars.fd.bz2" > "$W/vars.qcow2"; qemu-img convert -O raw "$W/vars.qcow2" "$W/vars.fd"
"$Q" -M q35 -accel tcg,thread=multi -cpu "${CPU:-max}" -smp 4 -m "$RAM" -L "$ROOT/upstreams/qemu/pc-bios" \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$FW/edk2-x86_64-code.fd" \
  -drive if=pflash,format=raw,unit=1,file="$W/vars.fd" \
  -cdrom "$ISO" -boot d -display none -vga std -nic none \
  -monitor unix:"$W/mon.sock",server,nowait -serial file:"$W/serial.log" -daemonize -pidfile "$W/pid"
t0=$(date +%s)
while [ $(( $(date +%s) - t0 )) -lt "$DUR" ]; do
  sleep "$INT"; el=$(( $(date +%s) - t0 ))
  if [ -n "${ENTER_AT:-}" ] && [ -z "${SENT:-}" ] && [ "$el" -ge "$ENTER_AT" ]; then echo "sendkey ret" | nc -U -w2 "$W/mon.sock" >/dev/null; SENT=1; echo "enter sent at ${el}s"; fi
  echo "screendump $W/s.ppm" | nc -U -w2 "$W/mon.sock" >/dev/null; sleep 1
  sips -s format png "$W/s.ppm" --out "$OUT/t$(printf %04d $el).png" >/dev/null 2>&1 || true
  echo "t=${el}s"
done
kill "$(cat "$W/pid")"
