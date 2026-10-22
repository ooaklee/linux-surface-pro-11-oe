/* SPDX-License-Identifier: BSD-3-Clause */
/* Public, libc-only entry point. No SDK/stub is linked or loaded here. */
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "sp11_compute_cli.h"

#ifndef __linux__
#error "This launcher requires Linux /proc/self/exe"
#endif

int main(int argc, char **argv)
{
    enum { EXECUTABLE_PATH_CAPACITY = 4096 };
    static const char worker_name[] = "compute-rpc-worker";
    char worker_path[EXECUTABLE_PATH_CAPACITY];
    char *separator;
    ssize_t length;
    size_t directory_bytes;
    unsigned long expected_arch;

    /* Admission occurs before even resolving the active worker's path. */
    if (sp11_compute_cli_parse(argc, argv, &expected_arch) != EXIT_SUCCESS)
        return EXIT_FAILURE;
    (void)expected_arch; /* The shared parser already checked the paired ISA. */

    length = readlink("/proc/self/exe", worker_path, sizeof(worker_path));
    if (length < 0) {
        fprintf(stderr, "Could not resolve launcher executable (errno %d).\n", errno);
        return EXIT_FAILURE;
    }
    if (length == 0 || (size_t)length >= sizeof(worker_path)) {
        fputs("Launcher executable path is empty or too long.\n", stderr);
        return EXIT_FAILURE;
    }
    worker_path[(size_t)length] = '\0';
    separator = strrchr(worker_path, '/');
    if (worker_path[0] != '/' || separator == NULL || separator[1] == '\0') {
        fputs("Launcher executable path is not an absolute file path.\n", stderr);
        return EXIT_FAILURE;
    }
    directory_bytes = (size_t)(separator - worker_path) + 1;
    if (directory_bytes > sizeof(worker_path) - sizeof(worker_name)) {
        fputs("Sibling worker path is too long.\n", stderr);
        return EXIT_FAILURE;
    }
    memcpy(worker_path + directory_bytes, worker_name, sizeof(worker_name));

    /* /proc resolves the executed file, including a launcher reached through a
     * symlink. Never search argv[0], PATH or cwd, and never fall back elsewhere.
     * A fixed sibling is a package-layout rule, not authentication against
     * replacement of the installed files. The worker is explicitly active:
     * its genuine SDK constructors may run before its own main/argument check.
     */
    execv(worker_path, argv);
    fprintf(stderr, "Could not execute sibling compute-rpc-worker (errno %d).\n", errno);
    return EXIT_FAILURE;
}
