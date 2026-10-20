/* SPDX-License-Identifier: BSD-3-Clause */
/* Only the standard declaration needed by the included HAP debug helper. */
#ifndef SP11_ANALYSIS_STDIO_H
#define SP11_ANALYSIS_STDIO_H
#include <stddef.h>
#include <stdarg.h>
int vsnprintf(char *restrict buffer, size_t capacity,
              const char *restrict format, va_list arguments);
#endif
