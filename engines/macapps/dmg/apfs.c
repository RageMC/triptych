#include "macpkg_internal.h"
#include <sys/stat.h>

#define APFS_OBJ_NX_SUPERBLOCK   1u
#define APFS_OBJ_BTREE           2u
#define APFS_OBJ_BTREE_NODE      3u
#define APFS_OBJ_OMAP            11u
#define APFS_OBJ_FS              13u

#define BTNODE_ROOT              0x0001u
#define BTNODE_LEAF              0x0002u
#define BTNODE_FIXED_KV_SIZE     0x0004u

#define APFS_TYPE_INODE          3u
#define APFS_TYPE_XATTR          4u
#define APFS_TYPE_FILE_EXTENT    8u
#define APFS_TYPE_DIR_REC        9u

#define APFS_ROOT_DIR_INO_NUM    2ULL

#define APFS_XATTR_DATA_STREAM   0x0001u
#define APFS_XATTR_DATA_EMBEDDED 0x0002u

#define APFS_INO_EXT_DSTREAM     8u
#define APFS_UF_COMPRESSED       0x20u

typedef struct {
    uint64_t oid;
    char *rel_path;
} apfs_hlink_t;

typedef struct {
    macpkg_stream_t *stream;
    uint32_t block_size;
    uint64_t block_count;
    uint64_t nx_xid;
    uint64_t vol_omap_tree_paddr;
    uint64_t vol_root_tree_oid;
    apfs_hlink_t *hlinks;
    size_t hlink_count;
    size_t hlink_cap;
    mp_sink_t *sink;
    const macpkg_options_t *opts;
} apfs_vol_t;

static uint64_t apfs_fletcher64(const uint8_t *buf, size_t len) {
    uint64_t sum1 = 0, sum2 = 0;
    for (size_t i = 8; i + 4 <= len; i += 4) {
        sum1 = (sum1 + mp_le32(buf + i)) % 0xFFFFFFFFULL;
        sum2 = (sum2 + sum1) % 0xFFFFFFFFULL;
    }
    uint64_t c1 = 0xFFFFFFFFULL - ((sum1 + sum2) % 0xFFFFFFFFULL);
    uint64_t c2 = 0xFFFFFFFFULL - ((sum1 + c1) % 0xFFFFFFFFULL);
    return (c2 << 32) | c1;
}

static macpkg_status_t apfs_read_block(const apfs_vol_t *v, uint64_t paddr, uint8_t *buf,
                                       char *err, size_t err_sz) {
    if (paddr >= v->block_count || paddr > UINT64_MAX / v->block_size) {
        mp_set_err(err, err_sz, "APFS block %llu out of range (%llu)",
                   (unsigned long long)paddr, (unsigned long long)v->block_count);
        return MACPKG_ERR_CORRUPT;
    }
    return mp_stream_read_exact(v->stream, paddr * v->block_size, buf, v->block_size, err, err_sz);
}

static int apfs_cmp_omap_key(uint64_t a_oid, uint64_t a_xid, uint64_t b_oid, uint64_t b_xid) {
    if (a_oid != b_oid) return (a_oid < b_oid) ? -1 : 1;
    if (a_xid != b_xid) return (a_xid < b_xid) ? -1 : 1;
    return 0;
}

