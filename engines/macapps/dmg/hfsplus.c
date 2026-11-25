#include "macpkg_internal.h"
#include <sys/stat.h>

#define HFS_ROOT_FOLDER_ID        2u
#define HFS_EXTENTS_FILE_ID       3u
#define HFS_CATALOG_FILE_ID       4u
#define HFS_ATTRIBUTES_FILE_ID    8u

#define HFS_REC_FOLDER            1u
#define HFS_REC_FILE              2u
#define HFS_REC_FOLDER_THREAD     3u
#define HFS_REC_FILE_THREAD       4u

#define HFS_FORK_DATA             0x00u
#define HFS_FORK_RSRC             0xFFu

#define HFS_UF_COMPRESSED         0x20u

typedef struct {
    uint32_t start_block;
    uint32_t block_count;
} hfs_extent_t;

typedef struct {
    uint64_t logical_size;
    uint32_t clump_size;
    uint32_t total_blocks;
    hfs_extent_t extents[8];
} hfs_fork_t;

typedef struct {
    uint32_t root_node;
    uint32_t first_leaf;
    uint16_t node_size;
    uint32_t total_nodes;
    uint8_t key_compare_type;
    uint32_t attributes;
    hfs_fork_t fork;
    uint32_t file_id;
} hfs_btree_t;

typedef struct {
    uint32_t inode_num;
    char *rel_path;
} hfs_hlink_t;

typedef struct {
    macpkg_stream_t *stream;
    uint32_t block_size;
    uint32_t total_blocks;
    hfs_btree_t extents;
    hfs_btree_t catalog;
    hfs_btree_t attrs;
    int has_attrs;
    uint32_t priv_data_folder_id;
    uint32_t priv_dir_folder_id;
    hfs_hlink_t *hlinks;
    size_t hlink_count;
    size_t hlink_cap;
    mp_sink_t *sink;
    const macpkg_options_t *opts;
} hfs_vol_t;

static void parse_fork(const uint8_t *p, hfs_fork_t *f) {
    f->logical_size = mp_be64(p);
    f->clump_size = mp_be32(p + 8);
    f->total_blocks = mp_be32(p + 12);
    for (int i = 0; i < 8; i++) {
        f->extents[i].start_block = mp_be32(p + 16 + i * 8);
        f->extents[i].block_count = mp_be32(p + 20 + i * 8);
    }
}

static size_t utf16be_to_utf8(const uint8_t *u16, uint16_t char_cnt, char *out, size_t out_cap) {
    size_t op = 0;
    for (uint16_t i = 0; i < char_cnt; i++) {
        uint32_t cp = mp_be16(u16 + i * 2);
        if (cp >= 0xD800u && cp <= 0xDBFFu && i + 1 < char_cnt) {
            uint32_t lo = mp_be16(u16 + (i + 1) * 2);
            if (lo >= 0xDC00u && lo <= 0xDFFFu) {
                cp = 0x10000u + (((cp - 0xD800u) << 10) | (lo - 0xDC00u));
                i++;
            }
        }
        /* HFS+ stores POSIX ':' as '/' on disk; preserve embedded NULs as 0x01 for private dirs */
        if (cp == '/') cp = ':';
        else if (cp == 0) cp = 1;

        if (cp < 0x80u) {
            if (op + 1 >= out_cap) break;
            out[op++] = (char)cp;
        } else if (cp < 0x800u) {
            if (op + 2 >= out_cap) break;
            out[op++] = (char)(0xC0u | (cp >> 6));
            out[op++] = (char)(0x80u | (cp & 0x3Fu));
        } else if (cp < 0x10000u) {
            if (op + 3 >= out_cap) break;
            out[op++] = (char)(0xE0u | (cp >> 12));
            out[op++] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
            out[op++] = (char)(0x80u | (cp & 0x3Fu));
        } else {
            if (op + 4 >= out_cap) break;
            out[op++] = (char)(0xF0u | (cp >> 18));
            out[op++] = (char)(0x80u | ((cp >> 12) & 0x3Fu));
            out[op++] = (char)(0x80u | ((cp >> 6) & 0x3Fu));
            out[op++] = (char)(0x80u | (cp & 0x3Fu));
        }
    }
    out[op] = '\0';
    return op;
}

static macpkg_status_t hfs_read_fork_range(hfs_vol_t *v, uint32_t file_id, uint8_t fork_type,
                                           const hfs_fork_t *fork, uint64_t off, void *buf, size_t len,
                                           char *err, size_t err_sz);

static macpkg_status_t hfs_read_btree_node(hfs_vol_t *v, const hfs_btree_t *bt, uint32_t node_idx,
                                           uint8_t *buf, char *err, size_t err_sz) {
    if (node_idx >= bt->total_nodes) {
        mp_set_err(err, err_sz, "HFS+ B-tree node %u out of range", node_idx);
        return MACPKG_ERR_CORRUPT;
    }
    return hfs_read_fork_range(v, bt->file_id, HFS_FORK_DATA, &bt->fork,
                               (uint64_t)node_idx * bt->node_size, buf, bt->node_size, err, err_sz);
}

