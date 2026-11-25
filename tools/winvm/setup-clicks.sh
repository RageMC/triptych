#!/bin/bash
# Click through Windows 11 Setup from "Select language settings" to "Ready to install"; with "install" also click Install.
#   tools/winvm/setup-clicks.sh DIR [install]
# The user accepted Microsoft's license terms for this Windows 11 Pro test install on 2026-11-15 (their own ISO,
# no product key: Setup's own "I don't have a product key" option). Do not reuse this for anything else.
# Coordinates are for the 800x600 framebuffer. Waits are generous; check the k*.png screenshots if a step is missed.
C="$(dirname "$0")/ctl.sh"; D=${1:?dir}
"$C" "$D" wait-setup 900 || exit 1; sleep 8
WAIT=8  "$C" "$D" click 661 535 k1   # Select language settings -> Next
WAIT=25 "$C" "$D" click 661 535 k2   # Select keyboard settings -> Next
WAIT=2  "$C" "$D" click 97 268       # "I agree everything will be deleted" (the empty test disk)
WAIT=12 "$C" "$D" click 661 535 k3   # Select setup option -> Next
WAIT=12 "$C" "$D" click 158 474 k4   # "I don't have a product key"
WAIT=2  "$C" "$D" click 143 260      # Windows 11 Pro
WAIT=12 "$C" "$D" click 661 535 k5   # Select Image -> Next
WAIT=15 "$C" "$D" click 661 535 k6   # license terms -> Accept (see the header)
WAIT=25 "$C" "$D" click 661 535 k7   # Disk 0 Unallocated Space -> Next
[ "$2" = install ] && WAIT=30 "$C" "$D" click 661 535 k8   # Ready to install -> Install
echo done
