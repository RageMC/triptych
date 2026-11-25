#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
ISH_BIN="${ISH_BIN:-$ROOT/build/linux/host-patched/ish}"
ROOTFS="${ROOTFS:-$ROOT/build/linux/ubuntu-fs}"
PROTO_DIR="$ROOT/engines/linux-desktop/proto"
PROOF_DIR="$ROOT/engines/linux-desktop/proof"
LOG_DIR="$ROOT/build/linux"
INPUT_PORT="${TRIPTYCH_INPUT_PORT:-5950}"

mkdir -p "$PROOF_DIR" "$LOG_DIR"

# Install the XTest input agent into guest /tmp via stdin (recorded cleanly in fakefs meta.db).
"$ISH_BIN" -f "$ROOTFS" /bin/sh -c 'cat > /tmp/guest_input_agent.py && chmod 755 /tmp/guest_input_agent.py' < "$PROTO_DIR/guest_input_agent.py" >> "$LOG_DIR/phase1-stage.log" 2>&1

# Boot guest in background with Xvfb (-fbdir /dev/shm) + Xfce 4.20 + XTest input agent.
"$ISH_BIN" -f "$ROOTFS" /bin/sh -s <<EOF > "$LOG_DIR/phase1-guest.log" 2>&1 &
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root XDG_RUNTIME_DIR=/tmp/runtime-root XDG_CONFIG_HOME=/root/.config XDG_DATA_HOME=/root/.local/share
export DISPLAY=:0 TRIPTYCH_INPUT_PORT=$INPUT_PORT TRIPTYCH_INPUT_READY_FILE=/tmp/triptych-ready
mkdir -p /tmp/runtime-root /root/.config /root/.local/share
chmod 700 /tmp/runtime-root
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 /dev/shm/Xvfb_screen0 /tmp/triptych-ready

Xvfb :0 -screen 0 1280x720x24 -fbdir /dev/shm -nolisten tcp >/tmp/xvfb.log 2>&1 &
XPID=\$!
for i in \$(seq 1 60); do [ -S /tmp/.X11-unix/X0 ] && [ -s /dev/shm/Xvfb_screen0 ] && break; sleep 0.1; done

dbus-run-session -- sh -c '
  xfce4-session >/tmp/xfce-session.log 2>&1 &
  SPID=\$!
  for i in \$(seq 1 120); do
    if ps -e -o comm | grep -q xfce4-panel && ps -e -o comm | grep -q xfwm4 && ps -e -o comm | grep -q xfdesktop; then
      break
    fi
    sleep 0.25
  done
  sleep 4
  # Disable xfwm4 software compositing for crisp root XWD capture and low CPU overhead,
  # and select standard XFCE backdrop included in xfdesktop4.
  xfconf-query -c xfwm4 -p /general/use_compositing -t bool -s false --create >/dev/null 2>&1 || true
  xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorscreen/workspace0/last-image -t string -s /usr/share/backgrounds/xfce/xfce-blue.jpg --create >/dev/null 2>&1 || true
  xfconf-query -c xfce4-desktop -p /backdrop/screen0/monitorscreen/workspace0/image-style -t int -s 5 --create >/dev/null 2>&1 || true
  sleep 2
  python3 /tmp/guest_input_agent.py >/tmp/input-agent.log 2>&1
  kill \$SPID 2>/dev/null || true
  wait \$SPID 2>/dev/null || true
'
kill \$XPID 2>/dev/null || true
wait \$XPID 2>/dev/null || true
echo === COMPAT ===
cat /proc/ish/compat
EOF
GUEST_PID=$!

