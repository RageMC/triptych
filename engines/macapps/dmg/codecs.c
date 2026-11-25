#include "macpkg_internal.h"
#include "bzlib.h"
#include "lzfse.h"
#include "lzvn_decode_base.h"
#include "xz.h"
#include "zlib.h"

/* Needed by libbzip2 when compiled with -DBZ_NO_STDIO */
void bz_internal_error(int errcode) {
    (void)errcode;
}

static voidpf mp_zalloc(voidpf opaque, uInt items, uInt size) {
    (void)opaque;
    return calloc(items, size);
}

static void mp_zfree(voidpf opaque, voidpf address) {
    (void)opaque;
    free(address);
}

static void mp_xz_global_init(void) {
    static int inited = 0;
    if (!inited) {
        xz_crc32_init();
        xz_crc64_init();
        inited = 1;
    }
}

/* ---- Apple Data Compression (ADC) ---- */
static macpkg_status_t decode_adc(const uint8_t *in, size_t in_len,
                                  uint8_t *out, size_t out_cap, size_t *out_len,
                                  char *err, size_t err_sz) {
    size_t ip = 0, op = 0;
    while (ip < in_len) {
        uint8_t b = in[ip++];
        if (b & 0x80) {
            size_t cnt = (size_t)(b & 0x7Fu) + 1u;
            if (ip + cnt > in_len || op + cnt > out_cap) {
                mp_set_err(err, err_sz, "ADC literal overflow");
                return MACPKG_ERR_CORRUPT;
            }
            memcpy(out + op, in + ip, cnt);
            ip += cnt;
            op += cnt;
        } else if (b & 0x40) {
            if (ip + 2 > in_len) {
                mp_set_err(err, err_sz, "ADC truncated 3-byte match");
                return MACPKG_ERR_CORRUPT;
            }
            size_t cnt = (size_t)(b & 0x3Fu) + 4u;
            size_t dist = ((size_t)in[ip] << 8 | in[ip + 1]) + 1u;
            ip += 2;
            if (dist > op || op + cnt > out_cap) {
                mp_set_err(err, err_sz, "ADC 3-byte match out of bounds");
                return MACPKG_ERR_CORRUPT;
            }
            for (size_t i = 0; i < cnt; i++) {
                out[op] = out[op - dist];
                op++;
            }
        } else {
            if (ip + 1 > in_len) {
                mp_set_err(err, err_sz, "ADC truncated 2-byte match");
                return MACPKG_ERR_CORRUPT;
            }
            size_t cnt = (size_t)((b & 0x3Fu) >> 2) + 3u;
            size_t dist = (((size_t)(b & 0x03u) << 8) | in[ip++]) + 1u;
            if (dist > op || op + cnt > out_cap) {
                mp_set_err(err, err_sz, "ADC 2-byte match out of bounds");
                return MACPKG_ERR_CORRUPT;
            }
            for (size_t i = 0; i < cnt; i++) {
                out[op] = out[op - dist];
                op++;
            }
        }
    }
    *out_len = op;
    return MACPKG_OK;
}

static macpkg_status_t decode_zlib_fixed(int window_bits, const uint8_t *in, size_t in_len,
                                         uint8_t *out, size_t out_cap, size_t *out_len,
                                         char *err, size_t err_sz) {
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.zalloc = mp_zalloc;
    strm.zfree = mp_zfree;
    strm.next_in = (Bytef *)in;
    strm.avail_in = (uInt)in_len;
    if (in_len > UINT32_MAX) {
        mp_set_err(err, err_sz, "zlib input too large");
        return MACPKG_ERR_UNSUPPORTED;
    }
    int rc = inflateInit2(&strm, window_bits);
    if (rc != Z_OK) {
        mp_set_err(err, err_sz, "inflateInit2 failed (%d)", rc);
        return MACPKG_ERR_CORRUPT;
    }
    strm.next_out = out;
    strm.avail_out = (uInt)(out_cap > UINT32_MAX ? UINT32_MAX : out_cap);
    rc = inflate(&strm, Z_FINISH);
    size_t produced = (size_t)strm.total_out;
    inflateEnd(&strm);
    if (rc != Z_STREAM_END && !(rc == Z_OK && strm.avail_in == 0 && produced == out_cap)) {
        mp_set_err(err, err_sz, "zlib inflate failed (%d)", rc);
        return MACPKG_ERR_CORRUPT;
    }
    *out_len = produced;
    return MACPKG_OK;
}

