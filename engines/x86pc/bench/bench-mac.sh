#!/bin/bash
# Boot-to-login + guest-bench.py on the macOS build (TCG JIT). usage: bench-mac.sh <iso> [smp]   (NIC=user,model=virtio-net-pci NET=1 for the slirp tests)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
Q="$ROOT/build/x86pc/macos/qemu-build/qemu-system-x86_64-unsigned"
"$Q" -M q35 -accel tcg,thread=multi -cpu max -smp "${2:-4}" -m 1024 -cdrom "$1" -boot d -display none -vga std -nic "${NIC:-none}" \
  -serial tcp:127.0.0.1:44445,server,nowait &
P=$!; python3 "$(dirname "$0")/guest-bench.py" 44445 600; sleep 3; kill $P 2>/dev/null || true