/* Search extents overflow B-tree for (file_id, fork_type, start_block). */
static macpkg_status_t hfs_find_overflow_extent(hfs_vol_t *v, uint32_t file_id, uint8_t fork_type,
                                                uint32_t target_block, hfs_extent_t out_extents[8],
                                                uint32_t *out_start_block,
                                                char *err, size_t err_sz) {
    if (v->extents.root_node == 0 || v->extents.node_size == 0) {
        mp_set_err(err, err_sz, "missing HFS+ extents B-tree");
        return MACPKG_ERR_NOT_FOUND;
    }
    uint8_t *node = (uint8_t *)malloc(v->extents.node_size);
    if (!node) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }

    uint32_t cur = v->extents.root_node;
    int depth = 0;
    while (depth++ < 32) {
        macpkg_status_t st = hfs_read_btree_node(v, &v->extents, cur, node, err, err_sz);
        if (st != MACPKG_OK) { free(node); return st; }
        int8_t kind = (int8_t)node[8];
        uint16_t nrec = mp_be16(node + 10);
        if (14u + (size_t)nrec * 2u > v->extents.node_size) {
            free(node);
            mp_set_err(err, err_sz, "HFS+ extents B-tree nrec out of bounds");
            return MACPKG_ERR_CORRUPT;
        }

        if (kind == 0) { /* index node */
            uint32_t chosen_child = 0;
            int found = 0;
            for (uint16_t i = 0; i < nrec; i++) {
                uint16_t roff = mp_be16(node + v->extents.node_size - 2u * (i + 1u));
                if (roff + 16u > v->extents.node_size) break;
                const uint8_t *r = node + roff;
                uint16_t klen = mp_be16(r);
                if (klen < 10 || (size_t)roff + 2u + klen + 4u > v->extents.node_size) continue;
                uint8_t kfork = r[2];
                uint32_t kfid = mp_be32(r + 4);
                uint32_t kblk = mp_be32(r + 8);
                int cmp;
                if (kfid != file_id) cmp = (kfid < file_id) ? -1 : 1;
                else if (kfork != fork_type) cmp = (kfork < fork_type) ? -1 : 1;
                else if (kblk != target_block) cmp = (kblk < target_block) ? -1 : 1;
                else cmp = 0;

                if (cmp <= 0) {
                    chosen_child = mp_be32(r + 2 + klen);
                    found = 1;
                } else {
                    break;
                }
            }
            if (!found) { free(node); return MACPKG_ERR_NOT_FOUND; }
            cur = chosen_child;
        } else if (kind == -1) { /* leaf node */
            int matched = 0;
            for (uint16_t i = 0; i < nrec; i++) {
                uint16_t roff = mp_be16(node + v->extents.node_size - 2u * (i + 1u));
                if (roff + 12u + 64u > v->extents.node_size) break;
                const uint8_t *r = node + roff;
                uint16_t klen = mp_be16(r);
                if (klen < 10 || (size_t)roff + 2u + klen + 64u > v->extents.node_size) continue;
                uint8_t kfork = r[2];
                uint32_t kfid = mp_be32(r + 4);
                uint32_t kblk = mp_be32(r + 8);
                if (kfid == file_id && kfork == fork_type && kblk <= target_block) {
                    const uint8_t *ed = r + 2 + klen;
                    for (int j = 0; j < 8; j++) {
                        out_extents[j].start_block = mp_be32(ed + j * 8);
                        out_extents[j].block_count = mp_be32(ed + 4 + j * 8);
                    }
                    *out_start_block = kblk;
                    matched = 1;
                } else if (kfid > file_id || (kfid == file_id && kfork > fork_type) ||
                           (kfid == file_id && kfork == fork_type && kblk > target_block)) {
                    break;
                }
            }
            free(node);
            return matched ? MACPKG_OK : MACPKG_ERR_NOT_FOUND;
        } else {
            free(node);
            mp_set_err(err, err_sz, "unexpected HFS+ extents node kind %d", kind);
            return MACPKG_ERR_CORRUPT;
        }
    }
    free(node);
    mp_set_err(err, err_sz, "HFS+ extents B-tree depth exceeded");
    return MACPKG_ERR_CORRUPT;
}