static macpkg_status_t decode_bzip2_fixed(const uint8_t *in, size_t in_len,
                                          uint8_t *out, size_t out_cap, size_t *out_len,
                                          char *err, size_t err_sz) {
    if (in_len > UINT32_MAX) {
        mp_set_err(err, err_sz, "bzip2 input too large");
        return MACPKG_ERR_UNSUPPORTED;
    }
    bz_stream strm;
    memset(&strm, 0, sizeof(strm));
    int rc = BZ2_bzDecompressInit(&strm, 0, 0);
    if (rc != BZ_OK) {
        mp_set_err(err, err_sz, "BZ2_bzDecompressInit failed (%d)", rc);
        return MACPKG_ERR_CORRUPT;
    }
    strm.next_in = (char *)in;
    strm.avail_in = (unsigned int)in_len;
    strm.next_out = (char *)out;
    strm.avail_out = (unsigned int)(out_cap > UINT32_MAX ? UINT32_MAX : out_cap);
    rc = BZ2_bzDecompress(&strm);
    size_t produced = ((size_t)strm.total_out_hi32 << 32) | strm.total_out_lo32;
    BZ2_bzDecompressEnd(&strm);
    if (rc != BZ_STREAM_END) {
        mp_set_err(err, err_sz, "bzip2 decompress failed (%d)", rc);
        return MACPKG_ERR_CORRUPT;
    }
    *out_len = produced;
    return MACPKG_OK;
}

static macpkg_status_t decode_xz_fixed(const uint8_t *in, size_t in_len,
                                       uint8_t *out, size_t out_cap, size_t *out_len,
                                       char *err, size_t err_sz) {
    mp_xz_global_init();
    struct xz_dec *dec = xz_dec_init(XZ_DYNALLOC, 64u * 1024u * 1024u);
    if (!dec) {
        mp_set_err(err, err_sz, "xz_dec_init failed");
        return MACPKG_ERR_NOMEM;
    }
    struct xz_buf b;
    b.in = in;
    b.in_pos = 0;
    b.in_size = in_len;
    b.out = out;
    b.out_pos = 0;
    b.out_size = out_cap;
    enum xz_ret ret;
    do {
        ret = xz_dec_run(dec, &b);
    } while (ret == XZ_UNSUPPORTED_CHECK || ret == XZ_OK);
    xz_dec_end(dec);
    if (ret != XZ_STREAM_END) {
        mp_set_err(err, err_sz, "xz_dec_run failed (%d)", (int)ret);
        return MACPKG_ERR_CORRUPT;
    }
    *out_len = b.out_pos;
    return MACPKG_OK;
}

macpkg_status_t mp_decompress(mp_codec_t codec, const uint8_t *in, size_t in_len,
                              uint8_t *out, size_t out_cap, size_t *out_len,
                              char *err, size_t err_sz) {
    switch (codec) {
        case MP_CODEC_RAW:
            if (in_len > out_cap) {
                mp_set_err(err, err_sz, "raw chunk larger than output buffer");
                return MACPKG_ERR_CORRUPT;
            }
            memcpy(out, in, in_len);
            *out_len = in_len;
            return MACPKG_OK;
        case MP_CODEC_ZLIB:
            return decode_zlib_fixed(15, in, in_len, out, out_cap, out_len, err, err_sz);
        case MP_CODEC_DEFLATE_RAW:
            return decode_zlib_fixed(-15, in, in_len, out, out_cap, out_len, err, err_sz);
        case MP_CODEC_GZIP:
            return decode_zlib_fixed(16 + 15, in, in_len, out, out_cap, out_len, err, err_sz);
        case MP_CODEC_BZIP2:
            return decode_bzip2_fixed(in, in_len, out, out_cap, out_len, err, err_sz);
        case MP_CODEC_LZFSE: {
            size_t scratch_sz = lzfse_decode_scratch_size();
            uint8_t *scratch = scratch_sz ? (uint8_t *)malloc(scratch_sz) : NULL;
            if (scratch_sz && !scratch) {
                mp_set_err(err, err_sz, "out of memory");
                return MACPKG_ERR_NOMEM;
            }
            size_t decoded = lzfse_decode_buffer(out, out_cap, in, in_len, scratch);
            free(scratch);
            if (decoded == 0 && out_cap > 0) {
                mp_set_err(err, err_sz, "lzfse_decode_buffer failed");
                return MACPKG_ERR_CORRUPT;
            }
            *out_len = decoded;
            return MACPKG_OK;
        }
        case MP_CODEC_LZVN: {
            lzvn_decoder_state st;
            memset(&st, 0, sizeof(st));
            st.src = in;
            st.src_end = in + in_len;
            st.dst = out;
            st.dst_begin = out;
            st.dst_end = out + out_cap;
            lzvn_decode(&st);
            *out_len = (size_t)(st.dst - out);
            return MACPKG_OK;
        }
        case MP_CODEC_XZ:
            return decode_xz_fixed(in, in_len, out, out_cap, out_len, err, err_sz);
        case MP_CODEC_ADC:
            return decode_adc(in, in_len, out, out_cap, out_len, err, err_sz);
        default:
            mp_set_err(err, err_sz, "unsupported codec %d", (int)codec);
            return MACPKG_ERR_UNSUPPORTED;
    }
}

