# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by every build script: keeps the builder's home folder (user name, checkout paths) out of everything the
# build produces. Compilers embed source paths in __FILE__, assert messages, debug info and Swift/Rust panics;
# these maps rewrite "$HOME/..." to "~/...".
#
#   C/ObjC/C++ (any clang the script runs, including configure, meson, cmake and make): CCC_OVERRIDE_OPTIONS
#   Swift (swiftc in scripts):            "${TRIPTYCH_SWIFT_PREFIX_MAP[@]}"
#   xcodebuild of a third-party project:  "${TRIPTYCH_XCODE_PREFIX_MAP[@]}" (Triptych's own project sets them in project.yml)
#   Rust (cargo):                         RUSTFLAGS
# A value baked in at configure time (an install prefix) is not a compiler path; triptych_check_no_home finds those
# and the packaging step rewrites them (scripts/package-ipa.sh).
_tp_home=${HOME%/}
_tp_map="$_tp_home=~"
# The clang driver appends each "+arg" to every invocation; "#" keeps it quiet.
case "${CCC_OVERRIDE_OPTIONS:-}" in
  *"-ffile-prefix-map=$_tp_map"*) ;;
  *) _tp_ccc=${CCC_OVERRIDE_OPTIONS:-}; export CCC_OVERRIDE_OPTIONS="# ${_tp_ccc#\# } +-ffile-prefix-map=$_tp_map +-fdebug-prefix-map=$_tp_map";;
esac
case " ${RUSTFLAGS:-} " in
  *" --remap-path-prefix=$_tp_map "*) ;;
  *) export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }--remap-path-prefix=$_tp_map";;
esac
TRIPTYCH_PREFIX_MAP_CFLAGS="-ffile-prefix-map=$_tp_map -fdebug-prefix-map=$_tp_map"
# #filePath is never remapped; ConciseMagicFile makes #file (and so fatalError/precondition) "Module/File.swift".
TRIPTYCH_SWIFT_PREFIX_MAP=(-file-prefix-map "$_tp_map" -debug-prefix-map "$_tp_map" -enable-upcoming-feature ConciseMagicFile)
TRIPTYCH_PREFIX_MAP_SWIFTFLAGS="${TRIPTYCH_SWIFT_PREFIX_MAP[*]}"
TRIPTYCH_XCODE_PREFIX_MAP=(
  "OTHER_CFLAGS=\$(inherited) $TRIPTYCH_PREFIX_MAP_CFLAGS"
  "OTHER_SWIFT_FLAGS=\$(inherited) $TRIPTYCH_PREFIX_MAP_SWIFTFLAGS"
)

# triptych_check_no_home DIR...: lists files under DIR that still contain the home path or user name; status 1 if any.
triptych_check_no_home() {
  local name; name=$(basename "$_tp_home")
  ! grep -rlaF -e "$_tp_home" -e "$name" "$@" 2>/dev/null | sed "s|^|still has a home path or user name: |" | grep .
}

# triptych_scrub_home DIR...: rewrites "$HOME" in every file under DIR to a same-length path ("/home//////..."; extra
# slashes are harmless) so Mach-O offsets and code signatures computed afterwards stay valid. Run before signing.
triptych_scrub_home() {
  /usr/bin/python3 - "$_tp_home" "$@" <<'PY'
import os, sys
home = sys.argv[1].encode()
new = (b"/home" + b"/" * len(home))[:len(home)]
for top in sys.argv[2:]:
    for d, _, files in os.walk(top):
        for f in files:
            p = os.path.join(d, f)
            if os.path.islink(p):
                continue
            data = open(p, "rb").read()
            if home in data:
                open(p, "wb").write(data.replace(home, new))
PY
}
