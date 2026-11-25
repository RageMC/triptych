#!/bin/bash
# Build EDK2 ArmVirtQemu AARCH64 firmware (RELEASE, CLANGDWARF) on macOS.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
SRC="$ROOT/build/edk2-src"
OUT="$ROOT/build/firmware"
TAG="${EDK2_TAG:-edk2-stable202608}"
for p in llvm lld acpica nasm make; do brew list "$p" >/dev/null 2>&1 || brew install "$p"; done
if [ ! -d "$SRC/.git" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/tianocore/edk2 "$SRC"
fi
# Build through a fixed path outside the home folder: GenFw writes each module's absolute .dll path into the
# firmware's PE debug entries, and a prefix map cannot reach those.
WS=/tmp/triptych-edk2
ln -sfn "$SRC" "$WS"
cd "$WS"
git submodule update --init --depth 1 \
  CryptoPkg/Library/OpensslLib/openssl \
  MdePkg/Library/MipiSysTLib/mipisyst \
  MdePkg/Library/BaseFdtLib/libfdt \
  MdeModulePkg/Universal/RegularExpressionDxe/oniguruma \
  MdeModulePkg/Library/BrotliCustomDecompressLib/brotli \
  BaseTools/Source/C/BrotliCompress/brotli \
  SecurityPkg/DeviceSecurity/SpdmLib/libspdm \
  CryptoPkg/Library/MbedTlsLib/mbedtls 2>&1 | tail -3

export PATH="/opt/homebrew/opt/llvm/bin:/opt/homebrew/opt/lld/bin:/opt/homebrew/opt/make/libexec/gnubin:/opt/homebrew/bin:$PATH"
export CLANG_BIN="/opt/homebrew/opt/llvm/bin/"
export PACKAGES_PATH="$WS"
export WORKSPACE="$WS"
export PYTHON_COMMAND=/usr/bin/python3
export CC=clang CXX=clang++
# shellcheck disable=SC1091
set +u; . ./edksetup.sh BaseTools >/dev/null; set -u
make -C BaseTools -j6 CC=clang CXX=clang++ EXTRA_OPTFLAGS=-Wno-error

# Tcg2Pei runs execute-in-place from the flash, which ArmVirt maps read-only; the BaseRngLib it links writes a
# global in its constructor (mRndrSupported), a permission fault the moment a TPM makes Tcg2Pei run
# ("Synchronous Exception" at the constructor). Tcg2Pei only hashes: give it the null RngLib.
if ! grep -q "BaseRngLibNull" ArmVirtPkg/ArmVirtQemu.dsc; then
  /usr/bin/python3 - <<'PY'
p = "ArmVirtPkg/ArmVirtQemu.dsc"
s = open(p).read()
old = "  SecurityPkg/Tcg/Tcg2Pei/Tcg2Pei.inf {\n    <LibraryClasses>\n"
assert old in s
open(p, "w").write(s.replace(old, old + "      RngLib|MdePkg/Library/BaseRngLibNull/BaseRngLibNull.inf\n", 1))
PY
fi

# EDK2 tracks this file with CRLF. Apply the preferred-mode patch once, retaining
# its original line endings so a rebuild can identify the already-applied patch.
RAMFB_PATCH="$ROOT/engines/winvm/edk2/ramfb-mode.patch"
ramfb_apply() {
  /usr/bin/sed $'s/$/\r/' "$RAMFB_PATCH" | git apply "$@" -
}
if ! ramfb_apply --reverse --check 2>/dev/null; then
  ramfb_apply
fi

BUILD_TYPE="${BUILD_TYPE:-RELEASE}"
DEFS="-D TPM2_ENABLE=TRUE -D SECURE_BOOT_ENABLE=TRUE -D NETWORK_HTTP_BOOT_ENABLE=FALSE -D NETWORK_TLS_ENABLE=FALSE"
[ "$BUILD_TYPE" = DEBUG ] && DEFS="$DEFS -D DEBUG_ON_SERIAL_PORT=TRUE"
# shellcheck disable=SC2086
build -a AARCH64 -t CLANGDWARF -b "$BUILD_TYPE" -n 6 -p ArmVirtPkg/ArmVirtQemu.dsc $DEFS

FV="$SRC/Build/ArmVirtQemu-AARCH64/${BUILD_TYPE}_CLANGDWARF/FV"
mkdir -p "$OUT"
if [ "$BUILD_TYPE" = DEBUG ]; then
  cp "$FV/QEMU_EFI.fd" "$OUT/QEMU_EFI-debug.fd"
  truncate -s 64m "$OUT/QEMU_EFI-debug.fd"
  ls -l "$OUT"; exit 0
fi
cp "$FV/QEMU_EFI.fd" "$FV/QEMU_VARS.fd" "$OUT/"
truncate -s 64m "$OUT/QEMU_EFI.fd" "$OUT/QEMU_VARS.fd"
echo "$TAG $(git rev-parse HEAD)" > "$OUT/edk2-version.txt"
cp License.txt "$OUT/License.txt"
ls -l "$OUT"
