#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Captures the booted Simulator's screen into docs/screenshots/NAME.png with a clean status bar and no metadata.
#   tools/screenshots/capture.sh NAME [DEVICE]   (DEVICE: a Simulator name or UDID; default: the booted one)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
NAME=${1:?name}; DEV=${2:-booted}
xcrun simctl status_bar "$DEV" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 --dataNetwork wifi --operatorName ""
OUT="$ROOT/docs/screenshots/$NAME.png"
xcrun simctl io "$DEV" screenshot --type=png "$OUT" >/dev/null 2>&1
python3 "$ROOT/tools/screenshots/strip-png-metadata.py" "$OUT"
