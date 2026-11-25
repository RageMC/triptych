// SPDX-License-Identifier: GPL-2.0-or-later
// SSDT with the TPM 2.0 device (compiled with iasl into ssdt_tpm_aml.h). acpi.c adds it, with the
// TPM2 table, only when the board has a TPM. The window must match WA_TPM / WA_TPM_SIZE in winarm.h.
// MSFT0101 is what Windows' tpm.sys and Linux' tpm_tis match (QEMU's tpm-tis-device uses the same).
DefinitionBlock ("ssdt_tpm.aml", "SSDT", 2, "TRPTCH", "WINTPM  ", 1)
{
    Scope (\_SB)
    {
        Device (TPM0)
        {
            Name (_HID, "MSFT0101")
            Name (_STR, Unicode ("TPM 2.0 Device"))
            Name (_UID, One)
            Name (_STA, 0x0F)
            Name (_CRS, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x0C000000, 0x00005000)
            })
        }
    }
}