/* Lookup virtual OID in an omap B-tree (tree_root_paddr is physical block number). */
static macpkg_status_t apfs_omap_lookup(const apfs_vol_t *v, uint64_t tree_root_paddr,
                                        uint64_t target_oid, uint64_t max_xid,
                                        uint64_t *out_paddr, char *err, size_t err_sz) {
    uint8_t *node = (uint8_t *)malloc(v->block_size);
    if (!node) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }

    uint64_t cur_paddr = tree_root_paddr;
    int depth = 0;
    while (depth++ < 32) {
        macpkg_status_t st = apfs_read_block(v, cur_paddr, node, err, err_sz);
        if (st != MACPKG_OK) { free(node); return st; }

        uint16_t flags = mp_le16(node + 32);
        uint32_t nkeys = mp_le32(node + 36);
        uint16_t tbl_off = mp_le16(node + 40);
        uint16_t tbl_len = mp_le16(node + 42);

        uint32_t key_base = 56u + tbl_off + tbl_len;
        uint32_t val_end = (flags & BTNODE_ROOT) ? (v->block_size - 40u) : v->block_size;
        if (56u + (uint64_t)tbl_off > v->block_size || key_base > val_end) {
            free(node);
            mp_set_err(err, err_sz, "APFS omap B-tree node table out of bounds");
            return MACPKG_ERR_CORRUPT;
        }
        const uint8_t *toc = node + 56u + tbl_off;
        int fixed = (flags & BTNODE_FIXED_KV_SIZE) != 0;

        if (!(flags & BTNODE_LEAF)) {
            uint64_t chosen = 0;
            int has_chosen = 0;
            for (uint32_t i = 0; i < nkeys; i++) {
                uint16_t k_off, v_off;
                if (fixed) {
                    if (56u + (uint64_t)tbl_off + ((uint64_t)i + 1u) * 4u > v->block_size) break;
                    k_off = mp_le16(toc + i * 4u);
                    v_off = mp_le16(toc + i * 4u + 2u);
                } else {
                    if (56u + (uint64_t)tbl_off + ((uint64_t)i + 1u) * 8u > v->block_size) break;
                    k_off = mp_le16(toc + i * 8u);
                    v_off = mp_le16(toc + i * 8u + 4u);
                }
                if ((uint64_t)key_base + k_off + 16u > v->block_size || v_off < 8u || val_end < v_off) continue;
                uint64_t k_oid = mp_le64(node + key_base + k_off);
                uint64_t k_xid = mp_le64(node + key_base + k_off + 8);
                int cmp = apfs_cmp_omap_key(k_oid, k_xid, target_oid, max_xid);
                if (cmp <= 0 || !has_chosen) {
                    chosen = mp_le64(node + val_end - v_off);
                    has_chosen = 1;
                }
                if (cmp > 0) break;
            }
            if (!has_chosen) { free(node); return MACPKG_ERR_NOT_FOUND; }
            cur_paddr = chosen;
        } else {
            uint64_t best_paddr = 0;
            int found = 0;
            for (uint32_t i = 0; i < nkeys; i++) {
                uint16_t k_off, v_off;
                if (fixed) {
                    if (56u + (uint64_t)tbl_off + ((uint64_t)i + 1u) * 4u > v->block_size) break;
                    k_off = mp_le16(toc + i * 4u);
                    v_off = mp_le16(toc + i * 4u + 2u);
                } else {
                    if (56u + (uint64_t)tbl_off + ((uint64_t)i + 1u) * 8u > v->block_size) break;
                    k_off = mp_le16(toc + i * 8u);
                    v_off = mp_le16(toc + i * 8u + 4u);
                }
                if ((uint64_t)key_base + k_off + 16u > v->block_size || v_off < 16u || val_end < v_off) continue;
                uint64_t k_oid = mp_le64(node + key_base + k_off);
                uint64_t k_xid = mp_le64(node + key_base + k_off + 8);
                if (k_oid == target_oid && k_xid <= max_xid) {
                    best_paddr = mp_le64(node + val_end - v_off + 8);
                    found = 1;
                } else if (k_oid > target_oid || (k_oid == target_oid && k_xid > max_xid)) {
                    break;
                }
            }
            free(node);
            if (!found) {
                mp_set_err(err, err_sz, "APFS omap OID %llu not found", (unsigned long long)target_oid);
                return MACPKG_ERR_NOT_FOUND;
            }
            *out_paddr = best_paddr;
            return MACPKG_OK;
        }
    }

    free(node);
    mp_set_err(err, err_sz, "APFS omap B-tree depth exceeded");
    return MACPKG_ERR_CORRUPT;
}

typedef macpkg_status_t (*apfs_fs_rec_cb)(void *ctx, const uint8_t *key, uint16_t klen,
                                          const uint8_t *val, uint16_t vlen,
                                          char *err, size_t err_sz);

static int apfs_cmp_jkey_prefix(uint64_t raw_key, uint64_t target_oid, uint8_t target_type) {
    uint64_t oid = raw_key & 0x0FFFFFFFFFFFFFFFULL;
    uint8_t type = (uint8_t)(raw_key >> 60);
    if (oid != target_oid) return (oid < target_oid) ? -1 : 1;
    if (type != target_type) return (type < target_type) ? -1 : 1;
    return 0;
}

