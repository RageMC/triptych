#include "macpkg_internal.h"
#include <sys/stat.h>

typedef enum {
    CPIO_STATE_HDR = 0,
    CPIO_STATE_NAME,
    CPIO_STATE_NAME_PAD,
    CPIO_STATE_DATA,
    CPIO_STATE_DATA_PAD,
    CPIO_STATE_DONE
} cpio_state_t;

typedef struct {
    uint64_t dev;
    uint64_t ino;
    char *rel_path;
} cpio_ino_path_t;

typedef struct {
    uint64_t dev;
    uint64_t ino;
    uint16_t mode;
    char *rel_path;
} cpio_deferred_t;

typedef struct {
    mp_sink_t *sink;
    const macpkg_options_t *opts;
    cpio_state_t state;
    int is_newc;
    uint8_t hdr_buf[110];
    size_t hdr_len;
    size_t hdr_need;

    char *name_buf;
    size_t name_len;
    size_t name_pos;

    uint64_t file_dev;
    uint64_t file_ino;
    uint32_t file_mode;
    uint32_t file_nlink;
    uint64_t file_size;
    uint64_t data_pos;
    size_t pad_rem;

    int cur_keep;
    char cur_rel[4096];
    FILE *cur_fp;
    char *cur_full_path;
    uint8_t *symlink_buf;

    cpio_ino_path_t *ino_map;
    size_t ino_count, ino_cap;
    cpio_deferred_t *deferred;
    size_t def_count, def_cap;
} cpio_parser_t;

static int parse_octal(const uint8_t *p, size_t n, uint64_t *out) {
    uint64_t v = 0;
    for (size_t i = 0; i < n; i++) {
        if (p[i] < '0' || p[i] > '7') return -1;
        v = (v << 3) | (uint64_t)(p[i] - '0');
    }
    *out = v;
    return 0;
}

static int parse_hex(const uint8_t *p, size_t n, uint64_t *out) {
    uint64_t v = 0;
    for (size_t i = 0; i < n; i++) {
        uint8_t c = p[i];
        uint64_t d;
        if (c >= '0' && c <= '9') d = (uint64_t)(c - '0');
        else if (c >= 'a' && c <= 'f') d = (uint64_t)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') d = (uint64_t)(c - 'A' + 10);
        else return -1;
        v = (v << 4) | d;
    }
    *out = v;
    return 0;
}

static const char *cpio_find_ino(const cpio_parser_t *p, uint64_t dev, uint64_t ino) {
    for (size_t i = 0; i < p->ino_count; i++) {
        if (p->ino_map[i].dev == dev && p->ino_map[i].ino == ino) return p->ino_map[i].rel_path;
    }
    return NULL;
}

static void cpio_add_ino(cpio_parser_t *p, uint64_t dev, uint64_t ino, const char *rel) {
    if (p->ino_count == p->ino_cap) {
        size_t ncap = p->ino_cap ? p->ino_cap * 2 : 32;
        cpio_ino_path_t *nm = (cpio_ino_path_t *)realloc(p->ino_map, ncap * sizeof(*nm));
        if (!nm) return;
        p->ino_map = nm;
        p->ino_cap = ncap;
    }
    size_t len = strlen(rel) + 1;
    char *copy = (char *)malloc(len);
    if (!copy) return;
    memcpy(copy, rel, len);
    p->ino_map[p->ino_count].dev = dev;
    p->ino_map[p->ino_count].ino = ino;
    p->ino_map[p->ino_count].rel_path = copy;
    p->ino_count++;
}

static void cpio_add_deferred(cpio_parser_t *p, uint64_t dev, uint64_t ino, uint16_t mode, const char *rel) {
    if (p->def_count == p->def_cap) {
        size_t ncap = p->def_cap ? p->def_cap * 2 : 16;
        cpio_deferred_t *nd = (cpio_deferred_t *)realloc(p->deferred, ncap * sizeof(*nd));
        if (!nd) return;
        p->deferred = nd;
        p->def_cap = ncap;
    }
    size_t len = strlen(rel) + 1;
    char *copy = (char *)malloc(len);
    if (!copy) return;
    memcpy(copy, rel, len);
    p->deferred[p->def_count].dev = dev;
    p->deferred[p->def_count].ino = ino;
    p->deferred[p->def_count].mode = mode;
    p->deferred[p->def_count].rel_path = copy;
    p->def_count++;
}