cleanup() {
    python3 "$PROTO_DIR/shm_capture.py" --shm "$ROOTFS/data/dev/shm/Xvfb_screen0" --port "$INPUT_PORT" --input-json '[{"type":"shutdown"}]' >/dev/null 2>&1 || true
    for _ in $(seq 1 25); do
        if ! kill -0 "$GUEST_PID" 2>/dev/null; then
            break
        fi
        sleep 0.2
    done
    if kill -0 "$GUEST_PID" 2>/dev/null; then
        kill "$GUEST_PID" 2>/dev/null || true
        sleep 0.5
        kill -9 "$GUEST_PID" 2>/dev/null || true
    fi
    wait "$GUEST_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait until Xvfb_screen0 and guest input socket are ready.
for _ in $(seq 1 180); do
    if ! kill -0 "$GUEST_PID" 2>/dev/null; then
        echo "ERROR: guest exited early:"
        tail -n 50 "$LOG_DIR/phase1-guest.log"
        exit 1
    fi
    if [ -s "$ROOTFS/data/dev/shm/Xvfb_screen0" ] && [ -f "$ROOTFS/data/tmp/triptych-ready" ]; then
        if python3 "$PROTO_DIR/shm_capture.py" --shm "$ROOTFS/data/dev/shm/Xvfb_screen0" --port "$INPUT_PORT" --input-json '[{"type":"ping"}]' >/dev/null 2>&1; then
            break
        fi
    fi
    sleep 0.25
done

# 1. Capture clean initial Xfce desktop straight from host-mapped /dev/shm/Xvfb_screen0
python3 "$PROTO_DIR/shm_capture.py" \
    --shm "$ROOTFS/data/dev/shm/Xvfb_screen0" \
    --out "$PROOF_DIR/xfce-desktop.png" \
    --settle 1.0

# 2. Send Alt+F2 to open Xfce Application Finder, launch xfce4-terminal, and type guest telemetry commands
python3 "$PROTO_DIR/shm_capture.py" \
    --shm "$ROOTFS/data/dev/shm/Xvfb_screen0" \
    --port "$INPUT_PORT" \
    --input-json '[{"type":"key_combo","mods":["Alt_L"],"keysym":"F2"}]'
sleep 2.0

python3 "$PROTO_DIR/shm_capture.py" \
    --shm "$ROOTFS/data/dev/shm/Xvfb_screen0" \
    --port "$INPUT_PORT" \
    --input-json '[{"type":"text","text":"xfce4-terminal --geometry=96x24+140+95\n"}]'
sleep 3.0

# Focus/click terminal interior and open Applications menu too after typing command
python3 "$PROTO_DIR/shm_capture.py" \
    --shm "$ROOTFS/data/dev/shm/Xvfb_screen0" \
    --port "$INPUT_PORT" \
    --input-json '[{"type":"click","x":450,"y":280,"button":1},{"type":"text","text":"uname -a && . /etc/os-release && echo \"$PRETTY_NAME\" && DISPLAY=:0 glxinfo -B | head -n 8\n"}]'
sleep 2.5

# 3. Capture interactive Xfce desktop + terminal frame straight from host-mapped /dev/shm/Xvfb_screen0
python3 "$PROTO_DIR/shm_capture.py" \
    --shm "$ROOTFS/data/dev/shm/Xvfb_screen0" \
    --out "$PROOF_DIR/xfce-desktop-terminal.png" \
    --settle 1.0

# 4. Also demonstrate top-left Applications menu click capture
python3 "$PROTO_DIR/shm_capture.py" \
    --shm "$ROOTFS/data/dev/shm/Xvfb_screen0" \
    --port "$INPUT_PORT" \
    --input-json '[{"type":"click","x":24,"y":12,"button":1}]'
sleep 1.0
python3 "$PROTO_DIR/shm_capture.py" \
    --shm "$ROOTFS/data/dev/shm/Xvfb_screen0" \
    --out "$PROOF_DIR/xfce-desktop-menu.png" \
    --settle 0.8

python3 "$PROTO_DIR/shm_capture.py" --shm "$ROOTFS/data/dev/shm/Xvfb_screen0" --port "$INPUT_PORT" --input-json '[{"type":"shutdown"}]' || true
wait "$GUEST_PID" 2>/dev/null || true
echo "PROTOTYPE_COMPLETE"
