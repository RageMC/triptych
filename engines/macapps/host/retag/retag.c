// SPDX-License-Identifier: GPL-3.0-or-later
// retag: Retag an arm64 macOS Mach-O binary for iOS (2) or iOS Simulator (7),
// shrink __PAGEZERO for dlopen (LiveContainer pattern), convert MH_EXECUTE to a
// loadable MH_DYLIB (with LC_ID_DYLIB, preserving LC_MAIN), rewrite macOS
// framework dependencies (AppKit/Cocoa -> @rpath/libShim_AppKit.dylib,
// versioned Apple frameworks -> flat iOS layout), and optionally ad-hoc sign.

#include <errno.h>
#include <libgen.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>

extern char **environ;

#ifndef PLATFORM_IOS
#define PLATFORM_IOS 2
#endif
#ifndef PLATFORM_IOSSIMULATOR
#define PLATFORM_IOSSIMULATOR 7
#endif
#ifndef DYLIB_USE_MARKER
#define DYLIB_USE_MARKER 0x1a741800
#endif

static uint32_t swap32(uint32_t v) { return __builtin_bswap32(v); }
static uint64_t swap64(uint64_t v) { return __builtin_bswap64(v); }
static size_t align8(size_t v) { return (v + 7u) & ~7u; }
static uint64_t align16k(uint64_t v) { return (v + 0x3fffULL) & ~0x3fffULL; }

static bool parse_version(const char *s, uint32_t *out) {
    unsigned maj = 0, min = 0, pat = 0;
    int n = sscanf(s, "%u.%u.%u", &maj, &min, &pat);
    if (n < 1 || maj > 0xffff || min > 0xff || pat > 0xff) return false;
    *out = (maj << 16) | (min << 8) | pat;
    return true;
}

static bool parse_platform(const char *s, uint32_t *out) {
    if (strcmp(s, "ios") == 0 || strcmp(s, "2") == 0) {
        *out = PLATFORM_IOS;
        return true;
    }
    if (strcmp(s, "iossim") == 0 || strcmp(s, "sim") == 0 || strcmp(s, "7") == 0) {
        *out = PLATFORM_IOSSIMULATOR;
        return true;
    }
    return false;
}

static const char *platform_name(uint32_t p) {
    if (p == PLATFORM_IOS) return "iOS (2)";
    if (p == PLATFORM_IOSSIMULATOR) return "iOS Simulator (7)";
    return "unknown";
}

// Extract arm64 slice if input is a FAT binary; returns newly allocated thin Mach-O.
static uint8_t *extract_arm64_slice(const uint8_t *buf, size_t len, size_t *out_len) {
    if (len < sizeof(uint32_t)) return NULL;
    uint32_t magic;
    memcpy(&magic, buf, 4);

    if (magic == MH_MAGIC_64) {
        uint8_t *copy = malloc(len);
        if (!copy) return NULL;
        memcpy(copy, buf, len);
        *out_len = len;
        return copy;
    }

    bool is_fat32 = (magic == FAT_MAGIC || magic == FAT_CIGAM);
    bool is_fat64 = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64);
    if (!is_fat32 && !is_fat64) return NULL;

    bool be = (magic == FAT_CIGAM || magic == FAT_CIGAM_64);
    if (len < sizeof(struct fat_header)) return NULL;
    struct fat_header fh;
    memcpy(&fh, buf, sizeof(fh));
    uint32_t nfat = be ? swap32(fh.nfat_arch) : fh.nfat_arch;

    size_t pos = sizeof(fh);
    for (uint32_t i = 0; i < nfat; i++) {
        uint32_t cputype = 0;
        uint64_t offset = 0, size = 0;
        if (is_fat32) {
            if (pos + sizeof(struct fat_arch) > len) return NULL;
            struct fat_arch fa;
            memcpy(&fa, buf + pos, sizeof(fa));
            pos += sizeof(fa);
            cputype = be ? swap32((uint32_t)fa.cputype) : (uint32_t)fa.cputype;
            offset = be ? swap32(fa.offset) : fa.offset;
            size = be ? swap32(fa.size) : fa.size;
        } else {
            if (pos + sizeof(struct fat_arch_64) > len) return NULL;
            struct fat_arch_64 fa;
            memcpy(&fa, buf + pos, sizeof(fa));
            pos += sizeof(fa);
            cputype = be ? swap32((uint32_t)fa.cputype) : (uint32_t)fa.cputype;
            offset = be ? swap64(fa.offset) : fa.offset;
            size = be ? swap64(fa.size) : fa.size;
        }
        if ((cpu_type_t)cputype == CPU_TYPE_ARM64) {
            if (offset > len || size > len - offset || size < sizeof(struct mach_header_64)) return NULL;
            uint8_t *slice = malloc((size_t)size);
            if (!slice) return NULL;
            memcpy(slice, buf + offset, (size_t)size);
            *out_len = (size_t)size;
            return slice;
        }
    }
    return NULL;
}