static macpkg_status_t hfs_read_fork_range(hfs_vol_t *v, uint32_t file_id, uint8_t fork_type,
                                           const hfs_fork_t *fork, uint64_t off, void *buf, size_t len,
                                           char *err, size_t err_sz) {
    if (len == 0) return MACPKG_OK;
    if (off > fork->logical_size || len > fork->logical_size - off) {
        mp_set_err(err, err_sz, "HFS+ fork read out of bounds");
        return MACPKG_ERR_CORRUPT;
    }

    uint8_t *dst = (uint8_t *)buf;
    size_t done = 0;

    while (done < len) {
        uint64_t cur = off + done;
        uint64_t lblock = cur / v->block_size;
        uint32_t in_block = (uint32_t)(cur % v->block_size);
        if (lblock > UINT32_MAX) {
            mp_set_err(err, err_sz, "HFS+ logical block overflow");
            return MACPKG_ERR_CORRUPT;
        }

        /* Find extent covering lblock */
        uint64_t acc = 0;
        uint64_t phys_block = 0;
        uint64_t rem_blocks = 0;
        int found = 0;

        for (int i = 0; i < 8; i++) {
            if (fork->extents[i].block_count == 0) break;
            if (lblock < acc + fork->extents[i].block_count) {
                uint64_t delta = lblock - acc;
                phys_block = (uint64_t)fork->extents[i].start_block + delta;
                rem_blocks = (uint64_t)fork->extents[i].block_count - delta;
                found = 1;
                break;
            }
            acc += fork->extents[i].block_count;
        }

        if (!found) {
            if (file_id == HFS_EXTENTS_FILE_ID) {
                mp_set_err(err, err_sz, "HFS+ extents file overflowed");
                return MACPKG_ERR_CORRUPT;
            }
            hfs_extent_t ov[8];
            uint32_t ov_start = 0;
            macpkg_status_t st = hfs_find_overflow_extent(v, file_id, fork_type, (uint32_t)lblock, ov, &ov_start, err, err_sz);
            if (st != MACPKG_OK) return st;
            uint64_t oacc = ov_start;
            for (int i = 0; i < 8; i++) {
                if (ov[i].block_count == 0) break;
                if (lblock < oacc + ov[i].block_count) {
                    uint64_t delta = lblock - oacc;
                    phys_block = (uint64_t)ov[i].start_block + delta;
                    rem_blocks = (uint64_t)ov[i].block_count - delta;
                    found = 1;
                    break;
                }
                oacc += ov[i].block_count;
            }
            if (!found) {
                mp_set_err(err, err_sz, "HFS+ block %llu not covered by extent", (unsigned long long)lblock);
                return MACPKG_ERR_CORRUPT;
            }
        }

        if (phys_block >= v->total_blocks || phys_block > UINT64_MAX / v->block_size) {
            mp_set_err(err, err_sz, "HFS+ physical block %llu out of range", (unsigned long long)phys_block);
            return MACPKG_ERR_CORRUPT;
        }
        if (rem_blocks > v->total_blocks - phys_block) {
            rem_blocks = v->total_blocks - phys_block;
        }
        if (rem_blocks > UINT64_MAX / v->block_size) {
            rem_blocks = UINT64_MAX / v->block_size;
        }
        uint64_t avail = rem_blocks * v->block_size - in_block;
        size_t step = (avail > len - done) ? (len - done) : (size_t)avail;
        uint64_t disk_off = phys_block * v->block_size + in_block;
        macpkg_status_t st = mp_stream_read_exact(v->stream, disk_off, dst + done, step, err, err_sz);
        if (st != MACPKG_OK) return st;
        done += step;
    }
    return MACPKG_OK;
}

static macpkg_status_t hfs_read_fork_alloc(hfs_vol_t *v, uint32_t file_id, uint8_t fork_type,
                                           const hfs_fork_t *fork, uint8_t **out_buf, size_t *out_len,
                                           char *err, size_t err_sz) {
    if (fork->logical_size > 512ULL * 1024ULL * 1024ULL) {
        mp_set_err(err, err_sz, "HFS+ fork too large for buffer (%llu)",
                   (unsigned long long)fork->logical_size);
        return MACPKG_ERR_UNSUPPORTED;
    }
    size_t sz = (size_t)fork->logical_size;
    uint8_t *buf = (uint8_t *)malloc(sz ? sz : 1);
    if (!buf) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
    macpkg_status_t st = hfs_read_fork_range(v, file_id, fork_type, fork, 0, buf, sz, err, err_sz);
    if (st != MACPKG_OK) { free(buf); return st; }
    *out_buf = buf;
    *out_len = sz;
    return MACPKG_OK;
}

static macpkg_status_t hfs_open_btree(hfs_vol_t *v, uint32_t file_id, const hfs_fork_t *fork,
                                      hfs_btree_t *bt, char *err, size_t err_sz) {
    memset(bt, 0, sizeof(*bt));
    bt->file_id = file_id;
    bt->fork = *fork;
    if (fork->logical_size < 128) {
        mp_set_err(err, err_sz, "HFS+ B-tree file %u empty", file_id);
        return MACPKG_ERR_NOT_FOUND;
    }
    uint8_t hdr[128];
    macpkg_status_t st = hfs_read_fork_range(v, file_id, HFS_FORK_DATA, fork, 0, hdr, sizeof(hdr), err, err_sz);
    if (st != MACPKG_OK) return st;

    if ((int8_t)hdr[8] != 1) { /* kBTHeaderNode */
        mp_set_err(err, err_sz, "HFS+ B-tree %u node 0 is not header", file_id);
        return MACPKG_ERR_CORRUPT;
    }
    const uint8_t *bth = hdr + 14;
    bt->root_node = mp_be32(bth + 2);
    bt->first_leaf = mp_be32(bth + 10);
    bt->node_size = mp_be16(bth + 18);
    bt->total_nodes = mp_be32(bth + 22);
    bt->key_compare_type = bth[37];
    bt->attributes = mp_be32(bth + 38);
    if (bt->node_size < 512 || (bt->node_size & (bt->node_size - 1)) != 0) {
        mp_set_err(err, err_sz, "invalid HFS+ B-tree node size %u", bt->node_size);
        return MACPKG_ERR_CORRUPT;
    }
    return MACPKG_OK;
}

