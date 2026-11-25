#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Perl 5.42 for iOS (CrossOver Preview's cx tools are Perl scripts): static libperl.a + core XS module archives
# + xs_init (perlxsi.c) + the pure-Perl library, in build/perl/<sdk>/. Perl is Artistic-1.0/GPL-1.0+ (credited in
# the app's licenses). Method: a native static macOS build (same OS family and config.h); a clang wrapper records
# every compile (cwd + args); each target object is recompiled for the iOS SDK and archived.
# Every iOS object force-includes engines/macapps/perl/triptych_perl_guard.h: Perl runs inside Triptych, so its
# fork/exec/exit/kill/signal calls go to app/MacAppsKit/PerlCommand.c instead of acting on the app.
# Output for Xcode: build/perl/<sdk>/libtriptychperl.a (libperl + modules + xs_init) and include/.
# Usage: scripts/build-perl-ios.sh iphonesimulator|iphoneos   (skips work when the archive is up to date)
set -euo pipefail
SDK=${1:?iphonesimulator|iphoneos}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/scripts/lib/no-home-paths.sh"  # no home paths in build output
V=5.42.0; SHA=e093ef184d7f9a1b9797e2465296f55510adb6dab8842b0c3ed53329663096dc
H=$ROOT/build/perl; M=$H/mac; REC=$H/compiles.tsv; OUT=$H/$SDK
case $SDK in iphonesimulator) MIN=-mios-simulator-version-min=17.0;; iphoneos) MIN=-miphoneos-version-min=17.0;; *) exit 2;; esac
# Modules that need libraries iOS doesn't have.
SKIP='GDBM_File|DB_File|NDBM_File'
GUARD=$ROOT/engines/macapps/perl/triptych_perl_guard.h
if [ -f "$OUT/libtriptychperl.a" ] && [ "$OUT/libtriptychperl.a" -nt "$GUARD" ] && [ "$OUT/libtriptychperl.a" -nt "$0" ] \
   && [ -d "$H/lib" ]; then exit 0; fi
mkdir -p "$H"
if [ ! -x "$M/perl" ]; then
  T=$H/perl-$V.tar.gz
  [ -f "$T" ] || curl -fsSL -o "$T" "https://www.cpan.org/src/5.0/perl-$V.tar.gz"
  echo "$SHA  $T" | shasum -a 256 -c - >/dev/null
  rm -rf "$M"; mkdir -p "$M"; tar xzf "$T" -C "$M" --strip-components=1
  (cd "$M" && ./Configure -des -Dusethreads -Dusemultiplicity -Uusedl -Dprefix=/triptych-perl -Dman1dir=none \
     -Dman3dir=none -Dcc=clang -Doptimize=-O2 >/dev/null && make -j"$(sysctl -n hw.ncpu)" >/dev/null)
  rm -f "$REC"
fi
if [ ! -s "$REC" ]; then
  mkdir -p "$H/wrap"; cat > "$H/wrap/clang" <<W
#!/bin/bash
for a in "\$@"; do if [ "\$a" = -c ]; then line=\$(printf '%s' "\$PWD"; printf '\t%q' "\$@"); printf '%s\n' "\$line" >> "$REC"; break; fi; done
exec /usr/bin/clang "\$@"
W
  chmod +x "$H/wrap/clang"
  (cd "$M" && for o in $(ar t libperl.a | grep '\.o$'); do rm -f "$o"; done; find cpan dist ext -name '*.o' -delete
   find lib/auto -name '*.a' -delete; rm -f libperl.a; PATH=$H/wrap:$PATH make -j"$(sysctl -n hw.ncpu)" >/dev/null)
fi
rm -rf "$OUT"; mkdir -p "$OUT/obj" "$OUT/ext" "$OUT/include"
CORE=" $(cd "$M" && ar t libperl.a | grep '\.o$' | tr '\n' ' ')"
while IFS=$'\t' read -r dir rest; do
  eval "args=($rest)"
  dir=$M${dir#*/build/perl/mac}  # the record may come from another checkout of this repo
  src=""; for a in "${args[@]}"; do case $a in *.c) src=$a;; esac; done
  [ -n "$src" ] || continue
  obj=$(basename "${src%.c}").o; rel=${dir#"$M"}; rel=${rel#/}
  if [ -z "$rel" ]; then case "$CORE" in *" $obj "*) ;; *) continue;; esac; dest=$OUT/obj/core; else dest=$OUT/obj/$rel; fi
  echo "$rel" | grep -qE "$SKIP" && continue
  mkdir -p "$dest"
  (cd "$dir" && xcrun -sdk "$SDK" clang -arch arm64 $MIN -include "$GUARD" "${args[@]}" -o "$dest/$obj")
done < <(awk -F'\t' '!seen[$0]++' "$REC")
ar rcs "$OUT/libperl.a" "$OUT"/obj/core/*.o
for d in $(cd "$OUT/obj" && find . -mindepth 2 -type d); do
  ls "$OUT/obj/$d"/*.o >/dev/null 2>&1 || continue
  ar rcs "$OUT/ext/$(echo "${d#./}" | tr '/' '_').a" "$OUT/obj/$d"/*.o
done
# xs_init for the static modules (from the native perlmain.c, minus the skipped ones).
{ printf '#include "EXTERN.h"\n#include "perl.h"\n#include "XSUB.h"\n'
  grep -vE "$SKIP" "$M/perlmain.c" | sed -n '/^EXTERN_C void boot_DynaLoader/,$p' | sed 's/^static void$//; s/^xs_init(pTHX)/void triptych_perl_xs_init(pTHX)/'
} > "$OUT/perlxsi.c"
cp "$M"/*.h "$OUT/include/"
# The embedding flags must match the objects' (they change the interpreter struct): see PerlCommand.c.
xcrun -sdk "$SDK" clang -arch arm64 $MIN -c -O2 -fno-common -DPERL_DARWIN -DNO_THREAD_SAFE_QUERYLOCALE \
  -DNO_POSIX_2008_LOCALE -DHAS_BROKEN_LANGINFO_CODESET -DNO_LOCALE_COLLATE -fno-strict-aliasing -I"$OUT/include" \
  "$OUT/perlxsi.c" -o "$OUT/obj/perlxsi.o"
libtool -static -o "$OUT/libtriptychperl.a" "$OUT/libperl.a" "$OUT"/ext/*.a "$OUT/obj/perlxsi.o" 2>/dev/null
rm -rf "$OUT/obj"
# Pure-Perl library (shared by both SDKs): lib/ minus docs, tests and the skipped modules.
if [ ! -d "$H/lib" ]; then
  rsync -a --exclude '*.pod' --exclude 'pod/' --exclude '*.t' --exclude 't/' --exclude 'auto/' \
    --exclude '*DBM_File*' --exclude 'DB_File*' --exclude buildcustomize.pl "$M/lib/" "$H/lib/"  # buildcustomize.pl: miniperl's build-tree @INC
fi
echo "Perl $V for $SDK: $(ls "$OUT/ext" | wc -l | tr -d ' ') modules, lib $(du -sh "$H/lib" | cut -f1)"
