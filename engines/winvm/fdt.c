// SPDX-License-Identifier: GPL-2.0-or-later
#include "fdt.h"
#include <stdlib.h>
#include <string.h>

enum { BEGIN_NODE = 1, END_NODE = 2, PROP = 3, END = 9 };

static uint32_t be(uint32_t v) { return __builtin_bswap32(v); }

static void put(Fdt *f, const void *d, size_t n) {
    if (f->st_len + n + 4 > f->st_cap) { f->st_cap = (f->st_cap + n + 4) * 2; f->st = realloc(f->st, f->st_cap); if (!f->st) abort(); }
    memcpy(f->st + f->st_len, d, n);
    f->st_len += n;
    while (f->st_len & 3) f->st[f->st_len++] = 0;
}
static void put32(Fdt *f, uint32_t v) { v = be(v); put(f, &v, 4); }

static uint32_t string_off(Fdt *f, const char *s) {
    for (size_t i = 0; i < f->str_len; i += strlen(f->str + i) + 1)
        if (!strcmp(f->str + i, s)) return (uint32_t)i;
    size_t n = strlen(s) + 1;
    if (f->str_len + n > f->str_cap) { f->str_cap = (f->str_cap + n) * 2; f->str = realloc(f->str, f->str_cap); if (!f->str) abort(); }
    memcpy(f->str + f->str_len, s, n);
    f->str_len += n;
    return (uint32_t)(f->str_len - n);
}

void fdt_begin(Fdt *f) { memset(f, 0, sizeof *f); }
void fdt_node(Fdt *f, const char *name) { put32(f, BEGIN_NODE); put(f, name, strlen(name) + 1); }
void fdt_end_node(Fdt *f) { put32(f, END_NODE); }
void fdt_prop(Fdt *f, const char *name, const void *data, uint32_t len) {
    put32(f, PROP); put32(f, len); put32(f, string_off(f, name));
    if (len) put(f, data, len);
}
void fdt_prop_str(Fdt *f, const char *name, const char *s) { fdt_prop(f, name, s, (uint32_t)strlen(s) + 1); }
void fdt_prop_strs(Fdt *f, const char *name, const char *const *s, int n) {
    char buf[512]; size_t len = 0;
    for (int i = 0; i < n; i++) { size_t k = strlen(s[i]) + 1; memcpy(buf + len, s[i], k); len += k; }
    fdt_prop(f, name, buf, (uint32_t)len);
}
void fdt_prop_u32(Fdt *f, const char *name, uint32_t v) { v = be(v); fdt_prop(f, name, &v, 4); }
void fdt_prop_cells(Fdt *f, const char *name, const uint32_t *c, int n) {
    uint32_t *b = malloc(4 * (size_t)n + 4);
    for (int i = 0; i < n; i++) b[i] = be(c[i]);
    fdt_prop(f, name, b, (uint32_t)(4 * n));
    free(b);
}
void fdt_prop_empty(Fdt *f, const char *name) { fdt_prop(f, name, NULL, 0); }

uint8_t *fdt_finish(Fdt *f, uint32_t *size) {
    put32(f, END);
    uint32_t hdr = 40, rsv = 16; /* one empty reservation entry */
    uint32_t off_st = hdr + rsv, off_str = off_st + (uint32_t)f->st_len, total = off_str + (uint32_t)f->str_len;
    uint8_t *b = calloc(1, total);
    uint32_t h[10] = {be(0xd00dfeed), be(total), be(off_st), be(off_str), be(hdr), be(17), be(16), be(0),
                      be((uint32_t)f->str_len), be((uint32_t)f->st_len)};
    memcpy(b, h, sizeof h);
    memcpy(b + off_st, f->st, f->st_len);
    memcpy(b + off_str, f->str, f->str_len);
    free(f->st); free(f->str);
    *size = total;
    return b;
}
