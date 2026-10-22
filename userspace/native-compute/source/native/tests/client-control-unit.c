/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * MOCKCONTROLONLY: exercise the real client's admission/error/cleanup flow.
 * Link compute-client.c with main renamed and the checked API; do NOT link
 * the real SDK, generated stub, DSP implementation, or another backend.
 * These mock result constants prove no RPC, DSP, transport or NPU behavior.
 * Client stdout is captured, including its success text, never advertised as
 * a physical result. A close-error case proves an attempted close, not that
 * a failing remote close actually retired a resource.
 */
#define _POSIX_C_SOURCE 200809L
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "AEEStdErr.h"
#include "remote.h"
#include "rpcmem.h"
#include "sp11_native_compute_v1.h"

#ifndef SP11_COMPUTE_ARCH_BYTE
#error "Compile client and control unit with the same paired skeleton ISA"
#endif
_Static_assert(SP11_COMPUTE_ARCH_BYTE == 0x73, "this finite fixture uses v73");

int sp11_client_main(int argc, char **argv);

enum fault {
    GOOD, NO_INTENT, EMPTY_ARGV, NULL_PROGRAM_NAME, BAD_ARCH_TEXT, PAIRED_ARCH_MISMATCH,
    UNSIGNED_CAP_ERROR, ARCH_CAP_ERROR, UNSIGNED_DENIED, DEVICE_ARCH_MISMATCH,
    SETUP_ERROR, OPEN_ERROR, ALLOC_ERROR, SUM_ERROR, MAX_ERROR,
    SUM_WRONG, MAX_WRONG, EMPTY_SUM_WRONG, EMPTY_MAX_SUCCEEDS,
    EMPTY_MAX_ERROR, CLOSE_ERROR, SUM_AND_CLOSE_ERROR, WRONG_AND_CLOSE_ERROR
};
enum {
    MOCK_CAP_ERROR = 0x7101, MOCK_SETUP_ERROR = 0x7102,
    MOCK_OPEN_ERROR = 0x7103, MOCK_INVOKE_ERROR = 0x7104,
    MOCK_CLOSE_ERROR = 0x7105
};
#define MOCK_HANDLE UINT64_C(0x8123456789abcdef)

struct scenario {
    const char *name;
    enum fault fault;
    const char *events;
    int primary_error;
    const char *prefix;
};
struct mock_state {
    enum fault fault;
    char events[32];
    unsigned int event_count, cap_calls, setup_calls, open_calls;
    unsigned int alloc_calls, free_calls, sum_calls, max_calls, close_calls;
    bool open_succeeded;
    int32_t *allocation;
};
static struct mock_state state;

static void require(bool condition, const char *what)
{
    if (!condition) {
        fprintf(stderr, "MOCKCONTROLONLY assertion failed: %s\n", what);
        abort();
    }
}

static void event(char value)
{
    require(state.event_count + 1 < sizeof(state.events), "bounded event count");
    state.events[state.event_count++] = value;
    state.events[state.event_count] = '\0';
}

int remote_handle_control(uint32_t req, void *data, uint32_t datalen)
{
    struct remote_dsp_capability *cap = data;
    require(req == DSPRPC_GET_DSP_INFO && data != NULL &&
            datalen == sizeof(*cap), "real public capability API shape");
    require(cap->domain == CDSP_DOMAIN_ID && cap->capability == 0,
            "CDSP capability input initialized");
    require(state.cap_calls < 2 && state.setup_calls == 0,
            "capabilities precede unsigned setup");
    ++state.cap_calls;
    if (state.cap_calls == 1) {
        event('U');
        require(cap->attribute_ID == UNSIGNED_PD_SUPPORT, "first unsigned query");
        if (state.fault == UNSIGNED_CAP_ERROR)
            return MOCK_CAP_ERROR;
        cap->capability = state.fault == UNSIGNED_DENIED ? 0 : 1;
    } else {
        event('A');
        require(cap->attribute_ID == ARCH_VER, "second architecture query");
        if (state.fault == ARCH_CAP_ERROR)
            return MOCK_CAP_ERROR;
        cap->capability = state.fault == DEVICE_ARCH_MISMATCH ? 0x8c75 : 0x8c73;
    }
    return AEE_SUCCESS;
}

