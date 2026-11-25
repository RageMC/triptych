#include <stdbool.h>
#include <stdint.h>

// macOS Swift binaries reference _stdlib_isOSVersionAtLeastOrVariantVersionAtLeast for
// @available(macOS ...) checks, whereas iOS libswiftCore only exports the 3-arg variant.
__attribute__((visibility("default")))
bool shim_isOSVersionAtLeastOrVariant(intptr_t major, intptr_t minor, intptr_t patch,
                                      intptr_t vMajor, intptr_t vMinor, intptr_t vPatch)
    __asm__("_$ss042_stdlib_isOSVersionAtLeastOrVariantVersiondE0yBi1_Bw_BwBwBwBwBwtF");

bool shim_isOSVersionAtLeastOrVariant(intptr_t major, intptr_t minor, intptr_t patch,
                                      intptr_t vMajor, intptr_t vMinor, intptr_t vPatch) {
    (void)minor;
    (void)patch;
    (void)vMajor;
    (void)vMinor;
    (void)vPatch;
    return major <= 27;
}
