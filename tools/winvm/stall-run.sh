#!/bin/bash
# Fresh install run that watches disk I/O and dumps the interrupt trace when the VM stalls.
#   tools/winvm/stall-run.sh DIR      -> DIR/status (one line per 20 s), DIR/trace.txt, DIR/stall.png
# Outcomes in DIR/status: NOSETUP (Setup never appeared), STALL (I/O stopped after it had started),
# NOIO (I/O never started), RESTART (the guest restarted; a bugcheck line follows if there was one), dead, timeout.
# The VM is left running so it can be inspected; kill it with: kill $(cat DIR/pid)
cd "$(dirname "$0")/../.." || exit 1; D=${1:?usage: stall-run.sh DIR}
dump(){ tools/winvm/ctl.sh "$D" shot "$1" >/dev/null; printf 'trace %s/trace.txt\n' "$D" > "$D/ctl"; sleep 3; }
FRESH=1 VMENV="${VMENV:-WINVM_GICDBG=1 WINVM_PCS=30}" tools/winvm/vm.sh "$D" >/dev/null
if ! tools/winvm/setup-clicks.sh "$D" install > "$D/clicks.log" 2>&1; then echo "NOSETUP $(date +%T)" > "$D/status"; dump stall; exit 0; fi
echo "clicked $(date +%T)" > "$D/status"
z=0; seen=0
for i in $(seq 1 "${ROUNDS:-180}"); do
  kill -0 "$(cat "$D/pid")" 2>/dev/null || { echo "dead $(date +%T)" >> "$D/status"; exit 0; }
  if grep -aq "guest restart" "$D/live.log"; then echo "RESTART $(date +%T)" >> "$D/status"; grep -a "bugcheck" "$D/live.log" >> "$D/status"; dump restart; exit 0; fi
  r=$(python3 tools/winvm/io.py 20 "$D"); echo "$(date +%T) $r" >> "$D/status"
  case "$r" in "read 0.00 MB/s  written 0.00"*) z=$((z+1));; *) z=0; seen=1;; esac
  [ $((i % 9)) = 0 ] && tools/winvm/ctl.sh "$D" shot prog >/dev/null
  if [ $z -ge 3 ] && [ $seen = 1 ]; then echo "STALL $(date +%T)" >> "$D/status"; dump stall; exit 0; fi
  if [ $z -ge 9 ]; then echo "NOIO $(date +%T)" >> "$D/status"; dump stall; exit 0; fi
done
echo "timeout $(date +%T)" >> "$D/status"; dump stall
