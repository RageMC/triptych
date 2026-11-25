#include "macpkg_internal.h"
#include <ctype.h>

/* ---- Base64 decoder ---- */
static int b64_val(unsigned char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static uint8_t *b64_decode(const char *s, size_t len, size_t *out_len) {
    size_t max_out = (len / 4 + 1) * 3 + 4;
    uint8_t *out = (uint8_t *)malloc(max_out);
    if (!out) return NULL;
    size_t op = 0;
    uint32_t acc = 0;
    int bits = 0;
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (isspace(c) || c == '=') continue;
        int v = b64_val(c);
        if (v < 0) continue;
        acc = (acc << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[op++] = (uint8_t)((acc >> bits) & 0xFFu);
        }
    }
    *out_len = op;
    return out;
}

/* ---- Minimal XML scanner ---- */
static char *xml_unescape(const char *s, size_t len) {
    char *out = (char *)malloc(len + 1);
    if (!out) return NULL;
    size_t op = 0;
    for (size_t i = 0; i < len; i++) {
        if (s[i] == '&') {
            if (i + 5 <= len && strncmp(s + i, "&amp;", 5) == 0) {
                out[op++] = '&'; i += 4; continue;
            }
            if (i + 4 <= len && strncmp(s + i, "&lt;", 4) == 0) {
                out[op++] = '<'; i += 3; continue;
            }
            if (i + 4 <= len && strncmp(s + i, "&gt;", 4) == 0) {
                out[op++] = '>'; i += 3; continue;
            }
            if (i + 6 <= len && strncmp(s + i, "&quot;", 6) == 0) {
                out[op++] = '"'; i += 5; continue;
            }
            if (i + 6 <= len && strncmp(s + i, "&apos;", 6) == 0) {
                out[op++] = '\''; i += 5; continue;
            }
        }
        out[op++] = s[i];
    }
    out[op] = '\0';
    return out;
}

static char *mp_strndup_local(const char *s, size_t n) {
    char *p = (char *)malloc(n + 1);
    if (p) { memcpy(p, s, n); p[n] = '\0'; }
    return p;
}

/* Parse attribute value inside a tag string, e.g. style="application/x-gzip" */
static char *xml_get_attr(const char *tag_start, const char *tag_end, const char *attr) {
    size_t alen = strlen(attr);
    const char *p = tag_start;
    while (p < tag_end) {
        while (p < tag_end && isspace((unsigned char)*p)) p++;
        if (p + alen + 2 <= tag_end && strncmp(p, attr, alen) == 0 && p[alen] == '=') {
            const char *q = p + alen + 1;
            if (q < tag_end && (*q == '"' || *q == '\'')) {
                char quote = *q++;
                const char *e = (const char *)memchr(q, quote, (size_t)(tag_end - q));
                if (e) return xml_unescape(q, (size_t)(e - q));
            }
        }
        while (p < tag_end && !isspace((unsigned char)*p)) p++;
    }
    return NULL;
}

