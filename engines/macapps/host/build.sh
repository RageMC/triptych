#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
UDID="${UDID:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F]{8}(-[0-9A-F]{4}){3}-[0-9A-F]{12}' | head -1)}"
[ -n "$UDID" ] || { echo "Boot a Simulator first, or set UDID=<simulator-udid>"; exit 1; }
BUILD_DIR="$PWD/build"
DERIVED="$BUILD_DIR/DerivedData"
PROOF_DIR="$PWD/proof"
mkdir -p "$BUILD_DIR" "$PROOF_DIR"

echo "==> Generating MacAppHost.xcodeproj via xcodegen"
xcodegen generate

echo "==> Building MacAppHost for iOS Simulator ($UDID)"
xcodebuild \
  -project MacAppHost.xcodeproj \
  -scheme MacAppHost \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build-for-testing

APP_PATH="$DERIVED/Build/Products/Debug-iphonesimulator/MacAppHost.app"
echo "==> Verifying Mach-O artifacts inside $APP_PATH"
otool -hv "$APP_PATH/MacGuest/Contents/MacOS/TestMacApp"
otool -L "$APP_PATH/MacGuest/Contents/MacOS/TestMacApp"
vtool -show-build "$APP_PATH/MacGuest/Contents/MacOS/TestMacApp"

echo "==> Installing MacAppHost.app to Simulator $UDID"
xcrun simctl terminate "$UDID" app.triptych.MacAppHost 2>/dev/null || true
xcrun simctl uninstall "$UDID" app.triptych.MacAppHost 2>/dev/null || true
xcrun simctl install "$UDID" "$APP_PATH"

CONSOLE_LOG="$BUILD_DIR/sim-console.log"
rm -f "$CONSOLE_LOG"

echo "==> Launching MacAppHost with --console-pty to capture stderr"
xcrun simctl launch --terminate-running-process --console-pty "$UDID" app.triptych.MacAppHost > "$CONSOLE_LOG" 2>&1 &
SIM_PID=$!
sleep 3

echo "==> Taking initial screenshot -> proof/01-launched.png"
xcrun simctl io "$UDID" screenshot "$PROOF_DIR/01-launched.png"

echo "==> Running XCUITest tap verification against running instance"
xcodebuild \
  -project MacAppHost.xcodeproj \
  -scheme MacAppHost \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  -only-testing:MacAppHostUITests/MacAppHostUITests/testTapRunningMacAppHost \
  CODE_SIGNING_ALLOWED=NO \
  test-without-building

sleep 1
echo "==> Taking post-tap screenshot -> proof/02-after-tap.png"
xcrun simctl io "$UDID" screenshot "$PROOF_DIR/02-after-tap.png"

kill "$SIM_PID" 2>/dev/null || true
wait "$SIM_PID" 2>/dev/null || true

echo "==> Captured stderr/console output:"
cat "$CONSOLE_LOG"
