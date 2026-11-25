#!/bin/bash
# Builds the Mac-app pieces from engines/macapps (read-only) into build/macapps/<sdk>/:
#   libmacpkg.a                 .dmg/.pkg/.zip reader for the active SDK (via the engine's Makefile, BUILD_DIR overridden)
#   Frameworks/libShim_*.dylib  the UIKit-backed AppKit shim and its re-export anchors (dlopened by MacAppsKit at launch)
#   seed/TestMacApp.zip         the engine's retagged test app, zipped: Triptych's built-in "import sample"
# Usage: scripts/build-macapps.sh iphonesimulator|iphoneos
set -euo pipefail
SDK=${1:?sdk: iphonesimulator|iphoneos}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
E=$ROOT/engines/macapps; H=$E/host
OUT=$ROOT/build/macapps/$SDK; STAGE=$OUT/stage
rm -rf "$OUT"; mkdir -p "$OUT/Frameworks" "$OUT/seed" "$STAGE"
case $SDK in
  iphonesimulator) TGT=arm64-apple-ios17.0-simulator; PLAT=iossim ;;
  iphoneos) TGT=arm64-apple-ios17.0; PLAT=ios ;;
  *) echo "unknown sdk $SDK" >&2; exit 1 ;;
esac
clean() { env -u SDKROOT -u PLATFORM_NAME -u IPHONEOS_DEPLOYMENT_TARGET -u ARCHS "$@"; }

# 1. macpkg for iOS: the engine's Makefile, all output redirected out of the source tree.
clean make -s -C "$E" BUILD_DIR="$OUT/macpkg" CC="xcrun -sdk $SDK clang -target $TGT" "$OUT/macpkg/libmacpkg.a" >/dev/null
cp "$OUT/macpkg/libmacpkg.a" "$OUT/libmacpkg.a"; rm -rf "$OUT/macpkg"

# 2. The AppKit shim (+ the other shims that exist; the engine lane adds them over time).
FW=$OUT/Frameworks
cc_ios() { clean xcrun -sdk "$SDK" clang -fobjc-arc -target "$TGT" "$@"; }
SRCS=("$H/shim/libShim_AppKit.m"); [ -f "$H/shim/libShim_Nib.m" ] && SRCS+=("$H/shim/libShim_Nib.m")
cc_ios -w -dynamiclib -install_name @rpath/libShim_AppKit.dylib -Wl,-reexport_framework,UIKit \
  -framework Foundation -framework QuartzCore -framework CoreGraphics -framework Metal "${SRCS[@]}" -o "$FW/libShim_AppKit.dylib"
printf 'void _shim_reexport_anchor(void) {}\n' > "$STAGE/reexport.c"
cc_ios -dynamiclib -install_name @rpath/libShim_Cocoa.dylib -Wl,-reexport_library,"$FW/libShim_AppKit.dylib" "$STAGE/reexport.c" -o "$FW/libShim_Cocoa.dylib"
cc_ios -dynamiclib -install_name @rpath/libShim_System.dylib -Wl,-reexport-lSystem \
  "$H/shim/libShim_System.c" -o "$FW/libShim_System.dylib"
if [ -f "$H/shim/libShim_MacShims.m" ]; then
  cc_ios -w -dynamiclib -install_name @rpath/libShim_MacShims.dylib \
    -Wl,-reexport_framework,CoreFoundation -Wl,-reexport_framework,Foundation -Wl,-reexport_framework,CoreGraphics \
    -Wl,-reexport_framework,CoreServices -Wl,-reexport_framework,Security -Wl,-reexport_framework,SystemConfiguration \
    -Wl,-reexport_framework,IOKit -framework UIKit "$H/shim/libShim_MacShims.m" -o "$FW/libShim_MacShims.dylib"
  for n in CoreFoundation Foundation CoreGraphics CoreServices Security SecurityFoundation DiskArbitration ServiceManagement SystemConfiguration IOKit; do
    cc_ios -dynamiclib -install_name "@rpath/libShim_$n.dylib" -Wl,-reexport_library,"$FW/libShim_MacShims.dylib" "$STAGE/reexport.c" -o "$FW/libShim_$n.dylib"
  done
