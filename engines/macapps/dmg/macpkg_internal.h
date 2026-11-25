#ifndef MACPKG_INTERNAL_H
#define MACPKG_INTERNAL_H

#include "macpkg.h"
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- Error helpers ---- */
void mp_set_err(char *errbuf, size_t errbuf_sz, const char *fmt, ...);

/* ---- Endianness helpers ---- */
static inline uint16_t mp_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}
static inline uint32_t mp_be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}
static inline uint64_t mp_be64(const uint8_t *p) {
    return ((uint64_t)mp_be32(p) << 32) | mp_be32(p + 4);
}
static inline uint16_t mp_le16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[1] << 8) | p[0]);
}
static inline uint32_t mp_le32(const uint8_t *p) {
    return ((uint32_t)p[3] << 24) | ((uint32_t)p[2] << 16) |
           ((uint32_t)p[1] << 8) | (uint32_t)p[0];
}
static inline uint64_t mp_le64(const uint8_t *p) {
    return ((uint64_t)mp_le32(p + 4) << 32) | mp_le32(p);
}

/* ---- Stream helpers ---- */
macpkg_status_t mp_stream_read_exact(macpkg_stream_t *s, uint64_t off, void *buf, size_t len,
                                     char *err, size_t err_sz);
macpkg_status_t mp_stream_slice(macpkg_stream_t *parent, uint64_t off, uint64_t len,
                                macpkg_stream_t *out);
macpkg_status_t mp_stream_from_memory(const uint8_t *data, size_t len, int take_ownership,
                                      macpkg_stream_t *out);

/* ---- Path & Output Sink ---- */
typedef struct mp_dir_mode {
    char *path;
    uint16_t mode;
} mp_dir_mode_t;

typedef struct mp_sink {
    char *root_dir;
    int root_fd;
    mp_dir_mode_t *dirs;
    size_t dir_count;
    size_t dir_cap;
    int verbose;
    size_t files_written;
    size_t symlinks_written;
    size_t hardlinks_written;
    size_t dirs_created;
} mp_sink_t;

macpkg_status_t mp_sink_init(mp_sink_t *sink, const char *root_dir, int verbose,
                             char *err, size_t err_sz);
void mp_sink_finish(mp_sink_t *sink); /* applies deferred dir modes & frees */
void mp_sink_free(mp_sink_t *sink);

/* rel_path must be clean relative path without leading '/' or '..' */
macpkg_status_t mp_sink_mkdir(mp_sink_t *sink, const char *rel_path, uint16_t mode,
                              char *err, size_t err_sz);
macpkg_status_t mp_sink_write_file(mp_sink_t *sink, const char *rel_path, uint16_t mode,
                                   const uint8_t *data, size_t len,
                                   char *err, size_t err_sz);
/* Streaming file write for huge files */
macpkg_status_t mp_sink_begin_file(mp_sink_t *sink, const char *rel_path, uint16_t mode,
                                   FILE **out_fp, char **out_full_path,
                                   char *err, size_t err_sz);
macpkg_status_t mp_sink_end_file(FILE *fp, const char *full_path, uint16_t mode,
                                 char *err, size_t err_sz);
macpkg_status_t mp_sink_symlink(mp_sink_t *sink, const char *rel_path, const char *target,
                                char *err, size_t err_sz);
macpkg_status_t mp_sink_hardlink(mp_sink_t *sink, const char *rel_path, const char *target_rel_path,
                                 char *err, size_t err_sz);

/* Path filtering helper for .app extraction */
int mp_filter_app_relpath(const char *raw_path, const macpkg_options_t *opts,
                          char *out_rel, size_t out_cap);
int mp_sanitize_relpath(const char *raw_path, char *out, size_t out_cap);

/* ---- Codecs ---- */
typedef enum {
    MP_CODEC_RAW = 0,
    MP_CODEC_ZLIB = 1,
    MP_CODEC_DEFLATE_RAW = 2,
    MP_CODEC_GZIP = 3,
    MP_CODEC_BZIP2 = 4,
    MP_CODEC_LZFSE = 5,
    MP_CODEC_LZVN = 6,
    MP_CODEC_XZ = 7,
    MP_CODEC_ADC = 8
} mp_codec_t;

macpkg_status_t mp_decompress(mp_codec_t codec, const uint8_t *in, size_t in_len,
                              uint8_t *out, size_t out_cap, size_t *out_len,
                              char *err, size_t err_sz);

/* Growing-buffer decompression (for unknown output size, e.g. gzip/xz/zlib streams) */
macpkg_status_t mp_decompress_alloc(mp_codec_t codec, const uint8_t *in, size_t in_len,
                                    uint8_t **out_buf, size_t *out_len,
                                    char *err, size_t err_sz);

/* Streaming decompression callback */
typedef macpkg_status_t (*mp_write_cb)(void *ctx, const uint8_t *data, size_t len,
                                       char *err, size_t err_sz);

macpkg_status_t mp_decompress_stream_xz(const uint8_t *in, size_t in_len,
                                        mp_write_cb cb, void *cb_ctx,
                                        char *err, size_t err_sz);
macpkg_status_t mp_decompress_stream_gzip(const uint8_t *in, size_t in_len,
                                          mp_write_cb cb, void *cb_ctx,
                                          char *err, size_t err_sz);

/* ---- XML / Plist helpers ---- */
typedef struct {
    char *name;
    char *id;
    char *cfname;
    uint8_t *data;
    size_t data_len;
} mp_blkx_entry_t;

macpkg_status_t mp_parse_udif_plist(const char *xml, size_t xml_len,
                                    mp_blkx_entry_t **out_entries, size_t *out_count,
                                    char *err, size_t err_sz);
void mp_free_blkx_entries(mp_blkx_entry_t *entries, size_t count);

typedef struct mp_xar_file {
    char *rel_path;
    int is_dir;
    uint64_t offset;
    uint64_t length;
    uint64_t size;
    char *encoding;
    struct mp_xar_file *next;
} mp_xar_file_t;

macpkg_status_t mp_parse_xar_toc(const char *xml, size_t xml_len,
                                 mp_xar_file_t **out_list,
                                 char *err, size_t err_sz);
void mp_free_xar_files(mp_xar_file_t *list);

/* ---- Format extractors ---- */
macpkg_status_t mp_extract_dmg(macpkg_stream_t *stream, const char *output_dir,
                               const macpkg_options_t *opts, char *err, size_t err_sz);
macpkg_status_t mp_extract_hfsplus(macpkg_stream_t *stream, const char *output_dir,
                                   const macpkg_options_t *opts, char *err, size_t err_sz);
macpkg_status_t mp_extract_apfs(macpkg_stream_t *stream, const char *output_dir,
                                const macpkg_options_t *opts, char *err, size_t err_sz);
macpkg_status_t mp_extract_pkg(macpkg_stream_t *stream, const char *output_dir,
                               const macpkg_options_t *opts, char *err, size_t err_sz);
macpkg_status_t mp_extract_zip(macpkg_stream_t *stream, const char *output_dir,
                               const macpkg_options_t *opts, char *err, size_t err_sz);

/* Shared decmpfs helper used by both HFS+ and APFS */
macpkg_status_t mp_decode_decmpfs(const uint8_t *xattr, size_t xattr_len,
                                  const uint8_t *rsrc_fork, size_t rsrc_len,
                                  uint8_t **out_buf, size_t *out_len,
                                  char *err, size_t err_sz);

#endif /* MACPKG_INTERNAL_H */