/* Lookup an extended attribute in attributesFile B-tree for (file_id, attr_name_ascii). */
static macpkg_status_t hfs_read_attr(hfs_vol_t *v, uint32_t file_id, const char *attr_name,
                                     uint8_t **out_data, size_t *out_len,
                                     char *err, size_t err_sz) {
    *out_data = NULL;
    *out_len = 0;
    if (!v->has_attrs || v->attrs.root_node == 0) return MACPKG_ERR_NOT_FOUND;

    uint8_t *node = (uint8_t *)malloc(v->attrs.node_size);
    if (!node) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }

    /* Descend B-tree looking for (file_id, startBlock=0, attrName="") */
    uint32_t cur = v->attrs.root_node;
    int depth = 0;
    int reached_leaf = 0;
    while (depth++ < 32) {
        macpkg_status_t st = hfs_read_btree_node(v, &v->attrs, cur, node, err, err_sz);
        if (st != MACPKG_OK) { free(node); return st; }
        int8_t kind = (int8_t)node[8];
        uint16_t nrec = mp_be16(node + 10);
        if (14u + (size_t)nrec * 2u > v->attrs.node_size) {
            free(node);
            mp_set_err(err, err_sz, "HFS+ attributes B-tree nrec out of bounds");
            return MACPKG_ERR_CORRUPT;
        }

        if (kind == 0) { /* index */
            uint32_t chosen = 0;
            int has_chosen = 0;
            for (uint16_t i = 0; i < nrec; i++) {
                uint16_t roff = mp_be16(node + v->attrs.node_size - 2u * (i + 1u));
                if (roff + 18u > v->attrs.node_size) break;
                const uint8_t *r = node + roff;
                uint16_t klen = mp_be16(r);
                if (klen < 12 || roff + 2u + klen + 4u > v->attrs.node_size) continue;
                uint32_t kfid = mp_be32(r + 4);
                uint32_t kblk = mp_be32(r + 8);
                uint16_t knlen = mp_be16(r + 12);
                int cmp;
                if (kfid != file_id) cmp = (kfid < file_id) ? -1 : 1;
                else if (kblk != 0) cmp = 1;
                else cmp = (knlen == 0) ? 0 : 1;

                if (cmp <= 0 || !has_chosen) {
                    chosen = mp_be32(r + 2 + klen);
                    has_chosen = 1;
                }
                if (cmp > 0) break;
            }
            if (!has_chosen) { free(node); return MACPKG_ERR_NOT_FOUND; }
            cur = chosen;
        } else if (kind == -1) {
            reached_leaf = 1;
            break;
        } else {
            free(node);
            mp_set_err(err, err_sz, "invalid HFS+ attributes B-tree node kind %d", kind);
            return MACPKG_ERR_CORRUPT;
        }
    }
    if (!reached_leaf) {
        free(node);
        mp_set_err(err, err_sz, "HFS+ attributes B-tree depth exceeded");
        return MACPKG_ERR_CORRUPT;
    }

    size_t target_len = strlen(attr_name);
    uint32_t tortoise = cur;
    uint64_t power = 1, lam = 0, steps = 0;
    while (cur != 0) {
        if ((int8_t)node[8] != -1) {
            free(node);
            mp_set_err(err, err_sz, "HFS+ attributes B-tree expected leaf node");
            return MACPKG_ERR_CORRUPT;
        }
        uint32_t next = mp_be32(node);
        uint16_t nrec = mp_be16(node + 10);
        if (14u + (size_t)nrec * 2u > v->attrs.node_size) {
            free(node);
            mp_set_err(err, err_sz, "HFS+ attributes B-tree nrec out of bounds");
            return MACPKG_ERR_CORRUPT;
        }
        for (uint16_t i = 0; i < nrec; i++) {
            uint16_t roff = mp_be16(node + v->attrs.node_size - 2u * (i + 1u));
            if (roff + 16u > v->attrs.node_size) break;
            const uint8_t *r = node + roff;
            uint16_t klen = mp_be16(r);
            if (klen < 12 || roff + 2u + klen > v->attrs.node_size) continue;
            uint32_t kfid = mp_be32(r + 4);
            if (kfid < file_id) continue;
            if (kfid > file_id) { free(node); return MACPKG_ERR_NOT_FOUND; }

            uint32_t kblk = mp_be32(r + 8);
            uint16_t knlen = mp_be16(r + 12);
            if (12u + (size_t)knlen * 2u > klen) continue;
            char namebuf[256];
            utf16be_to_utf8(r + 14, knlen, namebuf, sizeof(namebuf));
            if (kblk == 0 && strlen(namebuf) == target_len && strcmp(namebuf, attr_name) == 0) {
                const uint8_t *val = r + 2 + klen;
                size_t avail = v->attrs.node_size - (size_t)(val - node);
                if (avail < 16) { free(node); return MACPKG_ERR_CORRUPT; }
                uint32_t rec_type = mp_be32(val);
                if (rec_type == 0x10u) { /* kHFSPlusAttrInlineData */
                    uint32_t dsz = mp_be32(val + 12);
                    if ((size_t)dsz > avail - 16u) { free(node); return MACPKG_ERR_CORRUPT; }
                    uint8_t *out = (uint8_t *)malloc(dsz ? dsz : 1);
                    if (!out) { free(node); mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
                    memcpy(out, val + 16, dsz);
                    *out_data = out;
                    *out_len = dsz;
                    free(node);
                    return MACPKG_OK;
                } else if (rec_type == 0x20u) { /* kHFSPlusAttrForkData */
                    if (avail < 88) { free(node); return MACPKG_ERR_CORRUPT; }
                    hfs_fork_t afork;
                    parse_fork(val + 8, &afork);
                    free(node);
                    return hfs_read_fork_alloc(v, file_id, HFS_FORK_DATA, &afork, out_data, out_len, err, err_sz);
                }
            }
        }
        cur = next;
        if (cur != 0) {
            if (cur == tortoise || ++steps > v->attrs.total_nodes) {
                free(node);
                mp_set_err(err, err_sz, "HFS+ attributes B-tree leaf cycle");
                return MACPKG_ERR_CORRUPT;
            }
            if (++lam == power) { tortoise = cur; power *= 2; lam = 0; }
            macpkg_status_t st = hfs_read_btree_node(v, &v->attrs, cur, node, err, err_sz);
            if (st != MACPKG_OK) { free(node); return st; }
        }
    }

    free(node);
    return MACPKG_ERR_NOT_FOUND;
}

