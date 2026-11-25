#!/bin/bash
# Retags a Mac app the way Triptych's import does (whole bundle), then link-checks the files the app loads at startup
# against the Simulator shims. Usage: tools/macapps/test-retag-bundle.sh [installer.zip|.dmg|.pkg] [--only SUBSTR ...]
# Default installer: the user's CrossOver Preview zip in ~/Downloads (read in place, never copied into the repo).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
IN=${1:-$HOME/Downloads/crossover-preview-arm64.zip}; shift || true
ONLY=("$@"); [ ${#ONLY[@]} -eq 0 ] && ONLY=(--only MacOS/ --only Python.framework/Versions/3.14/Python --only ArcadeKit --only Versions/B/Sparkle --only aarch64-unix/ntdll.so)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
clang -O1 -Wall -o "$T/rt" "$ROOT/tools/macapps/retag_bundle_test.c"
"$T/rt"
[ -f "$IN" ] || { echo "skip bundle test: $IN not found"; exit 0; }
[ -d "$ROOT/build/macapps/iphonesimulator/Frameworks" ] || "$ROOT/scripts/build-macapps.sh" iphonesimulator >/dev/null
make -s -C "$ROOT/engines/macapps" build/macpkg >/dev/null
"$ROOT/engines/macapps/build/macpkg" "$IN" "$T/out" >/dev/null
APP=$(ls -d "$T"/out/*.app | head -1)
"$T/rt" "$APP"
python3 "$ROOT/tools/macapps/linkcheck.py" "$APP" --shims "$ROOT/build/macapps/iphonesimulator/Frameworks" "${ONLY[@]}"