/* ---- UDIF Plist Parser ---- */
macpkg_status_t mp_parse_udif_plist(const char *xml, size_t xml_len,
                                    mp_blkx_entry_t **out_entries, size_t *out_count,
                                    char *err, size_t err_sz) {
    *out_entries = NULL;
    *out_count = 0;

    mp_blkx_entry_t *entries = NULL;
    size_t count = 0, cap = 0;

    int in_blkx_array = 0;
    int array_depth = 0;
    int in_blkx_dict = 0;
    int dict_depth = 0;
    char cur_key[128] = {0};
    char last_key[128] = {0};

    mp_blkx_entry_t cur;
    memset(&cur, 0, sizeof(cur));

    const char *p = xml;
    const char *end = xml + xml_len;

    while (p < end) {
        const char *lt = (const char *)memchr(p, '<', (size_t)(end - p));
        if (!lt) break;
        p = lt;
        if (p + 4 <= end && strncmp(p, "<!--", 4) == 0) {
            const char *ce = strstr(p + 4, "-->");
            if (!ce || ce >= end) break;
            p = ce + 3;
            continue;
        }
        if (p + 2 <= end && (p[1] == '?' || p[1] == '!')) {
            const char *gt = (const char *)memchr(p, '>', (size_t)(end - p));
            if (!gt) break;
            p = gt + 1;
            continue;
        }
        const char *gt = (const char *)memchr(p + 1, '>', (size_t)(end - (p + 1)));
        if (!gt) break;

        int is_close = (p[1] == '/');
        int is_self_close = (gt > p + 1 && gt[-1] == '/');
        const char *name_s = is_close ? p + 2 : p + 1;
        const char *name_e = name_s;
        while (name_e < gt && !isspace((unsigned char)*name_e) && *name_e != '/') name_e++;
        size_t nlen = (size_t)(name_e - name_s);

        p = gt + 1;

        if (!is_close && !is_self_close) {
            if (nlen == 3 && strncmp(name_s, "key", 3) == 0) {
                const char *close_tag = (const char *)memchr(p, '<', (size_t)(end - p));
                if (!close_tag) break;
                size_t kl = (size_t)(close_tag - p);
                if (kl >= sizeof(last_key)) kl = sizeof(last_key) - 1;
                memcpy(last_key, p, kl);
                last_key[kl] = '\0';
                if (in_blkx_dict) {
                    snprintf(cur_key, sizeof(cur_key), "%s", last_key);
                }
            } else if (nlen == 5 && strncmp(name_s, "array", 5) == 0) {
                if (!in_blkx_array && strcmp(last_key, "blkx") == 0) {
                    in_blkx_array = 1;
                    array_depth = 1;
                } else if (in_blkx_array) {
                    array_depth++;
                }
            } else if (nlen == 4 && strncmp(name_s, "dict", 4) == 0) {
                if (in_blkx_array && array_depth == 1 && !in_blkx_dict) {
                    in_blkx_dict = 1;
                    dict_depth = 1;
                    memset(&cur, 0, sizeof(cur));
                    cur_key[0] = '\0';
                } else if (in_blkx_dict) {
                    dict_depth++;
                }
            } else if (in_blkx_dict && dict_depth == 1) {
                if ((nlen == 6 && strncmp(name_s, "string", 6) == 0) ||
                    (nlen == 4 && strncmp(name_s, "data", 4) == 0)) {
                    const char *close_tag = (const char *)memchr(p, '<', (size_t)(end - p));
                    if (!close_tag) break;
                    size_t vlen = (size_t)(close_tag - p);
                    if (nlen == 6) {
                        char *val = xml_unescape(p, vlen);
                        if (strcmp(cur_key, "Name") == 0) { free(cur.name); cur.name = val; }
                        else if (strcmp(cur_key, "ID") == 0) { free(cur.id); cur.id = val; }
                        else if (strcmp(cur_key, "CFName") == 0) { free(cur.cfname); cur.cfname = val; }
                        else free(val);
                    } else {
                        if (strcmp(cur_key, "Data") == 0) {
                            free(cur.data);
                            cur.data = b64_decode(p, vlen, &cur.data_len);
                        }
                    }
                    cur_key[0] = '\0';
                }
            }
        } else if (is_close) {
            if (nlen == 5 && strncmp(name_s, "array", 5) == 0 && in_blkx_array) {
                array_depth--;
                if (array_depth == 0) in_blkx_array = 0;
            } else if (nlen == 4 && strncmp(name_s, "dict", 4) == 0 && in_blkx_dict) {
                dict_depth--;
                if (dict_depth == 0) {
                    in_blkx_dict = 0;
                    if (cur.data && cur.data_len >= 204) {
                        if (count == cap) {
                            size_t ncap = cap ? cap * 2 : 16;
                            mp_blkx_entry_t *ne = (mp_blkx_entry_t *)realloc(entries, ncap * sizeof(*ne));
                            if (!ne) {
                                free(cur.name); free(cur.id); free(cur.cfname); free(cur.data);
                                mp_free_blkx_entries(entries, count);
                                mp_set_err(err, err_sz, "out of memory");
                                return MACPKG_ERR_NOMEM;
                            }
                            entries = ne;
                            cap = ncap;
                        }
                        entries[count++] = cur;
                        memset(&cur, 0, sizeof(cur));
                    } else {
                        free(cur.name); free(cur.id); free(cur.cfname); free(cur.data);
                        memset(&cur, 0, sizeof(cur));
                    }
                }
            }
        }
    }

    if (count == 0) {
        mp_set_err(err, err_sz, "no blkx entries found in UDIF plist");
        return MACPKG_ERR_CORRUPT;
    }
    *out_entries = entries;
    *out_count = count;
    return MACPKG_OK;
}

void mp_free_blkx_entries(mp_blkx_entry_t *entries, size_t count) {
    if (!entries) return;
    for (size_t i = 0; i < count; i++) {
        free(entries[i].name);
        free(entries[i].id);
        free(entries[i].cfname);
        free(entries[i].data);
    }
    free(entries);
}

/* ---- XAR TOC Parser ---- */
typedef struct {
    char *name;
    int is_dir;
    int has_data;
    uint64_t offset;
    uint64_t length;
    uint64_t size;
    char *encoding;
} xar_frame_t;