// Rewrite a macOS dylib dependency path for iOS/Simulator, or return false if unchanged.
// Each shimmed framework maps 1-to-1 to a distinct dylib name so Mach-O library ordinals
// (used by LC_DYLD_INFO bind opcodes, chained fixups, and two-level symbol n_desc) never shift.
// --exe-rel: a dlopened guest's @executable_path is the host app, so guest paths relative to the guest's own main
// executable are rewritten to @loader_path/<rel>, where <rel> leads from this file's directory to the main
// executable's directory.
static const char *g_exe_rel = NULL;
static bool map_exe_relative(const char *orig, char *out, size_t out_sz) {
    static const char kExe[] = "@executable_path";
    if (!g_exe_rel || strncmp(orig, kExe, sizeof(kExe) - 1) != 0) return false;
    const char *rest = orig + sizeof(kExe) - 1;
    if (*rest != '/' && *rest != '\0') return false;
    if (strcmp(g_exe_rel, ".") == 0) snprintf(out, out_sz, "@loader_path%s", rest);
    else snprintf(out, out_sz, "@loader_path/%s%s", g_exe_rel, rest);
    return true;
}

static bool imports_clear_cache(const uint8_t *data, size_t len, const struct symtab_command *symtab) {
    if (symtab->symoff > len || symtab->nsyms > (len - symtab->symoff) / sizeof(struct nlist_64) ||
        symtab->stroff > len || symtab->strsize > len - symtab->stroff) return false;

    const char *strings = (const char *)data + symtab->stroff;
    static const char name[] = "___clear_cache";
    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        struct nlist_64 symbol;
        memcpy(&symbol, data + symtab->symoff + i * sizeof(symbol), sizeof(symbol));
        uint32_t index = symbol.n_un.n_strx;
        if (symbol.n_type == (N_UNDF | N_EXT) && index < symtab->strsize &&
            sizeof name <= symtab->strsize - index && !memcmp(strings + index, name, sizeof name)) {
            return true;
        }
    }
    return false;
}

