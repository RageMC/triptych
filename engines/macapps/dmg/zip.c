#include "macpkg_internal.h"
#include "zlib.h"
#include <sys/stat.h>

static voidpf zip_zalloc(voidpf opaque, uInt items, uInt size) {
    (void)opaque;
    return calloc(items, size);
}
static void zip_zfree(voidpf opaque, voidpf address) {
    (void)opaque;
    free(address);
}

static macpkg_status_t find_eocd(macpkg_stream_t *s, uint64_t *cd_off, uint64_t *cd_size,
                                 uint64_t *num_entries, char *err, size_t err_sz) {
    if (s->size < 22) {
        mp_set_err(err, err_sz, "file too small for ZIP");
        return MACPKG_ERR_FORMAT;
    }
    size_t tail_sz = (s->size > 65557ULL) ? 65557u : (size_t)s->size;
    uint64_t tail_off = s->size - tail_sz;
    uint8_t *tail = (uint8_t *)malloc(tail_sz);
    if (!tail) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }

    macpkg_status_t st = mp_stream_read_exact(s, tail_off, tail, tail_sz, err, err_sz);
    if (st != MACPKG_OK) { free(tail); return st; }

    ssize_t eocd_rel = -1;
    for (ssize_t i = (ssize_t)tail_sz - 22; i >= 0; i--) {
        if (tail[i] == 0x50 && tail[i + 1] == 0x4b && tail[i + 2] == 0x05 && tail[i + 3] == 0x06) {
            uint16_t clen = mp_le16(tail + i + 20);
            if ((size_t)i + 22u + clen == tail_sz) {
                eocd_rel = i;
                break;
            }
        }
    }
    if (eocd_rel < 0) {
        free(tail);
        mp_set_err(err, err_sz, "ZIP End of Central Directory not found");
        return MACPKG_ERR_FORMAT;
    }

    const uint8_t *eocd = tail + eocd_rel;
    uint16_t entries16 = mp_le16(eocd + 10);
    uint32_t cd_sz32 = mp_le32(eocd + 12);
    uint32_t cd_off32 = mp_le32(eocd + 16);
    uint64_t eocd_abs = tail_off + (uint64_t)eocd_rel;
    free(tail);

    *num_entries = entries16;
    *cd_size = cd_sz32;
    *cd_off = cd_off32;

    if (eocd_abs >= 20 && (entries16 == 0xFFFFu || cd_sz32 == 0xFFFFFFFFu || cd_off32 == 0xFFFFFFFFu)) {
        uint8_t loc[20];
        if (mp_stream_read_exact(s, eocd_abs - 20, loc, 20, err, err_sz) == MACPKG_OK &&
            loc[0] == 0x50 && loc[1] == 0x4b && loc[2] == 0x06 && loc[3] == 0x07) {
            uint64_t z64_off = mp_le64(loc + 8);
            uint8_t z64[56];
            st = mp_stream_read_exact(s, z64_off, z64, sizeof(z64), err, err_sz);
            if (st != MACPKG_OK) return st;
            if (z64[0] != 0x50 || z64[1] != 0x4b || z64[2] != 0x06 || z64[3] != 0x06) {
                mp_set_err(err, err_sz, "invalid Zip64 EOCD signature");
                return MACPKG_ERR_CORRUPT;
            }
            *num_entries = mp_le64(z64 + 32);
            *cd_size = mp_le64(z64 + 40);
            *cd_off = mp_le64(z64 + 48);
        }
    }

    if (*cd_off > s->size || *cd_size > s->size - *cd_off) {
        mp_set_err(err, err_sz, "ZIP Central Directory out of bounds");
        return MACPKG_ERR_CORRUPT;
    }
    return MACPKG_OK;
}

