// SPDX-License-Identifier: GPL-3.0-or-later
// Mac-side test of MacRetagBundle (app/MacAppsKit/MacRetag.c), compiled for macOS with the Simulator platform tag.
// Usage: retag_bundle_test                      (unit tests only)
//        retag_bundle_test APP.app              (retag a whole bundle in place, print stats)
#define MACRETAG_PLATFORM "iossim"
#include "../../app/MacAppsKit/MacRetag.c"
#include <assert.h>

static int check_rel(const char *from, const char *to, const char *want) {
    char out[PATH_MAX];
    relpath(from, to, out, sizeof out);
    if (strcmp(out, want) != 0) { fprintf(stderr, "relpath(%s, %s) = %s, want %s\n", from, to, out, want); return 1; }
    return 0;
}

int main(int argc, char **argv) {
    int bad = 0;
    bad += check_rel("/a/X.app/Contents/MacOS", "/a/X.app/Contents/MacOS", ".");
    bad += check_rel("/a/X.app/Contents/Frameworks/P.framework/Versions/3.14", "/a/X.app/Contents/MacOS", "../../../../MacOS");
    bad += check_rel("/a/X.app/Contents", "/a/X.app/Contents/MacOS", "MacOS");
    bad += check_rel("/a/X.app/Contents/MacOSX", "/a/X.app/Contents/MacOS", "../MacOS");
    bad += check_rel("/a/X.app/Contents/MacOS/sub", "/a/X.app/Contents/MacOS", "..");
    uint8_t java[64] = {0xca, 0xfe, 0xba, 0xbe, 0x00, 0x00, 0x00, 0x34};
    if (classify(java, sizeof java) != KIND_OTHER) { fprintf(stderr, "Java class file taken for a fat Mach-O\n"); bad++; }
    if (bad) return 1;
    printf("unit tests ok\n");
    if (argc < 2) return 0;
    char exe[PATH_MAX], err[512] = {0};
    snprintf(exe, sizeof exe, "%s/Contents/MacOS", argv[1]);
    MacRetagStats st;
    int rc = MacRetagBundle(argv[1], exe, &st, err, sizeof err);
    printf("retagged %u, already %u, skipped (no arm64) %u, failed %u%s%s\n", st.retagged, st.already, st.skipped, st.failed,
           err[0] ? ": " : "", err);
    return rc ? 1 : 0;
}
