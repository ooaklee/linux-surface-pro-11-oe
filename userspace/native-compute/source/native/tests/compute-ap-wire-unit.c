/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Link the unchanged genuine QAIC AP stub and host/compute-checked.c, not the
 * SDK, DSP implementation, or replacement sum/max functions. These transport
 * mocks inspect the actual stub's synchronous buffers and supply literal reply
 * bytes. They perform no sum/max arithmetic or remote/device operation.
 */
#include <limits.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "AEEStdErr.h"
#include "HAP_debug.h"
#include "sp11_compute_checked.h"

_Static_assert(CHAR_BIT == 8 && sizeof(int) == 4 &&
               INT_MIN == INT32_MIN && INT_MAX == INT32_MAX,
               "QAIC sequence lengths require a signed 32-bit int");
_Static_assert(sizeof(int32_t) == 4 && sizeof(int64_t) == 8 &&
               sizeof(remote_handle64) == 8,
               "wire values and opaque handles must retain their full widths");
_Static_assert(SP11_NATIVE_COMPUTE_MAX_VALUES == 4096,
               "the checked API must retain the exact 4096-value limit");

enum wire_api { WIRE_NONE, WIRE_SUM, WIRE_MAX };

struct wire_expectation {
    enum wire_api api;
    remote_handle64 handle;
    uint32_t scalar;
    const int32_t *values;
    int count;
    unsigned char count_bytes[4];
    size_t output_bytes;
    const void *caller_output;
    int result;
    unsigned int invokes;
    unsigned int scratch_writes;
    unsigned int runtime_logs;
    unsigned int v2_logs;
    unsigned int legacy_logs;
};

struct sum_guard {
    uint64_t before;
    int64_t value;
    uint64_t after;
};

struct max_guard {
    uint32_t before;
    int32_t value;
    uint32_t after;
};

static struct wire_expectation wire;
static unsigned int checks;
static unsigned int cases;
static const remote_handle64 test_handle = UINT64_C(0xfedcba9876543210);
static const uint64_t sum_before = UINT64_C(0x1122334455667788);
static const uint64_t sum_after = UINT64_C(0x8877665544332211);
static const uint32_t max_before = UINT32_C(0x12345678);
static const uint32_t max_after = UINT32_C(0x87654321);
static const int64_t sum_sentinel = -INT64_C(0x123456789abcdef);
static const int32_t max_sentinel = -INT32_C(123456789);
static const unsigned char sum_reply[8] = {
    0x78, 0x56, 0x34, 0x12, 0xef, 0xcd, 0xab, 0x89
};
static const unsigned char max_reply[4] = { 0xe1, 0xac, 0x68, 0x24 };
static const unsigned char zero_reply[8] = {0};

static void check(int condition, const char *label, const char *expression,
                  int line)
{
    ++checks;
    if (!condition) {
        fprintf(stderr, "ap-wire-unit: %s, line %d: %s\n",
                label, line, expression);
        exit(EXIT_FAILURE);
    }
}

