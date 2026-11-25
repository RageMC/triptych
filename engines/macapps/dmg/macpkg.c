#include "macpkg_internal.h"

macpkg_format_t macpkg_detect_format(macpkg_stream_t *stream) {
    if (!stream || !stream->read_at) return MACPKG_FMT_AUTO;

    if (stream->size >= 512) {
        uint8_t koly[4];
        if (stream->read_at(stream->ctx, stream->size - 512, koly, 4) == 0 &&
            memcmp(koly, "koly", 4) == 0) {
            return MACPKG_FMT_DMG;
        }
    }

    if (stream->size >= 4) {
        uint8_t head[4];
        if (stream->read_at(stream->ctx, 0, head, 4) == 0) {
            if (memcmp(head, "xar!", 4) == 0) return MACPKG_FMT_PKG;
            if (head[0] == 0x50 && head[1] == 0x4b &&
                (head[2] == 0x03 || head[2] == 0x05)) {
                return MACPKG_FMT_ZIP;
            }
        }
    }

    if (stream->size >= 1028) {
        uint8_t sig[2];
        if (stream->read_at(stream->ctx, 1024, sig, 2) == 0) {
            uint16_t s = mp_be16(sig);
            if (s == 0x482Bu || s == 0x4858u) return MACPKG_FMT_HFS;
        }
    }

    if (stream->size >= 36) {
        uint8_t magic[4];
        if (stream->read_at(stream->ctx, 32, magic, 4) == 0 &&
            memcmp(magic, "NXSB", 4) == 0) {
            return MACPKG_FMT_APFS;
        }
    }

    /* Check ZIP EOCD in tail in case ZIP has leading SFX stub */
    if (stream->size >= 22) {
        size_t tail_sz = (stream->size > 65557ULL) ? 65557u : (size_t)stream->size;
        uint8_t *tail = (uint8_t *)malloc(tail_sz);
        if (tail) {
            if (stream->read_at(stream->ctx, stream->size - tail_sz, tail, tail_sz) == 0) {
                for (ssize_t i = (ssize_t)tail_sz - 22; i >= 0; i--) {
                    if (tail[i] == 0x50 && tail[i + 1] == 0x4b &&
                        tail[i + 2] == 0x05 && tail[i + 3] == 0x06 &&
                        (size_t)i + 22u + mp_le16(tail + i + 20) == tail_sz) {
                        free(tail);
                        return MACPKG_FMT_ZIP;
                    }
                }
            }
            free(tail);
        }
    }

    return MACPKG_FMT_AUTO;
}

macpkg_status_t macpkg_extract_stream(macpkg_stream_t *stream, const char *output_dir,
                                      const macpkg_options_t *opts,
                                      char *errbuf, size_t errbuf_sz) {
    if (!stream || !output_dir) {
        mp_set_err(errbuf, errbuf_sz, "invalid argument");
        return MACPKG_ERR_IO;
    }

    macpkg_options_t def_opts;
    memset(&def_opts, 0, sizeof(def_opts));
    if (!opts) opts = &def_opts;

    macpkg_format_t fmt = opts->format;
    if (fmt == MACPKG_FMT_AUTO) {
        fmt = macpkg_detect_format(stream);
    }

    switch (fmt) {
        case MACPKG_FMT_DMG:
            return mp_extract_dmg(stream, output_dir, opts, errbuf, errbuf_sz);
        case MACPKG_FMT_PKG:
            return mp_extract_pkg(stream, output_dir, opts, errbuf, errbuf_sz);
        case MACPKG_FMT_ZIP:
            return mp_extract_zip(stream, output_dir, opts, errbuf, errbuf_sz);
        case MACPKG_FMT_HFS:
            return mp_extract_hfsplus(stream, output_dir, opts, errbuf, errbuf_sz);
        case MACPKG_FMT_APFS:
            return mp_extract_apfs(stream, output_dir, opts, errbuf, errbuf_sz);
        default:
            mp_set_err(errbuf, errbuf_sz, "unrecognized installer format");
            return MACPKG_ERR_FORMAT;
    }
}

macpkg_status_t macpkg_extract_file(const char *input_path, const char *output_dir,
                                    const macpkg_options_t *opts,
                                    char *errbuf, size_t errbuf_sz) {
    macpkg_stream_t s;
    macpkg_status_t st = macpkg_stream_open_file(input_path, &s, errbuf, errbuf_sz);
    if (st != MACPKG_OK) return st;
    st = macpkg_extract_stream(&s, output_dir, opts, errbuf, errbuf_sz);
    macpkg_stream_close(&s);
    return st;
}
