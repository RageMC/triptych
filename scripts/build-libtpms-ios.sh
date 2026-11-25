#!/bin/bash
# Build the winarm board's TPM 2.0 for iOS: OpenSSL's libcrypto (Apache-2.0) and libtpms (BSD-3-Clause), both static.
#   scripts/build-libtpms-ios.sh iphoneos|iphonesimulator
#   -> build/libtpms-ios/<sdk>/install/{include,lib}  (libtpms.a + libcrypto.a)
# scripts/build-winvm.sh links both into libwinvm.a with every symbol hidden, so this libcrypto never clashes with others.
# Pins: OpenSSL 3.5.9 (sha256 checked), libtpms v0.10.2 (same tag as scripts/build-libtpms.sh).
set -euo pipefail
SDK=${1:?sdk: iphoneos|iphonesimulator}
OSSL_VER=3.5.9; OSSL_SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
TAG="${LIBTPMS_TAG:-v0.10.2}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
B=$ROOT/build/libtpms-ios; S=$B/src; O=$B/$SDK; P=$O/install
export PATH="/opt/homebrew/bin:$PATH"
mkdir -p "$S" "$O"
case $SDK in
  iphoneos) OTARGET=ios64-xcrun; MIN=-miphoneos-version-min=17.0 ;;
  iphonesimulator) OTARGET=iossimulator-arm64-xcrun; MIN=-mios-simulator-version-min=17.0 ;;
  *) echo "unknown sdk $SDK" >&2; exit 1 ;;
esac
SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)

# OpenSSL libcrypto
T=$S/openssl-$OSSL_VER.tar.gz
[ -f "$T" ] || curl -fsSL -o "$T" "https://github.com/openssl/openssl/releases/download/openssl-$OSSL_VER/openssl-$OSSL_VER.tar.gz"
echo "$OSSL_SHA  $T" | shasum -a 256 -c - >/dev/null
if [ ! -f "$P/lib/libcrypto.a" ]; then
  rm -rf "$O/openssl"; mkdir -p "$O/openssl"; tar -xzf "$T" -C "$O/openssl" --strip-components 1
  (cd "$O/openssl" && ./Configure "$OTARGET" no-shared no-apps no-tests no-docs no-engine no-dso no-ui-console \
     no-ssl no-tls no-dtls no-quic no-module --prefix="$P" --libdir=lib CFLAGS="$MIN -O2 -fno-common" >/dev/null &&
   make -j6 build_libs >/dev/null && make install_dev >/dev/null)
fi

# libtpms
if [ ! -d "$S/libtpms/.git" ]; then git clone -q --depth 1 --branch "$TAG" https://github.com/stefanberger/libtpms "$S/libtpms"; fi
rm -rf "$O/libtpms"; cp -R "$S/libtpms" "$O/libtpms"
cd "$O/libtpms"
CC="xcrun --sdk $SDK clang -arch arm64 -isysroot $SYSROOT $MIN"
NOCONFIGURE=1 ./autogen.sh >/dev/null 2>&1 || autoreconf -fi >/dev/null
./configure --host=aarch64-apple-darwin --with-openssl --with-tpm2 --without-tpm1 --disable-shared --enable-static \
  --prefix="$P" CC="$CC" CFLAGS="-O2 -g -fno-common" CPPFLAGS="-I$P/include" LDFLAGS="-L$P/lib" LIBS="-lcrypto" \
  PKG_CONFIG_PATH="$P/lib/pkgconfig" PKG_CONFIG_LIBDIR="$P/lib/pkgconfig" >/dev/null
make -j6 >/dev/null
make install >/dev/null
ls -l "$P/lib/libtpms.a" "$P/lib/libcrypto.a"
