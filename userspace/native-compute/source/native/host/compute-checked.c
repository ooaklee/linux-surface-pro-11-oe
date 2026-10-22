/* SPDX-License-Identifier: BSD-3-Clause */
/* Local admission only; valid calls retain the genuine generated RPC path. */
#include <limits.h>
#include <stddef.h>
#include <stdint.h>

#include "AEEStdErr.h"
#include "sp11_compute_checked.h"

_Static_assert(CHAR_BIT == 8, "QAIC requires eight-bit bytes");
_Static_assert(sizeof(int) == 4, "QAIC sequence lengths use a 32-bit int");
_Static_assert(sizeof(int32_t) == 4, "input elements must be exactly 32 bits");
_Static_assert(sizeof(int64_t) == 8, "sum output must be exactly 64 bits");
_Static_assert(sizeof(remote_handle64) == 8, "opaque handles must be 64 bits");

int sp11_native_compute_v1_sum_checked(remote_handle64 handle,
                                     const int32_t *values, int valuesLen,
                                     int64_t *total)
{
    if (valuesLen < 0 || valuesLen > SP11_NATIVE_COMPUTE_MAX_VALUES ||
        total == NULL || (valuesLen > 0 && values == NULL))
        return AEE_EBADPARM;

    return sp11_native_compute_v1_sum(handle, values, valuesLen, total);
}

int sp11_native_compute_v1_max_checked(remote_handle64 handle,
                                     const int32_t *values, int valuesLen,
                                     int32_t *maximum)
{
    if (valuesLen <= 0 || valuesLen > SP11_NATIVE_COMPUTE_MAX_VALUES ||
        maximum == NULL || values == NULL)
        return AEE_EBADPARM;

    return sp11_native_compute_v1_max(handle, values, valuesLen, maximum);
}