int remote_session_control(uint32_t req, void *data, uint32_t datalen)
{
    struct remote_rpc_control_unsigned_module *mode = data;
    require(req == DSPRPC_CONTROL_UNSIGNED_MODULE && data != NULL &&
            datalen == sizeof(*mode), "only unsigned setup control requested");
    require(mode->domain == CDSP_DOMAIN_ID && mode->enable == 1,
            "explicit CDSP unsigned request");
    require(state.cap_calls == 2 && state.setup_calls == 0 &&
            state.open_calls == 0, "single setup before open");
    ++state.setup_calls;
    event('E');
    return state.fault == SETUP_ERROR ? MOCK_SETUP_ERROR : AEE_SUCCESS;
}

int sp11_native_compute_v1_open(const char *uri, remote_handle64 *handle)
{
    require(uri != NULL && handle != NULL &&
            strcmp(uri, sp11_native_compute_v1_URI CDSP_DOMAIN) == 0,
            "actual generated URI and domain macro");
    require(state.cap_calls == 2 && state.setup_calls == 1 &&
            state.open_calls == 0 && state.alloc_calls == 0,
            "single open after admission before allocation");
    ++state.open_calls;
    event('O');
    if (state.fault == OPEN_ERROR)
        return MOCK_OPEN_ERROR;
    state.open_succeeded = true;
    *handle = MOCK_HANDLE;
    return AEE_SUCCESS;
}

void *rpcmem_alloc(int heapid, uint32_t flags, int size)
{
    require(state.open_succeeded && state.alloc_calls == 0 &&
            heapid == RPCMEM_HEAP_ID_SYSTEM && flags == RPCMEM_DEFAULT_FLAGS &&
            size == 25 * (int)sizeof(int32_t), "bounded public rpcmem allocation");
    ++state.alloc_calls;
    event('B');
    if (state.fault == ALLOC_ERROR)
        return NULL;
    state.allocation = malloc((size_t)size);
    require(state.allocation != NULL, "test-owned mock buffer allocated");
    return state.allocation;
}

void rpcmem_free(void *pointer)
{
    require(pointer != NULL && pointer == state.allocation &&
            state.free_calls == 0 && state.close_calls == 0,
            "exact allocated pointer freed once before close");
    ++state.free_calls;
    event('F');
    free(state.allocation);
    state.allocation = NULL;
}

static void check_input(remote_handle64 handle, const int32_t *values,
                        int length, unsigned int index)
{
    static const int32_t negatives[] = { -7, -3, -11 };
    static const int32_t extremes[] = { INT32_MIN, 0, INT32_MAX };
    require(handle == MOCK_HANDLE && state.open_succeeded &&
            state.close_calls == 0 && values == state.allocation &&
            state.allocation != NULL, "full-width handle and live shared buffer");
    require(index < 5, "finite five-vector schedule");
    if (index == 0) {
        require(length == 25, "ordinary vector length");
        for (int i = 0; i < length; ++i)
            require(values[i] == i, "ordinary vector bytes");
    } else if (index == 1) {
        require(length == 3 && memcmp(values, negatives, sizeof(negatives)) == 0,
                "negative-only vector bytes");
    } else if (index == 2) {
        require(length == 3 && memcmp(values, extremes, sizeof(extremes)) == 0,
                "mixed-extreme vector bytes");
    } else if (index == 3) {
        require(length == 1 && values[0] == INT32_MIN, "single minimum vector");
    } else {
        require(length == 0, "empty vector schedule");
    }
}