static macpkg_status_t cpio_resolve_deferred_for(cpio_parser_t *p, uint64_t dev, uint64_t ino,
                                                 const char *target_rel, char *err, size_t err_sz) {
    for (size_t i = 0; i < p->def_count; ) {
        if (p->deferred[i].dev == dev && p->deferred[i].ino == ino) {
            macpkg_status_t st = mp_sink_hardlink(p->sink, p->deferred[i].rel_path, target_rel, err, err_sz);
            if (st != MACPKG_OK) return st;
            free(p->deferred[i].rel_path);
            p->deferred[i] = p->deferred[--p->def_count];
        } else {
            i++;
        }
    }
    return MACPKG_OK;
}

static macpkg_status_t cpio_flush_all_deferred(cpio_parser_t *p, char *err, size_t err_sz) {
    for (size_t i = 0; i < p->def_count; i++) {
        const char *existing = cpio_find_ino(p, p->deferred[i].dev, p->deferred[i].ino);
        macpkg_status_t st;
        if (existing) {
            st = mp_sink_hardlink(p->sink, p->deferred[i].rel_path, existing, err, err_sz);
        } else {
            st = mp_sink_write_file(p->sink, p->deferred[i].rel_path, p->deferred[i].mode,
                                    (const uint8_t *)"", 0, err, err_sz);
            if (st == MACPKG_OK) {
                cpio_add_ino(p, p->deferred[i].dev, p->deferred[i].ino, p->deferred[i].rel_path);
            }
        }
        if (st != MACPKG_OK) return st;
    }
    return MACPKG_OK;
}

static void cpio_parser_free(cpio_parser_t *p) {
    free(p->name_buf);
    free(p->symlink_buf);
    if (p->cur_fp) fclose(p->cur_fp);
    free(p->cur_full_path);
    for (size_t i = 0; i < p->ino_count; i++) free(p->ino_map[i].rel_path);
    free(p->ino_map);
    for (size_t i = 0; i < p->def_count; i++) free(p->deferred[i].rel_path);
    free(p->deferred);
}

static macpkg_status_t cpio_finish_entry_data(cpio_parser_t *p, char *err, size_t err_sz) {
    if (!p->cur_keep) return MACPKG_OK;
    if (S_ISLNK(p->file_mode) && p->symlink_buf) {
        p->symlink_buf[p->file_size] = '\0';
        macpkg_status_t st = mp_sink_symlink(p->sink, p->cur_rel, (const char *)p->symlink_buf, err, err_sz);
        free(p->symlink_buf);
        p->symlink_buf = NULL;
        return st;
    }
    if (p->cur_fp) {
        macpkg_status_t st = mp_sink_end_file(p->cur_fp, p->cur_full_path, p->file_mode & 07777u, err, err_sz);
        p->cur_fp = NULL;
        p->cur_full_path = NULL;
        if (st != MACPKG_OK) return st;
        if (p->file_nlink > 1) {
            cpio_add_ino(p, p->file_dev, p->file_ino, p->cur_rel);
            return cpio_resolve_deferred_for(p, p->file_dev, p->file_ino, p->cur_rel, err, err_sz);
        }
    }
    return MACPKG_OK;
}