static macpkg_status_t zip_read_payload_to_buf(macpkg_stream_t *s, uint64_t data_off,
                                               uint64_t comp_sz, uint64_t uncomp_sz,
                                               uint16_t method, uint8_t **out_buf,
                                               char *err, size_t err_sz) {
    if (comp_sz > 64ULL * 1024ULL * 1024ULL || uncomp_sz > 64ULL * 1024ULL * 1024ULL) {
        mp_set_err(err, err_sz, "ZIP symlink buffer too large");
        return MACPKG_ERR_UNSUPPORTED;
    }
    uint8_t *cbuf = (uint8_t *)malloc(comp_sz ? (size_t)comp_sz : 1);
    if (!cbuf) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
    macpkg_status_t st = mp_stream_read_exact(s, data_off, cbuf, (size_t)comp_sz, err, err_sz);
    if (st != MACPKG_OK) { free(cbuf); return st; }

    if (method == 0) {
        if (comp_sz != uncomp_sz) {
            free(cbuf);
            mp_set_err(err, err_sz, "ZIP stored size mismatch");
            return MACPKG_ERR_CORRUPT;
        }
        *out_buf = cbuf;
        return MACPKG_OK;
    }
    if (method == 8) {
        uint8_t *ubuf = (uint8_t *)malloc(uncomp_sz ? (size_t)uncomp_sz : 1);
        if (!ubuf) { free(cbuf); mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
        size_t got = 0;
        st = mp_decompress(MP_CODEC_DEFLATE_RAW, cbuf, (size_t)comp_sz, ubuf, (size_t)uncomp_sz,
                           &got, err, err_sz);
        free(cbuf);
        if (st != MACPKG_OK || got != (size_t)uncomp_sz) {
            free(ubuf);
            return st != MACPKG_OK ? st : MACPKG_ERR_CORRUPT;
        }
        *out_buf = ubuf;
        return MACPKG_OK;
    }
    free(cbuf);
    mp_set_err(err, err_sz, "unsupported ZIP compression method %u", method);
    return MACPKG_ERR_UNSUPPORTED;
}

static macpkg_status_t zip_stream_entry_to_file(macpkg_stream_t *s, uint64_t data_off,
                                                uint64_t comp_sz, uint64_t uncomp_sz,
                                                uint16_t method, uint32_t expected_crc,
                                                FILE *fp, char *err, size_t err_sz) {
    uint8_t *in_buf = (uint8_t *)malloc(262144);
    uint8_t *out_buf = (uint8_t *)malloc(262144);
    if (!in_buf || !out_buf) {
        free(in_buf); free(out_buf);
        mp_set_err(err, err_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }

    uLong crc = crc32(0L, Z_NULL, 0);

    if (method == 0) {
        uint64_t pos = 0;
        while (pos < comp_sz) {
            size_t step = (comp_sz - pos > 262144u) ? 262144u : (size_t)(comp_sz - pos);
            macpkg_status_t st = mp_stream_read_exact(s, data_off + pos, in_buf, step, err, err_sz);
            if (st != MACPKG_OK) { free(in_buf); free(out_buf); return st; }
            crc = crc32(crc, in_buf, (uInt)step);
            if (fwrite(in_buf, 1, step, fp) != step) {
                free(in_buf); free(out_buf);
                mp_set_err(err, err_sz, "write error");
                return MACPKG_ERR_IO;
            }
            pos += step;
        }
    } else if (method == 8) {
        z_stream strm;
        memset(&strm, 0, sizeof(strm));
        strm.zalloc = zip_zalloc;
        strm.zfree = zip_zfree;
        if (inflateInit2(&strm, -15) != Z_OK) {
            free(in_buf); free(out_buf);
            mp_set_err(err, err_sz, "zlib inflateInit2 failed");
            return MACPKG_ERR_CORRUPT;
        }

        uint64_t in_pos = 0;
        uint64_t out_total = 0;
        for (;;) {
            if (strm.avail_in == 0 && in_pos < comp_sz) {
                size_t step = (comp_sz - in_pos > 262144u) ? 262144u : (size_t)(comp_sz - in_pos);
                macpkg_status_t st = mp_stream_read_exact(s, data_off + in_pos, in_buf, step, err, err_sz);
                if (st != MACPKG_OK) { inflateEnd(&strm); free(in_buf); free(out_buf); return st; }
                strm.next_in = in_buf;
                strm.avail_in = (uInt)step;
                in_pos += step;
            }
            strm.next_out = out_buf;
            strm.avail_out = 262144u;
            int rc = inflate(&strm, Z_NO_FLUSH);
            size_t produced = 262144u - strm.avail_out;
            if (produced > 0) {
                crc = crc32(crc, out_buf, (uInt)produced);
                if (fwrite(out_buf, 1, produced, fp) != produced) {
                    inflateEnd(&strm); free(in_buf); free(out_buf);
                    mp_set_err(err, err_sz, "write error");
                    return MACPKG_ERR_IO;
                }
                out_total += produced;
            }
            if (rc == Z_STREAM_END) break;
            if (rc != Z_OK || (produced == 0 && strm.avail_in == 0 && in_pos == comp_sz)) {
                inflateEnd(&strm); free(in_buf); free(out_buf);
                mp_set_err(err, err_sz, "ZIP deflate stream error (%d)", rc);
                return MACPKG_ERR_CORRUPT;
            }
        }
        inflateEnd(&strm);
        if (out_total != uncomp_sz) {
            free(in_buf); free(out_buf);
            mp_set_err(err, err_sz, "ZIP uncompressed size mismatch");
            return MACPKG_ERR_CORRUPT;
        }
    } else {
        free(in_buf); free(out_buf);
        mp_set_err(err, err_sz, "unsupported ZIP compression method %u", method);
        return MACPKG_ERR_UNSUPPORTED;
    }

    free(in_buf);
    free(out_buf);

    if ((uint32_t)crc != expected_crc) {
        mp_set_err(err, err_sz, "ZIP CRC-32 mismatch (got 0x%08x expected 0x%08x)",
                   (uint32_t)crc, expected_crc);
        return MACPKG_ERR_CORRUPT;
    }
    return MACPKG_OK;
}

macpkg_status_t mp_extract_zip(macpkg_stream_t *stream, const char *output_dir,
                               const macpkg_options_t *opts, char *err, size_t err_sz) {
    uint64_t cd_off = 0, cd_size = 0, num_entries = 0;
    macpkg_status_t st = find_eocd(stream, &cd_off, &cd_size, &num_entries, err, err_sz);
    if (st != MACPKG_OK) return st;

    if (cd_size > 128ULL * 1024ULL * 1024ULL) {
        mp_set_err(err, err_sz, "ZIP Central Directory too large");
        return MACPKG_ERR_UNSUPPORTED;
    }
    uint8_t *cd = (uint8_t *)malloc((size_t)cd_size);
    if (!cd) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
    st = mp_stream_read_exact(stream, cd_off, cd, (size_t)cd_size, err, err_sz);
    if (st != MACPKG_OK) { free(cd); return st; }

    mp_sink_t sink;
    st = mp_sink_init(&sink, output_dir, opts ? opts->verbose : 0, err, err_sz);
    if (st != MACPKG_OK) { free(cd); return st; }

    size_t pos = 0;
    for (uint64_t idx = 0; idx < num_entries && pos + 46 <= cd_size; idx++) {
        const uint8_t *e = cd + pos;
        if (e[0] != 0x50 || e[1] != 0x4b || e[2] != 0x01 || e[3] != 0x02) {
            mp_set_err(err, err_sz, "corrupt ZIP Central Directory entry");
            st = MACPKG_ERR_CORRUPT;
            break;
        }
        uint16_t ver_made = mp_le16(e + 4);
        uint16_t method = mp_le16(e + 10);
        uint32_t crc = mp_le32(e + 16);
        uint64_t comp_sz = mp_le32(e + 20);
        uint64_t uncomp_sz = mp_le32(e + 24);
        uint16_t fname_len = mp_le16(e + 28);
        uint16_t extra_len = mp_le16(e + 30);
        uint16_t comment_len = mp_le16(e + 32);
        uint32_t ext_attr = mp_le32(e + 38);
        uint64_t local_off = mp_le32(e + 42);

        if (pos + 46u + fname_len + extra_len + comment_len > cd_size) {
            mp_set_err(err, err_sz, "truncated ZIP Central Directory entry");
            st = MACPKG_ERR_CORRUPT;
            break;
        }

        const char *raw_name_ptr = (const char *)(e + 46);
        char *raw_name = (char *)malloc(fname_len + 1);
        if (!raw_name) { st = MACPKG_ERR_NOMEM; break; }
        memcpy(raw_name, raw_name_ptr, fname_len);
        raw_name[fname_len] = '\0';

        /* Parse Zip64 extra field (0x0001) if needed */
        if (comp_sz == 0xFFFFFFFFu || uncomp_sz == 0xFFFFFFFFu || local_off == 0xFFFFFFFFu) {
            const uint8_t *ex = e + 46 + fname_len;
            size_t ep = 0;
            while (ep + 4 <= extra_len) {
                uint16_t tag = mp_le16(ex + ep);
                uint16_t tsz = mp_le16(ex + ep + 2);
                ep += 4;
                if (ep + tsz > extra_len) break;
                if (tag == 0x0001u) {
                    size_t zp = 0;
                    if (uncomp_sz == 0xFFFFFFFFu && zp + 8 <= tsz) {
                        uncomp_sz = mp_le64(ex + ep + zp); zp += 8;
                    }
                    if (comp_sz == 0xFFFFFFFFu && zp + 8 <= tsz) {
                        comp_sz = mp_le64(ex + ep + zp); zp += 8;
                    }
                    if (local_off == 0xFFFFFFFFu && zp + 8 <= tsz) {
                        local_off = mp_le64(ex + ep + zp); zp += 8;
                    }
                }
                ep += tsz;
            }
        }

        pos += 46u + fname_len + extra_len + comment_len;

        int is_dir_name = (fname_len > 0 && raw_name[fname_len - 1] == '/');
        char rel_path[4096];
        int keep = mp_filter_app_relpath(raw_name, opts, rel_path, sizeof(rel_path));
        free(raw_name);
        if (!keep) continue;

        uint8_t made_os = (uint8_t)(ver_made >> 8);
        uint16_t unix_mode = (made_os == 3 || made_os == 19) ? (uint16_t)(ext_attr >> 16) : 0;

        if (S_ISDIR(unix_mode) || is_dir_name) {
            uint16_t perm = (unix_mode & 07777u) ? (unix_mode & 07777u) : 0755u;
            st = mp_sink_mkdir(&sink, rel_path, perm, err, err_sz);
            if (st != MACPKG_OK) break;
            continue;
        }

        uint8_t lfh[30];
        st = mp_stream_read_exact(stream, local_off, lfh, sizeof(lfh), err, err_sz);
        if (st != MACPKG_OK) break;
        if (lfh[0] != 0x50 || lfh[1] != 0x4b || lfh[2] != 0x03 || lfh[3] != 0x04) {
            mp_set_err(err, err_sz, "invalid ZIP local file header");
            st = MACPKG_ERR_CORRUPT;
            break;
        }
        uint64_t data_off = local_off + 30u + mp_le16(lfh + 26) + mp_le16(lfh + 28);

        if (S_ISLNK(unix_mode)) {
            uint8_t *tbuf = NULL;
            st = zip_read_payload_to_buf(stream, data_off, comp_sz, uncomp_sz, method, &tbuf, err, err_sz);
            if (st != MACPKG_OK) break;
            char *target = (char *)malloc((size_t)uncomp_sz + 1);
            if (!target) { free(tbuf); st = MACPKG_ERR_NOMEM; break; }
            memcpy(target, tbuf, (size_t)uncomp_sz);
            target[uncomp_sz] = '\0';
            free(tbuf);
            st = mp_sink_symlink(&sink, rel_path, target, err, err_sz);
            free(target);
            if (st != MACPKG_OK) break;
        } else {
            uint16_t perm = (unix_mode & 07777u) ? (unix_mode & 07777u) : 0644u;
            FILE *fp = NULL;
            char *full_path = NULL;
            st = mp_sink_begin_file(&sink, rel_path, perm, &fp, &full_path, err, err_sz);
            if (st != MACPKG_OK) break;
            st = zip_stream_entry_to_file(stream, data_off, comp_sz, uncomp_sz, method, crc, fp, err, err_sz);
            if (st != MACPKG_OK) {
                fclose(fp); free(full_path);
                break;
            }
            if (sink.verbose) {
                fprintf(stderr, "  file %s (%llu bytes, mode %04o)\n", rel_path,
                        (unsigned long long)uncomp_sz, perm);
            }
            st = mp_sink_end_file(fp, full_path, perm, err, err_sz);
            if (st != MACPKG_OK) break;
        }
    }

    size_t total_items = sink.files_written + sink.symlinks_written + sink.hardlinks_written + sink.dirs_created;
    mp_sink_finish(&sink);
    free(cd);

    if (st != MACPKG_OK) return st;
    if (total_items == 0) {
        mp_set_err(err, err_sz, "no .app bundle found in ZIP");
        return MACPKG_ERR_NOT_FOUND;
    }
    return MACPKG_OK;
}