int sp11_native_compute_v1_sum(remote_handle64 handle, const int32_t *values,
                              int valuesLen, int64_t *total)
{
    static const int64_t mock_results[] = { 300, -21, -1, INT32_MIN, 0 };
    unsigned int index = state.sum_calls;
    check_input(handle, values, valuesLen, index);
    require(total != NULL && state.max_calls == index, "sum precedes matching max");
    ++state.sum_calls;
    event('S');
    if (state.fault == SUM_ERROR || state.fault == SUM_AND_CLOSE_ERROR)
        return MOCK_INVOKE_ERROR;
    *total = mock_results[index];
    if (index == 0 && (state.fault == SUM_WRONG ||
                       state.fault == WRONG_AND_CLOSE_ERROR))
        *total = 301;
    if (index == 4 && state.fault == EMPTY_SUM_WRONG)
        *total = 1;
    return AEE_SUCCESS;
}

int sp11_native_compute_v1_max(remote_handle64 handle, const int32_t *values,
                              int valuesLen, int32_t *maximum)
{
    static const int32_t mock_results[] = { 24, -3, INT32_MAX, INT32_MIN, 0 };
    unsigned int index = state.max_calls;
    check_input(handle, values, valuesLen, index);
    require(maximum != NULL && state.sum_calls == index + 1,
            "max follows matching successful sum");
    ++state.max_calls;
    event('M');
    if (state.fault == MAX_ERROR)
        return MOCK_INVOKE_ERROR;
    if (index == 4) {
        if (state.fault == EMPTY_MAX_SUCCEEDS)
            return AEE_SUCCESS;
        if (state.fault == EMPTY_MAX_ERROR)
            return MOCK_INVOKE_ERROR;
        return AEE_EBADPARM;
    }
    *maximum = state.fault == MAX_WRONG ? 25 : mock_results[index];
    return AEE_SUCCESS;
}

int sp11_native_compute_v1_close(remote_handle64 handle)
{
    require(handle == MOCK_HANDLE && state.open_succeeded &&
            state.close_calls == 0 && state.allocation == NULL,
            "one close attempt after uses and test-owned buffer release");
    ++state.close_calls;
    event('C');
    return state.fault == CLOSE_ERROR || state.fault == SUM_AND_CLOSE_ERROR ||
           state.fault == WRONG_AND_CLOSE_ERROR ? MOCK_CLOSE_ERROR : AEE_SUCCESS;
}

static void read_capture(FILE *file, char *buffer, size_t capacity)
{
    long length;
    require(fseek(file, 0, SEEK_END) == 0, "capture seek end");
    length = ftell(file);
    require(length >= 0 && (unsigned long)length < capacity, "bounded capture size");
    require(fseek(file, 0, SEEK_SET) == 0, "capture rewind");
    require(fread(buffer, 1, (size_t)length, file) == (size_t)length,
            "complete captured bytes");
    buffer[(size_t)length] = '\0';
}

