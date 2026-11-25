// SPDX-License-Identifier: GPL-2.0-or-later
// winvm_disk_blank (usb.h): the installer auto-boot presses keys only on a disk with nothing installed.
#include "../usb.h"
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include "machine.h"
int hv_knob[HV_K_COUNT]; /* disk.c reads one knob; the machine (which owns them) is not linked here */

static int check(const char *dir, const char *name, const void *patch, unsigned off, unsigned len, int want) {
    char p[1024]; snprintf(p, sizeof p, "%s/%s", dir, name);
    int fd = open(p, O_CREAT | O_TRUNC | O_RDWR, 0644);
    if (fd < 0 || ftruncate(fd, 1 << 20) != 0) { perror(p); return 1; }
    if (len && pwrite(fd, patch, len, off) != (ssize_t)len) { perror("pwrite"); return 1; }
    close(fd);
    HvDisk d;
    if (hv_disk_open(&d, p, 0, 1) != 0) { fprintf(stderr, "open %s\n", p); return 1; }
    int got = winvm_disk_blank(&d);
    hv_disk_close(&d); unlink(p);
    if (got != want) { fprintf(stderr, "FAIL %s: blank=%d, want %d\n", name, got, want); return 1; }
    return 0;
}

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "/tmp";
    int f = 0;
    f += check(dir, "blank.img", NULL, 0, 0, 1);
    f += check(dir, "gpt.img", "EFI PART", 512, 8, 0);
    f += check(dir, "mbr.img", "\x55\xaa", 510, 2, 0);
    f += check(dir, "junk.img", "hello", 100, 5, 1); /* bytes but no partition table: still nothing bootable */
    if (f) return 1;
    printf("blank_test: all passed\n");
    return 0;
}
