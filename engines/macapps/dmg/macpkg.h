#ifndef MACPKG_H
#define MACPKG_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    MACPKG_OK = 0,
    MACPKG_ERR_IO = -1,
    MACPKG_ERR_FORMAT = -2,
    MACPKG_ERR_UNSUPPORTED = -3,
    MACPKG_ERR_NOMEM = -4,
    MACPKG_ERR_CORRUPT = -5,
    MACPKG_ERR_NOT_FOUND = -6,
    MACPKG_ERR_PATH = -7
} macpkg_status_t;

typedef enum {
    MACPKG_FMT_AUTO = 0,
    MACPKG_FMT_DMG = 1,
    MACPKG_FMT_PKG = 2,
    MACPKG_FMT_ZIP = 3,
    MACPKG_FMT_HFS = 4,
    MACPKG_FMT_APFS = 5
} macpkg_format_t;

typedef struct {
    int verbose;
    int extract_all_files; /* 0 = extract only .app bundles (default), 1 = extract entire tree */
    const char *app_name;  /* NULL = all .app bundles found, or specific e.g. "Steam.app" */
    macpkg_format_t format;
} macpkg_options_t;

/* Callback-based random-access input stream (portable for iOS/memory/file). */
typedef struct macpkg_stream {
    void *ctx;
    uint64_t size;
    int (*read_at)(void *ctx, uint64_t offset, void *buf, size_t len);
    void (*close)(void *ctx);
} macpkg_stream_t;

/* Open a file-backed stream using standard POSIX I/O. */
macpkg_status_t macpkg_stream_open_file(const char *path, macpkg_stream_t *out_stream,
                                        char *errbuf, size_t errbuf_sz);

/* Close a stream opened with macpkg_stream_open_file. */
void macpkg_stream_close(macpkg_stream_t *stream);

/* Detect installer format from stream magic/trailer. */
macpkg_format_t macpkg_detect_format(macpkg_stream_t *stream);

/* Extract .app bundle(s) from an installer file into output_dir.
 * output_dir is created if it does not exist; e.g. output_dir/Steam.app/... */
macpkg_status_t macpkg_extract_file(const char *input_path, const char *output_dir,
                                    const macpkg_options_t *opts,
                                    char *errbuf, size_t errbuf_sz);

/* Extract .app bundle(s) from an already-opened stream into output_dir. */
macpkg_status_t macpkg_extract_stream(macpkg_stream_t *stream, const char *output_dir,
                                      const macpkg_options_t *opts,
                                      char *errbuf, size_t errbuf_sz);

const char *macpkg_strerror(macpkg_status_t st);

#ifdef __cplusplus
}
#endif

#endif /* MACPKG_H */