static macpkg_status_t cpio_begin_entry(cpio_parser_t *p, char *err, size_t err_sz) {
    if (p->name_len > 0) p->name_buf[p->name_len - 1] = '\0';
    if (strcmp(p->name_buf, "TRAILER!!!") == 0) {
        p->state = CPIO_STATE_DONE;
        return cpio_flush_all_deferred(p, err, err_sz);
    }

    p->cur_keep = mp_filter_app_relpath(p->name_buf, p->opts, p->cur_rel, sizeof(p->cur_rel));
    p->data_pos = 0;

    if (p->cur_keep) {
        if (S_ISDIR(p->file_mode)) {
            macpkg_status_t st = mp_sink_mkdir(p->sink, p->cur_rel, p->file_mode & 07777u, err, err_sz);
            if (st != MACPKG_OK) return st;
        } else if (S_ISLNK(p->file_mode)) {
            if (p->file_size > 65536u) {
                mp_set_err(err, err_sz, "cpio symlink target too long");
                return MACPKG_ERR_CORRUPT;
            }
            p->symlink_buf = (uint8_t *)malloc((size_t)p->file_size + 1u);
            if (!p->symlink_buf) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
        } else if (S_ISREG(p->file_mode)) {
            if (p->file_nlink > 1 && p->file_size == 0) {
                const char *existing = cpio_find_ino(p, p->file_dev, p->file_ino);
                if (existing) {
                    macpkg_status_t st = mp_sink_hardlink(p->sink, p->cur_rel, existing, err, err_sz);
                    if (st != MACPKG_OK) return st;
                } else {
                    cpio_add_deferred(p, p->file_dev, p->file_ino, p->file_mode & 07777u, p->cur_rel);
                }
            } else {
                macpkg_status_t st = mp_sink_begin_file(p->sink, p->cur_rel, p->file_mode & 07777u,
                                                        &p->cur_fp, &p->cur_full_path, err, err_sz);
                if (st != MACPKG_OK) return st;
            }
        }
    }

    if (p->file_size > 0) {
        p->state = CPIO_STATE_DATA;
    } else {
        macpkg_status_t st = cpio_finish_entry_data(p, err, err_sz);
        if (st != MACPKG_OK) return st;
        if (p->is_newc && (p->file_size % 4u) != 0) {
            p->pad_rem = 4u - (size_t)(p->file_size % 4u);
            p->state = CPIO_STATE_DATA_PAD;
        } else {
            p->hdr_len = 0;
            p->hdr_need = 6;
            p->state = CPIO_STATE_HDR;
        }
    }
    return MACPKG_OK;
}

