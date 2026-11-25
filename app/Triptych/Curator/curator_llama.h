// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

bool curator_llama_generate(const char *path, const char *prompt,
                            bool (*should_continue)(void *), void *state,
                            char *output, size_t capacity);

#ifdef __cplusplus
}
#endif
