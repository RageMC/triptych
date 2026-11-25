/*
 * Triptych display backend: the embedding app (an iOS/macOS process that loaded libqemu-*-softmmu) pulls the guest
 * framebuffer and injects keyboard/pointer input through these C functions. Select it with `-display triptych`.
 * Plain C, no QEMU types, so the app can declare these prototypes itself (it reaches them with dlsym).
 *
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef UI_TRIPTYCH_H
#define UI_TRIPTYCH_H

#include <stdint.h>
#include <stddef.h>

/* Frame pull, safe from any thread. The backend keeps a private x8r8g8b8 shadow (bytes B,G,R,X in memory) guarded by
 * a mutex and never hands out a pointer to it: the app copies the frame out under that lock.
 * Returns 0 when nothing changed since *seq (or no surface yet). Otherwise sets *w, *h, *stride (bytes) and returns
 * the frame size in bytes; the pixels were copied into dst and *seq updated only if cap is large enough, so a caller
 * with a smaller buffer (or dst NULL, cap 0, to just ask the size) reallocates from the returned size and calls again. */
size_t triptych_display_copy(void *dst, size_t cap, int *w, int *h, int *stride, uint64_t *seq);

/* Input: safe from any thread, ignored until the display is up; events are queued and delivered on the main-loop
 * thread. usb = USB HID keyboard usage (UIKeyboardHIDUsage raw value), translated to a QKeyCode with QEMU's
 * usb->qcode table. qcode = QKeyCode enum value; name = QKeyCode name ("ret", "a", "shift"...), returns -1 if unknown.
 * text: ASCII characters (letters, digits, US punctuation, ' ', '\n', '\t') typed as press+release with shift where
 * needed; returns the number of characters consumed. Pointer: abs coordinates in 0..max (any range, scaled by QEMU to
 * the guest device), buttons bit0 = left, bit1 = middle, bit2 = right; needs an absolute pointer device in the guest
 * (-device virtio-tablet-pci); rel is for PS/2 or virtio-mouse. */
int  triptych_input_key_usb(int usb, int down);     /* 0 when the usage has no QKeyCode */
void triptych_input_key(int qcode, int down);
int  triptych_input_key_name(const char *name, int down);
int  triptych_input_text(const char *text);
void triptych_input_pointer_abs(int x, int y, int max_x, int max_y, unsigned buttons);
void triptych_input_pointer_rel(int dx, int dy, unsigned buttons);

/* Unregisters the display listener and asks QEMU to shut down (host-ui cause) from the main loop; qemu_main_loop then
 * returns, and the embedder joins its QEMU thread instead of letting QEMU call exit(). */
void triptych_display_shutdown(void);

/* Statistics for tests: surfaces switched and update rectangles received so far. */
void triptych_display_stats(uint64_t *switches, uint64_t *updates);

#endif
