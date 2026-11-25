// SPDX-License-Identifier: GPL-3.0-or-later
// retag.c (engines/macapps/host/retag, Mach-O transform) is compiled in with main renamed and run without its
// codesign step; the ad-hoc signature is written here, in-process, because iOS has no /usr/bin/codesign.
#include "MacRetag.h"
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <mach-o/loader.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define main retag_main
#include "../../engines/macapps/host/retag/retag.c"
#undef main

#include <TargetConditionals.h>

static void seterr(char *err, size_t n, const char *fmt, ...) {
    if (!err || !n) return;
    va_list ap; va_start(ap, fmt); vsnprintf(err, n, fmt, ap); va_end(ap);
}

static void put32(uint8_t *p, uint32_t v) { p[0] = v >> 24; p[1] = v >> 16; p[2] = v >> 8; p[3] = v; }
static void put64(uint8_t *p, uint64_t v) { put32(p, (uint32_t)(v >> 32)); put32(p + 4, (uint32_t)v); }

int MacAdhocSignFile(const char *path, char *err, size_t errlen) {
    FILE *f = fopen(path, "rb");
    if (!f) { seterr(err, errlen, "sign: cannot open %s", path); return -1; }
    fseek(f, 0, SEEK_END); long flen = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *d = malloc((size_t)flen + 1);
    if (!d || fread(d, 1, (size_t)flen, f) != (size_t)flen) { fclose(f); free(d); seterr(err, errlen, "sign: read failed"); return -1; }
    fclose(f);
    int rc = -1;
    struct mach_header_64 *mh = (void *)d;
    if ((size_t)flen < sizeof(*mh) || mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64) { seterr(err, errlen, "sign: not a thin arm64 Mach-O"); goto out; }

    struct segment_command_64 *linkedit = NULL, *text = NULL;
    uint8_t *p = d + sizeof(*mh);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        struct load_command *lc = (void *)p;
        if (lc->cmd == LC_CODE_SIGNATURE) { seterr(err, errlen, "sign: already has a signature"); goto out; }
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *s = (void *)p;
            if (!strncmp(s->segname, "__LINKEDIT", 16)) linkedit = s;
            else if (!strncmp(s->segname, "__TEXT", 16)) text = s;
        }
        p += lc->cmdsize;
    }
    if (!linkedit || !text) { seterr(err, errlen, "sign: no __LINKEDIT/__TEXT"); goto out; }
    // The signature must end the file, inside __LINKEDIT.
    if (linkedit->fileoff + linkedit->filesize != (uint64_t)flen) { seterr(err, errlen, "sign: __LINKEDIT is not last in the file"); goto out; }
    // Room for one more load command: the gap before the first section/segment content.
    uint64_t room = (uint64_t)flen;
    p = d + sizeof(*mh);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        struct load_command *lc = (void *)p;
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *s = (void *)p;
            if (s->fileoff > 0 && s->fileoff < room) room = s->fileoff;
            struct section_64 *sec = (void *)(s + 1);
            for (uint32_t k = 0; k < s->nsects; k++) if (sec[k].offset > 0 && sec[k].offset < room) room = sec[k].offset;
        }
        p += lc->cmdsize;
    }
    size_t cmd_end = sizeof(*mh) + mh->sizeofcmds;
    if (cmd_end + sizeof(struct linkedit_data_command) > room) { seterr(err, errlen, "sign: no header room for LC_CODE_SIGNATURE"); goto out; }

    const char *ident = "triptych.adhoc";
    size_t idlen = strlen(ident) + 1;
    uint64_t sigoff = ((uint64_t)flen + 15) & ~15ULL;
    uint32_t pages = (uint32_t)((sigoff + 4095) / 4096);
    size_t cdhdr = 88; // CS_CodeDirectory through execSegFlags (version 0x20400)
    size_t cdlen = cdhdr + idlen + (size_t)pages * 32;
    size_t total = 20 + cdlen; // SuperBlob header (12) + 1 index (8)
    // Grow __LINKEDIT first so the hashes cover the final header.
    linkedit->filesize = sigoff + ((total + 15) & ~15ULL) - linkedit->fileoff;
    linkedit->vmsize = (linkedit->filesize + 0x3fff) & ~0x3fffULL;
    struct linkedit_data_command ld = { .cmd = LC_CODE_SIGNATURE, .cmdsize = sizeof(ld), .dataoff = (uint32_t)sigoff, .datasize = (uint32_t)((total + 15) & ~15ULL) };
    memcpy(d + cmd_end, &ld, sizeof(ld));
    mh->ncmds++; mh->sizeofcmds += sizeof(ld);

    uint8_t *sig = calloc(1, ld.datasize);
    uint8_t *cd = sig + 20;
    put32(sig, 0xfade0cc0); put32(sig + 4, (uint32_t)total); put32(sig + 8, 1);
    put32(sig + 12, 0); put32(sig + 16, 20);
    put32(cd, 0xfade0c02); put32(cd + 4, (uint32_t)cdlen); put32(cd + 8, 0x20400);
    put32(cd + 12, 0x2); // ad-hoc
    put32(cd + 16, (uint32_t)(cdhdr + idlen)); // hashOffset
    put32(cd + 20, (uint32_t)cdhdr);           // identOffset
    put32(cd + 24, 0); put32(cd + 28, pages);
    put32(cd + 32, (uint32_t)sigoff);          // codeLimit
    cd[36] = 32; cd[37] = 2; cd[38] = 0; cd[39] = 12; // hashSize, SHA-256, no platform, 4 KiB pages
    put64(cd + 56, 0);                         // codeLimit64 unused
    put64(cd + 64, text->fileoff); put64(cd + 72, text->filesize);
    put64(cd + 80, mh->filetype == MH_EXECUTE ? 1 : 0); // execSegFlags: main binary
    memcpy(cd + cdhdr, ident, idlen);
    // Pages of the (padded to sigoff) file.
    uint8_t *full = calloc(1, sigoff);
    memcpy(full, d, (size_t)flen);
    for (uint32_t i = 0; i < pages; i++) {
        size_t n = (i == pages - 1) ? (size_t)(sigoff - (uint64_t)i * 4096) : 4096;
        CC_SHA256(full + (size_t)i * 4096, (CC_LONG)n, cd + cdhdr + idlen + (size_t)i * 32);
    }
    FILE *o = fopen(path, "wb");
    if (o && fwrite(full, 1, sigoff, o) == sigoff && fwrite(sig, 1, ld.datasize, o) == ld.datasize) rc = 0;
    else seterr(err, errlen, "sign: write failed");
    if (o) fclose(o);
    chmod(path, 0755);
    free(full); free(sig);
