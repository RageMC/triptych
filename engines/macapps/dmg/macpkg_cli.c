#include "macpkg.h"
#include <stdio.h>
#include <string.h>

static void usage(const char *prog) {
    fprintf(stderr,
            "Usage: %s [options] <installer.(dmg|pkg|zip)> <output_dir>\n"
            "Options:\n"
            "  -v            Verbose logging\n"
            "  -a            Extract all files (not just .app bundles)\n"
            "  -n <name.app> Extract only the named .app bundle\n"
            "  -h            Show help\n",
            prog);
}

int main(int argc, char **argv) {
    macpkg_options_t opts;
    memset(&opts, 0, sizeof(opts));

    int idx = 1;
    while (idx < argc && argv[idx][0] == '-' && argv[idx][1] != '\0') {
        const char *arg = argv[idx];
        if (strcmp(arg, "-v") == 0) {
            opts.verbose = 1;
        } else if (strcmp(arg, "-a") == 0) {
            opts.extract_all_files = 1;
        } else if (strcmp(arg, "-n") == 0) {
            if (idx + 1 >= argc) { usage(argv[0]); return 2; }
            opts.app_name = argv[++idx];
        } else if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "Unknown option: %s\n", arg);
            usage(argv[0]);
            return 2;
        }
        idx++;
    }

    if (argc - idx != 2) {
        usage(argv[0]);
        return 2;
    }

    const char *input = argv[idx];
    const char *outdir = argv[idx + 1];

    char err[512];
    err[0] = '\0';
    macpkg_status_t st = macpkg_extract_file(input, outdir, &opts, err, sizeof(err));
    if (st != MACPKG_OK) {
        fprintf(stderr, "macpkg: error (%s): %s\n", macpkg_strerror(st), err);
        return 1;
    }
    return 0;
}