static bool map_dependency_path(const char *orig, char *out, size_t out_sz, bool shim_system) {
    if (map_exe_relative(orig, out, out_sz)) return true;
    if (shim_system && !strcmp(orig, "/usr/lib/libSystem.B.dylib")) {
        snprintf(out, out_sz, "@rpath/libShim_System.dylib");
        return true;
    }
    static const struct {
        const char *needle;
        const char *target;
    } kShimMap[] = {
        {"/AppKit.framework/", "@rpath/libShim_AppKit.dylib"},
        {"/Cocoa.framework/", "@rpath/libShim_Cocoa.dylib"},
        {"/SwiftUI.framework/", "@rpath/libShim_SwiftUI.dylib"},
        {"/CoreFoundation.framework/", "@rpath/libShim_CoreFoundation.dylib"},
        {"/Foundation.framework/", "@rpath/libShim_Foundation.dylib"},
        {"/CoreGraphics.framework/", "@rpath/libShim_CoreGraphics.dylib"},
        {"/CoreServices.framework/", "@rpath/libShim_CoreServices.dylib"},
        {"/Security.framework/", "@rpath/libShim_Security.dylib"},
        {"/SecurityFoundation.framework/", "@rpath/libShim_SecurityFoundation.dylib"},
        {"/DiskArbitration.framework/", "@rpath/libShim_DiskArbitration.dylib"},
        {"/ServiceManagement.framework/", "@rpath/libShim_ServiceManagement.dylib"},
        {"/SystemConfiguration.framework/", "@rpath/libShim_SystemConfiguration.dylib"},
        {"/IOKit.framework/", "@rpath/libShim_IOKit.dylib"},
        {"/libswiftCore.dylib", "@rpath/libShim_swiftCore.dylib"},
    };
    for (size_t i = 0; i < sizeof(kShimMap) / sizeof(kShimMap[0]); i++) {
        if (strstr(orig, kShimMap[i].needle)) {
            snprintf(out, out_sz, "%s", kShimMap[i].target);
            return strcmp(orig, out) != 0;
        }
    }
    // Flatten /System/Library/Frameworks/<Name>.framework/Versions/<Ver>/<Name>
    const char *prefix = "/System/Library/Frameworks/";
    size_t plen = strlen(prefix);
    if (strncmp(orig, prefix, plen) == 0) {
        const char *fw = orig + plen;
        const char *fw_end = strstr(fw, ".framework/Versions/");
        if (fw_end) {
            size_t fw_len = (size_t)(fw_end - fw);
            if (fw_len == 5 && strncmp(fw, "IOKit", 5) == 0) return false;
            const char *after_ver = strchr(fw_end + strlen(".framework/Versions/"), '/');
            if (after_ver && *(after_ver + 1) != '\0') {
                const char *bin_name = after_ver + 1;
                if (fw_len == strlen(bin_name) && strncmp(fw, bin_name, fw_len) == 0) {
                    snprintf(out, out_sz, "%s%.*s.framework/%s", prefix, (int)fw_len, fw, bin_name);
                    return strcmp(orig, out) != 0;
                }
            }
        }
    }
    return false;
}

typedef struct {
    uint8_t *buf;
    size_t len;
    size_t cap;
    uint32_t ncmds;
} CmdBuilder;

static void cb_append(CmdBuilder *cb, const void *data, size_t size) {
    if (cb->len + size > cb->cap) {
        size_t ncap = cb->cap ? cb->cap * 2 : 4096;
        while (ncap < cb->len + size) ncap *= 2;
        uint8_t *nbuf = realloc(cb->buf, ncap);
        if (!nbuf) {
            fprintf(stderr, "retag: out of memory\n");
            exit(1);
        }
        cb->buf = nbuf;
        cb->cap = ncap;
    }
    memcpy(cb->buf + cb->len, data, size);
    cb->len += size;
    cb->ncmds++;
}

static void cb_append_dylib_cmd(CmdBuilder *cb, uint32_t cmd, const char *path,
                                uint32_t ts, uint32_t cur_ver, uint32_t compat_ver) {
    size_t plen = strlen(path) + 1;
    size_t csz = align8(sizeof(struct dylib_command) + plen);
    uint8_t *tmp = calloc(1, csz);
    if (!tmp) exit(1);
    struct dylib_command *dc = (struct dylib_command *)tmp;
    dc->cmd = cmd;
    dc->cmdsize = (uint32_t)csz;
    dc->dylib.name.offset = sizeof(struct dylib_command);
    dc->dylib.timestamp = ts;
    dc->dylib.current_version = cur_ver;
    dc->dylib.compatibility_version = compat_ver;
    memcpy(tmp + sizeof(struct dylib_command), path, plen);
    cb_append(cb, tmp, csz);
    free(tmp);
}

static void cb_append_dylib_use_cmd(CmdBuilder *cb, uint32_t cmd, const char *path,
                                    uint32_t cur_ver, uint32_t compat_ver, uint32_t flags) {
    size_t plen = strlen(path) + 1;
    size_t csz = align8(sizeof(struct dylib_use_command) + plen);
    uint8_t *tmp = calloc(1, csz);
    if (!tmp) exit(1);
    struct dylib_use_command *duc = (struct dylib_use_command *)tmp;
    duc->cmd = cmd;
    duc->cmdsize = (uint32_t)csz;
    duc->nameoff = sizeof(struct dylib_use_command);
    duc->marker = DYLIB_USE_MARKER;
    duc->current_version = cur_ver;
    duc->compat_version = compat_ver;
    duc->flags = flags;
    memcpy(tmp + sizeof(struct dylib_use_command), path, plen);
    cb_append(cb, tmp, csz);
    free(tmp);
}

