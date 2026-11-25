#!/bin/bash
# Drive a running VM through its WINVM_CTL channel (see engines/winvm/winvm_main.c ctl_thread).
#   ctl.sh DIR shot NAME            screenshot -> DIR/NAME.png (prints the path)
#   ctl.sh DIR click X Y [NAME]     click at framebuffer pixel X,Y; wait $WAIT s (default 5); optional screenshot
#   ctl.sh DIR type 'TEXT' [NAME]   type on the USB keyboard (\n \t \e, \d \u \r \l arrows); wait; optional screenshot
#   ctl.sh DIR key MOD USAGE [NAME] one key chord, hex HID (e.g. key 2 43 = Shift+F10); wait; optional screenshot
#   ctl.sh DIR mean                 mean pixel value 0-255 (black boot screen < 30, blue install screen ~80, white Setup window > 150)
#   ctl.sh DIR wait-setup [SECS]    wait until the white Setup window is up (default 900 s); exit 1 timeout, 2 VM died
D=${1:?dir}; cmd=${2:?command}; shift 2
send(){ printf '%s\n' "$1" > "$D/ctl"; while [ -f "$D/ctl" ]; do sleep 0.2; done; }
shot(){ send "shot $D/$1.ppm"; sleep 0.3; sips -s format png "$D/$1.ppm" --out "$D/$1.png" >/dev/null 2>&1 && echo "$D/$1.png"; }
case $cmd in
  shot) shot "$1";;
  click) send "click $1 $2"; sleep "${WAIT:-5}"; [ -n "$3" ] && shot "$3";;
  key) send "key $1 $2"; sleep "${WAIT:-5}"; [ -n "$3" ] && shot "$3";;
  type) send "type $1"; sleep "${WAIT:-5}"; [ -n "$2" ] && shot "$2";;
  mean) send "shot $D/_m.ppm"; sleep 0.3; python3 -c "
import sys
d=open(sys.argv[1],'rb').read(); b=d[d.index(b'\n255\n')+5:]; s=b[::499]; print(sum(s)//max(1,len(s)))" "$D/_m.ppm";;
  wait-setup) T=${1:-900}; S=$(date +%s)
    while :; do m=$("$0" "$D" mean 2>/dev/null); [ "${m:-0}" -gt 150 ] && { echo ready; exit 0; }
      [ $(( $(date +%s) - S )) -ge "$T" ] && { echo timeout; exit 1; }
      kill -0 "$(cat "$D/pid")" 2>/dev/null || { echo dead; exit 2; }; sleep 5; done;;
  *) echo "unknown command $cmd" >&2; exit 64;;
esac
