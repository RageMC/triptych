#!/bin/bash
# Start Triptych's Windows VM (engines/winvm) on a scratch directory, for testing on the Mac.
#   tools/winvm/vm.sh DIR      DIR gets vars.fd, a sparse 64 GB disk.img, tpm.bin, ctl, live.log, pid
# Env: CPUS (4), RAM (4096 MB), SECS (86400), WINVM (binary), VMENV="K=V K=V" (extra winvm env, e.g. WINVM_USB_LOG=1)
#      ISO: the user's own Windows 11 ARM64 ISO. It is read-only: never copy, modify or redistribute it.
#      FRESH=1: reset UEFI vars and the TPM (a new Setup boot from the ISO)
#      NET=1: attach the USB network adapter (--net)
#      NOKEY=1: don't press a key at "Press any key to boot from CD or DVD" (boot the installed system from NVMe)
set -e
R=$(cd "$(dirname "$0")/../.." && pwd); D=${1:?usage: vm.sh DIR}; mkdir -p "$D"
ISO=${ISO:-$HOME/Downloads/Windows11_arm64.iso}  # your own Windows 11 ARM64 ISO
[ -f "$D/disk.img" ] || mkfile -n 64g "$D/disk.img"
if [ -n "$FRESH" ] || [ ! -f "$D/vars.fd" ]; then cp "$R/build/firmware/QEMU_VARS.fd" "$D/vars.fd"; rm -f "$D/tpm.bin"; fi
rm -f "$D/ctl"
ENVV=(WINVM_CTL="$D/ctl" WINVM_RESET_SHOTS=1)
[ -z "$NOKEY" ] && ENVV+=(WINVM_TYPE=" " WINVM_TYPE_DELAY=10 WINVM_TYPE_REPEAT=60 WINVM_TYPE_EVERY=1)
for kv in $VMENV; do ENVV+=("$kv"); done
nohup env "${ENVV[@]}" "${WINVM:-$R/engines/winvm/build/winvm}" --code "$R/build/firmware/QEMU_EFI.fd" --vars "$D/vars.fd" \
  --ram "${RAM:-4096}" --cpus "${CPUS:-4}" --nvme "$D/disk.img" --cdrom "$ISO" --tpm "$D/tpm.bin" \
  ${NET:+--net} --seconds "${SECS:-86400}" --screenshot "$D/shot.ppm" > "$D/live.log" 2>&1 &
echo $! > "$D/pid"; echo "pid $(cat "$D/pid") log $D/live.log"
