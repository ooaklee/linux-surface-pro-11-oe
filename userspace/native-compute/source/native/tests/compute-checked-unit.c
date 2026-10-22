/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Local checked-API validation: link host/compute-checked.c and these raw-API
 * mocks against the actual QAIC-generated header reached through the checked
 * header. The mocks never read input and perform no arithmetic, allocation,
 * SDK, generated-stub, DSP, remote or device operation.
 */
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "AEEStdErr.h"
#include "sp11_compute_checked.h"

_Static_assert(CHAR_BIT == 8 && sizeof(int) == 4 &&
               INT_MIN == INT32_MIN && INT_MAX == INT32_MAX,
               "checked API sequence lengths require a signed 32-bit int");
_Static_assert(sizeof(remote_handle64) == 8,
               "checked API must preserve a complete 64-bit handle");
_Static_assert(SP11_NATIVE_COMPUTE_MAX_VALUES == 4096,
               "the checked API limit must remain exactly 4096 values");

enum raw_api { RAW_NONE, RAW_SUM, RAW_MAX };

struct raw_call {
    unsigned int calls;
    enum raw_api api;
    remote_handle64 handle;
    const int32_t *values;
    int length;
    const void *output;
    int result;
    int modify_output;
    int64_t sum_value;
    int32_t max_value;
};

static struct raw_call raw;
static unsigned int checks;
static const remote_handle64 test_handle =
    (remote_handle64)UINT64_C(0xfedcba9876543210);
static const int64_t sum_sentinel = INT64_C(0x1122334455667788);
static const int32_t max_sentinel = INT32_C(0x12345678);
static const int64_t backend_sum = -INT64_C(0x123456789abcdef);
static const int32_t backend_max = -INT32_C(123456789);

static void check(int condition, const char *label, const char *expression,
                  int line)
{
    ++checks;
    if (!condition) {
        fprintf(stderr, "checked-api-unit: %s, line %d: %s\n",
                label, line, expression);
        exit(EXIT_FAILURE);
    }
}