macpkg_status_t mp_parse_xar_toc(const char *xml, size_t xml_len,
                                 mp_xar_file_t **out_list,
                                 char *err, size_t err_sz) {
    *out_list = NULL;
    mp_xar_file_t *head = NULL, *tail = NULL;

    xar_frame_t stack[64];
    int depth = 0;
    int in_data = 0;
    memset(stack, 0, sizeof(stack));

    const char *p = xml;
    const char *end = xml + xml_len;

    while (p < end) {
        const char *lt = (const char *)memchr(p, '<', (size_t)(end - p));
        if (!lt) break;
        p = lt;
        if (p + 4 <= end && strncmp(p, "<!--", 4) == 0) {
            const char *ce = strstr(p + 4, "-->");
            if (!ce || ce >= end) break;
            p = ce + 3;
            continue;
        }
        if (p + 2 <= end && (p[1] == '?' || p[1] == '!')) {
            const char *gt = (const char *)memchr(p, '>', (size_t)(end - p));
            if (!gt) break;
            p = gt + 1;
            continue;
        }
        const char *gt = (const char *)memchr(p + 1, '>', (size_t)(end - (p + 1)));
        if (!gt) break;

        int is_close = (p[1] == '/');
        int is_self_close = (gt > p + 1 && gt[-1] == '/');
        const char *name_s = is_close ? p + 2 : p + 1;
        const char *name_e = name_s;
        while (name_e < gt && !isspace((unsigned char)*name_e) && *name_e != '/') name_e++;
        size_t nlen = (size_t)(name_e - name_s);
        const char *tag_body = name_e;

        p = gt + 1;

        if (!is_close) {
            if (nlen == 4 && strncmp(name_s, "file", 4) == 0 && !is_self_close) {
                if (depth >= 64) {
                    for (int i = 0; i < depth; i++) {
                        free(stack[i].name);
                        free(stack[i].encoding);
                    }
                    mp_free_xar_files(head);
                    mp_set_err(err, err_sz, "XAR TOC <file> nesting depth exceeded");
                    return MACPKG_ERR_CORRUPT;
                }
                memset(&stack[depth], 0, sizeof(stack[depth]));
                depth++;
            } else if (depth > 0) {
                xar_frame_t *f = &stack[depth - 1];
                if (nlen == 4 && strncmp(name_s, "data", 4) == 0 && !is_self_close) {
                    in_data = 1;
                    f->has_data = 1;
                } else if (in_data && nlen == 8 && strncmp(name_s, "encoding", 8) == 0) {
                    free(f->encoding);
                    f->encoding = xml_get_attr(tag_body, gt, "style");
                } else if (!is_self_close) {
                    const char *close_tag = (const char *)memchr(p, '<', (size_t)(end - p));
                    if (!close_tag) break;
                    size_t vlen = (size_t)(close_tag - p);
                    if (!in_data && nlen == 4 && strncmp(name_s, "name", 4) == 0) {
                        free(f->name);
                        f->name = xml_unescape(p, vlen);
                    } else if (!in_data && nlen == 4 && strncmp(name_s, "type", 4) == 0) {
                        if (vlen == 9 && strncmp(p, "directory", 9) == 0) f->is_dir = 1;
                    } else if (in_data && nlen == 6 && strncmp(name_s, "offset", 6) == 0) {
                        char *s = mp_strndup_local(p, vlen);
                        if (s) { f->offset = strtoull(s, NULL, 10); free(s); }
                    } else if (in_data && nlen == 6 && strncmp(name_s, "length", 6) == 0) {
                        char *s = mp_strndup_local(p, vlen);
                        if (s) { f->length = strtoull(s, NULL, 10); free(s); }
                    } else if (in_data && nlen == 4 && strncmp(name_s, "size", 4) == 0) {
                        char *s = mp_strndup_local(p, vlen);
                        if (s) { f->size = strtoull(s, NULL, 10); free(s); }
                    }
                }
            }
        } else {
            if (nlen == 4 && strncmp(name_s, "data", 4) == 0) {
                in_data = 0;
            } else if (nlen == 4 && strncmp(name_s, "file", 4) == 0 && depth > 0) {
                xar_frame_t *f = &stack[depth - 1];
                if (f->name && f->has_data && !f->is_dir) {
                    /* Build full rel_path from stack[0..depth-1] */
                    size_t total_len = 1;
                    for (int i = 0; i < depth; i++) {
                        total_len += (stack[i].name ? strlen(stack[i].name) : 0) + 1;
                    }
                    char *rel = (char *)malloc(total_len);
                    mp_xar_file_t *node = (mp_xar_file_t *)calloc(1, sizeof(*node));
                    if (!rel || !node) {
                        free(rel); free(node);
                        for (int i = 0; i < depth; i++) { free(stack[i].name); free(stack[i].encoding); }
                        mp_free_xar_files(head);
                        mp_set_err(err, err_sz, "out of memory");
                        return MACPKG_ERR_NOMEM;
                    }
                    rel[0] = '\0';
                    for (int i = 0; i < depth; i++) {
                        if (i > 0) strcat(rel, "/");
                        if (stack[i].name) strcat(rel, stack[i].name);
                    }
                    node->rel_path = rel;
                    node->is_dir = f->is_dir;
                    node->offset = f->offset;
                    node->length = f->length;
                    node->size = f->size;
                    node->encoding = f->encoding;
                    f->encoding = NULL;
                    if (!head) head = tail = node;
                    else { tail->next = node; tail = node; }
                }
                free(f->name);
                free(f->encoding);
                f->name = NULL;
                f->encoding = NULL;
                depth--;
            }
        }
    }

    for (int i = 0; i < depth; i++) {
        free(stack[i].name);
        free(stack[i].encoding);
    }

    *out_list = head;
    return MACPKG_OK;
}

void mp_free_xar_files(mp_xar_file_t *list) {
    while (list) {
        mp_xar_file_t *n = list->next;
        free(list->rel_path);
        free(list->encoding);
        free(list);
        list = n;
    }
}
