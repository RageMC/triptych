// SPDX-License-Identifier: GPL-3.0-or-later
// In-process retag + ad-hoc signing of an arm64 macOS Mach-O so an app imported from a real Mac can be dlopen'ed.
#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/// Retags the Mach-O at `path` in place for the iOS Simulator (platform 7) or iOS (2) per the build SDK
/// (MH_EXECUTE -> MH_DYLIB, AppKit/Cocoa -> the shim, page zero shrunk), then adds an ad-hoc code signature.
/// Returns 0 or -1 with a message in `err`.
int MacRetagFile(const char *path, char *err, size_t errlen);
/// Same, for a file that is not the app's main executable: `@executable_path` in its load paths and rpaths (the guest's
/// main executable directory on a Mac; Triptych's own executable once dlopened) becomes `@loader_path/<exeRel>`.
/// `exeRel` is the path from the file's directory to the main executable's directory ("." for the main executable).
int MacRetagFileRel(const char *path, const char *exeRel, char *err, size_t errlen);
typedef struct {
    unsigned retagged;   // arm64 (thin or from a universal binary) Mach-O files retagged and signed
    unsigned skipped;    // Mach-O files with no arm64 code (x86_64-only), left as they are
    unsigned already;    // already tagged for iOS / the Simulator
    unsigned failed;
} MacRetagStats;
/// Retags every arm64 Mach-O in an .app bundle (frameworks, dylibs, Python extension modules, helper executables),
/// not only the main executable, so everything the app loads later is loadable too. `exeDir` is Contents/MacOS.
/// Returns 0 when nothing failed; the first failure is described in `err`.
int MacRetagBundle(const char *appPath, const char *exeDir, MacRetagStats *stats, char *err, size_t errlen);
/// Appends an ad-hoc (SHA-256 CodeDirectory) signature to a thin arm64 Mach-O at `path`.
int MacAdhocSignFile(const char *path, char *err, size_t errlen);
#ifdef __cplusplus
}
#endif
