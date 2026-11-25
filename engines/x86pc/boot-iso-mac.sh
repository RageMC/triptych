#!/bin/bash
# Boot an x86-64 ISO headless on the macOS qemu build (TCG), screendump to PNG once "login:" shows on serial.
# usage: boot-iso-mac.sh <iso> <out.png>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
Q="$ROOT/build/x86pc/macos/qemu-build/qemu-system-x86_64-unsigned"
W=$(mktemp -d); : > "$W/serial.log"
"$Q" -M q35 -accel tcg,thread=multi -cpu max -smp 4 -m 1024 -cdrom "$1" -boot d -display none -vga std \
  -monitor unix:"$W/mon.sock",server,nowait -serial file:"$W/serial.log" -daemonize -pidfile "$W/pid"
t0=$(date +%s)
until grep -q 'login:' "$W/serial.log" || [ $(( $(date +%s) - t0 )) -gt 300 ]; do sleep 2; done
echo "login after $(( $(date +%s) - t0 ))s"
echo "screendump $W/s.ppm" | nc -U -w2 "$W/mon.sock" >/dev/null; sleep 1
sips -s format png "$W/s.ppm" --out "$2" >/dev/null
kill "$(cat "$W/pid")"