/* Catalog iterator callback for children of parent_id */
typedef macpkg_status_t (*hfs_cat_cb)(void *ctx, const char *name, const uint8_t *rec, size_t rec_len,
                                      char *err, size_t err_sz);

static macpkg_status_t hfs_iter_parent(hfs_vol_t *v, uint32_t parent_id, hfs_cat_cb cb, void *cb_ctx,
                                       char *err, size_t err_sz) {
    uint8_t *node = (uint8_t *)malloc(v->catalog.node_size);
    if (!node) { mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }

    /* Descend index nodes searching for (parent_id, "") */
    uint32_t cur = v->catalog.root_node;
    int depth = 0;
    int reached_leaf = 0;
    while (depth++ < 32) {
        macpkg_status_t st = hfs_read_btree_node(v, &v->catalog, cur, node, err, err_sz);
        if (st != MACPKG_OK) { free(node); return st; }
        int8_t kind = (int8_t)node[8];
        uint16_t nrec = mp_be16(node + 10);
        if (14u + (size_t)nrec * 2u > v->catalog.node_size) {
            free(node);
            mp_set_err(err, err_sz, "HFS+ catalog B-tree nrec out of bounds");
            return MACPKG_ERR_CORRUPT;
        }

        if (kind == 0) { /* index */
            uint32_t chosen = 0;
            int has_chosen = 0;
            for (uint16_t i = 0; i < nrec; i++) {
                uint16_t roff = mp_be16(node + v->catalog.node_size - 2u * (i + 1u));
                if (roff + 12u > v->catalog.node_size) break;
                const uint8_t *r = node + roff;
                uint16_t klen = mp_be16(r);
                if (klen < 6 || roff + 2u + klen + 4u > v->catalog.node_size) continue;
                uint32_t kpid = mp_be32(r + 2);
                uint16_t knlen = mp_be16(r + 6);
                int cmp;
                if (kpid != parent_id) cmp = (kpid < parent_id) ? -1 : 1;
                else cmp = (knlen == 0) ? 0 : 1;

                if (cmp <= 0 || !has_chosen) {
                    chosen = mp_be32(r + 2 + klen);
                    has_chosen = 1;
                }
                if (cmp > 0) break;
            }
            if (!has_chosen) { free(node); return MACPKG_OK; }
            cur = chosen;
        } else if (kind == -1) {
            reached_leaf = 1;
            break;
        } else {
            free(node);
            mp_set_err(err, err_sz, "unexpected HFS+ catalog node kind %d", kind);
            return MACPKG_ERR_CORRUPT;
        }
    }
    if (!reached_leaf) {
        free(node);
        mp_set_err(err, err_sz, "HFS+ catalog B-tree depth exceeded");
        return MACPKG_ERR_CORRUPT;
    }

    uint32_t tortoise = cur;
    uint64_t power = 1, lam = 0, steps = 0;
    while (cur != 0) {
        if ((int8_t)node[8] != -1) {
            free(node);
            mp_set_err(err, err_sz, "HFS+ catalog B-tree expected leaf node");
            return MACPKG_ERR_CORRUPT;
        }
        uint32_t next = mp_be32(node);
        uint16_t nrec = mp_be16(node + 10);
        if (14u + (size_t)nrec * 2u > v->catalog.node_size) {
            free(node);
            mp_set_err(err, err_sz, "HFS+ catalog B-tree nrec out of bounds");
            return MACPKG_ERR_CORRUPT;
        }
        for (uint16_t i = 0; i < nrec; i++) {
            uint16_t roff = mp_be16(node + v->catalog.node_size - 2u * (i + 1u));
            if (roff + 10u > v->catalog.node_size) break;
            const uint8_t *r = node + roff;
            uint16_t klen = mp_be16(r);
            if (klen < 6 || roff + 2u + klen > v->catalog.node_size) continue;
            uint32_t kpid = mp_be32(r + 2);
            if (kpid < parent_id) continue;
            if (kpid > parent_id) { free(node); return MACPKG_OK; }

            uint16_t knlen = mp_be16(r + 6);
            if (6u + (size_t)knlen * 2u > klen || knlen == 0) continue;
            char name[1024];
            utf16be_to_utf8(r + 8, knlen, name, sizeof(name));

            const uint8_t *rec = r + 2 + klen;
            size_t rec_avail = v->catalog.node_size - (size_t)(rec - node);
            macpkg_status_t st = cb(cb_ctx, name, rec, rec_avail, err, err_sz);
            if (st != MACPKG_OK) { free(node); return st; }
        }
        cur = next;
        if (cur != 0) {
            if (cur == tortoise || ++steps > v->catalog.total_nodes) {
                free(node);
                mp_set_err(err, err_sz, "HFS+ catalog B-tree leaf cycle");
                return MACPKG_ERR_CORRUPT;
            }
            if (++lam == power) { tortoise = cur; power *= 2; lam = 0; }
            macpkg_status_t st = hfs_read_btree_node(v, &v->catalog, cur, node, err, err_sz);
            if (st != MACPKG_OK) { free(node); return st; }
        }
    }

    free(node);
    return MACPKG_OK;
}

