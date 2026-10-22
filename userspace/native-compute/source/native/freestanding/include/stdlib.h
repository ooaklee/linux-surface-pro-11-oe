/* SPDX-License-Identifier: BSD-3-Clause */
/* Analysis-only C declarations. Not a DSP libc, allocator or runtime provider. */
#ifndef SP11_ANALYSIS_STDLIB_H
#define SP11_ANALYSIS_STDLIB_H
#include <stddef.h>
void *malloc(size_t size);
void free(void *pointer);
#endif
