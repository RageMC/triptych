#!/bin/bash
# Build libtpms (BSD-3-Clause, https://github.com/stefanberger/libtpms) as a static library for the
# Mac development build of the winarm board's TPM 2.0 (engines/winvm/tpm.c).
# Output: engines/winvm/build/libtpms/install/{include,lib}. Needs Homebrew openssl@3 + autotools.
# NOTE for iOS: libtpms needs libcrypto (bignum, RSA/ECC, AES, SHA, HMAC, RNG). Options:
#   1. Cross-build OpenSSL 3.x static for iOS arm64 (Configure ios64-xcrun no-shared no-apps no-tests)
#      and link libtpms against it. Easiest; ~3 MB; OpenSSL is Apache-2.0. libtpms stays BSD-3.
#   2. Use libtpms' --with-openssl against Apple's CommonCrypto: not supported (no bignum/ECC API).
#   3. Reuse a libcrypto that the app already ships (e.g. via wolfSSL's OpenSSL compat or BoringSSL):
#      libtpms calls EVP/BN/EC_POINT/RSA APIs, so only a full OpenSSL-API-compatible lib works.
# Pin: bump TAG deliberately.
set -euo pipefail
TAG="${LIBTPMS_TAG:-v0.10.2}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
B="$ROOT/engines/winvm/build/libtpms"
OSSL="${OPENSSL_PREFIX:-$(brew --prefix openssl@3)}"
export PATH="/opt/homebrew/bin:/opt/local/bin:$PATH"
mkdir -p "$B"
if [ ! -d "$B/src/.git" ]; then
  git clone --depth 1 --branch "$TAG" https://github.com/stefanberger/libtpms "$B/src"
fi
cd "$B/src"
git describe --tags 2>/dev/null || true
./autogen.sh --with-openssl --with-tpm2 --prefix="$B/install" --disable-shared --enable-static \
  --without-tpm1 PKG_CONFIG_PATH="$OSSL/lib/pkgconfig" CFLAGS="-O2 -g -fno-common" CPPFLAGS="-I$OSSL/include" LDFLAGS="-L$OSSL/lib" >/dev/null
make -j6 >/dev/null
make install >/dev/null
ls -l "$B/install/lib" "$B/install/include/libtpms"
