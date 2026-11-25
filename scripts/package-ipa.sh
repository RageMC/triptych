#!/bin/bash
# Builds every engine that is ready, then an unsigned Release IPA for devices.
# Sign it yourself (Sideloadly/AltStore/SideStore/your Xcode team); keep
# get-task-allow so a debugger can grant JIT.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
"$ROOT/scripts/build-linux-engine.sh" iphoneos
"$ROOT/scripts/build-henge-deps.sh" iphoneos
"$ROOT/scripts/build-macos-engine.sh" iphoneos
[ -f "$ROOT/build/libtpms-ios/iphoneos/install/lib/libtpms.a" ] || "$ROOT/scripts/build-libtpms-ios.sh" iphoneos
"$ROOT/scripts/build-winvm.sh" iphoneos
BUILD_TYPE=RELEASE "$ROOT/scripts/build-edk2.sh"
make -C "$ROOT/engines/gesso" build/tl-samples.dmg >/dev/null
"$ROOT/scripts/fetch-starter-rootfs.sh"
mkdir -p "$ROOT/build/resources"
python3 "$ROOT/scripts/make-jit-script.py" "$ROOT/upstreams/madeira/app/Madeira/madeira-jit.js" "$ROOT/build/resources/triptych-jit.js"
(cd "$ROOT/app" && xcodegen generate >/dev/null && xcodebuild -project Triptych.xcodeproj -scheme Triptych -skipPackagePluginValidation -skipMacroValidation \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath "$ROOT/build/dd-release" \
  CODE_SIGNING_ALLOWED=NO "TRIPTYCH_ENTITLEMENTS=${TRIPTYCH_ENTITLEMENTS:-Triptych/Triptych.sideload.entitlements}" build | grep -E "error:|BUILD (SUCCEEDED|FAILED)")
rm -rf "$ROOT/build/ipa" && mkdir -p "$ROOT/build/ipa/Payload" "$ROOT/dist"
cp -R "$ROOT/build/dd-release/Build/Products/Release-iphoneos/Triptych.app" "$ROOT/build/ipa/Payload/"
# Ad-hoc signature carrying the requested entitlements: SideStore/AltStore/Sideloadly re-sign
# with the user's own certificate and keep the entitlements the account supports (as Madeira does).
A="$ROOT/build/ipa/Payload/Triptych.app"
# The commit the IPA was built from, shown in every log banner and in Export logs' 00-device-and-app.txt.
C="$(git -C "$ROOT" rev-parse --short HEAD)$(git -C "$ROOT" diff --quiet HEAD -- app engines scripts 2>/dev/null || echo -dirty) $(date -u +%Y-%m-%dT%H:%MZ)"
/usr/libexec/PlistBuddy -c "Delete :TriptychCommit" "$A/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :TriptychCommit string $C" "$A/Info.plist"
# No builder paths in what ships: drop the debug map (object-file paths) from every Mach-O, rewrite any home path
# still baked in (configure-time prefixes, prebuilt engines) to a same-length placeholder, then refuse to package
# if the home path or user name is left anywhere. Must run before signing.
find "$A" -type f -print0 | while IFS= read -r -d '' f; do
  file -b "$f" | grep -q Mach-O && strip -S "$f" 2>/dev/null || true
done
triptych_scrub_home "$A"
triptych_check_no_home "$A" || { echo "ERROR: home path or user name left in the app bundle"; exit 1; }
for f in "$A"/Frameworks/*.framework "$A"/Frameworks/*.dylib; do [ -e "$f" ] && codesign --force --sign - "$f"; done
find "$A" -name "*.dylib" -not -path "*/Frameworks/*" -exec codesign --force --sign - {} \;
for x in "$A"/PlugIns/*.appex; do
  case $(basename "$x") in
    MadeiraMemoryHost.appex) codesign --force --sign - --entitlements "$ROOT/engines/windows/MemoryHost.entitlements" "$x";;
    *) codesign --force --sign - "$x";;
  esac
done
codesign --force --sign - --entitlements "$ROOT/app/${TRIPTYCH_ENTITLEMENTS:-Triptych/Triptych.sideload.entitlements}" "$A"
[ -e "$ROOT/build/windows/MadeiraRuntime.framework" ] || echo "NOTE: no Windows engine in this IPA (scripts/build-windows-engine.sh)"
rm -f "$ROOT/dist/Triptych-unsigned.ipa"; (cd "$ROOT/build/ipa" && zip -qry "$ROOT/dist/Triptych-unsigned.ipa" Payload)
ls -lh "$ROOT/dist/Triptych-unsigned.ipa"
