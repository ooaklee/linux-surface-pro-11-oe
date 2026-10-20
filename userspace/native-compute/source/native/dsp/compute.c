/* SPDX-License-Identifier: BSD-3-Clause */
/* Stateless native implementation; no allocation, transport or CPU fallback. */
#include <limits.h>
#include <stddef.h>
#include <stdint.h>

#include "AEEStdErr.h"
#include "sp11_native_compute_v1.h"

_Static_assert(CHAR_BIT == 8, "QAIC requires eight-bit bytes");
_Static_assert(sizeof(int) == 4, "QAIC sequence lengths and IDL long use int32");
_Static_assert(sizeof(int32_t) == 4, "input elements must be exactly 32 bits");
_Static_assert(sizeof(int64_t) == 8, "sum output must be exactly 64 bits");
_Static_assert(sizeof(remote_handle64) == 8, "opaque handles must be 64 bits");

enum { COMPUTE_MAX_VALUES = 4096 };
#define COMPUTE_STATELESS_HANDLE ((remote_handle64)1)

int sp11_native_compute_v1_open(const char *uri, remote_handle64 *handle)
{
    if (uri == NULL || uri[0] == '\0' || handle == NULL)
        return AEE_EBADPARM;
    *handle = COMPUTE_STATELESS_HANDLE;
    return AEE_SUCCESS;
}

int sp11_native_compute_v1_close(remote_handle64 handle)
{
    return handle == COMPUTE_STATELESS_HANDLE ? AEE_SUCCESS : AEE_EINVHANDLE;
}

int sp11_native_compute_v1_sum(remote_handle64 handle, const int32_t *values,
                              int valuesLen, int64_t *total)
{
    int64_t sum = 0;

    if (handle != COMPUTE_STATELESS_HANDLE)
        return AEE_EINVHANDLE;
    if (total == NULL || valuesLen < 0 || valuesLen > COMPUTE_MAX_VALUES ||
        (valuesLen > 0 && values == NULL))
        return AEE_EBADPARM;

    /* 4096 signed32 elements fit exactly in signed64 without saturation. */
    for (int i = 0; i < valuesLen; ++i)
        sum += (int64_t)values[i];
    *total = sum;
    return AEE_SUCCESS;
}

int sp11_native_compute_v1_max(remote_handle64 handle, const int32_t *values,
                              int valuesLen, int32_t *maximum)
{
    int32_t greatest;

    if (handle != COMPUTE_STATELESS_HANDLE)
        return AEE_EINVHANDLE;
    if (maximum == NULL || valuesLen <= 0 || valuesLen > COMPUTE_MAX_VALUES ||
        values == NULL)
        return AEE_EBADPARM;

    greatest = values[0];
    for (int i = 1; i < valuesLen; ++i) {
        if (values[i] > greatest)
            greatest = values[i];
    }
    *maximum = greatest;
    return AEE_SUCCESS;
}
