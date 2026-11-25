#!/bin/bash
# Crash-rate test: boot Windows Setup from the ISO N times, idle up to MIN minutes each, count bugchecks.
#   tools/winvm/boot-loop.sh DIR N [MIN]     (env as vm.sh: CPUS, VMENV)   -> DIR/results (one line per boot)
cd "$(dirname "$0")/../.." || exit 1; D=${1:?usage: boot-loop.sh DIR N [MIN]}; N=${2:-4}; MIN=${3:-8}
mkdir -p "$D"
for i in $(seq "$N"); do
  B=$D/b$i; rm -rf "$B"; mkdir -p "$B"
  FRESH=1 tools/winvm/vm.sh "$B" >/dev/null
  r=ok
  for s in $(seq $((MIN * 3))); do
    sleep 20
    grep -aq 'guest restart' "$B/live.log" && { r=CRASH; break; }
    kill -0 "$(cat "$B/pid")" 2>/dev/null || { r=dead; break; }
  done
  sleep 15; kill "$(cat "$B/pid")" 2>/dev/null
  [ -f "$B/shot.ppm.reset0.ppm" ] && sips -s format png "$B/shot.ppm.reset0.ppm" --out "$B/crash.png" >/dev/null 2>&1
  echo "b$i $r $(date +%T) $(grep -ac 'rare exception' "$B/live.log") rare" >> "$D/results"
  rm -f "$B/disk.img"
done
