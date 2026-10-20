/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef SP11_COMPUTE_CLI_H
#define SP11_COMPUTE_CLI_H

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef SP11_COMPUTE_ARCH_BYTE
#error "Build must bind this client to the explicit skeleton ISA byte"
#endif
_Static_assert(SP11_COMPUTE_ARCH_BYTE > 0 && SP11_COMPUTE_ARCH_BYTE <= UINT8_MAX,
               "skeleton architecture must be an explicit nonzero byte");

/* Pure libc-only admission shared by the launcher and active worker. Callers
 * supply main-like argc/argv and a non-NULL result pointer. Preserve the legacy
 * strtoul policy, including admitted leading-zero forms such as 0x073.
 * The result is written only on success. No SDK or device API is referenced.
 */
static inline int sp11_compute_cli_parse(int argc, char *const argv[],
                                        unsigned long *expected_arch)
{
    char *end = NULL;
    unsigned long parsed;
    const char *program = (argc > 0 && argv != NULL && argv[0] != NULL)
                          ? argv[0] : "compute-client";

    if (argc != 4 || strcmp(argv[1], "--run-cdsp") != 0 ||
        strcmp(argv[2], "--expect-arch") != 0) {
        fprintf(stderr, "Usage: %s --run-cdsp --expect-arch 0xNN\n"
                "Requires separately qualified CDSP firmware/runtime and architecture.\n"
                "This executes real DSP RPC; it is not a passive diagnostic.\n", program);
        return EXIT_FAILURE;
    }
    errno = 0;
    parsed = strtoul(argv[3], &end, 16);
    if (errno || end == argv[3] || *end || strncmp(argv[3], "0x", 2) != 0 ||
        parsed == 0 || parsed > UINT8_MAX) {
        fputs("Expected architecture must be an explicit nonzero hex byte.\n", stderr);
        return EXIT_FAILURE;
    }
    if (parsed != SP11_COMPUTE_ARCH_BYTE) {
        fputs("Requested architecture differs from this client's paired skeleton build.\n", stderr);
        return EXIT_FAILURE;
    }
    *expected_arch = parsed;
    return EXIT_SUCCESS;
}

#endif /* SP11_COMPUTE_CLI_H */
