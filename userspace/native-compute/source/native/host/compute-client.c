/* SPDX-License-Identifier: BSD-3-Clause */
/* Internal ACTIVE CDSP RPC worker. Never substitutes host arithmetic.
 * Loading its genuine SDK can open device resources before main, even for
 * invalid arguments. Use the libc-only public launcher for passive rejection;
 * direct execution of this worker is not a passive diagnostic.
 */
#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "AEEStdErr.h"
#include "remote.h"
#include "rpcmem.h"
#include "sp11_native_compute_v1.h"
#include "sp11_compute_checked.h"
#include "sp11_compute_cli.h"

enum { VECTOR_CAPACITY = 25 };

static int capability(uint32_t attribute, uint32_t *value)
{
    struct remote_dsp_capability cap = {
        .domain = CDSP_DOMAIN_ID, .attribute_ID = attribute, .capability = 0
    };
    int rc = remote_handle_control(DSPRPC_GET_DSP_INFO, &cap, sizeof(cap));
    if (rc == 0)
        *value = cap.capability;
    return rc;
}

static int check_vector(remote_handle64 handle, const int32_t *values,
                        int length, int64_t expected_sum, int32_t expected_max)
{
    int64_t total = INT64_MIN;
    int32_t maximum = 0;
    int rc = sp11_native_compute_v1_sum_checked(handle, values, length, &total);
    if (rc != 0)
        return rc;
    if (total != expected_sum) {
        fprintf(stderr, "remote sum mismatch: got %" PRId64 ", expected %" PRId64 "\n",
                total, expected_sum);
        return AEE_EFAILED;
    }
    rc = sp11_native_compute_v1_max_checked(handle, values, length, &maximum);
    if (rc != 0)
        return rc;
    if (maximum != expected_max) {
        fprintf(stderr, "remote max mismatch: got %" PRId32 ", expected %" PRId32 "\n",
                maximum, expected_max);
        return AEE_EFAILED;
    }
    return 0;
}

int main(int argc, char **argv)
{
    remote_handle64 handle = 0;
    bool opened = false;
    int32_t *values = NULL;
    uint32_t unsigned_pd = 0, arch = 0;
    unsigned long expected_arch;
    int rc = AEE_EBADPARM, close_rc;

    /* No capability queries or remote calls without explicit operator intent. */
    if (sp11_compute_cli_parse(argc, argv, &expected_arch) != EXIT_SUCCESS)
        return EXIT_FAILURE;

    rc = capability(UNSIGNED_PD_SUPPORT, &unsigned_pd);
    if (rc != 0)
        goto done;
    if (unsigned_pd != 1) {
        fputs("CDSP firmware does not advertise unsigned user-PD support.\n", stderr);
        rc = AEE_EUNSUPPORTED;
        goto done;
    }
    rc = capability(ARCH_VER, &arch);
    if (rc != 0)
        goto done;
    if ((arch & UINT8_MAX) != expected_arch) {
        fprintf(stderr, "CDSP architecture 0x%" PRIx32 " does not match 0x%02lx.\n",
                arch, expected_arch);
        rc = AEE_EUNSUPPORTED;
        goto done;
    }
    struct remote_rpc_control_unsigned_module mode = { CDSP_DOMAIN_ID, 1 };
    rc = remote_session_control(DSPRPC_CONTROL_UNSIGNED_MODULE, &mode, sizeof(mode));
    if (rc != 0)
        goto done; /* No signed-domain or policy-changing fallback. */

    rc = sp11_native_compute_v1_open(sp11_native_compute_v1_URI CDSP_DOMAIN, &handle);
    if (rc != 0)
        goto done;
    opened = true;
    values = rpcmem_alloc(RPCMEM_HEAP_ID_SYSTEM, RPCMEM_DEFAULT_FLAGS,
                          VECTOR_CAPACITY * (int)sizeof(*values));
    if (values == NULL) {
        rc = AEE_ENOMEMORY;
        goto done;
    }
    for (int i = 0; i < VECTOR_CAPACITY; ++i)
        values[i] = i;
    rc = check_vector(handle, values, VECTOR_CAPACITY, 300, 24);
    if (rc != 0)
        goto done;
    values[0] = -7; values[1] = -3; values[2] = -11;
    rc = check_vector(handle, values, 3, -21, -3);
    if (rc != 0)
        goto done;
    values[0] = INT32_MIN; values[1] = 0; values[2] = INT32_MAX;
    rc = check_vector(handle, values, 3, -1, INT32_MAX);
    if (rc != 0)
        goto done;
    values[0] = INT32_MIN;
    rc = check_vector(handle, values, 1, INT32_MIN, INT32_MIN);
    if (rc != 0)
        goto done;
    int64_t empty_sum = INT64_MIN;
    int32_t empty_max = 0;
    rc = sp11_native_compute_v1_sum_checked(handle, values, 0, &empty_sum);
    if (rc != 0)
        goto done;
    if (empty_sum != 0) {
        rc = AEE_EFAILED;
        goto done;
    }
    /* Empty max is a local rejection: it must not reach the RPC transport. */
    rc = sp11_native_compute_v1_max_checked(handle, values, 0, &empty_max);
    if (rc != AEE_EBADPARM) {
        if (rc == 0)
            rc = AEE_EFAILED;
        goto done;
    }
    rc = 0;
done:
    /* Keep the handle live until every use of the shared vector is finished. */
    if (values != NULL)
        rpcmem_free(values);
    if (opened) {
        close_rc = sp11_native_compute_v1_close(handle);
        if (close_rc != 0) {
            fprintf(stderr, "remote close failed: 0x%x\n", (unsigned)close_rc);
            if (rc == 0)
                rc = close_rc;
        }
        opened = false;
    }
    if (rc != 0) {
        fprintf(stderr, "CDSP RPC check failed: 0x%x (no fallback performed).\n", (unsigned)rc);
        return EXIT_FAILURE;
    }
    puts("PASS: real CDSP sum/max results matched all vectors; handle closed.");
    return EXIT_SUCCESS;
}
