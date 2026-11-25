#!/bin/bash
# Builds the Android engine (Husk: ARM64/ARM32 ELF + Dalvik translation layer,
# and optionally HuskRuntime.framework on iphoneos) into build/android/.
#
# Usage:
#   engines/android/build.sh [iphonesimulator|iphoneos] [husk_src_dir]
#
# Output:
#   build/android/<sdk>/libhusk_tl.a      Translation-layer static library (96 files)
#   build/android/<sdk>/include/*.h       Public C/ObjC bridge headers
#   build/android/HuskRuntime.framework   (iphoneos + BUILD_RUNTIME_FRAMEWORK=1)
#
# Environment variables:
#   HUSK_SRC                 Path to Husk checkout (default: $ROOT/upstreams/husk)
#   APPLY_PATCHES            1 (default) to apply engines/android/patches/series
#                            when $HUSK_SRC is clean and lacks triptych-embed
#   BUILD_RUNTIME_FRAMEWORK  1 to also fetch third-party device deps (ANGLE,
#                            MoltenVK, rppairing, StikJIT, java-runtime; NO QEMU
#                            unless HUSK_WITH_QEMU=1) and build HuskRuntime.framework
#   HUSK_WITH_QEMU           0 (default; GPL-2.0-only QEMU is incompatible with
#                            GPL-3.0 Triptych in a single linked binary)
set -euo pipefail

SDK=${1:-iphonesimulator}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
SRC=${2:-${HUSK_SRC:-$ROOT/upstreams/husk}}
OUT=$ROOT/build/android/$SDK
PATCH_DIR=$ROOT/engines/android/patches
log() { printf '\n==> %s\n' "$*"; }

case "$SDK" in
  iphonesimulator) MIN_IOS_FLAG="-mios-simulator-version-min=15.5" ;;
  iphoneos)        MIN_IOS_FLAG="-miphoneos-version-min=15.5" ;;
  *) echo "ERROR: unsupported SDK '$SDK' (expected iphonesimulator or iphoneos)" >&2; exit 1 ;;
esac

# Fetch Husk from submodule if configured in .gitmodules
if [ ! -d "$SRC/.git" ]; then
  if git -C "$ROOT" config --file .gitmodules --get-regexp 'path$' 2>/dev/null | grep -q 'upstreams/husk$'; then
    log "Fetching Husk submodule in upstreams/husk"
    git -C "$ROOT" submodule update --init --recursive upstreams/husk
  else
    echo "ERROR: Husk source not found at $SRC" >&2
    echo "Register the submodule first (see (private notes)):" >&2
    echo "  git submodule add https://github.com/Leviidev/Husk.git upstreams/husk" >&2
    exit 1
  fi
fi

# Apply Triptych patches cleanly on a local triptych-fixes branch when requested
if [ "${APPLY_PATCHES:-1}" = 1 ] && ! grep -q "husk_embed_make_root" "$SRC/src/app/Husk/HuskApp.swift" 2>/dev/null; then
  if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
    echo "ERROR: $SRC has uncommitted changes and lacks triptych-embed.patch" >&2
    exit 1
  fi
  log "Applying engines/android/patches/series onto $SRC"
  BASE=$(git -C "$SRC" rev-parse HEAD)
  git -C "$SRC" checkout -q -B triptych-fixes "$BASE"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    git -C "$SRC" apply --3way "$PATCH_DIR/$p" 2>/dev/null || git -C "$SRC" apply "$PATCH_DIR/$p"
    git -C "$SRC" -c user.name=triptych -c user.email=triptych@localhost commit -qam "${p%.patch} (triptych)"
    echo "  applied $p"
  done < "$PATCH_DIR/series"
fi

CC=$(xcrun --sdk "$SDK" --find clang)
SDKROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
AR=$(xcrun --sdk "$SDK" --find ar)
OBJ=$OUT/obj
mkdir -p "$OBJ" "$OUT/include"

TL1="$SRC/src/translation-layer"
TL2="$SRC/src/translation-layer-next"
CFLAGS=(
  -arch arm64
  -isysroot "$SDKROOT"
  "$MIN_IOS_FLAG"
  -O2
  -fobjc-arc
  -I"$TL1"
  -I"$TL2"
  -I"$SRC/src/app/Husk"
)

