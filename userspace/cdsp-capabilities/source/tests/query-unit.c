/* SPDX-License-Identifier: BSD-3-Clause */
#define _DEFAULT_SOURCE 1
#define _POSIX_C_SOURCE 200809L
#ifndef __linux__
#error "This fixture requires Linux ioctl definitions"
#endif

/* Link the real cdsp-caps.c with all four GNU --wrap options. The startup
 * binding checks fail before querying if any option is missing. Every wrapper
 * below is a terminal local mock: none calls a real syscall or __real_* symbol.
 * This is a finite userspace control-flow/ABI test, not a syscall sandbox or
 * evidence of kernel, firmware, permission, device or capability behavior.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "cdsp-caps.h"
#include "fastrpc.h"

#define DEVICE "/dev/fastrpc-cdsp"
#define SECURE_DEVICE "/dev/fastrpc-cdsp-secure"
#define MOCK_FD 37
#define RAW_PD UINT32_C(0xfedcba97)
#define RAW_ARCH UINT32_C(0x89abcd73)
#define FIRST_VALUE \
    .unsigned_pd = RAW_PD, .has_unsigned_pd = true, \
    .unsigned_query = {true, 0, 0}
#define BOTH_VALUES \
    FIRST_VALUE, .arch = RAW_ARCH, .has_arch = true, .arch_query = {true, 0, 0}

struct test_case {
    const char *name;
    const char *device;
    const char *trace;
    bool null_result;
    int open_error;
    int stat_error;
    bool non_character;
    int unsigned_return;
    int unsigned_errno;
    int arch_return;
    int arch_errno;
    int close_error;
    struct cdsp_caps_result expected;
};

/* O=open, S=fstat, U=attribute 1, A=attribute 6, C=close. Exact traces forbid
 * retries, fallback paths, a second close and queries after the first error.
 */
static const struct test_case cases[] = {
    {.name = "null-result", .device = DEVICE, .trace = "", .null_result = true},
    {.name = "null-device", .device = NULL, .trace = "",
     .expected = {.error = CDSP_CAPS_ARGUMENT, .error_number = EINVAL}},
    {.name = "disallowed-path", .device = "/dev/fastrpc-adsp", .trace = "",
     .expected = {.error = CDSP_CAPS_ARGUMENT, .error_number = EINVAL}},
    {.name = "open-error", .device = DEVICE, .trace = "O", .open_error = EACCES,
     .expected = {.error = CDSP_CAPS_OPEN, .error_number = EACCES}},
    {.name = "stat-error", .device = DEVICE, .trace = "OSC", .stat_error = EIO,
     .expected = {.error = CDSP_CAPS_STAT, .error_number = EIO}},
    {.name = "not-character", .device = DEVICE, .trace = "OSC", .non_character = true,
     .expected = {.error = CDSP_CAPS_DEVICE_TYPE, .error_number = ENODEV}},
    {.name = "unsigned-syscall-error", .device = DEVICE, .trace = "OSUC",
     .unsigned_return = -1, .unsigned_errno = EINTR,
     .expected = {.error = CDSP_CAPS_UNSIGNED_QUERY, .error_number = EINTR,
                  .unsigned_query = {true, -1, EINTR}}},
    {.name = "arch-syscall-error", .device = DEVICE, .trace = "OSUAC",
     .arch_return = -1, .arch_errno = ENOTTY,
     .expected = {FIRST_VALUE, .error = CDSP_CAPS_ARCH_QUERY, .error_number = ENOTTY,
                  .arch_query = {true, -1, ENOTTY}}},
    {.name = "close-error", .device = DEVICE, .trace = "OSUAC", .close_error = EINTR,
     .expected = {BOTH_VALUES, .error = CDSP_CAPS_CLOSE, .error_number = EINTR,
                  .close_error_number = EINTR}},
    {.name = "unsigned-and-close-error", .device = DEVICE, .trace = "OSUC",
     .unsigned_return = -1, .unsigned_errno = EOPNOTSUPP, .close_error = EIO,
     .expected = {.error = CDSP_CAPS_UNSIGNED_QUERY, .error_number = EOPNOTSUPP,
                  .close_error_number = EIO, .unsigned_query = {true, -1, EOPNOTSUPP}}},
    {.name = "arch-and-close-error", .device = DEVICE, .trace = "OSUAC",
     .arch_return = -1, .arch_errno = ETIMEDOUT, .close_error = EINTR,
     .expected = {FIRST_VALUE, .error = CDSP_CAPS_ARCH_QUERY, .error_number = ETIMEDOUT,
                  .close_error_number = EINTR, .arch_query = {true, -1, ETIMEDOUT}}},
    {.name = "unsigned-positive-status", .device = DEVICE, .trace = "OSUC",
     .unsigned_return = 7, .unsigned_errno = EIO,
     .expected = {.error = CDSP_CAPS_UNSIGNED_QUERY, .unsigned_query = {true, 7, 0}}},
    {.name = "arch-positive-status", .device = DEVICE, .trace = "OSUAC",
     .arch_return = 23, .arch_errno = EIO,
     .expected = {FIRST_VALUE, .error = CDSP_CAPS_ARCH_QUERY, .arch_query = {true, 23, 0}}},
    {.name = "raw-value-success", .device = DEVICE, .trace = "OSUAC",
     .expected = {BOTH_VALUES}},
    {.name = "secure-path-success", .device = SECURE_DEVICE, .trace = "OSUAC",
     .expected = {BOTH_VALUES}}
};

