// SPDX-License-Identifier: GPL-2.0-or-later
#ifndef WINVM_PFLASH_H
#define WINVM_PFLASH_H
#include <stdint.h>
#include "machine.h"

typedef struct PFlash {
    uint8_t *data;
    uint64_t size;
    int fd;           /* backing file, written through; -1: volatile */
    int mode;
    uint32_t buf_left;
    uint64_t buf_lo, buf_hi;
    int log;
} PFlash;

/* A writable flash bank at pa backed by path (read, then written through). */
int pflash_open(PFlash *p, HvMachine *m, uint64_t pa, uint64_t size, const char *path);
void pflash_close(PFlash *p);

#endif
