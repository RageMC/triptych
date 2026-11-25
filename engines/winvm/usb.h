// SPDX-License-Identifier: GPL-2.0-or-later
// USB for the winarm board: a general xHCI host controller (INTx only) with a HID boot
// keyboard, a HID absolute-pointer tablet and USB mass-storage (BOT + SCSI) devices.
#ifndef WINVM_USB_H
#define WINVM_USB_H
#include <stdint.h>
#include "winarm.h"
#include "disk.h"
#include <string.h>

/* Create the xHCI controller (idempotent) with the keyboard and the tablet attached.
   Call before winarm_finalize. Returns the controller, or NULL. */
void winvm_usb_destroy(void);
void *winvm_usb_create(WinArm *b);
/* Attach a mass-storage device (creating the controller if needed): disk presented as a
   CD-ROM (SCSI type 5, 2048-byte blocks, read-only) or a disk (type 0, 512-byte blocks).
   The HvDisk is copied. Returns the device, or NULL. */
void *winvm_usb_storage_create(WinArm *b, HvDisk *disk, int cdrom);

/* Attach a USB CDC NCM Ethernet adapter (Windows' inbox UsbNcm driver binds to it) with the given MAC,
   on Henge's user-mode NAT (net_slirp: the guest gets 10.0.2.15 by DHCP, gateway 10.0.2.2, DNS 10.0.2.3).
   Call before winarm_finalize, at most once. Returns the device, or NULL (also in builds without WINVM_NET). */
void *winvm_usb_net_create(WinArm *b, const uint8_t mac[6]);
extern uint64_t winvm_net_rx_frames, winvm_net_tx_frames;

/* Any thread. A key went down or up: code is a HID keyboard usage (usage page 7;
   4 = A, 0x28 = Enter, 0xe0-0xe7 = modifiers). */
void usb_key(uint8_t code, int down);
/* Any thread. The tablet: x and y in 0..32767, buttons bit 0 left / 1 right / 2 middle,
   wheel a signed step count (positive = up). */
void usb_tablet(int x, int y, int buttons, int wheel);

/* Bytes the guest has read from USB mass storage (the installer ISO) since start. */
uint64_t usb_storage_bytes_read(void);
/* Installer boot without a keyboard: Windows' cdboot.efi waits ~5 s for "Press any key to boot from CD or DVD"
   and otherwise falls through to the next boot option. If disk is blank (no GPT/MBR signature: nothing installed),
   start a thread that presses Space once a second until the guest has read 32 MB from USB storage (the installer
   is loading: the prompt is gone) or 120 s pass. Returns 1 if it started. */
int usb_autoboot_cd(HvDisk *disk);
/* 1 if disk has neither an MBR boot signature nor a GPT header (nothing installed), 0 otherwise or on a read error. */
static inline int winvm_disk_blank(HvDisk *disk) {
    unsigned char s[1024];
    if (!disk || disk->size < sizeof s || hv_disk_read(disk, 0, s, sizeof s) != 0) return 0;
    return !(s[510] == 0x55 && s[511] == 0xaa) && memcmp(s + 512, "EFI PART", 8) != 0;
}

#endif
