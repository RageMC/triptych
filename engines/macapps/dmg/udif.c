#include "macpkg_internal.h"

#define UDIF_CHUNK_ZERO     0x00000000u
#define UDIF_CHUNK_RAW      0x00000001u
#define UDIF_CHUNK_IGNORE   0x00000002u
#define UDIF_CHUNK_ADC      0x80000004u
#define UDIF_CHUNK_ZLIB     0x80000005u
#define UDIF_CHUNK_BZIP2    0x80000006u
#define UDIF_CHUNK_LZFSE    0x80000007u
#define UDIF_CHUNK_LZMA     0x80000008u
#define UDIF_CHUNK_COMMENT  0x7ffffffeu
#define UDIF_CHUNK_TERM     0xffffffffu

#define UDIF_CACHE_SLOTS 16

typedef struct {
    uint32_t type;
    uint64_t sector_off;
    uint64_t sector_cnt;
    uint64_t comp_off;
    uint64_t comp_len;
} udif_chunk_t;

typedef struct {
    size_t chunk_idx;
    uint8_t *data;
    size_t size;
    uint64_t lru_tick;
    int valid;
} udif_cache_slot_t;

typedef struct {
    macpkg_stream_t *dmg;
    uint64_t data_base;
    uint64_t sector_count;
    udif_chunk_t *chunks;
    size_t num_chunks;
    udif_cache_slot_t cache[UDIF_CACHE_SLOTS];
    uint64_t tick;
} udif_part_ctx_t;

static int cmp_chunk_sector(const void *a, const void *b) {
    const udif_chunk_t *ca = (const udif_chunk_t *)a;
    const udif_chunk_t *cb = (const udif_chunk_t *)b;
    if (ca->sector_off < cb->sector_off) return -1;
    if (ca->sector_off > cb->sector_off) return 1;
    return 0;
}

static ssize_t find_chunk(const udif_part_ctx_t *ctx, uint64_t sector) {
    size_t lo = 0, hi = ctx->num_chunks;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        const udif_chunk_t *c = &ctx->chunks[mid];
        if (sector < c->sector_off) {
            hi = mid;
        } else if (sector >= c->sector_off + c->sector_cnt) {
            lo = mid + 1;
        } else {
            return (ssize_t)mid;
        }
    }
    return -1;
}

static int udif_decode_chunk(udif_part_ctx_t *ctx, size_t idx, uint8_t **out_data, size_t *out_sz) {
    for (int i = 0; i < UDIF_CACHE_SLOTS; i++) {
        if (ctx->cache[i].valid && ctx->cache[i].chunk_idx == idx) {
            ctx->cache[i].lru_tick = ++ctx->tick;
            *out_data = ctx->cache[i].data;
            *out_sz = ctx->cache[i].size;
            return 0;
        }
    }

    const udif_chunk_t *c = &ctx->chunks[idx];
    if (c->sector_cnt > (SIZE_MAX / 512u)) return -1;
    size_t usize = (size_t)(c->sector_cnt * 512u);
    if (usize > 128u * 1024u * 1024u) return -1;

    uint8_t *ubuf = (uint8_t *)malloc(usize ? usize : 1);
    if (!ubuf) return -1;

    mp_codec_t codec = MP_CODEC_RAW;
    switch (c->type) {
        case UDIF_CHUNK_RAW:   codec = MP_CODEC_RAW; break;
        case UDIF_CHUNK_ADC:   codec = MP_CODEC_ADC; break;
        case UDIF_CHUNK_ZLIB:  codec = MP_CODEC_ZLIB; break;
        case UDIF_CHUNK_BZIP2: codec = MP_CODEC_BZIP2; break;
        case UDIF_CHUNK_LZFSE: codec = MP_CODEC_LZFSE; break;
        case UDIF_CHUNK_LZMA:  codec = MP_CODEC_XZ; break;
        default: free(ubuf); return -1;
    }

    if (c->comp_len > 128u * 1024u * 1024u || c->comp_off > UINT64_MAX - ctx->data_base) {
        free(ubuf);
        return -1;
    }
    uint8_t *cbuf = (uint8_t *)malloc(c->comp_len ? (size_t)c->comp_len : 1);
    if (!cbuf) {
        free(ubuf);
        return -1;
    }
    char err[128];
    if (mp_stream_read_exact(ctx->dmg, ctx->data_base + c->comp_off, cbuf, (size_t)c->comp_len,
                             err, sizeof(err)) != MACPKG_OK) {
        free(cbuf);
        free(ubuf);
        return -1;
    }

    size_t got = 0;
    macpkg_status_t st = mp_decompress(codec, cbuf, (size_t)c->comp_len, ubuf, usize, &got,
                                       err, sizeof(err));
    free(cbuf);
    if (st != MACPKG_OK || got != usize) {
        free(ubuf);
        return -1;
    }

    /* Evict LRU slot */
    int victim = 0;
    uint64_t oldest = UINT64_MAX;
    for (int i = 0; i < UDIF_CACHE_SLOTS; i++) {
        if (!ctx->cache[i].valid) { victim = i; break; }
        if (ctx->cache[i].lru_tick < oldest) {
            oldest = ctx->cache[i].lru_tick;
            victim = i;
        }
    }
    free(ctx->cache[victim].data);
    ctx->cache[victim].data = ubuf;
    ctx->cache[victim].size = usize;
    ctx->cache[victim].chunk_idx = idx;
    ctx->cache[victim].lru_tick = ++ctx->tick;
    ctx->cache[victim].valid = 1;

    *out_data = ubuf;
    *out_sz = usize;
    return 0;
}