static void run_scenario(const struct scenario *scenario)
{
    static const char success[] =
        "PASS: real CDSP sum/max results matched all vectors; handle closed.\n";
    char *argv[] = { "mock-client", "--run-cdsp", "--expect-arch", "0x73", NULL };
    char output[2048], error[2048], expected_error[2048];
    FILE *out = tmpfile(), *err = tmpfile();
    int saved_out, saved_err, rc, length = 0;
    /* These two raw empty-max faults must be unreachable behind the guard. */
    bool expect_success = scenario->fault == GOOD ||
                          scenario->fault == EMPTY_MAX_SUCCEEDS ||
                          scenario->fault == EMPTY_MAX_ERROR;
    memset(&state, 0, sizeof(state));
    state.fault = scenario->fault;
    require(out != NULL && err != NULL, "test-owned temporary captures");
    require(fflush(stdout) == 0 && fflush(stderr) == 0, "flush before capture");
    saved_out = dup(STDOUT_FILENO);
    saved_err = dup(STDERR_FILENO);
    require(saved_out >= 0 && saved_err >= 0, "save standard descriptors");
    require(dup2(fileno(out), STDOUT_FILENO) >= 0 &&
            dup2(fileno(err), STDERR_FILENO) >= 0, "capture client descriptors");
    if (scenario->fault == BAD_ARCH_TEXT)
        argv[3] = "73";
    if (scenario->fault == PAIRED_ARCH_MISMATCH)
        argv[3] = "0x75";
    if (scenario->fault == NULL_PROGRAM_NAME)
        argv[0] = NULL;
    if (scenario->fault == EMPTY_ARGV)
        rc = sp11_client_main(0, NULL);
    else
        rc = sp11_client_main((scenario->fault == NO_INTENT ||
                              scenario->fault == NULL_PROGRAM_NAME) ? 1 : 4, argv);
    require(fflush(stdout) == 0 && fflush(stderr) == 0, "flush client output");
    require(dup2(saved_out, STDOUT_FILENO) >= 0 &&
            dup2(saved_err, STDERR_FILENO) >= 0, "restore standard descriptors");
    require(close(saved_out) == 0 && close(saved_err) == 0, "close saved descriptors");
    clearerr(stdout);
    clearerr(stderr);
    read_capture(out, output, sizeof(output));
    read_capture(err, error, sizeof(error));
    require(fclose(out) == 0 && fclose(err) == 0, "close test-owned captures");

    require(strcmp(state.events, scenario->events) == 0, scenario->name);
    require(state.allocation == NULL, "every allocated fixture buffer freed");
    require(state.free_calls == (unsigned int)(state.alloc_calls &&
                                              scenario->fault != ALLOC_ERROR),
            "one free per successful allocation");
    require(state.close_calls == (unsigned int)state.open_succeeded,
            "one close attempt per successful open, none after open failure");
    require(rc == (expect_success ? EXIT_SUCCESS : EXIT_FAILURE),
            "actual client exit status");
    require(strcmp(output, expect_success ? success : "") == 0,
            "no success text on any failure path");
    if (expect_success)
        require(state.sum_calls == 5 && state.max_calls == 4,
                "empty sum forwarded; empty max never reaches raw transport");

    if (scenario->fault == NO_INTENT || scenario->fault == EMPTY_ARGV ||
        scenario->fault == NULL_PROGRAM_NAME) {
        length = snprintf(expected_error, sizeof(expected_error),
            "Usage: %s --run-cdsp --expect-arch 0xNN\n"
            "Requires separately qualified CDSP firmware/runtime and architecture.\n"
            "This executes real DSP RPC; it is not a passive diagnostic.\n",
            scenario->fault == NO_INTENT ? "mock-client" : "compute-client");
    } else if (scenario->fault == BAD_ARCH_TEXT ||
               scenario->fault == PAIRED_ARCH_MISMATCH) {
        length = snprintf(expected_error, sizeof(expected_error), "%s", scenario->prefix);
    } else {
        length = snprintf(expected_error, sizeof(expected_error), "%s", scenario->prefix);
        require(length >= 0 && (size_t)length < sizeof(expected_error), "error prefix fits");
        if (scenario->fault == CLOSE_ERROR || scenario->fault == SUM_AND_CLOSE_ERROR ||
            scenario->fault == WRONG_AND_CLOSE_ERROR) {
            int part = snprintf(expected_error + length, sizeof(expected_error) - (size_t)length,
                                "remote close failed: 0x%x\n", (unsigned int)MOCK_CLOSE_ERROR);
            require(part >= 0 && (size_t)part < sizeof(expected_error) - (size_t)length,
                    "close diagnostic fits");
            length += part;
        }
        if (scenario->primary_error != 0) {
            int part = snprintf(expected_error + length, sizeof(expected_error) - (size_t)length,
                "CDSP RPC check failed: 0x%x (no fallback performed).\n",
                (unsigned int)scenario->primary_error);
            require(part >= 0 && (size_t)part < sizeof(expected_error) - (size_t)length,
                    "primary diagnostic fits");
            length += part;
        }
    }
    require(length >= 0 && (size_t)length < sizeof(expected_error), "bounded expected diagnostics");
    require(strcmp(error, expected_error) == 0, "exact diagnostics and primary-error precedence");
}