static macpkg_status_t apfs_fs_scan_node(const apfs_vol_t *v, uint64_t node_oid,
                                         uint64_t target_oid, uint8_t target_type,
                                         apfs_fs_rec_cb cb, void *cb_ctx, int depth,
                                         char *err, size_t err_sz) {
    if (depth >= 64) {
        mp_set_err(err, err_sz, "APFS FS B-tree depth exceeded");
        return MACPKG_ERR_CORRUPT;
    }
    uint64_t paddr = 0;
    macpkg_status_t st = apfs_omap_lookup(v, v->vol_omap_tree_paddr, node_oid, v->nx_xid, &paddr, err, err_sz);
    if (st != MACPKG_OK) return st;

    uint8_t *node = (uint8_t *)malloc(v->block_size);
    if (!node) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }

    st = apfs_read_block(v, paddr, node, err, err_sz);
    if (st != MACPKG_OK) { free(node); return st; }

    uint16_t flags = mp_le16(node + 32);
    uint32_t nkeys = mp_le32(node + 36);
    uint16_t tbl_off = mp_le16(node + 40);
    uint16_t tbl_len = mp_le16(node + 42);

    uint32_t key_base = 56u + tbl_off + tbl_len;
    uint32_t val_end = (flags & BTNODE_ROOT) ? (v->block_size - 40u) : v->block_size;
    if (56u + (uint64_t)tbl_off > v->block_size || key_base > val_end) {
        free(node);
        mp_set_err(err, err_sz, "APFS FS B-tree node table out of bounds");
        return MACPKG_ERR_CORRUPT;
    }
    const uint8_t *toc = node + 56u + tbl_off;

    if (flags & BTNODE_LEAF) {
        for (uint32_t i = 0; i < nkeys; i++) {
            if (56u + (uint64_t)tbl_off + ((uint64_t)i + 1u) * 8u > v->block_size) break;
            uint16_t k_off = mp_le16(toc + i * 8u);
            uint16_t k_len = mp_le16(toc + i * 8u + 2u);
            uint16_t v_off = mp_le16(toc + i * 8u + 4u);
            uint16_t v_len = mp_le16(toc + i * 8u + 6u);
            if (k_len < 8 || (uint64_t)key_base + k_off + k_len > v->block_size || v_off > val_end || v_len > v_off) {
                continue;
            }
            const uint8_t *k = node + key_base + k_off;
            const uint8_t *val = node + val_end - v_off;
            int cmp = apfs_cmp_jkey_prefix(mp_le64(k), target_oid, target_type);
            if (cmp == 0) {
                st = cb(cb_ctx, k, k_len, val, v_len, err, err_sz);
                if (st != MACPKG_OK) { free(node); return st; }
            } else if (cmp > 0) {
                break;
            }
        }
    } else {
        for (uint32_t i = 0; i < nkeys; i++) {
            if (56u + (uint64_t)tbl_off + ((uint64_t)i + 1u) * 8u > v->block_size) break;
            uint16_t k_off = mp_le16(toc + i * 8u);
            uint16_t k_len = mp_le16(toc + i * 8u + 2u);
            uint16_t v_off = mp_le16(toc + i * 8u + 4u);
            uint16_t v_len = mp_le16(toc + i * 8u + 6u);
            if (k_len < 8 || (uint64_t)key_base + k_off + k_len > v->block_size ||
                v_off < 8 || v_off > val_end || v_len < 8 || v_len > v_off) {
                continue;
            }
            int cmp_cur = apfs_cmp_jkey_prefix(mp_le64(node + key_base + k_off), target_oid, target_type);
            if (cmp_cur > 0) break;

            int descend = 1;
            if (i + 1u < nkeys && 56u + (uint64_t)tbl_off + ((uint64_t)i + 2u) * 8u <= v->block_size) {
                uint16_t nk_off = mp_le16(toc + (i + 1u) * 8u);
                uint16_t nk_len = mp_le16(toc + (i + 1u) * 8u + 2u);
                if (nk_len >= 8 && (uint64_t)key_base + nk_off + 8u <= v->block_size) {
                    int cmp_next = apfs_cmp_jkey_prefix(mp_le64(node + key_base + nk_off), target_oid, target_type);
                    if (cmp_next < 0) descend = 0;
                }
            }
            if (descend) {
                uint64_t child_oid = mp_le64(node + val_end - v_off);
                st = apfs_fs_scan_node(v, child_oid, target_oid, target_type, cb, cb_ctx, depth + 1, err, err_sz);
                if (st != MACPKG_OK) { free(node); return st; }
            }
        }
    }

    free(node);
    return MACPKG_OK;
}

static macpkg_status_t apfs_fs_scan(const apfs_vol_t *v, uint64_t target_oid, uint8_t target_type,
                                    apfs_fs_rec_cb cb, void *cb_ctx, char *err, size_t err_sz) {
    return apfs_fs_scan_node(v, v->vol_root_tree_oid, target_oid, target_type, cb, cb_ctx, 0, err, err_sz);
}

/* ---- Extent reader ---- */
typedef struct {
    uint64_t logical_addr;
    uint64_t length;
    uint64_t phys_block;
} apfs_extent_t;

typedef struct {
    apfs_extent_t *items;
    size_t count;
    size_t cap;
} apfs_extents_vec_t;

