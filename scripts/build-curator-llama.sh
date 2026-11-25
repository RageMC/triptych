#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
SDK="${1:?Pass iphoneos or iphonesimulator}"
case "$SDK" in
    iphoneos) METAL=ON ;;
    iphonesimulator) METAL=OFF ;;
    *) echo "Unsupported Curator SDK: $SDK" >&2; exit 1 ;;
esac
SOURCE="$ROOT/upstreams/llama.cpp"
OUTPUT="$ROOT/build/curator-llama/$SDK"
if [[ ! -f "$SOURCE/include/llama.h" ]]; then
    echo "Initialize llama.cpp with git submodule update --init upstreams/llama.cpp" >&2
    exit 1
fi
# Xcode's script phase exports settings for Triptych. Give the nested build its own SDK/settings.
run_clean() {
    env -i PATH="$PATH" DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" TMPDIR="${TMPDIR:-/tmp}" "$@"
}
run_clean cmake -S "$SOURCE" -B "$OUTPUT/cmake" -G Xcode \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS="$SDK" -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF \
    -DGGML_BLAS=ON -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF -DGGML_METAL="$METAL" -DGGML_METAL_EMBED_LIBRARY=ON \
    -DGGML_METAL_TARGET_OS=ios \
    -DCMAKE_C_FLAGS="$TRIPTYCH_PREFIX_MAP_CFLAGS" -DCMAKE_CXX_FLAGS="$TRIPTYCH_PREFIX_MAP_CFLAGS" \
    -DCMAKE_OBJC_FLAGS="$TRIPTYCH_PREFIX_MAP_CFLAGS"
run_clean cmake --build "$OUTPUT/cmake" --target llama --config Release -j 6 -- -quiet CODE_SIGNING_ALLOWED=NO
LIBS=(libllama.a libggml.a libggml-base.a libggml-cpu.a libggml-blas.a)
if [[ "$METAL" == ON ]]; then LIBS+=(libggml-metal.a); fi
ARCHIVES=()
for lib in "${LIBS[@]}"; do
    ARCHIVE="$(find "$OUTPUT/cmake" -name "$lib" -print -quit)"
    [[ -n "$ARCHIVE" ]] || { echo "Missing archive: $lib" >&2; exit 1; }
    ARCHIVES+=("$ARCHIVE")
done
xcrun libtool -static -o "$OUTPUT/libcurator_llama.a" "${ARCHIVES[@]}"