out:
    free(d);
    return rc;
}

#ifndef MACRETAG_PLATFORM
#if TARGET_OS_SIMULATOR
#define MACRETAG_PLATFORM "iossim"
#else
#define MACRETAG_PLATFORM "ios"
#endif
#endif
int MacRetagFileRel(const char *path, const char *exeRel, char *err, size_t errlen) {
    // Only the main executable gets the host's Frameworks rpath (where the shims are): dyld searches the main
    // executable's rpaths for every @rpath load anyway, and helper binaries often have no header room to spare.
    int isMain = strcmp(exeRel, ".") == 0;
    char *argv[16] = { "retag", "--platform", MACRETAG_PLATFORM, "--minos", "17.0", "--sdk", "27.2", "--rewrite-deps",
                       "--exe-rel", (char *)exeRel, "--no-sign" };
    int argc = 11;
    if (isMain) { argv[argc++] = "--add-rpath"; argv[argc++] = "@executable_path/Frameworks"; }
    argv[argc++] = (char *)path;
    argv[argc] = NULL;
    if (retag_main(argc, argv) != 0) { seterr(err, errlen, "retag failed for %s", path); return -1; }
    return MacAdhocSignFile(path, err, errlen);
}

int MacRetagFile(const char *path, char *err, size_t errlen) {
    return MacRetagFileRel(path, ".", err, errlen);
}

// ---- whole bundle ----
#include <ftw.h>
#include <limits.h>
#include <mach-o/fat.h>
#include <pthread.h>

enum { KIND_OTHER, KIND_ARM64, KIND_ARM64_RETAGGED, KIND_NO_ARM64 };

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

