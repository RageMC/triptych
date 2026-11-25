// SPDX-License-Identifier: GPL-3.0-or-later
// Pane's per-command Wine API: one Wine command (CrossOver's native loader or wineserver invocation,
// as routed by MacProcessShim) run in-process against the WINEPREFIX in its environment.
#ifndef PANE_WINE_COMMAND_H
#define PANE_WINE_COMMAND_H

#ifdef __cplusplus
extern "C" {
#endif

/// Loads Pane (MadeiraRuntime.framework) the way the Windows engine does; returns 1 when it is loaded.
typedef int (*PaneWineLoaderFn)(void);
/// The app registers its loader (MadeiraRuntime.load in WindowsView.swift): CrossOver's first Wine command loads
/// Pane through it. Without a loader, commands run only once the Windows engine has loaded Pane itself.
void PaneWineCommandSetLoader(PaneWineLoaderFn loader);

/// Madeira's entry point (engines/windows/patches/triptych-command.patch, `madeira_embed_run_command`).
/// Runs `exe` (a Windows path or a bare program name such as "wineboot.exe") with the Windows command-line
/// tail `args` in the bottle `prefix`, blocking until it exits. `envp` adds the command's environment
/// (WINEDLLOVERRIDES, WINEDEBUG, ...). Returns the exit status (0-255) or a negative errno.
typedef int (*PaneWineRunnerFn)(const char *prefix, const char *exe, const char *args,
                                char *const envp[], int inFd, int outFd, int errFd);
/// Madeira's `madeira_embed_stop_prefix`: ends the session for `prefix` (wineserver -k). Returns 0 or -errno.
typedef int (*PaneWineStopFn)(const char *prefix);

/// Overrides the runner (tests, or a host that resolved Madeira itself). NULL restores the default lookup,
/// which finds the entry points in an already-loaded MadeiraRuntime.framework (it never loads Madeira).
void PaneWineCommandSetRunner(PaneWineRunnerFn runner, PaneWineStopFn stop);

/// MacProcessRuntimeFn for MacProcessShimSetWineRuntime: `path` is the resolved Wine loader or wineserver.
int PaneWineCommandRun(const char *path, char *const argv[], char *const envp[], int inFd, int outFd, int errFd);

/// Registers PaneWineCommandRun as the shim's Wine runtime.
void PaneWineCommandInstall(void);

/// Translates a Wine loader program argument to the form Madeira launches: bare names get ".exe",
/// Unix paths inside `prefix`/drive_c become C:\..., other Unix paths Z:\..., Windows paths are kept.
/// Returns 0, or -1 if `out` is too small.
int PaneWineCommandTranslateProgram(const char *prefix, const char *program, char *out, unsigned long outSize);

/// Joins arguments into a Windows command-line tail (CommandLineToArgvW quoting). Returns 0 or -1.
int PaneWineCommandQuoteArgs(char *const argv[], char *out, unsigned long outSize);

#ifdef __cplusplus
}
#endif

#endif
