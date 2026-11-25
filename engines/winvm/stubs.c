// SPDX-License-Identifier: GPL-2.0-or-later
#include "devices_ext.h"
__attribute__((weak)) void *winvm_nvme_create(WinArm *b, HvDisk *d, int ro) { (void)b; (void)d; (void)ro; return 0; }
__attribute__((weak)) void *winvm_usb_storage_create(WinArm *b, HvDisk *d, int cd) { (void)b; (void)d; (void)cd; return 0; }
__attribute__((weak)) void winvm_tpm_destroy(WinArm *b) { (void)b; }

__attribute__((weak)) unsigned winvm_tpm_command_count(void) { return 0; }
__attribute__((weak)) void *winvm_tpm_create(WinArm *b, const char *p) { (void)b; (void)p; return 0; }
