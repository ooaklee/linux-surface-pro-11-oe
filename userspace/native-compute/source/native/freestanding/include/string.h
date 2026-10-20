/* SPDX-License-Identifier: BSD-3-Clause */
/* Analysis-only standard declarations; unresolved imports remain unqualified. */
#ifndef SP11_ANALYSIS_STRING_H
#define SP11_ANALYSIS_STRING_H
#include <stddef.h>
void *memcpy(void *restrict destination, const void *restrict source, size_t count);
void *memmove(void *destination, const void *source, size_t count);
void *memset(void *destination, int value, size_t count);
size_t strlen(const char *string);
int strcmp(const char *left, const char *right);
int strncmp(const char *left, const char *right, size_t count);
#endif