static int classify(const uint8_t *b, size_t n) {
    if (n < 8) return KIND_OTHER;
    uint32_t m; memcpy(&m, b, 4);
    if (m == MH_MAGIC_64) {
        const struct mach_header_64 *mh = (const void *)b;
        if (mh->cputype != CPU_TYPE_ARM64) return KIND_NO_ARM64;
        const uint8_t *p = b + sizeof(*mh), *end = b + n;
        for (uint32_t i = 0; i < mh->ncmds && p + 8 <= end; i++) {
            const struct load_command *lc = (const void *)p;
            if (lc->cmdsize < 8) break;
            if (lc->cmd == LC_BUILD_VERSION && p + sizeof(struct build_version_command) <= end) {
                uint32_t plat = ((const struct build_version_command *)p)->platform;
                if (plat == PLATFORM_IOS || plat == PLATFORM_IOSSIMULATOR) return KIND_ARM64_RETAGGED;
            }
            p += lc->cmdsize;
        }
        return KIND_ARM64;
    }
    if (m == MH_MAGIC || m == MH_CIGAM || m == MH_CIGAM_64) return KIND_NO_ARM64;
    uint32_t bm = be32(b);
    if (bm == FAT_MAGIC || bm == FAT_MAGIC_64) {
        uint32_t nfat = be32(b + 4);
        size_t esz = bm == FAT_MAGIC ? sizeof(struct fat_arch) : sizeof(struct fat_arch_64);
        // Java class files share 0xcafebabe; their next word (version) is far above any real arch count.
        if (nfat == 0 || nfat > 16 || 8 + nfat * esz > n) return KIND_OTHER;
        for (uint32_t i = 0; i < nfat; i++)
            if (be32(b + 8 + i * esz) == (uint32_t)CPU_TYPE_ARM64) return KIND_ARM64;
        return KIND_NO_ARM64;
    }
    return KIND_OTHER;
}

/// Relative path from directory `from` to directory `to` (both absolute, normalised, no trailing slash).
static void relpath(const char *from, const char *to, char *out, size_t outsz) {
    size_t i = 0;
    while (from[i] && from[i] == to[i]) i++;
    if (!from[i] && !to[i]) { snprintf(out, outsz, "."); return; }
    size_t c;
    if ((!from[i] && to[i] == '/') || (!to[i] && from[i] == '/')) c = i;
    else { while (i > 0 && from[i] != '/') i--; c = i; } // back to the last shared component boundary
    out[0] = 0;
    for (const char *p = from + c; *p; p++)
        if (*p == '/') strlcat(out, out[0] ? "/.." : "..", outsz);
    const char *rest = to + c;
    if (*rest == '/') rest++;
    if (*rest) { if (out[0]) strlcat(out, "/", outsz); strlcat(out, rest, outsz); }
    if (!out[0]) snprintf(out, outsz, ".");
}

static pthread_mutex_t gBundleLock = PTHREAD_MUTEX_INITIALIZER;
static struct { const char *exeDir; MacRetagStats *st; char *err; size_t errlen; } gB;

static int bundle_visit(const char *path, const struct stat *sb, int type, struct FTW *ftw) {
    (void)ftw;
    if (type != FTW_F || !S_ISREG(sb->st_mode) || sb->st_size < 4096) return 0;
    uint8_t head[4096];
    int fd = open(path, O_RDONLY);
    if (fd < 0) return 0;
    ssize_t n = read(fd, head, sizeof head);
    close(fd);
    if (n <= 0) return 0;
    switch (classify(head, (size_t)n)) {
    case KIND_ARM64_RETAGGED: gB.st->already++; return 0;
    case KIND_NO_ARM64: gB.st->skipped++; return 0;
    case KIND_ARM64: break;
    default: return 0;
    }
    char dir[PATH_MAX], rel[PATH_MAX], e[256] = {0};
    snprintf(dir, sizeof dir, "%s", path);
    char *slash = strrchr(dir, '/');
    if (slash) *slash = 0;
    relpath(dir, gB.exeDir, rel, sizeof rel);
    if (MacRetagFileRel(path, rel, e, sizeof e) == 0) {
        gB.st->retagged++;
    } else {
        if (!gB.st->failed) seterr(gB.err, gB.errlen, "%s: %s", path, e);
        gB.st->failed++;
    }
    return 0;
}

int MacRetagBundle(const char *appPath, const char *exeDir, MacRetagStats *stats, char *err, size_t errlen) {
    MacRetagStats local = {0};
    if (!stats) stats = &local;
    memset(stats, 0, sizeof *stats);
    char app[PATH_MAX], exe[PATH_MAX];
    if (!realpath(appPath, app) || !realpath(exeDir, exe)) { seterr(err, errlen, "bundle path not found"); return -1; }
    pthread_mutex_lock(&gBundleLock);
    gB.exeDir = exe; gB.st = stats; gB.err = err; gB.errlen = errlen;
    int rc = nftw(app, bundle_visit, 32, FTW_PHYS);
    pthread_mutex_unlock(&gBundleLock);
    if (rc != 0) { seterr(err, errlen, "walking %s failed", app); return -1; }
    return stats->failed ? -1 : 0;
}