static int udif_part_read_at(void *vctx, uint64_t offset, void *buf, size_t len) {
    udif_part_ctx_t *ctx = (udif_part_ctx_t *)vctx;
    uint64_t total_bytes = ctx->sector_count * 512ULL;
    if (offset > total_bytes || len > total_bytes - offset) return -1;

    uint8_t *dst = (uint8_t *)buf;
    size_t done = 0;
    while (done < len) {
        uint64_t cur = offset + done;
        uint64_t sec = cur / 512ULL;
        ssize_t cidx = find_chunk(ctx, sec);
        if (cidx < 0) {
            /* Unmapped gap = zero fill */
            size_t step = 512u - (size_t)(cur % 512ULL);
            if (step > len - done) step = len - done;
            memset(dst + done, 0, step);
            done += step;
            continue;
        }
        const udif_chunk_t *c = &ctx->chunks[cidx];
        uint64_t chunk_start = c->sector_off * 512ULL;
        uint64_t chunk_end = (c->sector_off + c->sector_cnt) * 512ULL;
        size_t in_chunk = (size_t)(cur - chunk_start);
        size_t avail = (size_t)(chunk_end - cur);
        if (avail > len - done) avail = len - done;

        if (c->type == UDIF_CHUNK_ZERO || c->type == UDIF_CHUNK_IGNORE) {
            memset(dst + done, 0, avail);
            done += avail;
            continue;
        }
        if (c->type == UDIF_CHUNK_RAW && c->sector_cnt * 512ULL > 2u * 1024u * 1024u) {
            if (c->comp_off > UINT64_MAX - ctx->data_base ||
                in_chunk > UINT64_MAX - (ctx->data_base + c->comp_off)) {
                return -1;
            }
            if (ctx->dmg->read_at(ctx->dmg->ctx, ctx->data_base + c->comp_off + in_chunk,
                                  dst + done, avail) != 0) {
                return -1;
            }
            done += avail;
            continue;
        }
        uint8_t *cdata = NULL;
        size_t csz = 0;
        if (udif_decode_chunk(ctx, (size_t)cidx, &cdata, &csz) != 0) return -1;
        if (in_chunk + avail > csz) return -1;
        memcpy(dst + done, cdata + in_chunk, avail);
        done += avail;
    }
    return 0;
}