static void cb_append_rpath(CmdBuilder *cb, const char *rpath) {
    size_t plen = strlen(rpath) + 1;
    size_t csz = align8(sizeof(struct rpath_command) + plen);
    uint8_t *tmp = calloc(1, csz);
    if (!tmp) exit(1);
    struct rpath_command *rc = (struct rpath_command *)tmp;
    rc->cmd = LC_RPATH;
    rc->cmdsize = (uint32_t)csz;
    rc->path.offset = sizeof(struct rpath_command);
    memcpy(tmp + sizeof(struct rpath_command), rpath, plen);
    cb_append(cb, tmp, csz);
    free(tmp);
}

static int run_codesign(const char *path) {
    pid_t pid = 0;
    char *argv[] = {"/usr/bin/codesign", "--force", "--sign", "-", (char *)path, NULL};
    int rc = posix_spawn(&pid, "/usr/bin/codesign", NULL, NULL, argv, environ);
    if (rc != 0) {
        fprintf(stderr, "retag: posix_spawn codesign failed: %s\n", strerror(rc));
        return -1;
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        fprintf(stderr, "retag: codesign failed for %s\n", path);
        return -1;
    }
    return 0;
}

static void usage(void) {
    fprintf(stderr,
            "Usage: retag [options] <input> [-o <output>]\n"
            "  --platform <ios|iossim|2|7>   Target platform (default: iossim)\n"
            "  --minos <X.Y>                 Minimum OS version (default: 17.0)\n"
            "  --sdk <X.Y>                   SDK version (default: 27.2)\n"
            "  --pagezero / --no-pagezero    Shrink __PAGEZERO for dlopen (default: on)\n"
            "  --dylib / --no-dylib          Convert MH_EXECUTE -> MH_DYLIB (default: on)\n"
            "  --id <install_name>           LC_ID_DYLIB name (default: @rpath/<name>.dylib)\n"
            "  --rewrite-deps                Rewrite AppKit/Cocoa -> @rpath/libShim_AppKit.dylib & flatten Apple frameworks\n"
            "  --add-rpath <rpath>           Add LC_RPATH (repeatable)\n"
            "  --exe-rel <rel>               Rewrite @executable_path to @loader_path/<rel> (guest main exe dir)\n"
            "  --sign / --no-sign            Ad-hoc codesign output (default: on)\n");
}