#define CHECK(label, condition) \
    check((condition), (label), #condition, __LINE__)

static void reset_raw(int result, int modify_output)
{
    raw = (struct raw_call) {
        .api = RAW_NONE,
        .result = result,
        .modify_output = modify_output,
        .sum_value = backend_sum,
        .max_value = backend_max
    };
}

/* Raw API definitions satisfy the genuine generated prototypes. Input is
 * recorded only: even an invalid length cannot trigger a backend input read.
 */
int sp11_native_compute_v1_sum(remote_handle64 handle, const int32_t *values,
                              int valuesLen, int64_t *total)
{
    ++raw.calls;
    raw.api = RAW_SUM;
    raw.handle = handle;
    raw.values = values;
    raw.length = valuesLen;
    raw.output = total;
    if (raw.modify_output && total != NULL)
        *total = raw.sum_value;
    return raw.result;
}

int sp11_native_compute_v1_max(remote_handle64 handle, const int32_t *values,
                              int valuesLen, int32_t *maximum)
{
    ++raw.calls;
    raw.api = RAW_MAX;
    raw.handle = handle;
    raw.values = values;
    raw.length = valuesLen;
    raw.output = maximum;
    if (raw.modify_output && maximum != NULL)
        *maximum = raw.max_value;
    return raw.result;
}

static void reject_sum(const int32_t *values, int length, int null_output)
{
    char label[128];
    int64_t total = sum_sentinel;
    int64_t *output = null_output ? NULL : &total;

    (void)snprintf(label, sizeof(label),
                   "sum reject length=%d input=%s output=%s", length,
                   values == NULL ? "NULL" : "array",
                   null_output ? "NULL" : "sentinel");
    reset_raw(AEE_SUCCESS, 1);
    int rc = sp11_native_compute_v1_sum_checked(test_handle, values, length,
                                               output);
    CHECK(label, rc == AEE_EBADPARM);
    CHECK(label, raw.calls == 0);
    if (!null_output)
        CHECK(label, total == sum_sentinel);
}

static void reject_max(const int32_t *values, int length, int null_output)
{
    char label[128];
    int32_t maximum = max_sentinel;
    int32_t *output = null_output ? NULL : &maximum;

    (void)snprintf(label, sizeof(label),
                   "max reject length=%d input=%s output=%s", length,
                   values == NULL ? "NULL" : "array",
                   null_output ? "NULL" : "sentinel");
    reset_raw(AEE_SUCCESS, 1);
    int rc = sp11_native_compute_v1_max_checked(test_handle, values, length,
                                               output);
    CHECK(label, rc == AEE_EBADPARM);
    CHECK(label, raw.calls == 0);
    if (!null_output)
        CHECK(label, maximum == max_sentinel);
}

static void forward_sum(const int32_t *values, int length, int result,
                        int modify_output)
{
    char label[128];
    int64_t total = sum_sentinel;

    (void)snprintf(label, sizeof(label),
                   "sum forward length=%d input=%s result=%d write=%d",
                   length, values == NULL ? "NULL" : "array", result,
                   modify_output);
    reset_raw(result, modify_output);
    int rc = sp11_native_compute_v1_sum_checked(test_handle, values, length,
                                               &total);
    CHECK(label, rc == result);
    CHECK(label, raw.calls == 1);
    CHECK(label, raw.api == RAW_SUM);
    CHECK(label, raw.handle == test_handle);
    CHECK(label, raw.values == values);
    CHECK(label, raw.length == length);
    CHECK(label, raw.output == &total);
    CHECK(label, total == (modify_output ? backend_sum : sum_sentinel));
}

static void forward_max(const int32_t *values, int length, int result,
                        int modify_output)
{
    char label[128];
    int32_t maximum = max_sentinel;

    (void)snprintf(label, sizeof(label),
                   "max forward length=%d result=%d write=%d", length,
                   result, modify_output);
    reset_raw(result, modify_output);
    int rc = sp11_native_compute_v1_max_checked(test_handle, values, length,
                                               &maximum);
    CHECK(label, rc == result);
    CHECK(label, raw.calls == 1);
    CHECK(label, raw.api == RAW_MAX);
    CHECK(label, raw.handle == test_handle);
    CHECK(label, raw.values == values);
    CHECK(label, raw.length == length);
    CHECK(label, raw.output == &maximum);
    CHECK(label, maximum == (modify_output ? backend_max : max_sentinel));
}

int main(void)
{
    /* These literal boundaries independently pin the shared limit. All
     * non-NULL inputs use a real full-capacity array, never a fake pointer.
     */
    const int32_t values[4096] = {0};
    const int invalid_lengths[] = { INT_MIN, -1, 4097, INT_MAX };
    const int valid_lengths[] = { 1, 4096 };
    const struct {
        int result;
        int modify_output;
    } modes[] = {
        { AEE_SUCCESS, 1 },
        { AEE_EFAILED, 0 },
        { -73, 1 }
    };

    /* Every invalid boundary is combined with both input-pointer states and
     * both output-pointer states, including multiple invalid arguments.
     */
    for (size_t i = 0; i < sizeof(invalid_lengths) / sizeof(invalid_lengths[0]);
         ++i) {
        for (int null_input = 0; null_input <= 1; ++null_input) {
            for (int null_output = 0; null_output <= 1; ++null_output) {
                const int32_t *input = null_input ? NULL : values;
                reject_sum(input, invalid_lengths[i], null_output);
                reject_max(input, invalid_lengths[i], null_output);
            }
        }
    }

    for (size_t i = 0; i < sizeof(valid_lengths) / sizeof(valid_lengths[0]);
         ++i) {
        reject_sum(values, valid_lengths[i], 1);
        reject_sum(NULL, valid_lengths[i], 0);
        reject_sum(NULL, valid_lengths[i], 1);
        reject_max(values, valid_lengths[i], 1);
        reject_max(NULL, valid_lengths[i], 0);
        reject_max(NULL, valid_lengths[i], 1);
    }

    reject_sum(values, 0, 1);
    reject_sum(NULL, 0, 1);
    for (int null_output = 0; null_output <= 1; ++null_output) {
        reject_max(values, 0, null_output);
        reject_max(NULL, 0, null_output);
    }

    /* The final mode models partial output followed by failure: the wrapper
     * must preserve that backend result and must not restore the sentinel.
     */
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); ++i) {
        for (size_t j = 0; j < sizeof(valid_lengths) / sizeof(valid_lengths[0]);
             ++j) {
            forward_sum(values, valid_lengths[j], modes[i].result,
                        modes[i].modify_output);
            forward_max(values, valid_lengths[j], modes[i].result,
                        modes[i].modify_output);
        }
        forward_sum(NULL, 0, modes[i].result, modes[i].modify_output);
        forward_sum(values, 0, modes[i].result, modes[i].modify_output);
    }

    printf("checked-api-unit: %u checks passed "
           "(LOCAL VALIDATION ONLY; no SDK/stub/remote execution)\n", checks);
    return EXIT_SUCCESS;
}