static macpkg_status_t cpio_feed_cb(void *vctx, const uint8_t *data, size_t len,
                                    char *err, size_t err_sz) {
    cpio_parser_t *p = (cpio_parser_t *)vctx;
    size_t pos = 0;

    while (pos < len && p->state != CPIO_STATE_DONE) {
        if (p->state == CPIO_STATE_HDR) {
            while (p->hdr_len < p->hdr_need && pos < len) {
                p->hdr_buf[p->hdr_len++] = data[pos++];
            }
            if (p->hdr_len < p->hdr_need) break;

            if (p->hdr_need == 6) {
                if (memcmp(p->hdr_buf, "070707", 6) == 0) {
                    p->is_newc = 0;
                    p->hdr_need = 76;
                    continue;
                } else if (memcmp(p->hdr_buf, "070701", 6) == 0 || memcmp(p->hdr_buf, "070702", 6) == 0) {
                    p->is_newc = 1;
                    p->hdr_need = 110;
                    continue;
                } else {
                    mp_set_err(err, err_sz, "invalid cpio magic");
                    return MACPKG_ERR_CORRUPT;
                }
            }

            uint64_t mode = 0, nlink = 0, namesz = 0, filesz = 0;
            if (!p->is_newc) {
                if (parse_octal(p->hdr_buf + 6, 6, &p->file_dev) != 0 ||
                    parse_octal(p->hdr_buf + 12, 6, &p->file_ino) != 0 ||
                    parse_octal(p->hdr_buf + 18, 6, &mode) != 0 ||
                    parse_octal(p->hdr_buf + 36, 6, &nlink) != 0 ||
                    parse_octal(p->hdr_buf + 59, 6, &namesz) != 0 ||
                    parse_octal(p->hdr_buf + 65, 11, &filesz) != 0) {
                    mp_set_err(err, err_sz, "corrupt cpio odc header");
                    return MACPKG_ERR_CORRUPT;
                }
            } else {
                uint64_t maj = 0, min = 0;
                if (parse_hex(p->hdr_buf + 6, 8, &p->file_ino) != 0 ||
                    parse_hex(p->hdr_buf + 14, 8, &mode) != 0 ||
                    parse_hex(p->hdr_buf + 38, 8, &nlink) != 0 ||
                    parse_hex(p->hdr_buf + 54, 8, &filesz) != 0 ||
                    parse_hex(p->hdr_buf + 62, 8, &maj) != 0 ||
                    parse_hex(p->hdr_buf + 70, 8, &min) != 0 ||
                    parse_hex(p->hdr_buf + 94, 8, &namesz) != 0) {
                    mp_set_err(err, err_sz, "corrupt cpio newc header");
                    return MACPKG_ERR_CORRUPT;
                }
                p->file_dev = (maj << 32) | min;
            }

            if (namesz == 0 || namesz > 65536u) {
                mp_set_err(err, err_sz, "invalid cpio name size %llu", (unsigned long long)namesz);
                return MACPKG_ERR_CORRUPT;
            }
            p->file_mode = (uint32_t)mode;
            p->file_nlink = (uint32_t)nlink;
            p->file_size = filesz;
            p->name_len = (size_t)namesz;
            p->name_pos = 0;
            free(p->name_buf);
            p->name_buf = (char *)malloc(p->name_len + 1);
            if (!p->name_buf) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
            p->state = CPIO_STATE_NAME;
        } else if (p->state == CPIO_STATE_NAME) {
            size_t step = p->name_len - p->name_pos;
            if (step > len - pos) step = len - pos;
            memcpy(p->name_buf + p->name_pos, data + pos, step);
            p->name_pos += step;
            pos += step;
            if (p->name_pos == p->name_len) {
                p->name_buf[p->name_len] = '\0';
                if (p->is_newc && ((110u + p->name_len) % 4u) != 0) {
                    p->pad_rem = 4u - ((110u + p->name_len) % 4u);
                    p->state = CPIO_STATE_NAME_PAD;
                } else {
                    macpkg_status_t st = cpio_begin_entry(p, err, err_sz);
                    if (st != MACPKG_OK) return st;
                }
            }
        } else if (p->state == CPIO_STATE_NAME_PAD) {
            size_t step = (p->pad_rem > len - pos) ? (len - pos) : p->pad_rem;
            p->pad_rem -= step;
            pos += step;
            if (p->pad_rem == 0) {
                macpkg_status_t st = cpio_begin_entry(p, err, err_sz);
                if (st != MACPKG_OK) return st;
            }
        } else if (p->state == CPIO_STATE_DATA) {
            uint64_t rem = p->file_size - p->data_pos;
            size_t step = (rem > len - pos) ? (len - pos) : (size_t)rem;
            if (p->cur_keep) {
                if (S_ISLNK(p->file_mode) && p->symlink_buf) {
                    memcpy(p->symlink_buf + p->data_pos, data + pos, step);
                } else if (p->cur_fp) {
                    if (fwrite(data + pos, 1, step, p->cur_fp) != step) {
                        mp_set_err(err, err_sz, "write error on '%s'", p->cur_rel);
                        return MACPKG_ERR_IO;
                    }
                }
            }
            p->data_pos += step;
            pos += step;
            if (p->data_pos == p->file_size) {
                macpkg_status_t st = cpio_finish_entry_data(p, err, err_sz);
                if (st != MACPKG_OK) return st;
                if (p->is_newc && (p->file_size % 4u) != 0) {
                    p->pad_rem = 4u - (size_t)(p->file_size % 4u);
                    p->state = CPIO_STATE_DATA_PAD;
                } else {
                    p->hdr_len = 0;
                    p->hdr_need = 6;
                    p->state = CPIO_STATE_HDR;
                }
            }
        } else if (p->state == CPIO_STATE_DATA_PAD) {
            size_t step = (p->pad_rem > len - pos) ? (len - pos) : p->pad_rem;
            p->pad_rem -= step;
            pos += step;
            if (p->pad_rem == 0) {
                p->hdr_len = 0;
                p->hdr_need = 6;
                p->state = CPIO_STATE_HDR;
            }
        }
    }
    return MACPKG_OK;
}