int main(int argc, char **argv) {
    g_exe_rel = NULL; // main runs more than once in-process (MacRetag.c)
    uint32_t platform = PLATFORM_IOSSIMULATOR;
    uint32_t minos = (17u << 16);
    uint32_t sdk = (27u << 16) | (2u << 8);
    bool patch_pagezero = true;
    bool make_dylib = true;
    bool rewrite_deps = false;
    bool do_sign = true;
    const char *custom_id = NULL;
    const char *input_path = NULL;
    const char *output_path = NULL;
    const char *add_rpaths[16];
    int n_add_rpaths = 0;

    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "--platform") == 0 && i + 1 < argc) {
            if (!parse_platform(argv[++i], &platform)) {
                fprintf(stderr, "retag: invalid platform '%s'\n", argv[i]);
                return 1;
            }
        } else if (strcmp(arg, "--minos") == 0 && i + 1 < argc) {
            if (!parse_version(argv[++i], &minos)) {
                fprintf(stderr, "retag: invalid minos '%s'\n", argv[i]);
                return 1;
            }
        } else if (strcmp(arg, "--sdk") == 0 && i + 1 < argc) {
            if (!parse_version(argv[++i], &sdk)) {
                fprintf(stderr, "retag: invalid sdk '%s'\n", argv[i]);
                return 1;
            }
        } else if (strcmp(arg, "--pagezero") == 0) {
            patch_pagezero = true;
        } else if (strcmp(arg, "--no-pagezero") == 0) {
            patch_pagezero = false;
        } else if (strcmp(arg, "--dylib") == 0) {
            make_dylib = true;
        } else if (strcmp(arg, "--no-dylib") == 0) {
            make_dylib = false;
        } else if (strcmp(arg, "--exe-rel") == 0 && i + 1 < argc) {
            g_exe_rel = argv[++i];
        } else if (strcmp(arg, "--rewrite-deps") == 0) {
            rewrite_deps = true;
        } else if (strcmp(arg, "--id") == 0 && i + 1 < argc) {
            custom_id = argv[++i];
        } else if (strcmp(arg, "--add-rpath") == 0 && i + 1 < argc) {
            const char *rp = argv[++i];
            if (n_add_rpaths >= 16) {
                fprintf(stderr, "retag: too many --add-rpath arguments (max 16)\n");
                return 1;
            }
            add_rpaths[n_add_rpaths++] = rp;
        } else if (strcmp(arg, "--sign") == 0) {
            do_sign = true;
        } else if (strcmp(arg, "--no-sign") == 0) {
            do_sign = false;
        } else if (strcmp(arg, "-o") == 0 && i + 1 < argc) {
            output_path = argv[++i];
        } else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            usage();
            return 0;
        } else if (arg[0] == '-') {
            fprintf(stderr, "retag: unknown option '%s'\n", arg);
            usage();
            return 1;
        } else {
            input_path = arg;
        }
    }

    if (!input_path) {
        usage();
        return 1;
    }
    if (!output_path) output_path = input_path;

    FILE *fp = fopen(input_path, "rb");
    if (!fp) {
        fprintf(stderr, "retag: cannot open %s: %s\n", input_path, strerror(errno));
        return 1;
    }
    struct stat st;
    if (fstat(fileno(fp), &st) != 0 || st.st_size < (off_t)sizeof(struct mach_header_64)) {
        fclose(fp);
        fprintf(stderr, "retag: invalid file size for %s\n", input_path);
        return 1;
    }
    size_t raw_len = (size_t)st.st_size;
    uint8_t *raw = malloc(raw_len);
    if (!raw || fread(raw, 1, raw_len, fp) != raw_len) {
        fclose(fp);
        free(raw);
        fprintf(stderr, "retag: failed reading %s\n", input_path);
        return 1;
    }
    fclose(fp);

    size_t len = 0;
    uint8_t *data = extract_arm64_slice(raw, raw_len, &len);
    free(raw);
    if (!data) {
        fprintf(stderr, "retag: %s does not contain an arm64 Mach-O64 slice\n", input_path);
        return 1;
    }

    struct mach_header_64 mh;
    memcpy(&mh, data, sizeof(mh));
    if (mh.magic != MH_MAGIC_64 || mh.cputype != CPU_TYPE_ARM64) {
        fprintf(stderr, "retag: expected 64-bit arm64 Mach-O\n");
        free(data);
        return 1;
    }
    if (sizeof(mh) + mh.sizeofcmds > len) {
        fprintf(stderr, "retag: truncated load commands\n");
        free(data);
        return 1;
    }

    // The output is always signed afterwards (codesign or the in-process signer), which adds an LC_CODE_SIGNATURE.
    const size_t kSigReserve = sizeof(struct linkedit_data_command);

    // First pass: find header room limit (first section or non-zero segment fileoff) and __TEXT vmaddr.
    size_t header_limit = len;
    uint64_t text_vmaddr = 0x100000000ULL;
    bool shim_system = false;
    size_t off = sizeof(mh);
    for (uint32_t i = 0; i < mh.ncmds; i++) {
        struct load_command lc;
        memcpy(&lc, data + off, sizeof(lc));
        if (lc.cmdsize < sizeof(lc) || off + lc.cmdsize > sizeof(mh) + mh.sizeofcmds) {
            fprintf(stderr, "retag: corrupt load command at index %u\n", i);
            free(data);
            return 1;
        }
        if (rewrite_deps && lc.cmd == LC_SYMTAB && lc.cmdsize >= sizeof(struct symtab_command)) {
            struct symtab_command symtab;
            memcpy(&symtab, data + off, sizeof(symtab));
            shim_system = imports_clear_cache(data, len, &symtab);
        } else if (lc.cmd == LC_SEGMENT_64 && lc.cmdsize >= sizeof(struct segment_command_64)) {
            struct segment_command_64 seg;
            memcpy(&seg, data + off, sizeof(seg));
            if (strncmp(seg.segname, "__TEXT", 16) == 0) text_vmaddr = seg.vmaddr;
            if (seg.fileoff > 0 && seg.fileoff < header_limit) header_limit = (size_t)seg.fileoff;
            if ((uint64_t)seg.nsects > (lc.cmdsize - sizeof(seg)) / sizeof(struct section_64)) {
                fprintf(stderr, "retag: corrupt segment section count at command %u\n", i);
                free(data);
                return 1;
            }
            const uint8_t *sec_ptr = data + off + sizeof(seg);
            for (uint32_t s = 0; s < seg.nsects; s++) {
                struct section_64 sec;
                memcpy(&sec, sec_ptr + s * sizeof(sec), sizeof(sec));
                if (sec.offset > 0 && sec.offset < header_limit) header_limit = sec.offset;
            }
        }
        off += lc.cmdsize;
    }

    // Second pass: rebuild load commands.
    CmdBuilder cb = {0};
    bool saw_build_version = false;
    bool saw_id_dylib = false;
    bool converting_exec = (mh.filetype == MH_EXECUTE && make_dylib);
    uint32_t sig_off = 0, sig_size = 0;
    size_t linkedit_cmd_off_in_builder = (size_t)-1;
    bool rpath_seen[16] = {false};
    char *seen_deps[256];
    int n_seen_deps = 0;

    off = sizeof(mh);
    for (uint32_t i = 0; i < mh.ncmds; i++) {
        struct load_command lc;
        memcpy(&lc, data + off, sizeof(lc));
        const uint8_t *cmd_bytes = data + off;

        if (lc.cmd == LC_LOAD_DYLINKER && converting_exec) {
            // MH_DYLIB / MH_BUNDLE does not use LC_LOAD_DYLINKER; dropping it frees header bytes.
            off += lc.cmdsize;
            continue;
        }
        if (lc.cmd == LC_CODE_SIGNATURE && lc.cmdsize >= sizeof(struct linkedit_data_command)) {
            struct linkedit_data_command ldc;
            memcpy(&ldc, cmd_bytes, sizeof(ldc));
            sig_off = ldc.dataoff;
            sig_size = ldc.datasize;
            off += lc.cmdsize;
            continue;
        }
        if (lc.cmd == LC_BUILD_VERSION && lc.cmdsize >= sizeof(struct build_version_command)) {
            uint8_t *tmp = malloc(lc.cmdsize);
            memcpy(tmp, cmd_bytes, lc.cmdsize);
            struct build_version_command *bvc = (struct build_version_command *)tmp;
            bvc->platform = platform;
            bvc->minos = minos;
            bvc->sdk = sdk;
            cb_append(&cb, tmp, lc.cmdsize);
            free(tmp);
            saw_build_version = true;
            off += lc.cmdsize;
            continue;
        }
        if ((lc.cmd == LC_VERSION_MIN_MACOSX || lc.cmd == LC_VERSION_MIN_IPHONEOS) &&
            lc.cmdsize >= sizeof(struct version_min_command)) {
            struct build_version_command bvc = {
                .cmd = LC_BUILD_VERSION,
                .cmdsize = sizeof(struct build_version_command),
                .platform = platform,
                .minos = minos,
                .sdk = sdk,
                .ntools = 0,
            };
            cb_append(&cb, &bvc, sizeof(bvc));
            saw_build_version = true;
            off += lc.cmdsize;
            continue;
        }
        if (lc.cmd == LC_SEGMENT_64 && lc.cmdsize >= sizeof(struct segment_command_64)) {
            uint8_t *tmp = malloc(lc.cmdsize);
            memcpy(tmp, cmd_bytes, lc.cmdsize);
            struct segment_command_64 *seg = (struct segment_command_64 *)tmp;
            if (strncmp(seg->segname, "__PAGEZERO", 16) == 0 && patch_pagezero &&
                seg->vmaddr == 0 && seg->vmsize > 0x4000) {
                if (text_vmaddr >= 0x4000) {
                    // LiveContainer pattern: shrink 4 GB __PAGEZERO to 16 KB right below __TEXT.
                    seg->vmaddr = text_vmaddr - 0x4000;
                    seg->vmsize = 0x4000;
                } else {
                    memset(seg->segname, 0, 16);
                    memcpy(seg->segname, "__FAKEZERO", 10);
                    seg->vmaddr = 0;
                    seg->vmsize = 0;
                }
            } else if (strncmp(seg->segname, "__LINKEDIT", 16) == 0) {
                linkedit_cmd_off_in_builder = cb.len;
            }
            cb_append(&cb, tmp, lc.cmdsize);
            free(tmp);
            off += lc.cmdsize;
            continue;
        }
        if (lc.cmd == LC_ID_DYLIB && lc.cmdsize >= sizeof(struct dylib_command)) {
            saw_id_dylib = true;
            if (custom_id) {
                struct dylib_command dc;
                memcpy(&dc, cmd_bytes, sizeof(dc));
                cb_append_dylib_cmd(&cb, LC_ID_DYLIB, custom_id, dc.dylib.timestamp,
                                    dc.dylib.current_version, dc.dylib.compatibility_version);
                off += lc.cmdsize;
                continue;
            }
        }
        if ((lc.cmd == LC_LOAD_DYLIB || lc.cmd == LC_LOAD_WEAK_DYLIB || lc.cmd == LC_REEXPORT_DYLIB) &&
            rewrite_deps && lc.cmdsize >= sizeof(struct dylib_command)) {
            bool is_use_cmd = false;
            const char *orig = NULL;
            char mapped[1024];
            uint32_t ts = 0, cur_ver = 0, compat_ver = 0, flags = 0;
            bool do_map = false;

            if (lc.cmdsize >= sizeof(struct dylib_use_command)) {
                struct dylib_use_command duc;
                memcpy(&duc, cmd_bytes, sizeof(duc));
                if (duc.marker == DYLIB_USE_MARKER && duc.nameoff == sizeof(struct dylib_use_command) &&
                    memchr(cmd_bytes + duc.nameoff, '\0', lc.cmdsize - duc.nameoff) != NULL) {
                    is_use_cmd = true;
                    orig = (const char *)(cmd_bytes + duc.nameoff);
                    cur_ver = duc.current_version;
                    compat_ver = duc.compat_version;
                    flags = duc.flags;
                    do_map = map_dependency_path(orig, mapped, sizeof(mapped), shim_system);
                }
            }
            if (!is_use_cmd) {
                struct dylib_command dc;
                memcpy(&dc, cmd_bytes, sizeof(dc));
                if (dc.dylib.name.offset < lc.cmdsize &&
                    memchr(cmd_bytes + dc.dylib.name.offset, '\0', lc.cmdsize - dc.dylib.name.offset) != NULL) {
                    orig = (const char *)(cmd_bytes + dc.dylib.name.offset);
                    ts = dc.dylib.timestamp;
                    cur_ver = dc.dylib.current_version;
                    compat_ver = dc.dylib.compatibility_version;
                    do_map = map_dependency_path(orig, mapped, sizeof(mapped), shim_system);
                }
            }
            if (orig) {
                const char *final_path = do_map ? mapped : orig;
                bool dup = false;
                for (int d = 0; d < n_seen_deps; d++) {
                    if (strcmp(seen_deps[d], final_path) == 0) {
                        dup = true;
                        break;
                    }
                }
                if (dup) {
                    off += lc.cmdsize;
                    continue;
                }
                if (n_seen_deps < 256) {
                    seen_deps[n_seen_deps++] = strdup(final_path);
                }
                if (do_map) {
                    if (is_use_cmd) {
                        cb_append_dylib_use_cmd(&cb, lc.cmd, mapped, cur_ver, compat_ver, flags);
                    } else {
                        cb_append_dylib_cmd(&cb, lc.cmd, mapped, ts, cur_ver, compat_ver);
                    }
                    off += lc.cmdsize;
                    continue;
                }
            }
        }
        if (lc.cmd == LC_RPATH && lc.cmdsize >= sizeof(struct rpath_command)) {
            struct rpath_command rc;
            memcpy(&rc, cmd_bytes, sizeof(rc));
            if (rc.path.offset < lc.cmdsize &&
                memchr(cmd_bytes + rc.path.offset, '\0', lc.cmdsize - rc.path.offset) != NULL) {
                const char *rp = (const char *)(cmd_bytes + rc.path.offset);
                for (int r = 0; r < n_add_rpaths; r++) {
                    if (strcmp(rp, add_rpaths[r]) == 0) rpath_seen[r] = true;
                }
                char mapped_rp[1024];
                if (map_exe_relative(rp, mapped_rp, sizeof(mapped_rp))) {
                    cb_append_rpath(&cb, mapped_rp);
                    off += lc.cmdsize;
                    continue;
                }
            }
        }

        cb_append(&cb, cmd_bytes, lc.cmdsize);
        off += lc.cmdsize;
    }

    if (!saw_build_version) {
        struct build_version_command bvc = {
            .cmd = LC_BUILD_VERSION,
            .cmdsize = sizeof(struct build_version_command),
            .platform = platform,
            .minos = minos,
            .sdk = sdk,
            .ntools = 0,
        };
        cb_append(&cb, &bvc, sizeof(bvc));
    }

    for (int r = 0; r < n_add_rpaths; r++) {
        if (!rpath_seen[r]) cb_append_rpath(&cb, add_rpaths[r]);
    }

    if (converting_exec) {
        if (!saw_id_dylib) {
            char default_id[512];
            const char *id_str = custom_id;
            if (!id_str) {
                char *tmp_in = strdup(input_path);
                snprintf(default_id, sizeof(default_id), "@rpath/%s.dylib", basename(tmp_in));
                free(tmp_in);
                id_str = default_id;
            }
            size_t id_sz = align8(sizeof(struct dylib_command) + strlen(id_str) + 1);
            if (sizeof(mh) + cb.len + id_sz + kSigReserve <= header_limit) {
                cb_append_dylib_cmd(&cb, LC_ID_DYLIB, id_str, 2, 0x10000, 0x10000);
                mh.filetype = MH_DYLIB;
                mh.flags &= ~MH_PIE;
            } else {
                // Tight header without space for LC_ID_DYLIB: MH_BUNDLE is dlopenable without LC_ID_DYLIB.
                fprintf(stderr, "retag: insufficient header pad for LC_ID_DYLIB, falling back to MH_BUNDLE\n");
                mh.filetype = MH_BUNDLE;
                mh.flags &= ~MH_PIE;
            }
        } else {
            mh.filetype = MH_DYLIB;
            mh.flags &= ~MH_PIE;
        }
    }

    if (sizeof(mh) + cb.len + kSigReserve > header_limit) {
        fprintf(stderr, "retag: load commands (%zu bytes) exceed header limit (%zu bytes)\n",
                sizeof(mh) + cb.len, header_limit);
        free(cb.buf);
    for (int d = 0; d < n_seen_deps; d++) free(seen_deps[d]);
        free(data);
        return 1;
    }

    // Truncate stale code signature bytes at EOF so codesign writes cleanly.
    if (sig_off > 0 && sig_off + sig_size <= len && len - (sig_off + sig_size) < 16) {
        len = sig_off;
        if (linkedit_cmd_off_in_builder != (size_t)-1) {
            struct segment_command_64 le;
            memcpy(&le, cb.buf + linkedit_cmd_off_in_builder, sizeof(le));
            if (len >= le.fileoff) {
                le.filesize = len - le.fileoff;
                le.vmsize = align16k(le.filesize);
                memcpy(cb.buf + linkedit_cmd_off_in_builder, &le, sizeof(le));
            }
        }
    }

    mh.ncmds = cb.ncmds;
    mh.sizeofcmds = (uint32_t)cb.len;

    memset(data, 0, header_limit);
    memcpy(data, &mh, sizeof(mh));
    memcpy(data + sizeof(mh), cb.buf, cb.len);
    free(cb.buf);
    for (int d = 0; d < n_seen_deps; d++) free(seen_deps[d]);

    FILE *out_fp = fopen(output_path, "wb");
    if (!out_fp) {
        fprintf(stderr, "retag: cannot write %s: %s\n", output_path, strerror(errno));
        free(data);
        return 1;
    }
    if (fwrite(data, 1, len, out_fp) != len) {
        fprintf(stderr, "retag: write failed for %s\n", output_path);
        fclose(out_fp);
        free(data);
        return 1;
    }
    fclose(out_fp);
    free(data);
    chmod(output_path, 0755);

    if (do_sign) {
        if (run_codesign(output_path) != 0) return 1;
    }

    fprintf(stderr, "retag: %s -> platform=%s filetype=0x%x signed=%s\n",
            output_path, platform_name(platform), mh.filetype, do_sign ? "ad-hoc" : "no");
    return 0;
}