typedef struct {
    const char *target_name;
    int found;
    uint16_t rec_type;
    uint32_t obj_id;
    uint8_t file_rec[248];
    size_t file_rec_len;
} hfs_find_one_ctx_t;

static macpkg_status_t hfs_find_one_cb(void *vctx, const char *name, const uint8_t *rec, size_t rec_len,
                                       char *err, size_t err_sz) {
    (void)err; (void)err_sz;
    hfs_find_one_ctx_t *ctx = (hfs_find_one_ctx_t *)vctx;
    if (ctx->found) return MACPKG_OK;
    if (strcmp(name, ctx->target_name) != 0) return MACPKG_OK;
    if (rec_len < 12) return MACPKG_OK;
    ctx->rec_type = mp_be16(rec);
    ctx->obj_id = mp_be32(rec + 8);
    if (ctx->rec_type == HFS_REC_FILE && rec_len >= 248) {
        memcpy(ctx->file_rec, rec, 248);
        ctx->file_rec_len = 248;
    }
    ctx->found = 1;
    return MACPKG_OK;
}

static const char *hfs_lookup_hlink(const hfs_vol_t *v, uint32_t inode_num) {
    for (size_t i = 0; i < v->hlink_count; i++) {
        if (v->hlinks[i].inode_num == inode_num) return v->hlinks[i].rel_path;
    }
    return NULL;
}

static void hfs_record_hlink(hfs_vol_t *v, uint32_t inode_num, const char *rel_path) {
    if (v->hlink_count == v->hlink_cap) {
        size_t ncap = v->hlink_cap ? v->hlink_cap * 2 : 32;
        hfs_hlink_t *nh = (hfs_hlink_t *)realloc(v->hlinks, ncap * sizeof(*nh));
        if (!nh) return;
        v->hlinks = nh;
        v->hlink_cap = ncap;
    }
    size_t len = strlen(rel_path) + 1;
    char *copy = (char *)malloc(len);
    if (!copy) return;
    memcpy(copy, rel_path, len);
    v->hlinks[v->hlink_count].inode_num = inode_num;
    v->hlinks[v->hlink_count].rel_path = copy;
    v->hlink_count++;
}

static macpkg_status_t hfs_write_file_record(hfs_vol_t *v, const char *rel_path, const uint8_t *rec,
                                             char *err, size_t err_sz) {
    uint32_t file_id = mp_be32(rec + 8);
    uint8_t owner_flags = rec[41];
    uint16_t file_mode = mp_be16(rec + 42);
    uint32_t fd_type = mp_be32(rec + 48);
    uint32_t fd_creator = mp_be32(rec + 52);

    hfs_fork_t data_fork, rsrc_fork;
    parse_fork(rec + 88, &data_fork);
    parse_fork(rec + 168, &rsrc_fork);

    if (S_ISLNK(file_mode) || (fd_type == 0x736c6e6bu && fd_creator == 0x72686170u)) {
        uint8_t *tbuf = NULL;
        size_t tlen = 0;
        macpkg_status_t st = hfs_read_fork_alloc(v, file_id, HFS_FORK_DATA, &data_fork,
                                                 &tbuf, &tlen, err, err_sz);
        if (st != MACPKG_OK) return st;
        char *target = (char *)malloc(tlen + 1);
        if (!target) { free(tbuf); mp_set_err(err, err_sz, "out of memory"); return MACPKG_ERR_NOMEM; }
        memcpy(target, tbuf, tlen);
        target[tlen] = '\0';
        free(tbuf);
        st = mp_sink_symlink(v->sink, rel_path, target, err, err_sz);
        free(target);
        return st;
    }

    uint16_t perm = file_mode ? (file_mode & 07777u) : 0644u;

    /* Check decmpfs transparent compression */
    if ((owner_flags & HFS_UF_COMPRESSED) || (data_fork.logical_size == 0 && rsrc_fork.logical_size > 0 && v->has_attrs)) {
        uint8_t *xattr = NULL;
        size_t xlen = 0;
        macpkg_status_t ast = hfs_read_attr(v, file_id, "com.apple.decmpfs", &xattr, &xlen, err, err_sz);
        if (ast == MACPKG_OK) {
            uint8_t *rbuf = NULL;
            size_t rlen = 0;
            if (rsrc_fork.logical_size > 0) {
                macpkg_status_t rst = hfs_read_fork_alloc(v, file_id, HFS_FORK_RSRC, &rsrc_fork,
                                                          &rbuf, &rlen, err, err_sz);
                if (rst != MACPKG_OK) { free(xattr); return rst; }
            }
            uint8_t *ubuf = NULL;
            size_t ulen = 0;
            macpkg_status_t dst = mp_decode_decmpfs(xattr, xlen, rbuf, rlen, &ubuf, &ulen, err, err_sz);
            free(xattr);
            free(rbuf);
            if (dst != MACPKG_OK) return dst;
            dst = mp_sink_write_file(v->sink, rel_path, perm, ubuf, ulen, err, err_sz);
            free(ubuf);
            return dst;
        }
    }

    /* Stream data fork directly to output file (handles arbitrarily large binaries) */
    FILE *fp = NULL;
    char *full_path = NULL;
    macpkg_status_t st = mp_sink_begin_file(v->sink, rel_path, perm, &fp, &full_path, err, err_sz);
    if (st != MACPKG_OK) return st;

    uint8_t *chunk = (uint8_t *)malloc(262144);
    if (!chunk) {
        fclose(fp); free(full_path);
        mp_set_err(err, err_sz, "out of memory");
        return MACPKG_ERR_NOMEM;
    }

    uint64_t off = 0;
    while (off < data_fork.logical_size) {
        size_t step = (data_fork.logical_size - off > 262144u) ? 262144u : (size_t)(data_fork.logical_size - off);
        st = hfs_read_fork_range(v, file_id, HFS_FORK_DATA, &data_fork, off, chunk, step, err, err_sz);
        if (st != MACPKG_OK) {
            free(chunk); fclose(fp); free(full_path);
            return st;
        }
        if (fwrite(chunk, 1, step, fp) != step) {
            free(chunk); fclose(fp); free(full_path);
            mp_set_err(err, err_sz, "write error on '%s'", rel_path);
            return MACPKG_ERR_IO;
        }
        off += step;
    }
    free(chunk);
    if (v->sink->verbose) {
        fprintf(stderr, "  file %s (%llu bytes, mode %04o)\n", rel_path,
                (unsigned long long)data_fork.logical_size, perm);
    }
    return mp_sink_end_file(fp, full_path, perm, err, err_sz);
}

