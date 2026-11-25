// SPDX-License-Identifier: GPL-2.0-or-later
// Storage for the winarm board: NVMe (Windows' inbox stornvme) and USB mass storage
// on Henge's xHCI (installer media; Windows' inbox usbstor + cdrom/UDF).
#ifndef WINVM_DEVICES_EXT_H
#define WINVM_DEVICES_EXT_H
#include "winarm.h"
#include "disk.h"
void *winvm_nvme_create(WinArm *b, HvDisk *disk, int readonly);
void *winvm_usb_create(WinArm *b); /* xHCI with keyboard + tablet (usb.c) */
void *winvm_usb_storage_create(WinArm *b, HvDisk *disk, int cdrom);
/* TPM 2.0 (libtpms behind a TIS interface). state_path keeps the TPM's NVRAM between runs. */
void *winvm_tpm_create(WinArm *b, const char *state_path);
/* Commands the TPM has run since start (0 without a TPM). */
void winvm_tpm_destroy(WinArm *b);
unsigned winvm_tpm_command_count(void);
#endif
