// Triptych host bridge: the C surface the Swift app uses to drive engines.
// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <sys/types.h>

// ---- JIT / process state -------------------------------------------------
/// True when a debugger has marked this process CS_DEBUGGED (the only way a
/// sideloaded iOS app gets executable memory; see docs/ARCHITECTURE.md).
bool tp_process_is_debugged(void);
/// Frees the address range held for Madeira (call right before dlopen of MadeiraRuntime).
void tp_release_madeira_va(void);

// ---- Linux engine (LinuxRunner/iSH ARM64 interpreter) ---------------------
/// Starts the Linux engine on a background thread with the fakefs root at
/// `rootfs`, running `/bin/sh -l` as PID 1. On success returns 0 and stores
/// the app's console fd in *master_fd (read guest output, write input).
/// Only one guest per app launch (the iSH kernel keeps global state).
int tp_linux_start(const char *rootfs, int *master_fd);
void tp_linux_resize(int master_fd, uint16_t cols, uint16_t rows);
/// True once the guest's PID 1 has exited.
bool tp_linux_has_exited(int *status);
/// Whether this build linked the Linux engine.
bool tp_linux_available(void);
/// Imports a root filesystem archive (tar, .gz/.xz/.zst/.bz2) into a fakefs directory.
/// progress(cookie, 0…1) may be called from this thread. Returns 0, or -1 with errbuf set.
int tp_linux_import(const char *archive, const char *fsdir, void *cookie,
                    void (*progress)(void *cookie, double fraction), char *errbuf, int errlen);
/// Writes the host's active DNS resolvers (or 1.1.1.1 / 8.8.8.8 fallback) into `path`
/// in resolv.conf format. Returns 0 on success, -1 on write error.
int tp_write_host_resolv_conf(const char *path);

// ---- macOS engine (Henge) --------------------------------------------------
/// Whether this build linked Henge's engine.
bool tp_macos_available(void);
/// Runs a tiny self-check of the engine that needs no JIT and no macOS image:
/// creates Henge's auxiliary storage file (henge_make_aux) in `dir`.
/// Returns 0 on success.
int tp_macos_selftest(const char *dir, char *msg, int msglen);
/// Gets executable memory the way Henge does without a debugger (MAP_JIT or a
/// plain self-granted region), then runs the arm64 macOS program at `path`
/// through Henge's in-process Mach-O loader ("Mac programs without macOS").
/// Its stdout/stderr go to `out_path`. Returns main's result or -1.
int tp_macos_run_program(const char *path, const char *out_path, char *msg, int msglen);