int main(void)
{
    static const struct scenario scenarios[] = {
        { "correct-vectors", GOOD, "UAEOBSMSMSMSMSFC", 0, "" },
        { "operator-intent-required", NO_INTENT, "", 0, "" },
        { "empty-argument-vector", EMPTY_ARGV, "", 0, "" },
        { "null-program-name", NULL_PROGRAM_NAME, "", 0, "" },
        { "explicit-hex-required", BAD_ARCH_TEXT, "", 0,
          "Expected architecture must be an explicit nonzero hex byte.\n" },
        { "paired-artifact-ISA", PAIRED_ARCH_MISMATCH, "", 0,
          "Requested architecture differs from this client's paired skeleton build.\n" },
        { "unsigned-cap-error", UNSIGNED_CAP_ERROR, "U", MOCK_CAP_ERROR, "" },
        { "architecture-cap-error", ARCH_CAP_ERROR, "UA", MOCK_CAP_ERROR, "" },
        { "unsigned-denied", UNSIGNED_DENIED, "U", AEE_EUNSUPPORTED,
          "CDSP firmware does not advertise unsigned user-PD support.\n" },
        { "device-ISA-mismatch", DEVICE_ARCH_MISMATCH, "UA", AEE_EUNSUPPORTED,
          "CDSP architecture 0x8c75 does not match 0x73.\n" },
        { "setup-error", SETUP_ERROR, "UAE", MOCK_SETUP_ERROR, "" },
        { "open-error", OPEN_ERROR, "UAEO", MOCK_OPEN_ERROR, "" },
        { "allocation-error", ALLOC_ERROR, "UAEOBC", AEE_ENOMEMORY, "" },
        { "sum-error", SUM_ERROR, "UAEOBSFC", MOCK_INVOKE_ERROR, "" },
        { "max-error", MAX_ERROR, "UAEOBSMFC", MOCK_INVOKE_ERROR, "" },
        { "wrong-sum", SUM_WRONG, "UAEOBSFC", AEE_EFAILED,
          "remote sum mismatch: got 301, expected 300\n" },
        { "wrong-max", MAX_WRONG, "UAEOBSMFC", AEE_EFAILED,
          "remote max mismatch: got 25, expected 24\n" },
        { "wrong-empty-sum", EMPTY_SUM_WRONG, "UAEOBSMSMSMSMSFC", AEE_EFAILED, "" },
        { "raw-empty-max-success-unreachable", EMPTY_MAX_SUCCEEDS, "UAEOBSMSMSMSMSFC",
          0, "" },
        { "raw-empty-max-error-unreachable", EMPTY_MAX_ERROR, "UAEOBSMSMSMSMSFC",
          0, "" },
        { "close-error", CLOSE_ERROR, "UAEOBSMSMSMSMSFC", MOCK_CLOSE_ERROR, "" },
        { "invoke-over-close-error", SUM_AND_CLOSE_ERROR, "UAEOBSFC",
          MOCK_INVOKE_ERROR, "" },
        { "mismatch-over-close-error", WRONG_AND_CLOSE_ERROR, "UAEOBSFC", AEE_EFAILED,
          "remote sum mismatch: got 301, expected 300\n" }
    };
    for (size_t i = 0; i < sizeof(scenarios) / sizeof(scenarios[0]); ++i)
        run_scenario(&scenarios[i]);
    puts("client-control-unit: 23 scenarios passed (MOCKCONTROLONLY; no SDK/stub/remote execution)");
    return EXIT_SUCCESS;
}