typedef struct {
    hfs_vol_t *vol;
    const char *parent_raw_path;
    int depth;
} hfs_walk_ctx_t;

static macpkg_status_t hfs_walk_dir(hfs_vol_t *v, uint32_t folder_id, const char *parent_raw_path,
                                    int depth, char *err, size_t err_sz);

static macpkg_status_t hfs_walk_cb(void *vctx, const char *name, const uint8_t *rec, size_t rec_len,
                                   char *err, size_t err_sz) {
    hfs_walk_ctx_t *w = (hfs_walk_ctx_t *)vctx;
    hfs_vol_t *v = w->vol;

    /* Skip HFS+ private metadata directories */
    if (name[0] == '\x01' ||
        strstr(name, "HFS+ Private Data") != NULL ||
        strstr(name, "HFS+ Private Directory Data") != NULL) {
        return MACPKG_OK;
    }

    if (rec_len < 12) return MACPKG_OK;
    uint16_t rec_type = mp_be16(rec);

    char raw_path[4096];
    if (w->parent_raw_path[0]) {
        if (snprintf(raw_path, sizeof(raw_path), "%s/%s", w->parent_raw_path, name) >= (int)sizeof(raw_path)) {
            mp_set_err(err, err_sz, "path too long");
            return MACPKG_ERR_PATH;
        }
    } else {
        if (snprintf(raw_path, sizeof(raw_path), "%s", name) >= (int)sizeof(raw_path)) {
            mp_set_err(err, err_sz, "path too long");
            return MACPKG_ERR_PATH;
        }
    }

    char rel_path[4096];
    int keep = mp_filter_app_relpath(raw_path, v->opts, rel_path, sizeof(rel_path));

    if (rec_type == HFS_REC_FOLDER && rec_len >= 88) {
        uint32_t child_fid = mp_be32(rec + 8);
        uint16_t fmode = mp_be16(rec + 42);
        if (keep) {
            macpkg_status_t st = mp_sink_mkdir(v->sink, rel_path, fmode ? (fmode & 07777u) : 0755u, err, err_sz);
            if (st != MACPKG_OK) return st;
        }
        /* Always descend if keep OR if we haven't entered an .app yet */
        if (keep || !(v->opts && v->opts->extract_all_files)) {
            return hfs_walk_dir(v, child_fid, raw_path, w->depth + 1, err, err_sz);
        }
    } else if (rec_type == HFS_REC_FILE && rec_len >= 248) {
        uint32_t fd_type = mp_be32(rec + 48);
        uint32_t fd_creator = mp_be32(rec + 52);
        uint32_t special = mp_be32(rec + 44);

        /* Directory hard link */
        if (fd_type == 0x66647270u && fd_creator == 0x4d414353u && v->priv_dir_folder_id) {
            char dname[64];
            snprintf(dname, sizeof(dname), "dir_%u", special);
            hfs_find_one_ctx_t fc;
            memset(&fc, 0, sizeof(fc));
            fc.target_name = dname;
            macpkg_status_t st = hfs_iter_parent(v, v->priv_dir_folder_id, hfs_find_one_cb, &fc, err, err_sz);
            if (st != MACPKG_OK) return st;
            if (fc.found && fc.rec_type == HFS_REC_FOLDER) {
                if (keep) {
                    st = mp_sink_mkdir(v->sink, rel_path, 0755, err, err_sz);
                    if (st != MACPKG_OK) return st;
                }
                return hfs_walk_dir(v, fc.obj_id, raw_path, w->depth + 1, err, err_sz);
            }
            return MACPKG_OK;
        }

        if (!keep) return MACPKG_OK;

        /* File hard link */
        if (fd_type == 0x686c6e6bu && fd_creator == 0x6866732bu && v->priv_data_folder_id) {
            const char *existing = hfs_lookup_hlink(v, special);
            if (existing) {
                return mp_sink_hardlink(v->sink, rel_path, existing, err, err_sz);
            }
            char iname[64];
            snprintf(iname, sizeof(iname), "iNode%u", special);
            hfs_find_one_ctx_t fc;
            memset(&fc, 0, sizeof(fc));
            fc.target_name = iname;
            macpkg_status_t st = hfs_iter_parent(v, v->priv_data_folder_id, hfs_find_one_cb, &fc, err, err_sz);
            if (st != MACPKG_OK) return st;
            if (!fc.found || fc.rec_type != HFS_REC_FILE) {
                mp_set_err(err, err_sz, "missing HFS+ hardlink target %s", iname);
                return MACPKG_ERR_CORRUPT;
            }
            st = hfs_write_file_record(v, rel_path, fc.file_rec, err, err_sz);
            if (st == MACPKG_OK) hfs_record_hlink(v, special, rel_path);
            return st;
        }

        return hfs_write_file_record(v, rel_path, rec, err, err_sz);
    }

    return MACPKG_OK;
}

