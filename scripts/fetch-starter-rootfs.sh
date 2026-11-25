#!/bin/bash
# Downloads Alpine's official aarch64 minirootfs (checksum-verified) and
# imports it into LinuxRunner's fakefs format with its own fakefsify tool.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VER=3.22.2; BR=v3.22
URL=https://dl-cdn.alpinelinux.org/alpine/$BR/releases/aarch64/alpine-minirootfs-$VER-aarch64.tar.gz
DL=$ROOT/build/downloads; OUT=$ROOT/build/resources/alpine-fs
[ -f "$OUT/meta.db" ] && { echo "have $OUT"; exit 0; }
mkdir -p "$DL" "$ROOT/build/resources"
[ -f "$DL/${URL##*/}" ] || curl -sSfL -o "$DL/${URL##*/}" "$URL"
(cd "$DL" && curl -sSfL "$URL.sha256" | shasum -a 256 -c -)
HOST=$ROOT/build/linux/host
if [ ! -x "$HOST/tools/fakefsify" ]; then
  meson setup $([ -d "$HOST/meson-private" ] && echo --reconfigure) "$HOST" "$ROOT/upstreams/linuxrunner" -Dengine=asbestos -Dguest_arch=arm64 -Djit=false -Djit_emit=false -Dcli_aot= -Dvdso_required=true >/dev/null
  ninja -C "$HOST" ish tools/fakefsify >/dev/null
fi
"$HOST/tools/fakefsify" "$DL/${URL##*/}" "$OUT"
echo "imported $OUT"
