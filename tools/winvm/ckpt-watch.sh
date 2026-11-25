#!/bin/bash
# Checkpoint a running Windows VM at each guest restart (a clean point: Windows has flushed its disk).
#   tools/winvm/ckpt-watch.sh DIR   -> DIR/ck1, DIR/ck2, ... (APFS clones of disk.img, vars.fd, tpm.bin + shot)
# Boot a checkpoint: tools/winvm/ckpt-boot.sh DIR/ckN NEWDIR
D=${1:?usage: ckpt-watch.sh DIR}; n=0
while kill -0 "$(cat "$D/pid" 2>/dev/null)" 2>/dev/null; do
  c=$(grep -ac 'guest restart' "$D/live.log" 2>/dev/null); c=${c:-0}
  while [ "$n" -lt "$c" ]; do
    n=$((n + 1)); mkdir -p "$D/ck$n"
    for f in disk.img vars.fd tpm.bin; do cp -c "$D/$f" "$D/ck$n/$f"; done
    cp "$D/shot.ppm.reset$n.ppm" "$D/ck$n/" 2>/dev/null
    echo "ck$n $(date +%T)" >> "$D/ckpts"
  done
  sleep 1
done