fi

# SwiftUI (CrossOver links it) and swiftCore: a macOS Swift app binds Swift runtime symbols by these names.
if [ -f "$H/shim/libShim_SwiftUI.swift" ]; then
  clean xcrun -sdk "$SDK" swiftc -c -target "$TGT" "${TRIPTYCH_SWIFT_PREFIX_MAP[@]}" -module-name ShimSUI -parse-as-library -enable-library-evolution \
    -import-objc-header "$H/shim/libShim_SwiftUI_Bridge.h" "$H/shim/libShim_SwiftUI.swift" -o "$STAGE/libShim_SwiftUI.o"
  /usr/bin/python3 "$H/shim/gen_swiftui_aliases.py" "$STAGE/libShim_SwiftUI.o" "$STAGE/swiftui_aliases.txt"
  clean xcrun -sdk "$SDK" swiftc -target "$TGT" -emit-library -o "$FW/libShim_SwiftUI.dylib" "$STAGE/libShim_SwiftUI.o" \
    "$FW/libShim_AppKit.dylib" -framework SwiftUI -framework UIKit -framework Foundation \
    -Xlinker -install_name -Xlinker @rpath/libShim_SwiftUI.dylib -Xlinker -reexport_framework -Xlinker SwiftUI \
    -Xlinker -alias_list -Xlinker "$STAGE/swiftui_aliases.txt"
fi
if [ -f "$H/shim/libShim_swiftCore.c" ]; then
  SDKP=$(clean xcrun --sdk "$SDK" --show-sdk-path)
  cc_ios -dynamiclib -install_name @rpath/libShim_swiftCore.dylib -L"$SDKP/usr/lib/swift" -Wl,-reexport-lswiftCore \
    "$H/shim/libShim_swiftCore.c" -o "$FW/libShim_swiftCore.dylib"
fi

# 3. The sample guest: built against the macOS SDK, retagged for this platform, zipped as an .app.
clean xcrun -sdk macosx clang -Wall -O2 "$H/retag/retag.c" -o "$STAGE/retag"
APP=$STAGE/TestMacApp.app; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
clean xcrun -sdk macosx clang -fobjc-arc -arch arm64 -mmacosx-version-min=14.0 \
  -framework AppKit -framework Metal -framework QuartzCore -framework Foundation "$H/testapp/main.m" -o "$STAGE/TestMacApp"
clean xcrun -sdk macosx metal "$H/testapp/triangle.metal" -o "$APP/Contents/Resources/testapp.metallib"
"$STAGE/retag" --platform "$PLAT" --minos 17.0 --sdk 27.2 --rewrite-deps --add-rpath @executable_path/Frameworks \
  --no-sign "$STAGE/TestMacApp" -o "$APP/Contents/MacOS/TestMacApp"
cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>TestMacApp</string><key>CFBundleName</key><string>TestMacApp</string>
<key>CFBundleIdentifier</key><string>app.triptych.TestMacApp</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PL
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/TestMacApp"
(cd "$STAGE" && ditto -c -k --keepParent TestMacApp.app "$OUT/seed/TestMacApp.zip")
# The same app as a real Mac would hand it over: not retagged, macOS platform. Triptych retags and signs it on import.
RAW=$STAGE/raw/MacBuiltApp.app; mkdir -p "$RAW/Contents/MacOS" "$RAW/Contents/Resources"
cp "$STAGE/TestMacApp" "$RAW/Contents/MacOS/MacBuiltApp"; cp "$APP/Contents/Resources/testapp.metallib" "$RAW/Contents/Resources/"
sed -e 's/TestMacApp/MacBuiltApp/g' "$APP/Contents/Info.plist" > "$RAW/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$RAW/Contents/MacOS/MacBuiltApp"
(cd "$STAGE/raw" && ditto -c -k --keepParent MacBuiltApp.app "$OUT/seed/MacBuiltApp.zip")
rm -rf "$STAGE"
echo "built $OUT"; ls "$OUT" "$OUT/Frameworks" "$OUT/seed"
