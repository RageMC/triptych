#!/bin/bash
# Compile a synthetic absolute load for the two Darwin targets. No binary is run.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/build/guest-address-lowering"
mkdir -p "$OUT"

compile() {
    local sdk=$1 target=$2 output=$3
    shift 3
    /usr/bin/xcrun --sdk "$sdk" clang -target "$target" -Werror -O2 -S \
        "$@" -x c -o "$output" - <<'EOF'
typedef volatile const unsigned int GUEST_ADDRESS_SPACE GuestWord;

unsigned int read_shared_user_data(void) {
    return *(GuestWord *)0x7ffe0000UL;
}
EOF
}

check_target() {
    local sdk=$1 target=$2
    local plain="$OUT/$sdk-plain.s" qualified="$OUT/$sdk-qualified.s"
    local qualifier='-DGUEST_ADDRESS_SPACE=__attribute__((address_space(1)))'
    compile "$sdk" "$target" "$plain" -DGUEST_ADDRESS_SPACE=
    compile "$sdk" "$target" "$qualified" "$qualifier"
    compile "$sdk" "$target" "$OUT/$sdk-qualified.ll" "$qualifier" -emit-llvm
    rg -q 'load volatile i32, ptr addrspace\(1\) inttoptr' "$OUT/$sdk-qualified.ll"
    diff -u "$plain" "$qualified"
    rg -q 'mov\s+w8, #2147352576\b' "$plain"
    rg -q 'ldr\s+w0, \[x8\]' "$plain"
    printf '%s: both variants emit a direct load from 0x7ffe0000\n' "$target"
}

check_target macosx arm64-apple-macos12
check_target iphonesimulator arm64-apple-ios17.0-simulator
