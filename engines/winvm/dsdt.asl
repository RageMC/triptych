// SPDX-License-Identifier: GPL-2.0-or-later
// DSDT of the winarm board (compiled with iasl into dsdt_aml.h). CPUs are in an SSDT built
// at run time (their count varies). Addresses and interrupts must match winarm.h.
DefinitionBlock ("dsdt.aml", "DSDT", 2, "TRPTCH", "WINARM  ", 1)
{
    Scope (\_SB)
    {
        // PL011 UART (Windows: ARMH0011, the inbox SBSA/PL011 serial driver).
        Device (COM0)
        {
            Name (_HID, "ARMH0011")
            Name (_UID, Zero)
            Name (_CRS, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite, 0x09000000, 0x00001000)
                Interrupt (ResourceConsumer, Level, ActiveHigh, Exclusive) { 33 }
            })
        }

        // PCIe host bridge: ECAM at 0x3F000000 (buses 0-15), 32-bit window 0x10000000,
        // I/O window 0x3EFF0000. Slot s's INTx is GSI 35 + s (Henge's bridge).
        Device (PCI0)
        {
            Name (_HID, EisaId ("PNP0A08"))
            Name (_CID, EisaId ("PNP0A03"))
            Name (_SEG, Zero)
            Name (_BBN, Zero)
            Name (_UID, Zero)
            Name (_STR, Unicode ("PCIe 0 Device"))
            Name (_CCA, One)
            Name (_PRT, Package ()
            {
                Package () { 0x0000FFFF, 0, 0, 35 }, Package () { 0x0000FFFF, 1, 0, 35 }, Package () { 0x0000FFFF, 2, 0, 35 }, Package () { 0x0000FFFF, 3, 0, 35 },
                Package () { 0x0001FFFF, 0, 0, 36 }, Package () { 0x0001FFFF, 1, 0, 36 }, Package () { 0x0001FFFF, 2, 0, 36 }, Package () { 0x0001FFFF, 3, 0, 36 },
                Package () { 0x0002FFFF, 0, 0, 37 }, Package () { 0x0002FFFF, 1, 0, 37 }, Package () { 0x0002FFFF, 2, 0, 37 }, Package () { 0x0002FFFF, 3, 0, 37 },
                Package () { 0x0003FFFF, 0, 0, 38 }, Package () { 0x0003FFFF, 1, 0, 38 }, Package () { 0x0003FFFF, 2, 0, 38 }, Package () { 0x0003FFFF, 3, 0, 38 },
                Package () { 0x0004FFFF, 0, 0, 39 }, Package () { 0x0004FFFF, 1, 0, 39 }, Package () { 0x0004FFFF, 2, 0, 39 }, Package () { 0x0004FFFF, 3, 0, 39 },
                Package () { 0x0005FFFF, 0, 0, 40 }, Package () { 0x0005FFFF, 1, 0, 40 }, Package () { 0x0005FFFF, 2, 0, 40 }, Package () { 0x0005FFFF, 3, 0, 40 },
                Package () { 0x0006FFFF, 0, 0, 41 }, Package () { 0x0006FFFF, 1, 0, 41 }, Package () { 0x0006FFFF, 2, 0, 41 }, Package () { 0x0006FFFF, 3, 0, 41 },
                Package () { 0x0007FFFF, 0, 0, 42 }, Package () { 0x0007FFFF, 1, 0, 42 }, Package () { 0x0007FFFF, 2, 0, 42 }, Package () { 0x0007FFFF, 3, 0, 42 },
            })
            Method (_CRS, 0, Serialized)
            {
                Return (ResourceTemplate ()
                {
                    WordBusNumber (ResourceProducer, MinFixed, MaxFixed, PosDecode,
                        0x0000, 0x0000, 0x000F, 0x0000, 0x0010)
                    DWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed, NonCacheable, ReadWrite,
                        0x00000000, 0x10000000, 0x3EFEFFFF, 0x00000000, 0x2EFF0000)
                    DWordIO (ResourceProducer, MinFixed, MaxFixed, PosDecode, EntireRange,
                        0x00000000, 0x00000000, 0x0000FFFF, 0x3EFF0000, 0x00010000, , , , TypeTranslation)
                })
            }
            // Let the OS run PCIe native (hot plug, PME, AER, capability control).
            Method (_OSC, 4, NotSerialized)
            {
                CreateDWordField (Arg3, Zero, CDW1)
                If (LEqual (Arg0, ToUUID ("33db4d5b-1ff7-401c-9657-7441c03dd766")))
                {
                    CreateDWordField (Arg3, 0x08, CDW3)
                    And (CDW3, 0x1F, CDW3)
                    Return (Arg3)
                }
                Or (CDW1, 0x04, CDW1) // unrecognized UUID
                Return (Arg3)
            }
            Device (RES0)
            {
                Name (_HID, "PNP0C02")
                Name (_CRS, ResourceTemplate ()
                {
                    QWordMemory (ResourceProducer, PosDecode, MinFixed, MaxFixed, NonCacheable, ReadWrite,
                        0x0000000000000000, 0x000000003F000000, 0x000000003FFFFFFF, 0x0000000000000000, 0x0000000001000000)
                })
            }
        }

        // Power button: the Generic Event Device raises a Notify on GPIO's SPI.
        Device (PWRB)
        {
            Name (_HID, "PNP0C0C")
            Name (_UID, Zero)
        }
    }
}