static macpkg_status_t collect_extent_cb(void *vctx, const uint8_t *key, uint16_t klen,
                                         const uint8_t *val, uint16_t vlen,
                                         char *err, size_t err_sz) {
    if (klen < 16 || vlen < 24) return MACPKG_OK;
    apfs_extents_vec_t *vec = (apfs_extents_vec_t *)vctx;
    if (vec->count == vec->cap) {
        size_t ncap = vec->cap ? vec->cap * 2 : 16;
        apfs_extent_t *ni = (apfs_extent_t *)realloc(vec->items, ncap * sizeof(*ni));
        if (!ni) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
        vec->items = ni;
        vec->cap = ncap;
    }
    uint64_t logical_addr = mp_le64(key + 8);
    uint64_t length = mp_le64(val) & 0x00FFFFFFFFFFFFFFULL;
    uint64_t phys_block = mp_le64(val + 8);
    if (length == 0 || length > UINT64_MAX - logical_addr) {
        mp_set_err(err, err_sz, "APFS extent logical range overflow");
        return MACPKG_ERR_CORRUPT;
    }
    vec->items[vec->count].logical_addr = logical_addr;
    vec->items[vec->count].length = length;
    vec->items[vec->count].phys_block = phys_block;
    vec->count++;
    return MACPKG_OK;
}

static int cmp_apfs_extent(const void *a, const void *b) {
    const apfs_extent_t *ea = (const apfs_extent_t *)a;
    const apfs_extent_t *eb = (const apfs_extent_t *)b;
    if (ea->logical_addr < eb->logical_addr) return -1;
    if (ea->logical_addr > eb->logical_addr) return 1;
    return 0;
}

