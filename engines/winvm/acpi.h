// SPDX-License-Identifier: GPL-2.0-or-later
// ACPI tables for Windows, handed to EDK2 through fw_cfg's table loader.
#ifndef WINVM_ACPI_H
#define WINVM_ACPI_H
struct WinArm;
int acpi_build(struct WinArm *b);
#endif
