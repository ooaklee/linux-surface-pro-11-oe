/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Pure implementation unit: link dsp/compute.c using the actual QAIC-generated
 * header. No local substitute declarations, stub, RPC, DSP or device access.
 */
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

#include "AEEStdErr.h"
#include "sp11_native_compute_v1.h"

/* Compile-time prototype checks against the real generated header. */
static int (*const api_open)(const char *, remote_handle64 *) =
    sp11_native_compute_v1_open;
static int (*const api_close)(remote_handle64) = sp11_native_compute_v1_close;
static int (*const api_sum)(remote_handle64, const int32_t *, int, int64_t *) =
    sp11_native_compute_v1_sum;
static int (*const api_max)(remote_handle64, const int32_t *, int, int32_t *) =
    sp11_native_compute_v1_max;

#define CHECK(condition) do {                                                \
    ++checks;                                                               \
    if (!(condition)) {                                                     \
        fprintf(stderr, "compute-unit check failed at line %d: %s\n",         \
                __LINE__, #condition);                                      \
        return 1;                                                           \
    }                                                                       \
} while (0)

int main(void)
{
    unsigned int checks = 0;
    remote_handle64 handle = 77, second = 88;
    int64_t total;
    int32_t maximum;
    int32_t values[4097];
    const int32_t mixed[] = { INT32_MIN, INT32_MAX, -7, 0, 17, -1 };
    const int32_t negative[] = { -9, -3, INT32_MIN, -4 };

    CHECK(api_open(NULL, &handle) == AEE_EBADPARM);
    CHECK(handle == 77);
    CHECK(api_open("", &handle) == AEE_EBADPARM);
    CHECK(handle == 77);
    CHECK(api_open("unit:stateless", NULL) == AEE_EBADPARM);
    CHECK(api_open("unit:stateless", &handle) == AEE_SUCCESS);
    CHECK(handle == (remote_handle64)1);
    CHECK(api_open("unit:second", &second) == AEE_SUCCESS);
    CHECK(second == handle);

    total = -123;
    CHECK(api_sum(handle, NULL, 0, &total) == AEE_SUCCESS);
    CHECK(total == 0);
    CHECK(api_sum(handle, mixed, 6, &total) == AEE_SUCCESS);
    CHECK(total == 8);
    CHECK(api_max(handle, mixed, 6, &maximum) == AEE_SUCCESS);
    CHECK(maximum == INT32_MAX);
    CHECK(api_max(handle, negative, 4, &maximum) == AEE_SUCCESS);
    CHECK(maximum == -3);

    values[0] = INT32_MIN;
    CHECK(api_sum(handle, values, 1, &total) == AEE_SUCCESS);
    CHECK(total == INT32_MIN);
    CHECK(api_max(handle, values, 1, &maximum) == AEE_SUCCESS);
    CHECK(maximum == INT32_MIN);
    values[0] = 0;
    CHECK(api_max(handle, values, 1, &maximum) == AEE_SUCCESS);
    CHECK(maximum == 0);

    for (int i = 0; i < 4096; ++i)
        values[i] = INT32_MAX;
    CHECK(api_sum(handle, values, 4096, &total) == AEE_SUCCESS);
    CHECK(total == INT64_C(4096) * (int64_t)INT32_MAX);
    CHECK(api_max(handle, values, 4096, &maximum) == AEE_SUCCESS);
    CHECK(maximum == INT32_MAX);
    for (int i = 0; i < 4096; ++i)
        values[i] = INT32_MIN;
    CHECK(api_sum(handle, values, 4096, &total) == AEE_SUCCESS);
    CHECK(total == INT64_C(4096) * (int64_t)INT32_MIN);
    CHECK(api_max(handle, values, 4096, &maximum) == AEE_SUCCESS);
    CHECK(maximum == INT32_MIN);
    for (int i = 0; i < 4096; ++i)
        values[i] = (i & 1) ? INT32_MAX : INT32_MIN;
    CHECK(api_sum(handle, values, 4096, &total) == AEE_SUCCESS);
    CHECK(total == -INT64_C(2048));

    total = 123;
    maximum = 123;
    CHECK(api_sum(handle, NULL, 1, &total) == AEE_EBADPARM);
    CHECK(api_sum(handle, values, -1, &total) == AEE_EBADPARM);
    CHECK(api_sum(handle, values, 4097, &total) == AEE_EBADPARM);
    CHECK(api_sum(handle, values, INT_MAX, &total) == AEE_EBADPARM);
    CHECK(api_sum(handle, values, 1, NULL) == AEE_EBADPARM);
    CHECK(total == 123);
    CHECK(api_max(handle, NULL, 1, &maximum) == AEE_EBADPARM);
    CHECK(api_max(handle, NULL, 0, &maximum) == AEE_EBADPARM);
    CHECK(api_max(handle, values, 0, &maximum) == AEE_EBADPARM);
    CHECK(api_max(handle, values, -1, &maximum) == AEE_EBADPARM);
    CHECK(api_max(handle, values, 4097, &maximum) == AEE_EBADPARM);
    CHECK(api_max(handle, values, INT_MAX, &maximum) == AEE_EBADPARM);
    CHECK(api_max(handle, values, 1, NULL) == AEE_EBADPARM);
    CHECK(maximum == 123);

    CHECK(api_sum(0, values, 1, &total) == AEE_EINVHANDLE);
    CHECK(api_sum(2, values, 1, &total) == AEE_EINVHANDLE);
    CHECK(api_sum(UINT64_MAX, NULL, 0, NULL) == AEE_EINVHANDLE);
    CHECK(api_max(0, values, 1, &maximum) == AEE_EINVHANDLE);
    CHECK(api_max(2, values, 1, &maximum) == AEE_EINVHANDLE);
    CHECK(api_max(UINT64_MAX, NULL, 0, NULL) == AEE_EINVHANDLE);
    CHECK(total == 123 && maximum == 123);
    CHECK(api_close(0) == AEE_EINVHANDLE);
    CHECK(api_close(2) == AEE_EINVHANDLE);
    CHECK(api_close(UINT64_MAX) == AEE_EINVHANDLE);
    CHECK(api_close(handle) == AEE_SUCCESS);
    CHECK(api_close(second) == AEE_SUCCESS);
    /*
     * This constant token owns no per-open resource. Repeated close is
     * deliberately harmless; this is not a dynamic-handle lifecycle test.
     */
    CHECK(api_close(handle) == AEE_SUCCESS);

    printf("compute-unit: %u checks passed (pure implementation only)\n", checks);
    return 0;
}
