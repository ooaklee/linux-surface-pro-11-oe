/* SPDX-License-Identifier: BSD-3-Clause */
#define _POSIX_C_SOURCE 200809L
#ifndef __linux__
#error "This source requires the Linux FastRPC kernel UAPI"
#endif

#include <errno.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "cdsp-caps.h"
#include "fastrpc.h"

_Static_assert(sizeof(struct fastrpc_ioctl_capability) == 28,
               "FastRPC capability ABI must be seven u32 words");
_Static_assert(offsetof(struct fastrpc_ioctl_capability, attribute_id) == 4,
               "FastRPC attribute offset");
_Static_assert(offsetof(struct fastrpc_ioctl_capability, capability) == 8,
               "FastRPC result offset");

bool cdsp_caps_device_allowed(const char *device)
{
    return device != NULL &&
        (strcmp(device, "/dev/fastrpc-cdsp") == 0 ||
         strcmp(device, "/dev/fastrpc-cdsp-secure") == 0);
}

const char *cdsp_caps_error_name(enum cdsp_caps_error error)
{
    switch (error) {
    case CDSP_CAPS_OK: return "none";
    case CDSP_CAPS_ARGUMENT: return "argument";
    case CDSP_CAPS_OPEN: return "open";
    case CDSP_CAPS_STAT: return "fstat";
    case CDSP_CAPS_DEVICE_TYPE: return "not-character-device";
    case CDSP_CAPS_UNSIGNED_QUERY: return "unsigned-pd-query";
    case CDSP_CAPS_ARCH_QUERY: return "architecture-query";
    case CDSP_CAPS_CLOSE: return "close";
    }
    return "invalid-error-code";
}

static int query_one(int fd, uint32_t attribute, uint32_t *value,
                     struct cdsp_caps_query_status *status)
{
    struct fastrpc_ioctl_capability capability = {0};
    capability.attribute_id = attribute;
    status->attempted = true;
    status->return_value = ioctl(fd, FASTRPC_IOCTL_GET_DSP_INFO, &capability);
    status->error_number = status->return_value == -1 ? errno : 0;
    /* Preserve a positive firmware status separately from -1/syscall errno. */
    if (status->return_value != 0)
        return -1;
    *value = capability.capability;
    return 0;
}

static void fail(struct cdsp_caps_result *result, enum cdsp_caps_error phase,
                 int number)
{
    result->error = phase;
    result->error_number = number;
}

int cdsp_caps_query(const char *device, struct cdsp_caps_result *result)
{
    struct stat status;
    int fd;
    if (result == NULL) {
        errno = EINVAL;
        return -1;
    }
    *result = (struct cdsp_caps_result){0};
    if (!cdsp_caps_device_allowed(device)) {
        fail(result, CDSP_CAPS_ARGUMENT, EINVAL);
        errno = EINVAL;
        return -1;
    }
    fd = open(device, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NOCTTY);
    if (fd < 0) {
        fail(result, CDSP_CAPS_OPEN, errno);
        return -1;
    }
    if (fstat(fd, &status) != 0) {
        fail(result, CDSP_CAPS_STAT, errno);
        goto finish;
    }
    if (!S_ISCHR(status.st_mode)) {
        fail(result, CDSP_CAPS_DEVICE_TYPE, ENODEV);
        goto finish;
    }
    if (query_one(fd, CDSP_CAP_UNSIGNED_PD, &result->unsigned_pd,
                  &result->unsigned_query) != 0) {
        fail(result, CDSP_CAPS_UNSIGNED_QUERY, result->unsigned_query.error_number);
        goto finish;
    }
    result->has_unsigned_pd = true;
    if (query_one(fd, CDSP_CAP_ARCH, &result->arch, &result->arch_query) != 0) {
        fail(result, CDSP_CAPS_ARCH_QUERY, result->arch_query.error_number);
        goto finish;
    }
    result->has_arch = true;
finish:
    if (close(fd) != 0) {
        result->close_error_number = errno;
        if (result->error == CDSP_CAPS_OK)
            fail(result, CDSP_CAPS_CLOSE, result->close_error_number);
    }
    return result->error == CDSP_CAPS_OK ? 0 : -1;
}