static macpkg_status_t extract_payload_stream(const uint8_t *data, size_t len,
                                              mp_sink_t *sink, const macpkg_options_t *opts,
                                              char *err, size_t err_sz) {
    cpio_parser_t parser;
    memset(&parser, 0, sizeof(parser));
    parser.sink = sink;
    parser.opts = opts;
    parser.state = CPIO_STATE_HDR;
    parser.hdr_need = 6;

    macpkg_status_t st = MACPKG_OK;

    if (len >= 12 && memcmp(data, "pbzx", 4) == 0) {
        size_t pos = 12;
        while (pos + 16 <= len && parser.state != CPIO_STATE_DONE) {
            uint64_t u_len = mp_be64(data + pos);
            uint64_t c_len = mp_be64(data + pos + 8);
            pos += 16;
            if (c_len > len - pos) {
                mp_set_err(err, err_sz, "pbzx chunk truncated");
                st = MACPKG_ERR_CORRUPT;
                break;
            }
            if (c_len == u_len && (c_len < 6 || memcmp(data + pos, "\xfd""7zXZ\x00", 6) != 0)) {
                st = cpio_feed_cb(&parser, data + pos, (size_t)c_len, err, err_sz);
            } else {
                st = mp_decompress_stream_xz(data + pos, (size_t)c_len, cpio_feed_cb, &parser, err, err_sz);
            }
            if (st != MACPKG_OK) break;
            pos += (size_t)c_len;
        }
    } else if (len >= 2 && data[0] == 0x1F && data[1] == 0x8B) {
        st = mp_decompress_stream_gzip(data, len, cpio_feed_cb, &parser, err, err_sz);
    } else if (len >= 6 && memcmp(data, "\xfd""7zXZ\x00", 6) == 0) {
        st = mp_decompress_stream_xz(data, len, cpio_feed_cb, &parser, err, err_sz);
    } else if (len >= 6 && (memcmp(data, "070707", 6) == 0 ||
                            memcmp(data, "070701", 6) == 0 ||
                            memcmp(data, "070702", 6) == 0)) {
        st = cpio_feed_cb(&parser, data, len, err, err_sz);
    } else {
        mp_set_err(err, err_sz, "unrecognized .pkg Payload compression");
        st = MACPKG_ERR_UNSUPPORTED;
    }

    if (st == MACPKG_OK && parser.def_count > 0) {
        st = cpio_flush_all_deferred(&parser, err, err_sz);
    }

    cpio_parser_free(&parser);
    return st;
}

static int ends_with_payload(const char *rel_path) {
    const char *base = strrchr(rel_path, '/');
    base = base ? base + 1 : rel_path;
    return strcmp(base, "Payload") == 0;
}