_Static_assert(sizeof(cases) / sizeof(cases[0]) == 15, "fixed finite case roster");
_Static_assert(sizeof(struct fastrpc_ioctl_capability) == 28, "seven u32 words");
_Static_assert(CDSP_CAP_UNSIGNED_PD == 1 && CDSP_CAP_ARCH == 6, "literal attribute IDs");

static const struct test_case *active;
static char observed[8];
static size_t observed_count;
static unsigned int ioctl_count;

static void check(bool condition, const char *expression, int line)
{
    if (!condition) {
        fprintf(stderr, "query-unit: %s:%d: %s\n",
                active == NULL ? "wrap-bindings" : active->name, line, expression);
        exit(EXIT_FAILURE);
    }
}

#define CHECK(condition) check((condition), #condition, __LINE__)

int __wrap_open(const char *path, int flags, ...);
int __wrap_fstat(int fd, struct stat *status);
int __wrap_ioctl(int fd, unsigned long command, ...);
int __wrap_close(int fd);

static void event(char code)
{
    CHECK(active != NULL);
    CHECK(observed_count < sizeof(observed) - 1);
    CHECK(observed_count < strlen(active->trace));
    CHECK(active->trace[observed_count] == code);
    observed[observed_count++] = code;
    observed[observed_count] = '\0';
}

int __wrap_open(const char *path, int flags, ...)
{
    event('O');
    CHECK(path != NULL);
    CHECK(strcmp(path, DEVICE) == 0 || strcmp(path, SECURE_DEVICE) == 0);
    CHECK(strcmp(path, active->device) == 0);
    CHECK(flags == (O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NOCTTY));
    errno = active->open_error != 0 ? active->open_error : ECHILD;
    return active->open_error != 0 ? -1 : MOCK_FD;
}

int __wrap_fstat(int fd, struct stat *status)
{
    event('S');
    CHECK(fd == MOCK_FD);
    CHECK(status != NULL);
    *status = (struct stat){0};
    status->st_mode = active->non_character ? S_IFREG : S_IFCHR;
    errno = active->stat_error != 0 ? active->stat_error : ECHILD;
    return active->stat_error != 0 ? -1 : 0;
}