static macpkg_status_t hfs_walk_dir(hfs_vol_t *v, uint32_t folder_id, const char *parent_raw_path,
                                    int depth, char *err, size_t err_sz) {
    if (depth >= 64) {
        mp_set_err(err, err_sz, "HFS+ directory nesting depth exceeded");
        return MACPKG_ERR_CORRUPT;
    }
    hfs_walk_ctx_t w = {v, parent_raw_path, depth};
    return hfs_iter_parent(v, folder_id, hfs_walk_cb, &w, err, err_sz);
}

static macpkg_status_t hfs_find_priv_cb(void *vctx, const char *name, const uint8_t *rec, size_t rec_len,
                                        char *err, size_t err_sz) {
    (void)err; (void)err_sz;
    hfs_vol_t *v = (hfs_vol_t *)vctx;
    if (rec_len >= 88 && mp_be16(rec) == HFS_REC_FOLDER) {
        if (strstr(name, "HFS+ Private Data") != NULL) {
            v->priv_data_folder_id = mp_be32(rec + 8);
        } else if (strstr(name, "HFS+ Private Directory Data") != NULL) {
            v->priv_dir_folder_id = mp_be32(rec + 8);
        }
    }
    return MACPKG_OK;
}

macpkg_status_t mp_extract_hfsplus(macpkg_stream_t *stream, const char *output_dir,
                                   const macpkg_options_t *opts, char *err, size_t err_sz) {
    uint8_t vh[512];
    macpkg_status_t st = mp_stream_read_exact(stream, 1024, vh, sizeof(vh), err, err_sz);
    if (st != MACPKG_OK) return st;

    uint16_t sig = mp_be16(vh);
    if (sig != 0x482Bu && sig != 0x4858u) {
        mp_set_err(err, err_sz, "invalid HFS+ signature 0x%04x", sig);
        return MACPKG_ERR_FORMAT;
    }

    hfs_vol_t vol;
    memset(&vol, 0, sizeof(vol));
    vol.stream = stream;
    vol.block_size = mp_be32(vh + 40);
    vol.total_blocks = mp_be32(vh + 44);
    vol.opts = opts;
    if (vol.block_size < 512 || (vol.block_size & (vol.block_size - 1)) != 0) {
        mp_set_err(err, err_sz, "invalid HFS+ block size %u", vol.block_size);
        return MACPKG_ERR_CORRUPT;
    }

    hfs_fork_t ext_fork, cat_fork, attr_fork;
    parse_fork(vh + 192, &ext_fork);
    parse_fork(vh + 272, &cat_fork);
    parse_fork(vh + 352, &attr_fork);

    if (ext_fork.logical_size >= 128) {
        st = hfs_open_btree(&vol, HFS_EXTENTS_FILE_ID, &ext_fork, &vol.extents, err, err_sz);
        if (st != MACPKG_OK && st != MACPKG_ERR_NOT_FOUND) return st;
    }
    st = hfs_open_btree(&vol, HFS_CATALOG_FILE_ID, &cat_fork, &vol.catalog, err, err_sz);
    if (st != MACPKG_OK) return st;

    if (attr_fork.logical_size >= 128) {
        if (hfs_open_btree(&vol, HFS_ATTRIBUTES_FILE_ID, &attr_fork, &vol.attrs, err, err_sz) == MACPKG_OK) {
            vol.has_attrs = 1;
        }
    }

    /* Locate private metadata folders under root (folderID = 2) for hard links */
    hfs_iter_parent(&vol, HFS_ROOT_FOLDER_ID, hfs_find_priv_cb, &vol, err, err_sz);

    mp_sink_t sink;
    st = mp_sink_init(&sink, output_dir, opts ? opts->verbose : 0, err, err_sz);
    if (st != MACPKG_OK) return st;
    vol.sink = &sink;

    st = hfs_walk_dir(&vol, HFS_ROOT_FOLDER_ID, "", 0, err, err_sz);

    size_t total_items = sink.files_written + sink.symlinks_written + sink.hardlinks_written + sink.dirs_created;
    mp_sink_finish(&sink);
    for (size_t i = 0; i < vol.hlink_count; i++) free(vol.hlinks[i].rel_path);
    free(vol.hlinks);

    if (st != MACPKG_OK) return st;
    if (total_items == 0) {
        mp_set_err(err, err_sz, "no .app bundle found in HFS+ volume");
        return MACPKG_ERR_NOT_FOUND;
    }
    return MACPKG_OK;
}