static macpkg_status_t apfs_stream_dstream(const apfs_vol_t *v, uint64_t obj_id, uint64_t size,
                                           FILE *fp, uint8_t **out_buf,
                                           char *err, size_t err_sz) {
    apfs_extents_vec_t vec = {NULL, 0, 0};
    macpkg_status_t st = apfs_fs_scan(v, obj_id, APFS_TYPE_FILE_EXTENT, collect_extent_cb, &vec, err, err_sz);
    if (st != MACPKG_OK) { free(vec.items); return st; }
    for (size_t i = 0; i < vec.count; i++) {
        if (vec.items[i].phys_block != 0 &&
            (vec.items[i].phys_block >= v->block_count ||
             vec.items[i].phys_block > UINT64_MAX / v->block_size)) {
            free(vec.items);
            mp_set_err(err, err_sz, "APFS extent physical block out of range");
            return MACPKG_ERR_CORRUPT;
        }
    }
    if (vec.count > 1) qsort(vec.items, vec.count, sizeof(*vec.items), cmp_apfs_extent);

    uint8_t *buf = NULL;
    if (out_buf) {
        if (size > 512ULL * 1024ULL * 1024ULL) {
            free(vec.items);
            mp_set_err(err, err_sz, "APFS stream too large for memory buffer");
            return MACPKG_ERR_UNSUPPORTED;
        }
        buf = (uint8_t *)calloc(1, size ? (size_t)size : 1);
        if (!buf) { free(vec.items); mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
    }

    uint8_t *io_buf = (uint8_t *)malloc(262144);
    if (!io_buf) { free(buf); free(vec.items); mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }

    uint64_t pos = 0;
    size_t eidx = 0;
    while (pos < size) {
        while (eidx < vec.count && vec.items[eidx].logical_addr + vec.items[eidx].length <= pos) {
            eidx++;
        }
        uint64_t chunk_len = size - pos;
        int is_zero = 1;
        uint64_t disk_off = 0;

        if (eidx < vec.count) {
            const apfs_extent_t *e = &vec.items[eidx];
            if (pos < e->logical_addr) {
                uint64_t gap = e->logical_addr - pos;
                if (gap < chunk_len) chunk_len = gap;
            } else {
                uint64_t into = pos - e->logical_addr;
                uint64_t rem = e->length - into;
                if (rem < chunk_len) chunk_len = rem;
                if (e->phys_block != 0) {
                    uint64_t base_off = e->phys_block * v->block_size;
                    if (into > UINT64_MAX - base_off) {
                        free(io_buf); free(buf); free(vec.items);
                        mp_set_err(err, err_sz, "APFS extent offset overflow");
                        return MACPKG_ERR_CORRUPT;
                    }
                    is_zero = 0;
                    disk_off = base_off + into;
                }
            }
        }

        while (chunk_len > 0) {
            size_t step = (chunk_len > 262144u) ? 262144u : (size_t)chunk_len;
            if (is_zero) {
                memset(io_buf, 0, step);
            } else {
                st = mp_stream_read_exact(v->stream, disk_off, io_buf, step, err, err_sz);
                if (st != MACPKG_OK) { free(io_buf); free(buf); free(vec.items); return st; }
                disk_off += step;
            }
            if (fp) {
                if (fwrite(io_buf, 1, step, fp) != step) {
                    free(io_buf); free(buf); free(vec.items);
                    mp_set_err(err, err_sz, "write error");
                    return MACPKG_ERR_IO;
                }
            } else if (buf) {
                memcpy(buf + pos, io_buf, step);
            }
            pos += step;
            chunk_len -= step;
        }
    }

    free(io_buf);
    free(vec.items);
    if (out_buf) *out_buf = buf;
    return MACPKG_OK;
}

/* ---- Xattr lookup ---- */
typedef struct {
    const apfs_vol_t *vol;
    const char *name;
    int found;
    uint8_t *data;
    size_t len;
} apfs_xattr_find_t;

static macpkg_status_t xattr_find_cb(void *vctx, const uint8_t *key, uint16_t klen,
                                     const uint8_t *val, uint16_t vlen,
                                     char *err, size_t err_sz) {
    apfs_xattr_find_t *xf = (apfs_xattr_find_t *)vctx;
    if (xf->found || klen < 11 || vlen < 4) return MACPKG_OK;
    uint16_t nlen = mp_le16(key + 8);
    if (10u + nlen > klen) return MACPKG_OK;
    const char *kname = (const char *)(key + 10);
    size_t target_len = strlen(xf->name);
    size_t actual_len = (nlen > 0 && kname[nlen - 1] == '\0') ? (size_t)(nlen - 1) : (size_t)nlen;
    if (actual_len != target_len || memcmp(kname, xf->name, target_len) != 0) return MACPKG_OK;

    uint16_t flags = mp_le16(val);
    uint16_t xlen = mp_le16(val + 2);
    if (4u + xlen > vlen) return MACPKG_ERR_CORRUPT;

    if (flags & APFS_XATTR_DATA_EMBEDDED) {
        uint8_t *buf = (uint8_t *)malloc(xlen ? xlen : 1);
        if (!buf) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
        memcpy(buf, val + 4, xlen);
        xf->data = buf;
        xf->len = xlen;
        xf->found = 1;
        return MACPKG_OK;
    } else if ((flags & APFS_XATTR_DATA_STREAM) && xlen >= 16) {
        uint64_t xattr_obj_id = mp_le64(val + 4);
        uint64_t stream_size = mp_le64(val + 12);
        macpkg_status_t st = apfs_stream_dstream(xf->vol, xattr_obj_id, stream_size,
                                                 NULL, &xf->data, err, err_sz);
        if (st == MACPKG_OK) {
            xf->len = (size_t)stream_size;
            xf->found = 1;
        }
        return st;
    }
    return MACPKG_OK;
}

static macpkg_status_t apfs_read_xattr(const apfs_vol_t *v, uint64_t oid, const char *name,
                                       uint8_t **out_data, size_t *out_len,
                                       char *err, size_t err_sz) {
    apfs_xattr_find_t xf = {v, name, 0, NULL, 0};
    macpkg_status_t st = apfs_fs_scan(v, oid, APFS_TYPE_XATTR, xattr_find_cb, &xf, err, err_sz);
    if (st != MACPKG_OK) { free(xf.data); return st; }
    if (!xf.found) return MACPKG_ERR_NOT_FOUND;
    *out_data = xf.data;
    *out_len = xf.len;
    return MACPKG_OK;
}

/* ---- Inode info ---- */
typedef struct {
    int found;
    uint64_t private_id;
    uint32_t bsd_flags;
    uint16_t mode;
    uint64_t dstream_size;
    int has_dstream;
} apfs_inode_info_t;

static macpkg_status_t inode_find_cb(void *vctx, const uint8_t *key, uint16_t klen,
                                     const uint8_t *val, uint16_t vlen,
                                     char *err, size_t err_sz) {
    (void)key; (void)klen; (void)err; (void)err_sz;
    apfs_inode_info_t *info = (apfs_inode_info_t *)vctx;
    if (info->found || vlen < 92) return MACPKG_OK;
    info->private_id = mp_le64(val + 8);
    info->bsd_flags = mp_le32(val + 68);
    info->mode = mp_le16(val + 80);
    info->found = 1;

    if (vlen >= 96) {
        uint16_t num_exts = mp_le16(val + 92);
        size_t desc_off = 96;
        size_t data_off = 96u + (size_t)num_exts * 4u;
        if (data_off <= vlen) {
            for (uint16_t i = 0; i < num_exts; i++) {
                uint8_t xtype = val[desc_off + i * 4u];
                uint16_t xsize = mp_le16(val + desc_off + i * 4u + 2u);
                if (data_off + xsize > vlen) break;
                if (xtype == APFS_INO_EXT_DSTREAM && xsize >= 8) {
                    info->dstream_size = mp_le64(val + data_off);
                    info->has_dstream = 1;
                }
                data_off += (xsize + 7u) & ~7u;
            }
        }
    }
    return MACPKG_OK;
}

static const char *apfs_lookup_hlink(const apfs_vol_t *v, uint64_t oid) {
    for (size_t i = 0; i < v->hlink_count; i++) {
        if (v->hlinks[i].oid == oid) return v->hlinks[i].rel_path;
    }
    return NULL;
}

static void apfs_record_hlink(apfs_vol_t *v, uint64_t oid, const char *rel_path) {
    if (v->hlink_count == v->hlink_cap) {
        size_t ncap = v->hlink_cap ? v->hlink_cap * 2 : 32;
        apfs_hlink_t *nh = (apfs_hlink_t *)realloc(v->hlinks, ncap * sizeof(*nh));
        if (!nh) return;
        v->hlinks = nh;
        v->hlink_cap = ncap;
    }
    size_t n = strlen(rel_path) + 1;
    char *copy = (char *)malloc(n);
    if (!copy) return;
    memcpy(copy, rel_path, n);
    v->hlinks[v->hlink_count].oid = oid;
    v->hlinks[v->hlink_count].rel_path = copy;
    v->hlink_count++;
}

/* ---- Directory walk ---- */
typedef struct {
    char *name;
    uint64_t file_id;
} apfs_dentry_t;

typedef struct {
    apfs_dentry_t *items;
    size_t count;
    size_t cap;
} apfs_dentry_vec_t;

static macpkg_status_t collect_drec_cb(void *vctx, const uint8_t *key, uint16_t klen,
                                       const uint8_t *val, uint16_t vlen,
                                       char *err, size_t err_sz) {
    if (vlen < 18) return MACPKG_OK;
    const char *nptr = NULL;
    size_t nlen = 0;
    if (klen >= 12) {
        uint32_t nl_hash = mp_le32(key + 8);
        uint32_t cand = nl_hash & 0x3FFu;
        if (12u + cand == klen) {
            nptr = (const char *)(key + 12);
            nlen = cand;
        }
    }
    if (!nptr && klen >= 10) {
        uint16_t cand = mp_le16(key + 8);
        if (10u + cand == klen) {
            nptr = (const char *)(key + 10);
            nlen = cand;
        }
    }
    if (!nptr || nlen == 0) return MACPKG_OK;
    while (nlen > 0 && nptr[nlen - 1] == '\0') nlen--;
    if (nlen == 0) return MACPKG_OK;

    apfs_dentry_vec_t *vec = (apfs_dentry_vec_t *)vctx;
    if (vec->count == vec->cap) {
        size_t ncap = vec->cap ? vec->cap * 2 : 32;
        apfs_dentry_t *ni = (apfs_dentry_t *)realloc(vec->items, ncap * sizeof(*ni));
        if (!ni) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
        vec->items = ni;
        vec->cap = ncap;
    }
    char *name = (char *)malloc(nlen + 1);
    if (!name) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
    memcpy(name, nptr, nlen);
    name[nlen] = '\0';
    vec->items[vec->count].name = name;
    vec->items[vec->count].file_id = mp_le64(val);
    vec->count++;
    return MACPKG_OK;
}

static macpkg_status_t apfs_walk_dir(apfs_vol_t *v, uint64_t dir_oid, const char *parent_raw_path,
                                     int depth, char *err, size_t err_sz) {
    if (depth >= 64) {
        mp_set_err(err, err_sz, "APFS directory nesting depth exceeded");
        return MACPKG_ERR_CORRUPT;
    }
    apfs_dentry_vec_t vec = {NULL, 0, 0};
    macpkg_status_t st = apfs_fs_scan(v, dir_oid, APFS_TYPE_DIR_REC, collect_drec_cb, &vec, err, err_sz);
    if (st != MACPKG_OK) {
        for (size_t i = 0; i < vec.count; i++) free(vec.items[i].name);
        free(vec.items);
        return st;
    }

    for (size_t i = 0; i < vec.count; i++) {
        const char *name = vec.items[i].name;
        uint64_t child_oid = vec.items[i].file_id;

        char raw_path[4096];
        if (parent_raw_path[0]) {
            if (snprintf(raw_path, sizeof(raw_path), "%s/%s", parent_raw_path, name) >= (int)sizeof(raw_path)) {
                mp_set_err(err, err_sz, "path too long");
                st = MACPKG_ERR_PATH;
                break;
            }
        } else {
            if (snprintf(raw_path, sizeof(raw_path), "%s", name) >= (int)sizeof(raw_path)) {
                mp_set_err(err, err_sz, "path too long");
                st = MACPKG_ERR_PATH;
                break;
            }
        }

        char rel_path[4096];
        int keep = mp_filter_app_relpath(raw_path, v->opts, rel_path, sizeof(rel_path));

        apfs_inode_info_t info;
        memset(&info, 0, sizeof(info));
        st = apfs_fs_scan(v, child_oid, APFS_TYPE_INODE, inode_find_cb, &info, err, err_sz);
        if (st != MACPKG_OK) break;
        if (!info.found) continue;

        if (S_ISDIR(info.mode)) {
            if (keep) {
                st = mp_sink_mkdir(v->sink, rel_path, info.mode & 07777u, err, err_sz);
                if (st != MACPKG_OK) break;
            }
            if (keep || !(v->opts && v->opts->extract_all_files)) {
                st = apfs_walk_dir(v, child_oid, raw_path, depth + 1, err, err_sz);
                if (st != MACPKG_OK) break;
            }
        } else if (S_ISLNK(info.mode)) {
            if (!keep) continue;
            uint8_t *tbuf = NULL;
            size_t tlen = 0;
            st = apfs_read_xattr(v, child_oid, "com.apple.fs.symlink", &tbuf, &tlen, err, err_sz);
            if (st != MACPKG_OK) {
                if (st == MACPKG_ERR_NOT_FOUND) {
                    mp_set_err(err, err_sz, "APFS symlink missing com.apple.fs.symlink xattr");
                }
                break;
            }
            char *target = (char *)malloc(tlen + 1);
            if (!target) { free(tbuf); st = MACPKG_ERR_NOMEM; break; }
            memcpy(target, tbuf, tlen);
            target[tlen] = '\0';
            free(tbuf);
            st = mp_sink_symlink(v->sink, rel_path, target, err, err_sz);
            free(target);
            if (st != MACPKG_OK) break;
        } else if (S_ISREG(info.mode)) {
            if (!keep) continue;
            const char *existing = apfs_lookup_hlink(v, child_oid);
            if (existing) {
                st = mp_sink_hardlink(v->sink, rel_path, existing, err, err_sz);
                if (st != MACPKG_OK) break;
                continue;
            }

            uint16_t perm = (info.mode & 07777u) ? (info.mode & 07777u) : 0644u;
            if (info.bsd_flags & APFS_UF_COMPRESSED) {
                uint8_t *xattr = NULL;
                size_t xlen = 0;
                macpkg_status_t xst = apfs_read_xattr(v, child_oid, "com.apple.decmpfs", &xattr, &xlen, err, err_sz);
                if (xst == MACPKG_OK) {
                    uint8_t *rsrc = NULL;
                    size_t rlen = 0;
                    macpkg_status_t rst = apfs_read_xattr(v, child_oid, "com.apple.ResourceFork", &rsrc, &rlen, err, err_sz);
                    if (rst != MACPKG_OK && rst != MACPKG_ERR_NOT_FOUND) {
                        free(xattr); st = rst; break;
                    }
                    uint8_t *ubuf = NULL;
                    size_t ulen = 0;
                    st = mp_decode_decmpfs(xattr, xlen, rsrc, rlen, &ubuf, &ulen, err, err_sz);
                    free(xattr);
                    free(rsrc);
                    if (st != MACPKG_OK) break;
                    st = mp_sink_write_file(v->sink, rel_path, perm, ubuf, ulen, err, err_sz);
                    free(ubuf);
                    if (st != MACPKG_OK) break;
                    apfs_record_hlink(v, child_oid, rel_path);
                    continue;
                }
            }

            FILE *fp = NULL;
            char *full_path = NULL;
            st = mp_sink_begin_file(v->sink, rel_path, perm, &fp, &full_path, err, err_sz);
            if (st != MACPKG_OK) break;
            if (info.has_dstream && info.dstream_size > 0) {
                st = apfs_stream_dstream(v, info.private_id, info.dstream_size, fp, NULL, err, err_sz);
            }
            if (st != MACPKG_OK) {
                fclose(fp); free(full_path);
                break;
            }
            if (v->sink->verbose) {
                fprintf(stderr, "  file %s (%llu bytes, mode %04o)\n", rel_path,
                        (unsigned long long)(info.has_dstream ? info.dstream_size : 0ULL), perm);
            }
            st = mp_sink_end_file(fp, full_path, perm, err, err_sz);
            if (st != MACPKG_OK) break;
            apfs_record_hlink(v, child_oid, rel_path);
        }
    }

    for (size_t i = 0; i < vec.count; i++) free(vec.items[i].name);
    free(vec.items);
    return st;
}

macpkg_status_t mp_extract_apfs(macpkg_stream_t *stream, const char *output_dir,
                                const macpkg_options_t *opts, char *err, size_t err_sz) {
    uint8_t sb0[4096];
    macpkg_status_t st = mp_stream_read_exact(stream, 0, sb0, sizeof(sb0), err, err_sz);
    if (st != MACPKG_OK) return st;

    if (memcmp(sb0 + 32, "NXSB", 4) != 0) {
        mp_set_err(err, err_sz, "missing APFS NXSB superblock");
        return MACPKG_ERR_FORMAT;
    }

    uint32_t block_size = mp_le32(sb0 + 36);
    uint64_t block_count = mp_le64(sb0 + 40);
    if (block_size < 4096 || block_size > 65536 || (block_size & (block_size - 1)) != 0) {
        mp_set_err(err, err_sz, "invalid APFS block size %u", block_size);
        return MACPKG_ERR_CORRUPT;
    }

    uint8_t *best_sb = (uint8_t *)malloc(block_size);
    uint8_t *cand_sb = (uint8_t *)malloc(block_size);
    if (!best_sb || !cand_sb) {
        free(best_sb); free(cand_sb);
        mp_set_err(err, err_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }
    st = mp_stream_read_exact(stream, 0, best_sb, block_size, err, err_sz);
    if (st != MACPKG_OK) { free(best_sb); free(cand_sb); return st; }

    /* Check checkpoint descriptor blocks for newer valid NXSB */
    uint32_t xp_desc_blocks = mp_le32(best_sb + 104);
    uint64_t xp_desc_base = mp_le64(best_sb + 112);
    uint64_t best_xid = mp_le64(best_sb + 16);
    if ((xp_desc_base >> 63) == 0 && xp_desc_blocks > 0 && xp_desc_blocks < 4096) {
        for (uint32_t i = 0; i < xp_desc_blocks; i++) {
            uint64_t blk = xp_desc_base + i;
            if (blk >= block_count) break;
            if (mp_stream_read_exact(stream, blk * block_size, cand_sb, block_size, err, err_sz) != MACPKG_OK) {
                break;
            }
            if ((mp_le32(cand_sb + 24) & 0xFFFFu) == APFS_OBJ_NX_SUPERBLOCK &&
                memcmp(cand_sb + 32, "NXSB", 4) == 0 &&
                mp_le64(cand_sb) == apfs_fletcher64(cand_sb, block_size)) {
                uint64_t xid = mp_le64(cand_sb + 16);
                if (xid >= best_xid) {
                    best_xid = xid;
                    memcpy(best_sb, cand_sb, block_size);
                }
            }
        }
    }
    free(cand_sb);

    apfs_vol_t vol;
    memset(&vol, 0, sizeof(vol));
    vol.stream = stream;
    vol.block_size = block_size;
    vol.block_count = mp_le64(best_sb + 40);
    vol.nx_xid = mp_le64(best_sb + 16);
    vol.opts = opts;

    uint64_t nx_omap_oid = mp_le64(best_sb + 160);
    uint64_t fs_oid = mp_le64(best_sb + 184); /* first volume */
    free(best_sb);

    if (fs_oid == 0) {
        mp_set_err(err, err_sz, "APFS container has no volumes");
        return MACPKG_ERR_NOT_FOUND;
    }

    uint8_t *blk = (uint8_t *)malloc(block_size);
    if (!blk) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }

    /* Read container omap */
    st = apfs_read_block(&vol, nx_omap_oid, blk, err, err_sz);
    if (st != MACPKG_OK) { free(blk); return st; }
    uint64_t nx_omap_tree_paddr = mp_le64(blk + 48);

    uint64_t vol_sb_paddr = 0;
    st = apfs_omap_lookup(&vol, nx_omap_tree_paddr, fs_oid, vol.nx_xid, &vol_sb_paddr, err, err_sz);
    if (st != MACPKG_OK) { free(blk); return st; }

    st = apfs_read_block(&vol, vol_sb_paddr, blk, err, err_sz);
    if (st != MACPKG_OK) { free(blk); return st; }
    if (memcmp(blk + 32, "APSB", 4) != 0) {
        free(blk);
        mp_set_err(err, err_sz, "invalid APFS volume superblock");
        return MACPKG_ERR_CORRUPT;
    }

    uint64_t apfs_fs_flags = mp_le64(blk + 264);
    if (!(apfs_fs_flags & 0x01ULL)) {
        free(blk);
        mp_set_err(err, err_sz, "encrypted APFS volumes are not supported");
        return MACPKG_ERR_UNSUPPORTED;
    }

    uint64_t vol_omap_oid = mp_le64(blk + 128);
    vol.vol_root_tree_oid = mp_le64(blk + 136);

    st = apfs_read_block(&vol, vol_omap_oid, blk, err, err_sz);
    if (st != MACPKG_OK) { free(blk); return st; }
    vol.vol_omap_tree_paddr = mp_le64(blk + 48);
    free(blk);

    mp_sink_t sink;
    st = mp_sink_init(&sink, output_dir, opts ? opts->verbose : 0, err, err_sz);
    if (st != MACPKG_OK) return st;
    vol.sink = &sink;

    st = apfs_walk_dir(&vol, APFS_ROOT_DIR_INO_NUM, "", 0, err, err_sz);

    size_t total_items = sink.files_written + sink.symlinks_written + sink.hardlinks_written + sink.dirs_created;
    mp_sink_finish(&sink);
    for (size_t i = 0; i < vol.hlink_count; i++) free(vol.hlinks[i].rel_path);
    free(vol.hlinks);

    if (st != MACPKG_OK) return st;
    if (total_items == 0) {
        mp_set_err(err, err_sz, "no .app bundle found in APFS volume");
        return MACPKG_ERR_NOT_FOUND;
    }
    return MACPKG_OK;
}