int __wrap_ioctl(int fd, unsigned long command, ...)
{
    struct fastrpc_ioctl_capability *capability;
    uint32_t words[7];
    uint32_t attribute;
    int return_value;
    va_list arguments;

    CHECK(ioctl_count < 2);
    attribute = ioctl_count == 0 ? UINT32_C(1) : UINT32_C(6);
    event(ioctl_count == 0 ? 'U' : 'A');
    CHECK(fd == MOCK_FD);
    CHECK(command == (unsigned long)FASTRPC_IOCTL_GET_DSP_INFO);
    CHECK(_IOC_TYPE(command) == 'R');
    CHECK(_IOC_NR(command) == 13);
    CHECK(_IOC_SIZE(command) == 28);
    CHECK(_IOC_DIR(command) == (_IOC_READ | _IOC_WRITE));
    va_start(arguments, command);
    capability = va_arg(arguments, struct fastrpc_ioctl_capability *);
    va_end(arguments);
    CHECK(capability != NULL);
    memcpy(words, capability, sizeof(words));
    CHECK(words[0] == 0); /* unused is not a domain selector */
    CHECK(words[1] == attribute);
    for (size_t i = 2; i < sizeof(words) / sizeof(words[0]); ++i)
        CHECK(words[i] == 0); /* output and every reserved word start zero */
    /* Even a failing ioctl writes output here: the real query must not accept
     * those bytes unless its raw return is exactly zero.
     */
    capability->capability = ioctl_count == 0 ? RAW_PD : RAW_ARCH;
    return_value = ioctl_count == 0 ? active->unsigned_return : active->arch_return;
    errno = ioctl_count == 0 ? active->unsigned_errno : active->arch_errno;
    if (return_value == 0)
        errno = EDOM; /* successful queries must not report stale errno */
    ++ioctl_count;
    return return_value;
}

int __wrap_close(int fd)
{
    event('C');
    CHECK(fd == MOCK_FD);
    errno = active->close_error != 0 ? active->close_error : E2BIG;
    return active->close_error != 0 ? -1 : 0;
}

static void verify_wrap_bindings(void)
{
    /* Volatile reads retain runtime checks rather than comparing source names
     * at compile time. These take addresses only; they never call libc.
     */
    int (*volatile open_target)(const char *, int, ...) = open;
    int (*volatile stat_target)(int, struct stat *) = fstat;
    int (*volatile ioctl_target)(int, unsigned long, ...) = ioctl;
    int (*volatile close_target)(int) = close;
    CHECK(open_target == __wrap_open);
    CHECK(stat_target == __wrap_fstat);
    CHECK(ioctl_target == __wrap_ioctl);
    CHECK(close_target == __wrap_close);
}

static void verify_result(const struct cdsp_caps_result *actual,
                          const struct cdsp_caps_result *expected)
{
    CHECK(actual->unsigned_pd == expected->unsigned_pd);
    CHECK(actual->arch == expected->arch);
    CHECK(actual->has_unsigned_pd == expected->has_unsigned_pd);
    CHECK(actual->has_arch == expected->has_arch);
    CHECK(actual->error == expected->error);
    CHECK(actual->error_number == expected->error_number);
    CHECK(actual->close_error_number == expected->close_error_number);
    CHECK(actual->unsigned_query.attempted == expected->unsigned_query.attempted);
    CHECK(actual->unsigned_query.return_value == expected->unsigned_query.return_value);
    CHECK(actual->unsigned_query.error_number == expected->unsigned_query.error_number);
    CHECK(actual->arch_query.attempted == expected->arch_query.attempted);
    CHECK(actual->arch_query.return_value == expected->arch_query.return_value);
    CHECK(actual->arch_query.error_number == expected->arch_query.error_number);
}

int main(void)
{
    verify_wrap_bindings();
    for (size_t i = 0; i < sizeof(cases) / sizeof(cases[0]); ++i) {
        struct cdsp_caps_result result;
        int rc;
        active = &cases[i];
        memset(&result, 0xa5, sizeof(result));
        memset(observed, 0, sizeof(observed));
        observed_count = 0;
        ioctl_count = 0;
        errno = ERANGE;
        rc = cdsp_caps_query(active->device, active->null_result ? NULL : &result);
        CHECK(rc == (active->null_result || active->expected.error != CDSP_CAPS_OK ? -1 : 0));
        CHECK(strcmp(observed, active->trace) == 0);
        if (active->null_result)
            CHECK(errno == EINVAL);
        else {
            verify_result(&result, &active->expected);
            if (active->expected.error == CDSP_CAPS_ARGUMENT)
                CHECK(errno == EINVAL);
        }
    }
    puts("query-unit: 15 cases passed (WRAPPED SYSCALLS ONLY; no device execution)");
    return EXIT_SUCCESS;
}
