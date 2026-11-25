// SPDX-License-Identifier: GPL-3.0-or-later
// Host side of the x86pc engine (QEMU x86-64 system emulation, UTM's QEMU 10.0.12 fork, see (private notes)).
// The QEMU build is a framework loaded with dlopen: the native TCG (JIT) build when the process can use JIT
// (Simulator or a debugger attached), otherwise the TCTI interpreter build. Both export qemu_init / qemu_main_loop /
// qemu_cleanup, so only one can be loaded per process, and QEMU calls exit() on shutdown: one VM per app launch.
#ifndef TRIPTYCH_X86PC_HOST_H
#define TRIPTYCH_X86PC_HOST_H
#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef NS_ENUM(int, X86PCBuild) {
    X86PCBuildJIT = 0,   /* qemu-x86_64-softmmu.framework: native TCG, needs executable memory */
    X86PCBuildTCTI = 1,  /* qemu-x86_64-softmmu-tcti.framework: threaded interpreter, no JIT, very slow */
};

/// The build this process should use: JIT when running in the Simulator or under a debugger, else TCTI.
X86PCBuild x86pc_host_build_for_process(void);
/// The two builds as values, for Swift (NS_ENUM case names are not imported by a stable name).
X86PCBuild x86pc_host_build_jit(void);
X86PCBuild x86pc_host_build_tcti(void);
/// Whether the given QEMU framework is inside the app bundle.
bool x86pc_host_build_bundled(X86PCBuild build);
/// Creates a qcow2 image with the bundled qemu-img framework. Returns 0 on success.
int x86pc_host_create_qcow2(const char *path, uint64_t bytes, char *err, size_t errlen);
/// Starts the VM on an 8 MB-stack thread. args[0] is the program name, the rest are QEMU's command line. 0 on success.
int x86pc_host_start(NSArray<NSString *> *args, X86PCBuild build, char *err, size_t errlen);
bool x86pc_host_is_running(void);
/// Loopback TCP ports for the human monitor and QMP. Picked once per process from free ephemeral ports (bind port 0,
/// read the port back, release it), so two app launches or other listeners never collide; use them in the QEMU command line.
int x86pc_host_hmp_port(void);
int x86pc_host_qmp_port(void);
/// One human-monitor command over TCP 127.0.0.1:<hmp port> (for example "screendump <path>").
bool x86pc_host_hmp(const char *command);
/// QMP `quit` over TCP 127.0.0.1:<qmp port>. QEMU then exits its main loop and cleans up.
bool x86pc_host_qmp_quit(void);

// Display and input through QEMU's `-display triptych` backend (engines/x86pc/patches), same shape as winvm_host_*.
/// Latest guest frame as 32 bpp B,G,R,X pixels (w, h, stride in bytes), or NULL before the first frame. The frame is a
/// copy taken under the backend's lock into a buffer owned by this host; call from one thread only (the main thread's
/// display link). The pointer stays valid until the next call.
const uint8_t *x86pc_host_fb(uint32_t *w, uint32_t *h, uint32_t *stride);
/// Counts frames pulled by x86pc_host_fb that carried new pixels (0 before the first); lets the caller skip redrawing an unchanged frame.
uint64_t x86pc_host_fb_generation(void);
/// Absolute pointer in 0..32767 on both axes (virtio-tablet-pci); buttons bit0 left, bit1 middle, bit2 right. Wheel is unused.
void x86pc_host_tablet(int x, int y, int buttons, int wheel);
/// A key by USB HID keyboard usage (UIKeyboardHIDUsage raw value), translated to a QEMU QKeyCode inside the backend.
void x86pc_host_key(int hid_usage, int down);
/// Stops the VM like a power button on the host: unregisters the display, requests a QEMU shutdown and joins the QEMU
/// thread. Blocks until QEMU has left its main loop: call it off the main thread.
void x86pc_host_stop(void);

#endif