macpkg_status_t mp_extract_pkg(macpkg_stream_t *stream, const char *output_dir,
                               const macpkg_options_t *opts, char *err, size_t err_sz) {
    if (stream->size < 28) {
        mp_set_err(err, err_sz, "file too small to be XAR .pkg");
        return MACPKG_ERR_FORMAT;
    }
    uint8_t hdr[28];
    macpkg_status_t st = mp_stream_read_exact(stream, 0, hdr, sizeof(hdr), err, err_sz);
    if (st != MACPKG_OK) return st;

    if (memcmp(hdr, "xar!", 4) != 0) {
        mp_set_err(err, err_sz, "missing 'xar!' magic");
        return MACPKG_ERR_FORMAT;
    }

    uint16_t hdr_size = mp_be16(hdr + 4);
    uint64_t toc_comp_len = mp_be64(hdr + 8);
    uint64_t toc_uncomp_len = mp_be64(hdr + 16);
    if (hdr_size < 28 || toc_comp_len == 0 || toc_uncomp_len == 0 ||
        toc_uncomp_len > 64ULL * 1024ULL * 1024ULL ||
        (uint64_t)hdr_size + toc_comp_len > stream->size) {
        mp_set_err(err, err_sz, "invalid XAR header dimensions");
        return MACPKG_ERR_CORRUPT;
    }

    uint8_t *toc_comp = (uint8_t *)malloc((size_t)toc_comp_len);
    char *toc_xml = (char *)malloc((size_t)toc_uncomp_len + 1);
    if (!toc_comp || !toc_xml) {
        free(toc_comp); free(toc_xml);
        mp_set_err(err, err_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }
    st = mp_stream_read_exact(stream, hdr_size, toc_comp, (size_t)toc_comp_len, err, err_sz);
    if (st != MACPKG_OK) { free(toc_comp); free(toc_xml); return st; }

    size_t got = 0;
    st = mp_decompress(MP_CODEC_ZLIB, toc_comp, (size_t)toc_comp_len,
                       (uint8_t *)toc_xml, (size_t)toc_uncomp_len, &got, err, err_sz);
    free(toc_comp);
    if (st != MACPKG_OK) { free(toc_xml); return st; }
    toc_xml[got] = '\0';

    mp_xar_file_t *files = NULL;
    st = mp_parse_xar_toc(toc_xml, got, &files, err, err_sz);
    free(toc_xml);
    if (st != MACPKG_OK) return st;

    uint64_t heap_base = (uint64_t)hdr_size + toc_comp_len;
    mp_sink_t sink;
    st = mp_sink_init(&sink, output_dir, opts ? opts->verbose : 0, err, err_sz);
    if (st != MACPKG_OK) { mp_free_xar_files(files); return st; }

    int found_payload = 0;
    for (mp_xar_file_t *f = files; f; f = f->next) {
        if (!ends_with_payload(f->rel_path)) continue;
        found_payload = 1;
        if (opts && opts->verbose) {
            fprintf(stderr, "pkg: extracting %s (%llu bytes)\n", f->rel_path,
                    (unsigned long long)f->length);
        }
        if (f->length > 1024ULL * 1024ULL * 1024ULL ||
            f->offset > stream->size - heap_base ||
            f->length > stream->size - heap_base - f->offset) {
            mp_set_err(err, err_sz, "invalid Payload bounds in XAR");
            st = MACPKG_ERR_CORRUPT;
            break;
        }
        uint8_t *pdata = (uint8_t *)malloc((size_t)f->length);
        if (!pdata) {
            mp_set_err(err, err_sz, "out of memory");
            st = MACPKG_ERR_NOMEM;
            break;
        }
        st = mp_stream_read_exact(stream, heap_base + f->offset, pdata, (size_t)f->length, err, err_sz);
        if (st != MACPKG_OK) { free(pdata); break; }

        /* Unwrap XAR outer encoding if not octet-stream */
        if (f->encoding && strstr(f->encoding, "x-gzip")) {
            uint8_t *unwrapped = NULL;
            size_t ulen = 0;
            st = mp_decompress_alloc(MP_CODEC_GZIP, pdata, (size_t)f->length, &unwrapped, &ulen, err, err_sz);
            free(pdata);
            if (st != MACPKG_OK) break;
            st = extract_payload_stream(unwrapped, ulen, &sink, opts, err, err_sz);
            free(unwrapped);
        } else if (f->encoding && strstr(f->encoding, "x-bzip2")) {
            uint8_t *unwrapped = NULL;
            size_t ulen = 0;
            st = mp_decompress_alloc(MP_CODEC_BZIP2, pdata, (size_t)f->length, &unwrapped, &ulen, err, err_sz);
            free(pdata);
            if (st != MACPKG_OK) break;
            st = extract_payload_stream(unwrapped, ulen, &sink, opts, err, err_sz);
            free(unwrapped);
        } else if (f->encoding && strstr(f->encoding, "x-xz")) {
            uint8_t *unwrapped = NULL;
            size_t ulen = 0;
            st = mp_decompress_alloc(MP_CODEC_XZ, pdata, (size_t)f->length, &unwrapped, &ulen, err, err_sz);
            free(pdata);
            if (st != MACPKG_OK) break;
            st = extract_payload_stream(unwrapped, ulen, &sink, opts, err, err_sz);
            free(unwrapped);
        } else {
            st = extract_payload_stream(pdata, (size_t)f->length, &sink, opts, err, err_sz);
            free(pdata);
        }
        if (st != MACPKG_OK) break;
    }

    size_t total_items = sink.files_written + sink.symlinks_written + sink.hardlinks_written + sink.dirs_created;
    mp_sink_finish(&sink);
    mp_free_xar_files(files);

    if (st != MACPKG_OK) return st;
    if (!found_payload || total_items == 0) {
        mp_set_err(err, err_sz, "no .app bundle found in .pkg Payload");
        return MACPKG_ERR_NOT_FOUND;
    }
    return MACPKG_OK;
}
