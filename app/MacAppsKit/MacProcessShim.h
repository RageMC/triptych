// SPDX-License-Identifier: GPL-3.0-or-later
#ifndef MAC_PROCESS_SHIM_H
#define MAC_PROCESS_SHIM_H

#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/types.h>
#include <sys/wait.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Installs Mach-O rebinding for all dlopen'd guest images inside `appBundlePath`.
/// Safe to call multiple times; registers a dyld add-image callback so late-loaded
/// frameworks and Python extension modules are rebound automatically.
void MacProcessShimInstallForBundle(const char *appBundlePath);

/// Rebinds process-spawning imports on a single already-loaded Mach-O image.
void MacProcessShimRebindImage(const void *mh, intptr_t slide);

/// Looks up an intercepted libSystem process/FD symbol by Mach-O symbol name (e.g. "_fork", "_posix_spawn").
/// Used by tl_loader's tl_runtime_lookup / TlHost.shim_lookup. Returns NULL if not intercepted.
void *MacProcessShimLookup(const char *symbol);
void *tl_runtime_lookup(const char *symbol);

/// Callback invoked for bundled Mach-O helper executables (wine, wineserver, Python helpers).
/// Implementations should run the helper synchronously on the calling thread and set *exitStatus.
typedef int (*MacProcessHelperLauncherFn)(const char *path,
                                          char *const argv[],
                                          char *const envp[],
                                          int *exitStatus);

/// Registers the helper launcher for bundled Mach-O helpers (tl_loader or dlopen backend).
void MacProcessShimSetHelperLauncher(MacProcessHelperLauncherFn launcher);

/// In-process runtime for a resolved guest command. Return its exit status (0–255).
/// Arguments, environment and redirected FDs are borrowed for the call. Runtimes
/// must use these FDs and environment without replacing the host's process state.
typedef int (*MacProcessRuntimeFn)(const char *path, char *const argv[],
                                  char *const envp[], int inFd, int outFd, int errFd);
void MacProcessShimSetWineRuntime(MacProcessRuntimeFn runtime);
void MacProcessShimSetPerlRuntime(MacProcessRuntimeFn runtime);

/// Starts a command through the shim (as posix_spawn would, without file actions) with explicit standard FDs
/// (-1 leaves one closed). Returns 0 and sets *pid to a virtual pid for MacShim_waitpid, or an errno value.
/// In-process runtimes (PerlCommand.c) use it so that nothing ever replaces or forks the app.
int MacProcessShimSpawn(pid_t *pid, const char *path, char *const argv[], char *const envp[],
                        int inFd, int outFd, int errFd);
/// Ends the calling shim command thread with `status` (its virtual child's exit). Returns if the caller is not one.
void MacProcessShimExitCommand(int status);
/// 1 if `pid` is a live or unreaped virtual child of the shim.
int MacProcessShimIsChild(pid_t pid);

/// Fallback _exit handler when _exit is called outside a virtual fork child (e.g. tl_guest_exit_from).
typedef void (*MacProcessExitFallbackFn)(int status, const void *caller) __attribute__((noreturn));
void MacProcessShimSetExitFallback(MacProcessExitFallbackFn fn);

/// In-process OpenSSL verifier (implemented in MacOpenSSLVerify.m).
int MacOpenSSLRun(int argc, const char *const *argv, int in_fd, int out_fd, int err_fd);

/// Direct entrypoints exposed for unit tests and shim binding.
pid_t MacShim_fork(void);
pid_t MacShim_vfork(void);
int MacShim_execve(const char *path, char *const argv[], char *const envp[]);
int MacShim_execv(const char *path, char *const argv[]);
int MacShim_execvp(const char *file, char *const argv[]);
int MacShim_posix_spawn(pid_t *pid,
                        const char *path,
                        const posix_spawn_file_actions_t *file_actions,
                        const posix_spawnattr_t *attrp,
                        char *const argv[],
                        char *const envp[]);
int MacShim_posix_spawnp(pid_t *pid,
                         const char *file,
                         const posix_spawn_file_actions_t *file_actions,
                         const posix_spawnattr_t *attrp,
                         char *const argv[],
                         char *const envp[]);
int MacShim_posix_spawn_file_actions_init(posix_spawn_file_actions_t *file_actions);
int MacShim_posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *file_actions);
int MacShim_posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *file_actions, int fildes, int newfildes);
int MacShim_posix_spawn_file_actions_addclose(posix_spawn_file_actions_t *file_actions, int fildes);
int MacShim_posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *file_actions, int fildes, const char *path, int oflag, mode_t mode);
pid_t MacShim_waitpid(pid_t pid, int *stat_loc, int options);
int MacShim_system(const char *command);
FILE *MacShim_popen(const char *command, const char *mode);
int MacShim_pclose(FILE *stream);

// Virtual-fork child FD helpers (pass-through when not inside a MacShim_fork child).
int MacShim_close(int fd);
int MacShim_dup(int fd);
int MacShim_dup2(int oldfd, int newfd);
int MacShim_chdir(const char *path);
void MacShim__exit(int status) __attribute__((noreturn));

#ifdef __cplusplus
}
#endif

#endif