typedef struct {
    uint8_t *buf;
    size_t len;
    size_t cap;
} mp_grow_ctx_t;

static macpkg_status_t grow_write_cb(void *ctx, const uint8_t *data, size_t len,
                                     char *err, size_t err_sz) {
    mp_grow_ctx_t *g = (mp_grow_ctx_t *)ctx;
    if (len == 0) return MACPKG_OK;
    if (g->len + len > g->cap) {
        size_t ncap = g->cap ? g->cap * 2 : 65536;
        while (ncap < g->len + len) {
            if (ncap > SIZE_MAX / 2) {
                mp_set_err(err, err_sz, "decompressed output too large");
                return MACPKG_ERR_NOMEM;
            }
            ncap *= 2;
        }
        uint8_t *nb = (uint8_t *)realloc(g->buf, ncap);
        if (!nb) {
            mp_set_err(err, err_sz, "out of memory");
            return MACPKG_ERR_NOMEM;
        }
        g->buf = nb;
        g->cap = ncap;
    }
    memcpy(g->buf + g->len, data, len);
    g->len += len;
    return MACPKG_OK;
}

macpkg_status_t mp_decompress_stream_xz(const uint8_t *in, size_t in_len,
                                        mp_write_cb cb, void *cb_ctx,
                                        char *err, size_t err_sz) {
    mp_xz_global_init();
    struct xz_dec *dec = xz_dec_init(XZ_DYNALLOC, 64u * 1024u * 1024u);
    if (!dec) {
        mp_set_err(err, err_sz, "xz_dec_init failed");
        return MACPKG_ERR_NOMEM;
    }
    uint8_t *tmp = (uint8_t *)malloc(131072);
    if (!tmp) {
        xz_dec_end(dec);
        mp_set_err(err, err_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }
    struct xz_buf b;
    b.in = in;
    b.in_pos = 0;
    b.in_size = in_len;
    b.out = tmp;
    b.out_size = 131072;

    macpkg_status_t st = MACPKG_OK;
    for (;;) {
        b.out_pos = 0;
        enum xz_ret ret = xz_dec_run(dec, &b);
        if (b.out_pos > 0) {
            st = cb(cb_ctx, tmp, b.out_pos, err, err_sz);
            if (st != MACPKG_OK) break;
        }
        if (ret == XZ_STREAM_END) break;
        if ((ret == XZ_OK || ret == XZ_UNSUPPORTED_CHECK) &&
            !(b.in_pos == in_len && b.out_pos == 0)) {
            continue;
        }
        mp_set_err(err, err_sz, "xz stream decode error (%d)", (int)ret);
        st = MACPKG_ERR_CORRUPT;
        break;
    }
    free(tmp);
    xz_dec_end(dec);
    return st;
}

static macpkg_status_t decompress_stream_zlib_wbits(int window_bits, const uint8_t *in, size_t in_len,
                                                    mp_write_cb cb, void *cb_ctx,
                                                    char *err, size_t err_sz) {
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.zalloc = mp_zalloc;
    strm.zfree = mp_zfree;
    int rc = inflateInit2(&strm, window_bits);
    if (rc != Z_OK) {
        mp_set_err(err, err_sz, "inflateInit2 failed (%d)", rc);
        return MACPKG_ERR_CORRUPT;
    }
    uint8_t *tmp = (uint8_t *)malloc(131072);
    if (!tmp) {
        inflateEnd(&strm);
        mp_set_err(err, err_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }

    size_t ip = 0;
    macpkg_status_t st = MACPKG_OK;
    for (;;) {
        if (strm.avail_in == 0 && ip < in_len) {
            size_t chunk = in_len - ip;
            if (chunk > 0x40000000u) chunk = 0x40000000u;
            strm.next_in = (Bytef *)(in + ip);
            strm.avail_in = (uInt)chunk;
            ip += chunk;
        }
        strm.next_out = tmp;
        strm.avail_out = 131072;
        rc = inflate(&strm, Z_NO_FLUSH);
        size_t produced = 131072u - strm.avail_out;
        if (produced > 0) {
            st = cb(cb_ctx, tmp, produced, err, err_sz);
            if (st != MACPKG_OK) break;
        }
        if (rc == Z_STREAM_END) break;
        if (rc != Z_OK) {
            mp_set_err(err, err_sz, "zlib stream inflate error (%d)", rc);
            st = MACPKG_ERR_CORRUPT;
            break;
        }
    }
    free(tmp);
    inflateEnd(&strm);
    return st;
}

macpkg_status_t mp_decompress_stream_gzip(const uint8_t *in, size_t in_len,
                                          mp_write_cb cb, void *cb_ctx,
                                          char *err, size_t err_sz) {
    return decompress_stream_zlib_wbits(16 + 15, in, in_len, cb, cb_ctx, err, err_sz);
}

macpkg_status_t mp_decompress_alloc(mp_codec_t codec, const uint8_t *in, size_t in_len,
                                    uint8_t **out_buf, size_t *out_len,
                                    char *err, size_t err_sz) {
    mp_grow_ctx_t g = {NULL, 0, 0};
    macpkg_status_t st;
    if (codec == MP_CODEC_ZLIB) {
        st = decompress_stream_zlib_wbits(15, in, in_len, grow_write_cb, &g, err, err_sz);
    } else if (codec == MP_CODEC_DEFLATE_RAW) {
        st = decompress_stream_zlib_wbits(-15, in, in_len, grow_write_cb, &g, err, err_sz);
    } else if (codec == MP_CODEC_GZIP) {
        st = decompress_stream_zlib_wbits(16 + 15, in, in_len, grow_write_cb, &g, err, err_sz);
    } else if (codec == MP_CODEC_XZ) {
        st = mp_decompress_stream_xz(in, in_len, grow_write_cb, &g, err, err_sz);
    } else if (codec == MP_CODEC_BZIP2) {
        bz_stream strm;
        memset(&strm, 0, sizeof(strm));
        if (BZ2_bzDecompressInit(&strm, 0, 0) != BZ_OK) {
            mp_set_err(err, err_sz, "BZ2_bzDecompressInit failed");
            return MACPKG_ERR_CORRUPT;
        }
        uint8_t tmp[65536];
        size_t ip = 0;
        for (;;) {
            if (strm.avail_in == 0 && ip < in_len) {
                size_t chunk = in_len - ip;
                if (chunk > 0x40000000u) chunk = 0x40000000u;
                strm.next_in = (char *)(in + ip);
                strm.avail_in = (unsigned int)chunk;
                ip += chunk;
            }
            strm.next_out = (char *)tmp;
            strm.avail_out = sizeof(tmp);
            int rc = BZ2_bzDecompress(&strm);
            size_t produced = sizeof(tmp) - strm.avail_out;
            if (produced > 0) {
                st = grow_write_cb(&g, tmp, produced, err, err_sz);
                if (st != MACPKG_OK) { BZ2_bzDecompressEnd(&strm); free(g.buf); return st; }
            }
            if (rc == BZ_STREAM_END) { st = MACPKG_OK; break; }
            if (rc != BZ_OK || (produced == 0 && strm.avail_in == 0 && ip == in_len)) {
                mp_set_err(err, err_sz, "bzip2 stream error (%d)", rc);
                BZ2_bzDecompressEnd(&strm);
                free(g.buf);
                return MACPKG_ERR_CORRUPT;
            }
        }
        BZ2_bzDecompressEnd(&strm);
    } else if (codec == MP_CODEC_LZFSE) {
        size_t cap = in_len * 4 + 4096;
        size_t scratch_sz = lzfse_decode_scratch_size();
        uint8_t *scratch = scratch_sz ? (uint8_t *)malloc(scratch_sz) : NULL;
        for (;;) {
            uint8_t *buf = (uint8_t *)malloc(cap);
            if (!buf) { free(scratch); mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
            size_t n = lzfse_decode_buffer(buf, cap, in, in_len, scratch);
            if (n < cap) {
                free(scratch);
                if (n == 0 && in_len > 0) {
                    free(buf);
                    mp_set_err(err, err_sz, "lzfse_decode_buffer failed");
                    return MACPKG_ERR_CORRUPT;
                }
                *out_buf = buf;
                *out_len = n;
                return MACPKG_OK;
            }
            free(buf);
            if (cap > SIZE_MAX / 2) {
                free(scratch);
                mp_set_err(err, err_sz, "lzfse output too large");
                return MACPKG_ERR_NOMEM;
            }
            cap *= 2;
        }
    } else {
        mp_set_err(err, err_sz, "alloc decompression unsupported for codec %d", (int)codec);
        return MACPKG_ERR_UNSUPPORTED;
    }

    if (st != MACPKG_OK) {
        free(g.buf);
        return st;
    }
    *out_buf = g.buf;
    *out_len = g.len;
    return MACPKG_OK;
}

/* ---- decmpfs (Apple HFS+/APFS transparent compression) ---- */
macpkg_status_t mp_decode_decmpfs(const uint8_t *xattr, size_t xattr_len,
                                  const uint8_t *rsrc_fork, size_t rsrc_len,
                                  uint8_t **out_buf, size_t *out_len,
                                  char *err, size_t err_sz) {
    if (!xattr || xattr_len < 16) {
        mp_set_err(err, err_sz, "decmpfs xattr too short");
        return MACPKG_ERR_CORRUPT;
    }
    uint32_t magic = mp_le32(xattr);
    uint32_t ctype = mp_le32(xattr + 4);
    uint64_t usize = mp_le64(xattr + 8);
    if (magic != 0x636d7066u) { /* "fpmc" ('cmpf' LE) */
        mp_set_err(err, err_sz, "invalid decmpfs magic 0x%08x", magic);
        return MACPKG_ERR_CORRUPT;
    }
    if (usize > 1024ULL * 1024ULL * 1024ULL) {
        mp_set_err(err, err_sz, "decmpfs file too large (%llu)", (unsigned long long)usize);
        return MACPKG_ERR_UNSUPPORTED;
    }
    uint8_t *out = (uint8_t *)malloc(usize ? (size_t)usize : 1);
    if (!out) {
        mp_set_err(err, err_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }
    if (usize == 0) {
        *out_buf = out;
        *out_len = 0;
        return MACPKG_OK;
    }

    const uint8_t *inline_data = xattr + 16;
    size_t inline_len = xattr_len - 16;

    if (ctype == 3) {
        /* zlib inline */
        if (inline_len >= 1 && (inline_data[0] & 0x0Fu) == 0x0Fu) {
            if (inline_len - 1 < (size_t)usize) {
                free(out);
                mp_set_err(err, err_sz, "decmpfs type 3 uncompressed truncated");
                return MACPKG_ERR_CORRUPT;
            }
            memcpy(out, inline_data + 1, (size_t)usize);
        } else {
            size_t got = 0;
            macpkg_status_t st = mp_decompress(MP_CODEC_ZLIB, inline_data, inline_len,
                                               out, (size_t)usize, &got, err, err_sz);
            if (st != MACPKG_OK || got != (size_t)usize) {
                free(out);
                return st != MACPKG_OK ? st : MACPKG_ERR_CORRUPT;
            }
        }
    } else if (ctype == 4) {
        /* zlib in resource fork */
        if (!rsrc_fork || rsrc_len < 16) {
            free(out);
            mp_set_err(err, err_sz, "decmpfs type 4 missing resource fork");
            return MACPKG_ERR_CORRUPT;
        }
        uint32_t data_off = mp_be32(rsrc_fork);
        uint32_t data_len = mp_be32(rsrc_fork + 8);
        if ((uint64_t)data_off + data_len > rsrc_len || data_len < 8) {
            free(out);
            mp_set_err(err, err_sz, "decmpfs type 4 invalid resource fork header");
            return MACPKG_ERR_CORRUPT;
        }
        const uint8_t *table = rsrc_fork + data_off + 4;
        size_t table_max = data_len - 4;
        uint32_t num_chunks = mp_le32(table);
        if (4ULL + (uint64_t)num_chunks * 8ULL > table_max) {
            free(out);
            mp_set_err(err, err_sz, "decmpfs type 4 chunk table out of bounds");
            return MACPKG_ERR_CORRUPT;
        }
        size_t pos = 0;
        for (uint32_t i = 0; i < num_chunks; i++) {
            uint32_t coff = mp_le32(table + 4 + i * 8);
            uint32_t clen = mp_le32(table + 4 + i * 8 + 4);
            if ((uint64_t)coff + clen > table_max || clen == 0) {
                free(out);
                mp_set_err(err, err_sz, "decmpfs type 4 chunk %u out of bounds", i);
                return MACPKG_ERR_CORRUPT;
            }
            size_t expect = (size_t)usize - pos;
            if (expect > 65536u) expect = 65536u;
            const uint8_t *cd = table + coff;
            if ((cd[0] & 0x0Fu) == 0x0Fu) {
                if (clen - 1 < expect) {
                    free(out);
                    mp_set_err(err, err_sz, "decmpfs type 4 raw chunk truncated");
                    return MACPKG_ERR_CORRUPT;
                }
                memcpy(out + pos, cd + 1, expect);
            } else {
                size_t got = 0;
                macpkg_status_t st = mp_decompress(MP_CODEC_ZLIB, cd, clen,
                                                   out + pos, expect, &got, err, err_sz);
                if (st != MACPKG_OK || got != expect) {
                    free(out);
                    return st != MACPKG_OK ? st : MACPKG_ERR_CORRUPT;
                }
            }
            pos += expect;
        }
        if (pos != (size_t)usize) {
            free(out);
            mp_set_err(err, err_sz, "decmpfs type 4 size mismatch");
            return MACPKG_ERR_CORRUPT;
        }
    } else if (ctype == 7) {
        /* LZVN inline */
        if (inline_len >= 1 && inline_data[0] == 0x06) {
            if (inline_len - 1 < (size_t)usize) {
                free(out);
                mp_set_err(err, err_sz, "decmpfs type 7 raw truncated");
                return MACPKG_ERR_CORRUPT;
            }
            memcpy(out, inline_data + 1, (size_t)usize);
        } else {
            size_t got = 0;
            macpkg_status_t st = mp_decompress(MP_CODEC_LZVN, inline_data, inline_len,
                                               out, (size_t)usize, &got, err, err_sz);
            if (st != MACPKG_OK || got != (size_t)usize) {
                free(out);
                return st != MACPKG_OK ? st : MACPKG_ERR_CORRUPT;
            }
        }
    } else if (ctype == 8) {
        /* LZVN in resource fork (table of uint32le offsets) */
        if (!rsrc_fork || rsrc_len < 8) {
            free(out);
            mp_set_err(err, err_sz, "decmpfs type 8 missing resource fork");
            return MACPKG_ERR_CORRUPT;
        }
        /* Check if wrapped in Mac resource fork header or raw chunk offsets */
        const uint8_t *base = rsrc_fork;
        size_t blen = rsrc_len;
        if (rsrc_len >= 260 && mp_be32(rsrc_fork) == 256) {
            uint32_t doff = mp_be32(rsrc_fork);
            uint32_t dlen = mp_be32(rsrc_fork + 8);
            if ((uint64_t)doff + dlen <= rsrc_len && dlen >= 8) {
                base = rsrc_fork + doff + 4;
                blen = dlen - 4;
            }
        }
        uint32_t first_off = mp_le32(base);
        if (first_off < 4 || first_off > blen || (first_off % 4) != 0) {
            free(out);
            mp_set_err(err, err_sz, "decmpfs type 8 invalid offset table");
            return MACPKG_ERR_CORRUPT;
        }
        uint32_t num_chunks = (uint32_t)((usize + 65535u) / 65536u);
        if ((uint64_t)(num_chunks + 1) * 4ULL > blen) {
            free(out);
            mp_set_err(err, err_sz, "decmpfs type 8 table truncated");
            return MACPKG_ERR_CORRUPT;
        }
        size_t pos = 0;
        for (uint32_t i = 0; i < num_chunks; i++) {
            uint32_t s_off = mp_le32(base + i * 4);
            uint32_t e_off = mp_le32(base + (i + 1) * 4);
            if (e_off <= s_off || e_off > blen) {
                free(out);
                mp_set_err(err, err_sz, "decmpfs type 8 chunk %u bounds error", i);
                return MACPKG_ERR_CORRUPT;
            }
            size_t expect = (size_t)usize - pos;
            if (expect > 65536u) expect = 65536u;
            const uint8_t *cd = base + s_off;
            size_t clen = e_off - s_off;
            if (cd[0] == 0x06) {
                if (clen - 1 < expect) {
                    free(out);
                    mp_set_err(err, err_sz, "decmpfs type 8 raw chunk truncated");
                    return MACPKG_ERR_CORRUPT;
                }
                memcpy(out + pos, cd + 1, expect);
            } else {
                size_t got = 0;
                macpkg_status_t st = mp_decompress(MP_CODEC_LZVN, cd, clen,
                                                   out + pos, expect, &got, err, err_sz);
                if (st != MACPKG_OK || got != expect) {
                    free(out);
                    return st != MACPKG_OK ? st : MACPKG_ERR_CORRUPT;
                }
            }
            pos += expect;
        }
    } else if (ctype == 11) {
        /* LZFSE inline */
        if (inline_len >= 1 && inline_data[0] == 0x06) {
            if (inline_len - 1 < (size_t)usize) {
                free(out);
                mp_set_err(err, err_sz, "decmpfs type 11 raw truncated");
                return MACPKG_ERR_CORRUPT;
            }
            memcpy(out, inline_data + 1, (size_t)usize);
        } else {
            size_t got = 0;
            macpkg_status_t st = mp_decompress(MP_CODEC_LZFSE, inline_data, inline_len,
                                               out, (size_t)usize, &got, err, err_sz);
            if (st != MACPKG_OK || got != (size_t)usize) {
                free(out);
                return st != MACPKG_OK ? st : MACPKG_ERR_CORRUPT;
            }
        }
    } else if (ctype == 12) {
        /* LZFSE in resource fork (same offset table layout as type 8) */
        if (!rsrc_fork || rsrc_len < 8) {
            free(out);
            mp_set_err(err, err_sz, "decmpfs type 12 missing resource fork");
            return MACPKG_ERR_CORRUPT;
        }
        const uint8_t *base = rsrc_fork;
        size_t blen = rsrc_len;
        if (rsrc_len >= 260 && mp_be32(rsrc_fork) == 256) {
            uint32_t doff = mp_be32(rsrc_fork);
            uint32_t dlen = mp_be32(rsrc_fork + 8);
            if ((uint64_t)doff + dlen <= rsrc_len && dlen >= 8) {
                base = rsrc_fork + doff + 4;
                blen = dlen - 4;
            }
        }
        uint32_t num_chunks = (uint32_t)((usize + 65535u) / 65536u);
        if ((uint64_t)(num_chunks + 1) * 4ULL > blen) {
            free(out);
            mp_set_err(err, err_sz, "decmpfs type 12 table truncated");
            return MACPKG_ERR_CORRUPT;
        }
        size_t pos = 0;
        for (uint32_t i = 0; i < num_chunks; i++) {
            uint32_t s_off = mp_le32(base + i * 4);
            uint32_t e_off = mp_le32(base + (i + 1) * 4);
            if (e_off <= s_off || e_off > blen) {
                free(out);
                mp_set_err(err, err_sz, "decmpfs type 12 chunk %u bounds error", i);
                return MACPKG_ERR_CORRUPT;
            }
            size_t expect = (size_t)usize - pos;
            if (expect > 65536u) expect = 65536u;
            const uint8_t *cd = base + s_off;
            size_t clen = e_off - s_off;
            if (cd[0] == 0x06) {
                if (clen - 1 < expect) {
                    free(out);
                    mp_set_err(err, err_sz, "decmpfs type 12 raw chunk truncated");
                    return MACPKG_ERR_CORRUPT;
                }
                memcpy(out + pos, cd + 1, expect);
            } else {
                size_t got = 0;
                macpkg_status_t st = mp_decompress(MP_CODEC_LZFSE, cd, clen,
                                                   out + pos, expect, &got, err, err_sz);
                if (st != MACPKG_OK || got != expect) {
                    free(out);
                    return st != MACPKG_OK ? st : MACPKG_ERR_CORRUPT;
                }
            }
            pos += expect;
        }
    } else {
        free(out);
        mp_set_err(err, err_sz, "unsupported decmpfs compression type %u", ctype);
        return MACPKG_ERR_UNSUPPORTED;
    }

    *out_buf = out;
    *out_len = (size_t)usize;
    return MACPKG_OK;
}
