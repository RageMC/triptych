#!/bin/bash
# Boot a checkpoint made by ckpt-watch.sh in a new directory (APFS clones, so the checkpoint stays untouched).
#   tools/winvm/ckpt-boot.sh DIR/ckN NEWDIR      (env as vm.sh: CPUS, RAM, VMENV, ...)
set -e
cd "$(dirname "$0")/../.."; S=${1:?usage: ckpt-boot.sh CKPT NEWDIR}; D=${2:?usage: ckpt-boot.sh CKPT NEWDIR}
mkdir -p "$D"; for f in disk.img vars.fd tpm.bin; do cp -c "$S/$f" "$D/$f"; done
NOKEY=1 tools/winvm/vm.sh "$D"
