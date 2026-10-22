/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef SP11_CDSP_CAPS_H
#define SP11_CDSP_CAPS_H

#include <stdbool.h>
#include <stdint.h>

/* These firmware attribute indices are from the pinned public Qualcomm
 * remote.h enum, not inferred from a Windows binary. The kernel UAPI's unused
 * first word is NOT a domain selector: the opened device determines that.
 */
enum { CDSP_CAP_UNSIGNED_PD = 1, CDSP_CAP_ARCH = 6 };

enum cdsp_caps_error {
    CDSP_CAPS_OK,
    CDSP_CAPS_ARGUMENT,
    CDSP_CAPS_OPEN,
    CDSP_CAPS_STAT,
    CDSP_CAPS_DEVICE_TYPE,
    CDSP_CAPS_UNSIGNED_QUERY,
    CDSP_CAPS_ARCH_QUERY,
    CDSP_CAPS_CLOSE
};

struct cdsp_caps_query_status {
    bool attempted;
    int return_value;
    int error_number; /* errno only for a -1 syscall result; otherwise zero */
};

struct cdsp_caps_result {
    uint32_t unsigned_pd;
    uint32_t arch;
    bool has_unsigned_pd;
    bool has_arch;
    enum cdsp_caps_error error;
    int error_number;
    int close_error_number;
    struct cdsp_caps_query_status unsigned_query;
    struct cdsp_caps_query_status arch_query;
};

bool cdsp_caps_device_allowed(const char *device);
const char *cdsp_caps_error_name(enum cdsp_caps_error error);

/* ACTIVE: opens/reserves a FastRPC session; capability queries and close can
 * cause kernel-internal control RPC. No SDK/PD-create/attach/service invocation
 * is requested by this userspace code. Not a passive or deadline-bounded API.
 * Non-NULL result storage is caller-owned and written on all such calls.
 * An opened fd is closed exactly once; close/EINTR is never retried. An earlier
 * error takes precedence, with any close failure retained separately.
 * The reviewed driver ignores its internal DSP-release return in close, so a
 * successful close is not evidence that DSP firmware acknowledged release.
 */
int cdsp_caps_query(const char *device, struct cdsp_caps_result *result);

#endif
