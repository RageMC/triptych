#!/bin/bash
# Builds the Windows engine (Madeira: Wine ARM64EC + FEX + DXMT + madeira-d3d12) and
# turns it into pieces Triptych embeds:
#   build/windows/MadeiraRuntime.framework  Madeira's app binary rebuilt as a dynamic
#                                           library (UI + runtime); dlopened only when
#                                           the Windows engine starts
#   build/windows/Frameworks/               frameworks Madeira ships (StikJIT, MoltenVK, …)
#   build/windows/Resources/                Madeira's bundle resources (Wine DLLs, prefix
#                                           template, fonts, …), copied to the app root
#                                           because Madeira finds them with Bundle.main
#   build/windows/PlugIns/                  MadeiraMemoryHost.appex
#
# MADEIRA_SRC: a Madeira checkout on the triptych-fixes branch (default: the submodule).
# Point it at an existing build tree to reuse its compiled Wine/FEX/LLVM.
# SKIP_MADEIRA_BUILD=1 reuses the last tools/build-ipa.sh output.
# iphoneos only: FEX, Wine and DXMT are not built for the Simulator.
set -euo pipefail
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
SRC=${MADEIRA_SRC:-$ROOT/upstreams/madeira}
OUT=$ROOT/build/windows
DD=$ROOT/build/windows-dd
log() { printf '\n==> %s\n' "$*"; }

# The embed patch and the Triptych patches after it (triptych-command) are the last commits on triptych-fixes.
git -C "$SRC" log --oneline -3 | grep "Embedding entry points for Triptych" >/dev/null ||
  { echo "ERROR: $SRC lacks the triptych-embed patch (run scripts/apply-upstream-fixes.sh)"; exit 1; }

if [ "${SKIP_MADEIRA_BUILD:-0}" != 1 ]; then
  log "Madeira full build (Wine, FEX, LLVM, DXMT, app)"
  (cd "$SRC" && ./tools/build-ipa.sh)
fi

log "Madeira app target as a dynamic library"
xcodebuild -project "$SRC/app/Madeira.xcodeproj" -target Madeira -configuration Release \
  -sdk iphoneos IPHONEOS_DEPLOYMENT_TARGET=18.0 \
  MACH_O_TYPE=mh_dylib EXECUTABLE_EXTENSION= \
  LD_DYLIB_INSTALL_NAME=@rpath/MadeiraRuntime.framework/MadeiraRuntime \
  DYLIB_INSTALL_NAME_BASE=@rpath OTHER_LDFLAGS='$(inherited) -Wl,-export_dynamic' "${TRIPTYCH_XCODE_PREFIX_MAP[@]}" \
  SYMROOT="$DD/sym" OBJROOT="$DD/obj" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build | tail -5
APP=$DD/sym/Release-iphoneos/Madeira.app
file "$APP/Madeira" | grep -q "dynamically linked shared library" ||
  { echo "ERROR: Madeira binary is not a dylib"; file "$APP/Madeira"; exit 1; }
[ "$(nm -gU "$APP/Madeira" | grep -c _madeira_embed_make_root)" -gt 0 ] || { echo "ERROR: entry point missing"; exit 1; }

log "Bundle runtime components (Wine DLLs, prefix template, graphics libs)"
python3 "$SRC/tools/build/runtime-components.py" bundle "$APP"

log "Assemble build/windows"
rm -rf "$OUT"; mkdir -p "$OUT/Frameworks" "$OUT/Resources" "$OUT/PlugIns"
FW=$OUT/MadeiraRuntime.framework; mkdir -p "$FW"
cp "$APP/Madeira" "$FW/MadeiraRuntime"
cat > "$FW/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MadeiraRuntime</string>
<key>CFBundleIdentifier</key><string>app.triptych.MadeiraRuntime</string>
<key>CFBundleName</key><string>MadeiraRuntime</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>0.2.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>MinimumOSVersion</key><string>18.0</string>
<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict></plist>
PL
# Frameworks Madeira embeds (StikJIT; the app's embed phase keeps Triptych's own copy).
[ -d "$APP/Frameworks" ] && cp -R "$APP/Frameworks/." "$OUT/Frameworks/"
# MadeiraJITHelper (Madeira's built-in StikJIT debugger) and MadeiraMemoryHost; Madeira finds
# them by file name, and the app's embed phase gives them bundle IDs under Triptych's.
for x in "$APP"/PlugIns/*.appex; do [ -e "$x" ] || continue; cp -R "$x" "$OUT/PlugIns/"; done
# Everything else in the bundle is a resource.
rsync -a --exclude Madeira --exclude Info.plist --exclude _CodeSignature --exclude Frameworks \
  --exclude PlugIns --exclude embedded.mobileprovision --exclude PkgInfo --exclude 'Assets.car' \
  --exclude '*.lproj' --exclude 'AppIcon*' "$APP/" "$OUT/Resources/"
du -sh "$FW" "$OUT/Frameworks" "$OUT/Resources" "$OUT/PlugIns"
log "Windows engine ready in $OUT"