#define CHECK(label, condition) \
    check((condition), (label), #condition, __LINE__)

/* All descriptor and admission checks precede every mock buffer access. In
 * particular, a broken local-rejection gate exits at the first check, before
 * examining any raw-stub buffer for a NULL/negative/oversized argument.
 * No stack buffer pointer is retained beyond this synchronous invocation.
 */
int remote_handle64_invoke(remote_handle64 handle, uint32_t scalar,
                           remote_arg *args)
{
    CHECK("invoke admitted", wire.api == WIRE_SUM || wire.api == WIRE_MAX);
    CHECK("invoke once", wire.invokes == 0);
    ++wire.invokes;
    CHECK("full opaque handle", handle == wire.handle);
    CHECK("literal scalar", scalar == wire.scalar);
    CHECK("argument array", args != NULL);
    CHECK("bounded expected count", wire.count >= 0 && wire.count <= 4096);
    CHECK("bounded scratch width", wire.output_bytes == 4 ||
                                     wire.output_bytes == 8);
    CHECK("count pointer", args[0].buf.pv != NULL);
    CHECK("count width", args[0].buf.nLen == 4);
    CHECK("original vector pointer", args[1].buf.pv == wire.values);
    CHECK("vector byte extent", args[1].buf.nLen == (size_t)wire.count * 4);
    CHECK("scratch pointer", args[2].buf.pv != NULL);
    CHECK("scratch width", args[2].buf.nLen == wire.output_bytes);
    CHECK("not caller output", args[2].buf.pv != wire.caller_output);
    CHECK("not count buffer", args[2].buf.pv != args[0].buf.pv);
    CHECK("not input vector", args[2].buf.pv != wire.values);
    CHECK("literal little-endian count",
          memcmp(args[0].buf.pv, wire.count_bytes, 4) == 0);
    CHECK("genuine zeroed scratch",
          memcmp(args[2].buf.pv, zero_reply, wire.output_bytes) == 0);

    /* Deliberately write even on failure: only the genuine AP stub decides
     * whether these bytes are subsequently copied into the caller's output.
     */
    memcpy(args[2].buf.pv, wire.api == WIRE_SUM ? sum_reply : max_reply,
           wire.output_bytes);
    ++wire.scratch_writes;
    return wire.result;
}

/* The genuine stub contains these direct wrappers, but this unit never opens
 * or closes a remote handle. Definitions satisfy its real link requirements.
 */
int remote_handle64_open(const char *uri, remote_handle64 *handle)
{
    (void)uri;
    (void)handle;
    CHECK("no remote open", 0);
    return AEE_EFAILED;
}

int remote_handle64_close(remote_handle64 handle)
{
    (void)handle;
    CHECK("no remote close", 0);
    return AEE_EFAILED;
}

/* These are the actual public logger signatures, not disabled FARF macros.
 * Defining v2 keeps the generated outer logger-presence test true; the default
 * RUNTIME_ERROR path must dispatch once to runtime, not to v2 or legacy.
 * Variadic payloads are not formatted or consumed and nothing is emitted.
 */
void HAP_debug_runtime(int level, const char *file, int line,
                       const char *format, ...)
{
    CHECK("runtime log admitted", wire.api == WIRE_SUM || wire.api == WIRE_MAX);
    CHECK("runtime failure only", wire.result != AEE_SUCCESS);
    CHECK("runtime error level", level == HAP_LEVEL_ERROR);
    CHECK("runtime source file", file != NULL && file[0] != '\0');
    CHECK("runtime source line", line > 0);
    CHECK("runtime format", format != NULL && format[0] != '\0');
    CHECK("runtime after invoke", wire.invokes == 1);
    CHECK("runtime exactly once", wire.runtime_logs == 0);
    ++wire.runtime_logs;
}

void HAP_debug_v2(int level, const char *file, int line,
                  const char *format, ...)
{
    (void)level;
    (void)file;
    (void)line;
    (void)format;
    ++wire.v2_logs;
    CHECK("no non-runtime logger", 0);
}

void HAP_debug(const char *message, int level, const char *file, int line)
{
    (void)message;
    (void)level;
    (void)file;
    (void)line;
    ++wire.legacy_logs;
    CHECK("no legacy logger", 0);
}

static void valid_case(enum wire_api api, const int32_t *values, int count,
                       const unsigned char count_bytes[4], int result)
{
    struct sum_guard sum = { sum_before, sum_sentinel, sum_after };
    struct max_guard max = { max_before, max_sentinel, max_after };
    const size_t width = api == WIRE_SUM ? 8 : 4;
    const unsigned char *reply = api == WIRE_SUM ? sum_reply : max_reply;
    void *output = api == WIRE_SUM ? (void *)&sum.value : (void *)&max.value;
    const void *sentinel = api == WIRE_SUM ? (const void *)&sum_sentinel :
                                           (const void *)&max_sentinel;
    int rc;

    wire = (struct wire_expectation) {
        .api = api, .handle = test_handle,
        .scalar = api == WIRE_SUM ? UINT32_C(0x02020100) :
                                   UINT32_C(0x03020100),
        .values = values, .count = count, .output_bytes = width,
        .caller_output = output, .result = result
    };
    memcpy(wire.count_bytes, count_bytes, 4);
    if (api == WIRE_SUM)
        rc = sp11_native_compute_v1_sum_checked(test_handle, values, count,
                                               &sum.value);
    else
        rc = sp11_native_compute_v1_max_checked(test_handle, values, count,
                                               &max.value);

    CHECK("raw transport status unchanged", rc == result);
    CHECK("one genuine stub invoke", wire.invokes == 1);
    CHECK("scratch written on success and failure", wire.scratch_writes == 1);
    CHECK("default runtime log cardinality",
          wire.runtime_logs == (unsigned int)(result != AEE_SUCCESS));
    CHECK("no v2 log", wire.v2_logs == 0);
    CHECK("no legacy log", wire.legacy_logs == 0);
    CHECK("leading caller canary", api == WIRE_SUM ? sum.before == sum_before :
                                                   max.before == max_before);
    CHECK("trailing caller canary", api == WIRE_SUM ? sum.after == sum_after :
                                                    max.after == max_after);
    CHECK("success copy or failure suppression",
          memcmp(output, result == AEE_SUCCESS ? (const void *)reply : sentinel,
                 width) == 0);
    ++cases;
}

static void invalid_case(enum wire_api api, const int32_t *values, int count,
                         int null_output)
{
    struct sum_guard sum = { sum_before, sum_sentinel, sum_after };
    struct max_guard max = { max_before, max_sentinel, max_after };
    int rc;

    wire = (struct wire_expectation) { .api = WIRE_NONE };
    if (api == WIRE_SUM)
        rc = sp11_native_compute_v1_sum_checked(test_handle, values, count,
                                               null_output ? NULL : &sum.value);
    else
        rc = sp11_native_compute_v1_max_checked(test_handle, values, count,
                                               null_output ? NULL : &max.value);

    CHECK("local rejection status", rc == AEE_EBADPARM);
    CHECK("no invoke for invalid checked call", wire.invokes == 0);
    CHECK("no scratch write for invalid call", wire.scratch_writes == 0);
    CHECK("no runtime log for invalid call", wire.runtime_logs == 0);
    CHECK("no v2 log for invalid call", wire.v2_logs == 0);
    CHECK("no legacy log for invalid call", wire.legacy_logs == 0);
    CHECK("invalid leading canary", api == WIRE_SUM ? sum.before == sum_before :
                                                   max.before == max_before);
    CHECK("invalid trailing canary", api == WIRE_SUM ? sum.after == sum_after :
                                                    max.after == max_after);
    if (!null_output)
        CHECK("invalid output unchanged", api == WIRE_SUM ?
              sum.value == sum_sentinel : max.value == max_sentinel);
    ++cases;
}

int main(void)
{
    /* A real full-capacity vector with bounded, nonuniform signed elements.
     * Reply bytes above are independent literals, not calculations on it.
     */
    int32_t values[4096];
    const int results[] = { AEE_SUCCESS, 0x7351, -73 };
    const unsigned char count_zero[4] = { 0x00, 0x00, 0x00, 0x00 };
    const unsigned char count_one[4] = { 0x01, 0x00, 0x00, 0x00 };
    const unsigned char count_limit[4] = { 0x00, 0x10, 0x00, 0x00 };
    const int invalid_counts[] = { -1, 4097, INT_MIN, INT_MAX };

    for (size_t i = 0; i < 4096; ++i)
        values[i] = (int32_t)(i % 97) - 48;
    CHECK("pattern first", values[0] == -48);
    CHECK("pattern middle", values[2048] == -37);
    CHECK("pattern last", values[4095] == -27);

    for (size_t i = 0; i < sizeof(results) / sizeof(results[0]); ++i) {
        valid_case(WIRE_SUM, NULL, 0, count_zero, results[i]);
        valid_case(WIRE_SUM, values, 0, count_zero, results[i]);
        valid_case(WIRE_SUM, values, 1, count_one, results[i]);
        valid_case(WIRE_SUM, values, 4096, count_limit, results[i]);
        valid_case(WIRE_MAX, values, 1, count_one, results[i]);
        valid_case(WIRE_MAX, values, 4096, count_limit, results[i]);
    }

    for (size_t i = 0; i < sizeof(invalid_counts) / sizeof(invalid_counts[0]);
         ++i) {
        invalid_case(WIRE_SUM, values, invalid_counts[i], 0);
        invalid_case(WIRE_MAX, values, invalid_counts[i], 0);
    }
    invalid_case(WIRE_SUM, NULL, 1, 0);
    invalid_case(WIRE_SUM, values, 1, 1);
    invalid_case(WIRE_SUM, NULL, 0, 1);
    invalid_case(WIRE_MAX, values, 0, 0);
    invalid_case(WIRE_MAX, NULL, 1, 0);
    invalid_case(WIRE_MAX, values, 1, 1);

    printf("ap-wire-unit: %u cases, %u checks passed "
           "(MOCK TRANSPORT ONLY; genuine AP stub; no SDK/DSP/remote execution)\n",
           cases, checks);
    return EXIT_SUCCESS;
}