log "Building Husk translation-layer library for $SDK (arm64)"
OBJS=()
for f in "$TL1"/*.c "$TL2"/*.c "$TL2"/*.m; do
  [ -e "$f" ] || continue
  base=$(basename "${f%.*}")
  parent=$(basename "$(dirname "$f")")
  obj="$OBJ/${parent}__${base}.o"
  OBJS+=("$obj")
  if [ ! -f "$obj" ] || [ "$f" -nt "$obj" ]; then
    case "$f" in
      *.m) "$CC" "${CFLAGS[@]}" -x objective-c -c "$f" -o "$obj" ;;
      *)   "$CC" "${CFLAGS[@]}" -c "$f" -o "$obj" ;;
    esac
  fi
done

LIB="$OUT/libhusk_tl.a"
rm -f "$LIB"
"$AR" rcs "$LIB" "${OBJS[@]}"
cp "$TL1"/husk-tl.h "$TL2"/husk-tl-unity-app.h "$TL2"/husk-tl-dvm.h "$TL2"/husk-tl-dvm-javaapp.h \
   "$SRC/src/app/Husk/HuskBridge.h" "$SRC/src/app/Husk/HuskRPPairing.h" "$OUT/include/"

echo "Built $LIB (${#OBJS[@]} object files, $(du -h "$LIB" | awk '{print $1}'))"

if [ "${BUILD_RUNTIME_FRAMEWORK:-0}" = 1 ]; then
  if [ "$SDK" != "iphoneos" ]; then
    echo "ERROR: HuskRuntime.framework full app target requires SDK=iphoneos (StikJIT.xcframework & MoltenVK device deps)" >&2
    exit 1
  fi
  if [ "${HUSK_WITH_QEMU:-0}" = 1 ]; then
    echo "WARNING: HUSK_WITH_QEMU=1 includes GPL-2.0-only libqemu-aarch64-softmmu.dylib; review GPL-3.0 compatibility before shipping." >&2
  fi
  log "Generating and building HuskRuntime.framework (iphoneos)"
  command -v xcodegen >/dev/null || { echo "ERROR: xcodegen is required (brew install xcodegen)" >&2; exit 1; }
  (cd "$SRC/src/app" && xcodegen generate)
  DD="$ROOT/build/android-dd"
  xcodebuild -project "$SRC/src/app/Husk.xcodeproj" -scheme Husk -configuration Release \
    -sdk iphoneos IPHONEOS_DEPLOYMENT_TARGET=15.5 \
    MACH_O_TYPE=mh_dylib EXECUTABLE_EXTENSION= \
    LD_DYLIB_INSTALL_NAME=@rpath/HuskRuntime.framework/HuskRuntime \
    DYLIB_INSTALL_NAME_BASE=@rpath \
    OTHER_SWIFT_FLAGS="\$(inherited) -DTRIPTYCH_EMBED $TRIPTYCH_PREFIX_MAP_SWIFTFLAGS" \
    OTHER_CFLAGS="\$(inherited) $TRIPTYCH_PREFIX_MAP_CFLAGS" \
    OTHER_LDFLAGS='$(inherited) -Wl,-export_dynamic' \
    SYMROOT="$DD/sym" OBJROOT="$DD/obj" \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' build
  APP="$DD/sym/Release-iphoneos/Husk.app"
  FW="$ROOT/build/android/HuskRuntime.framework"
  rm -rf "$FW" && mkdir -p "$FW"
  cp "$APP/Husk" "$FW/HuskRuntime"
  [ -f "$APP/default.metallib" ] && cp "$APP/default.metallib" "$FW/"
  for dir in java-runtime android-system; do
    [ -d "$APP/$dir" ] && cp -R "$APP/$dir" "$FW/"
  done
  for res in cacert.pem husk-jit.js; do
    [ -f "$APP/$res" ] && cp "$APP/$res" "$FW/"
  done
  echo "Assembled $FW (check Frameworks/ for libANGLE-shared.dylib and MoltenVK.framework)"
fi
