// SPDX-License-Identifier: GPL-3.0-or-later
// In-process Perl 5.42 (scripts/build-perl-ios.sh) for CrossOver Preview's cx tools: each Perl script that
// MacProcessShim resolves runs in a fresh interpreter on the command's own thread, with the command's standard
// FDs and environment. Triptych::Process (engines/macapps/perl) routes every child process through the shim and
// libperl's own process calls are guarded (PerlGuard.c), so nothing ever forks or replaces the app.
#ifndef PERL_COMMAND_H
#define PERL_COMMAND_H

#ifdef __cplusplus
extern "C" {
#endif

/// Directory with Perl's library and Triptych/Process.pm. Default: "perl-lib" next to the app's executable.
/// NULL restores the default.
void PerlCommandSetLibraryPath(const char *dir);

/// MacProcessRuntimeFn for MacProcessShimSetPerlRuntime: runs the script `path` with argv[1...].
/// Returns the script's exit status (0-255); 255 if it does not compile.
int PerlCommandRun(const char *path, char *const argv[], char *const envp[], int inFd, int outFd, int errFd);

/// Runs Perl code (`perl -e code args...`) the same way. For tests and diagnostics.
int PerlCommandEval(const char *code, char *const args[], char *const envp[], int inFd, int outFd, int errFd);

/// Registers PerlCommandRun as the shim's Perl runtime.
void PerlCommandInstall(void);

#ifdef __cplusplus
}
#endif

#endif
