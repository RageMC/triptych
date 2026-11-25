// SPDX-License-Identifier: GPL-2.0-or-later
#include "../../../app/Triptych/Bridge/winvm_host.h"
#include <assert.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char code[256], vars[256], disk[256], iso[256], serial[256], tpm[256];

static void fixture(char *path, const char *dir, const char *name, off_t size) {
    snprintf(path, 256, "%s/%s", dir, name);
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0600);
    assert(fd >= 0 && ftruncate(fd, size) == 0 && close(fd) == 0);
}

static int start(const char *iso_path) {
    char err[256];
    int rc = winvm_host_start(code, vars, 64, 2, 0, 0, disk, iso_path,
                              winvm_host_has_tpm() ? tpm : NULL, serial, err, sizeof err);
    if (rc) fprintf(stderr, "winvm restart test: %s\n", err);
    return rc;
}

static void check_disk_closed(const char *path) {
    struct stat expected, open_file;
    assert(stat(path, &expected) == 0);
    for (int fd = 0; fd < 256; fd++)
        if (fstat(fd, &open_file) == 0)
            assert(open_file.st_dev != expected.st_dev || open_file.st_ino != expected.st_ino);
}

static void wait_for_uart(void) {
    for (int i = 0; i < 500; i++) {
        FILE *log = fopen(serial, "r");
        char line[8] = {0};
        assert(log);
        fgets(line, sizeof line, log);
        fclose(log);
        if (!strcmp(line, "A\n")) return;
        usleep(10000);
    }
    assert(!"guest did not write to its UART");
}

int main(int argc, char **argv) {
    assert(argc == 2);
    char dir[128];
    snprintf(dir, sizeof dir, "%s/restart.XXXXXX", argv[1]);
    assert(mkdtemp(dir));
    fixture(code, dir, "code", 0);
    fixture(vars, dir, "vars", 0);
    fixture(disk, dir, "disk", 1 << 20);
    fixture(iso, dir, "iso", 1 << 20);
    fixture(tpm, dir, "tpm", 0);
    snprintf(serial, sizeof serial, "%s/serial", dir);

    /* The test firmware writes 'A\n' to the PL011, then loops until stopped. */
    const uint32_t firmware[] = {0xd2a12000, 0x52800821, 0xb9000001, 0x52800141, 0xb9000001, 0x14000000};
    int fd = open(code, O_WRONLY);
    assert(fd >= 0 && write(fd, firmware, sizeof firmware) == sizeof firmware && close(fd) == 0);
    struct stat stdout_before, stdout_after;
    assert(fstat(STDOUT_FILENO, &stdout_before) == 0);

    /* A late setup failure must release the var store, NVMe, USB and serial log. */
    char missing[256];
    snprintf(missing, sizeof missing, "%s/missing.iso", dir);
    assert(start(missing) != 0);
    check_disk_closed(vars);
    check_disk_closed(disk);
    check_disk_closed(serial);

    /* A guest poweroff must release the board even without a host Stop. */
    const uint32_t poweroff[] = {0xd2800100, 0xf2b08000, 0xd4000003, 0x14000000};
    fd = open(code, O_WRONLY | O_TRUNC);
    assert(fd >= 0 && write(fd, poweroff, sizeof poweroff) == sizeof poweroff && close(fd) == 0);
    assert(start(iso) == 0);
    for (int i = 0; i < 500 && winvm_host_state() != 2; i++) usleep(10000);
    assert(winvm_host_state() == 2);
    check_disk_closed(iso);
    check_disk_closed(disk);
    fd = open(code, O_WRONLY | O_TRUNC);
    assert(fd >= 0 && write(fd, firmware, sizeof firmware) == sizeof firmware && close(fd) == 0);

    for (int run = 0; run < 3; run++) {
        assert(start(iso) == 0);
        if (run != 1) wait_for_uart();
        else assert(start(iso) != 0); /* Stop without waiting for the CPUs to begin. */
        winvm_host_stop();
        winvm_host_stop();
        assert(winvm_host_state() == 2);
        check_disk_closed(vars);
        check_disk_closed(disk);
        check_disk_closed(iso);
        check_disk_closed(serial);
    }
    assert(fstat(STDOUT_FILENO, &stdout_after) == 0 && stdout_before.st_dev == stdout_after.st_dev &&
           stdout_before.st_ino == stdout_after.st_ino);
    unlink(code); unlink(vars); unlink(disk); unlink(iso); unlink(tpm); unlink(serial);
    assert(rmdir(dir) == 0);
    puts("winvm restart: failed setup, repeated boot, immediate stop and resource cleanup passed");
    return 0;
}
