// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef TRIPTYCH_WINVM_HOST_H
#define TRIPTYCH_WINVM_HOST_H
#include <stdint.h>
int winvm_host_has_tpm(void); /* 1 if built with libtpms (TPM 2.0) */
unsigned winvm_host_tpm_commands(void); /* TPM commands the guest has run */
unsigned winvm_host_iso_read_mb(void);   /* MB read from the installer ISO */
int winvm_host_start(const char *code, const char *vars, int ram_mb, int ncpus,
                     uint32_t width, uint32_t height, const char *nvme, const char *iso,
                     const char *tpm, const char *serial_path, char *err, int errlen);
void winvm_host_stop(void);
int winvm_host_state(void); /* 0 idle, 1 running, 2 stopped, 3 stopping */
/* The frame pointer is valid only inside the reader. The reader must not reenter the host API. */
typedef void (*WinvmFrameReader)(void *opaque, const uint8_t *pixels, uint32_t w, uint32_t h, uint32_t stride);
void winvm_host_read_fb(WinvmFrameReader read, void *opaque);
void winvm_host_key(int hid_usage, int down);
void winvm_host_tablet(int x, int y, int buttons, int wheel);
#endif