static void udif_part_close(void *vctx) {
    udif_part_ctx_t *ctx = (udif_part_ctx_t *)vctx;
    if (!ctx) return;
    for (int i = 0; i < UDIF_CACHE_SLOTS; i++) {
        free(ctx->cache[i].data);
    }
    free(ctx->chunks);
    free(ctx);
}

static macpkg_status_t open_blkx_partition(macpkg_stream_t *dmg, uint64_t data_fork_off,
                                           const mp_blkx_entry_t *entry,
                                           macpkg_stream_t *out_part,
                                           char *err, size_t err_sz) {
    if (entry->data_len < 204) {
        mp_set_err(err, err_sz, "mish header too short");
        return MACPKG_ERR_CORRUPT;
    }
    const uint8_t *d = entry->data;
    if (memcmp(d, "mish", 4) != 0) {
        mp_set_err(err, err_sz, "invalid mish signature");
        return MACPKG_ERR_CORRUPT;
    }
    uint64_t sector_count = mp_be64(d + 16);
    uint64_t data_start = mp_be64(d + 24);
    uint32_t num_chunks = mp_be32(d + 200);
    if (sector_count > UINT64_MAX / 512ULL || data_start > UINT64_MAX - data_fork_off) {
        mp_set_err(err, err_sz, "mish header sector/offset overflow");
        return MACPKG_ERR_CORRUPT;
    }
    if (204ULL + (uint64_t)num_chunks * 40ULL > entry->data_len) {
        mp_set_err(err, err_sz, "mish chunk table truncated");
        return MACPKG_ERR_CORRUPT;
    }

    udif_chunk_t *chunks = (udif_chunk_t *)calloc(num_chunks ? num_chunks : 1, sizeof(*chunks));
    if (!chunks) {
        mp_set_err(err, err_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }
    size_t n = 0;
    for (uint32_t i = 0; i < num_chunks; i++) {
        const uint8_t *e = d + 204 + i * 40;
        uint32_t ctype = mp_be32(e);
        if (ctype == UDIF_CHUNK_TERM) break;
        if (ctype == UDIF_CHUNK_COMMENT) continue;
        uint64_t soff = mp_be64(e + 8);
        uint64_t scnt = mp_be64(e + 16);
        if (scnt == 0) continue;
        if (scnt > UINT64_MAX / 512ULL || soff > UINT64_MAX - scnt || soff + scnt > sector_count) {
            free(chunks);
            mp_set_err(err, err_sz, "mish chunk sector bounds out of range");
            return MACPKG_ERR_CORRUPT;
        }
        chunks[n].type = ctype;
        chunks[n].sector_off = soff;
        chunks[n].sector_cnt = scnt;
        chunks[n].comp_off = mp_be64(e + 24);
        chunks[n].comp_len = mp_be64(e + 32);
        n++;
    }
    qsort(chunks, n, sizeof(*chunks), cmp_chunk_sector);

    udif_part_ctx_t *ctx = (udif_part_ctx_t *)calloc(1, sizeof(*ctx));
    if (!ctx) {
        free(chunks);
        mp_set_err(err, err_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }
    ctx->dmg = dmg;
    ctx->data_base = data_fork_off + data_start;
    ctx->sector_count = sector_count;
    ctx->chunks = chunks;
    ctx->num_chunks = n;

    out_part->ctx = ctx;
    out_part->size = sector_count * 512ULL;
    out_part->read_at = udif_part_read_at;
    out_part->close = udif_part_close;
    return MACPKG_OK;
}

static int probe_fs(macpkg_stream_t *part) {
    uint8_t buf[1028];
    if (part->size >= 1028 && part->read_at(part->ctx, 1024, buf, 4) == 0) {
        uint16_t sig = mp_be16(buf);
        if (sig == 0x482Bu || sig == 0x4858u) return MACPKG_FMT_HFS;
    }
    if (part->size >= 64 && part->read_at(part->ctx, 32, buf, 4) == 0) {
        if (memcmp(buf, "NXSB", 4) == 0) return MACPKG_FMT_APFS;
    }
    return MACPKG_FMT_AUTO;
}

static macpkg_status_t try_extract_partition_or_gpt(macpkg_stream_t *part, const char *output_dir,
                                                    const macpkg_options_t *opts,
                                                    char *err, size_t err_sz) {
    int fs = probe_fs(part);
    if (fs == MACPKG_FMT_HFS) {
        return mp_extract_hfsplus(part, output_dir, opts, err, err_sz);
    }
    if (fs == MACPKG_FMT_APFS) {
        return mp_extract_apfs(part, output_dir, opts, err, err_sz);
    }

    /* Check GPT at LBA 1 (offset 512) */
    uint8_t hdr[512];
    if (part->size >= 1024 && part->read_at(part->ctx, 512, hdr, 512) == 0 &&
        memcmp(hdr, "EFI PART", 8) == 0) {
        uint64_t part_lba = mp_le64(hdr + 72);
        uint32_t num_parts = mp_le32(hdr + 80);
        uint32_t ent_sz = mp_le32(hdr + 84);
        if (num_parts > 128) num_parts = 128;
        if (ent_sz >= 128 && ent_sz <= 1024 && part_lba <= UINT64_MAX / 512ULL) {
            uint8_t *ents = (uint8_t *)malloc((size_t)num_parts * ent_sz);
            if (!ents) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
            if (part->read_at(part->ctx, part_lba * 512ULL, ents, (size_t)num_parts * ent_sz) == 0) {
                for (uint32_t i = 0; i < num_parts; i++) {
                    const uint8_t *e = ents + i * ent_sz;
                    uint64_t first_lba = mp_le64(e + 32);
                    uint64_t last_lba = mp_le64(e + 40);
                    if (first_lba == 0 || last_lba < first_lba ||
                        first_lba > UINT64_MAX / 512ULL ||
                        last_lba - first_lba >= UINT64_MAX / 512ULL) continue;
                    macpkg_stream_t slice;
                    if (mp_stream_slice(part, first_lba * 512ULL,
                                        (last_lba - first_lba + 1ULL) * 512ULL, &slice) == MACPKG_OK) {
                        int sfs = probe_fs(&slice);
                        if (sfs == MACPKG_FMT_HFS || sfs == MACPKG_FMT_APFS) {
                            macpkg_status_t st = (sfs == MACPKG_FMT_HFS)
                                ? mp_extract_hfsplus(&slice, output_dir, opts, err, err_sz)
                                : mp_extract_apfs(&slice, output_dir, opts, err, err_sz);
                            macpkg_stream_close(&slice);
                            if (st == MACPKG_OK) { free(ents); return MACPKG_OK; }
                        } else {
                            macpkg_stream_close(&slice);
                        }
                    }
                }
            }
            free(ents);
        }
    }

    /* Check Apple Partition Map (APM) at LBA 1 (offset 512, "PM") */
    if (part->size >= 1024 && part->read_at(part->ctx, 512, hdr, 512) == 0 &&
        hdr[0] == 'P' && hdr[1] == 'M') {
        uint32_t map_cnt = mp_be32(hdr + 4);
        if (map_cnt > 128) map_cnt = 128;
        for (uint32_t i = 1; i <= map_cnt; i++) {
            if (part->read_at(part->ctx, (uint64_t)i * 512ULL, hdr, 512) != 0) break;
            if (hdr[0] != 'P' || hdr[1] != 'M') break;
            if (strncmp((const char *)(hdr + 48), "Apple_HFS", 9) == 0 ||
                strncmp((const char *)(hdr + 48), "Apple_APFS", 10) == 0) {
                uint32_t pstart = mp_be32(hdr + 8);
                uint32_t pcnt = mp_be32(hdr + 12);
                macpkg_stream_t slice;
                if (mp_stream_slice(part, (uint64_t)pstart * 512ULL, (uint64_t)pcnt * 512ULL,
                                    &slice) == MACPKG_OK) {
                    int sfs = probe_fs(&slice);
                    if (sfs == MACPKG_FMT_HFS || sfs == MACPKG_FMT_APFS) {
                        macpkg_status_t st = (sfs == MACPKG_FMT_HFS)
                            ? mp_extract_hfsplus(&slice, output_dir, opts, err, err_sz)
                            : mp_extract_apfs(&slice, output_dir, opts, err, err_sz);
                        macpkg_stream_close(&slice);
                        if (st == MACPKG_OK) return MACPKG_OK;
                    } else {
                        macpkg_stream_close(&slice);
                    }
                }
            }
        }
    }

    return MACPKG_ERR_NOT_FOUND;
}

macpkg_status_t mp_extract_dmg(macpkg_stream_t *stream, const char *output_dir,
                               const macpkg_options_t *opts, char *err, size_t err_sz) {
    if (stream->size < 512) {
        mp_set_err(err, err_sz, "file too small to be UDIF DMG");
        return MACPKG_ERR_FORMAT;
    }
    uint8_t koly[512];
    macpkg_status_t st = mp_stream_read_exact(stream, stream->size - 512, koly, 512, err, err_sz);
    if (st != MACPKG_OK) return st;
    if (memcmp(koly, "koly", 4) != 0) {
        mp_set_err(err, err_sz, "missing UDIF 'koly' trailer");
        return MACPKG_ERR_FORMAT;
    }

    uint64_t data_fork_off = mp_be64(koly + 24);
    uint64_t xml_off = mp_be64(koly + 0xd8);
    uint64_t xml_len = mp_be64(koly + 0xe0);
    if (xml_len == 0 || xml_len > 64ULL * 1024ULL * 1024ULL ||
        xml_off > stream->size || xml_len > stream->size - xml_off) {
        mp_set_err(err, err_sz, "invalid UDIF XML plist bounds");
        return MACPKG_ERR_CORRUPT;
    }

    char *xml = (char *)malloc((size_t)xml_len + 1);
    if (!xml) {
        mp_set_err(err, err_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }
    st = mp_stream_read_exact(stream, xml_off, xml, (size_t)xml_len, err, err_sz);
    if (st != MACPKG_OK) { free(xml); return st; }
    xml[xml_len] = '\0';

    mp_blkx_entry_t *entries = NULL;
    size_t num_entries = 0;
    st = mp_parse_udif_plist(xml, (size_t)xml_len, &entries, &num_entries, err, err_sz);
    free(xml);
    if (st != MACPKG_OK) return st;

    /* Pass 1: try entries explicitly named Apple_HFS / Apple_APFS first */
    macpkg_status_t last_err = MACPKG_ERR_NOT_FOUND;
    for (int pass = 0; pass < 2; pass++) {
        for (size_t i = 0; i < num_entries; i++) {
            int is_named_fs = (entries[i].name &&
                               (strstr(entries[i].name, "Apple_HFS") != NULL ||
                                strstr(entries[i].name, "Apple_APFS") != NULL));
            if ((pass == 0 && !is_named_fs) || (pass == 1 && is_named_fs)) continue;

            macpkg_stream_t part;
            if (open_blkx_partition(stream, data_fork_off, &entries[i], &part, err, err_sz) != MACPKG_OK) {
                continue;
            }
            if (opts && opts->verbose) {
                fprintf(stderr, "udif: probing partition '%s' (%llu bytes)\n",
                        entries[i].name ? entries[i].name : "(unnamed)",
                        (unsigned long long)part.size);
            }
            st = try_extract_partition_or_gpt(&part, output_dir, opts, err, err_sz);
            macpkg_stream_close(&part);
            if (st == MACPKG_OK) {
                mp_free_blkx_entries(entries, num_entries);
                return MACPKG_OK;
            }
            if (st != MACPKG_ERR_NOT_FOUND) last_err = st;
        }
    }

    mp_free_blkx_entries(entries, num_entries);
    if (last_err == MACPKG_ERR_NOT_FOUND) {
        mp_set_err(err, err_sz, "no extractable HFS+/APFS .app bundle found in DMG");
    }
    return last_err;
}
