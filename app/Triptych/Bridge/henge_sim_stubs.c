// SPDX-License-Identifier: GPL-3.0-or-later
// The Simulator has no build of Henge's restore stack (libirecovery, usbmuxd,
// idevicerestore over the virtual USB port), so installing macOS is a
// device-only feature. Booting an existing (imported) Mac still links.
#include <TargetConditionals.h>
#if TARGET_OS_SIMULATOR && TRIPTYCH_HAS_MACOS
#include "install.h"
int hv_install_start(HvVirtioUsb *usb, const char *ipsw, const char *workdir, uint64_t ecid,
                     HvInstallProgress cb, void *user) {
    (void)usb; (void)ipsw; (void)workdir; (void)ecid; (void)cb; (void)user;
    return -1;
}
#endif
