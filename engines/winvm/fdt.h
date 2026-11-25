// SPDX-License-Identifier: GPL-2.0-or-later
// A minimal flattened device tree writer (DTB v17).
#ifndef WINVM_FDT_H
#define WINVM_FDT_H
#include <stddef.h>
#include <stdint.h>

typedef struct Fdt {
    uint8_t *st; size_t st_len, st_cap;      /* structure block */
    char *str; size_t str_len, str_cap;      /* strings block */
} Fdt;

void fdt_begin(Fdt *f);
void fdt_node(Fdt *f, const char *name);
void fdt_end_node(Fdt *f);
void fdt_prop(Fdt *f, const char *name, const void *data, uint32_t len);
void fdt_prop_str(Fdt *f, const char *name, const char *s);
void fdt_prop_strs(Fdt *f, const char *name, const char *const *s, int n); /* string list */
void fdt_prop_u32(Fdt *f, const char *name, uint32_t v);
void fdt_prop_cells(Fdt *f, const char *name, const uint32_t *cells, int n);
void fdt_prop_empty(Fdt *f, const char *name);
/* Finishes the tree; returns a malloc'd blob and its size. */
uint8_t *fdt_finish(Fdt *f, uint32_t *size);

#endif
