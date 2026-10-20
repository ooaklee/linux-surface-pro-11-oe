/* SPDX-License-Identifier: BSD-3-Clause */
/* Local launcher fixture only. No SDK, RPC, DSP or device API is linked. */
#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void fixture_error(void)
{
    _exit(120);
}

__attribute__((constructor))
static void mock_constructor(void)
{
    static const char marker[] = "launcher-worker-mock: constructor\n";
    if (write(STDOUT_FILENO, marker, sizeof(marker) - 1) !=
        (ssize_t)(sizeof(marker) - 1))
        fixture_error();
}

static void print_hex(const char *text)
{
    const unsigned char *cursor = (const unsigned char *)text;
    while (*cursor != '\0') {
        printf("%02x", (unsigned int)*cursor);
        ++cursor;
    }
    putchar('\n');
}

int main(int argc, char **argv)
{
    const char *configured = getenv("SP11_LAUNCHER_MOCK_EXIT");
    unsigned int result = 0;
    unsigned int digits = 0;
    char executable[4096];
    ssize_t length;

    if (configured == NULL || configured[0] == '\0')
        fixture_error();
    for (const char *cursor = configured; *cursor != '\0'; ++cursor) {
        if (++digits > 3 || *cursor < '0' || *cursor > '9')
            fixture_error();
        result = result * 10 + (unsigned int)(*cursor - '0');
        if (result > 255)
            fixture_error();
    }
    length = readlink("/proc/self/exe", executable, sizeof(executable));
    if (length <= 0 || (size_t)length >= sizeof(executable))
        fixture_error();
    executable[(size_t)length] = '\0';
    printf("launcher-worker-mock: argc=%d exit=%u\n", argc, result);
    fputs("exe.hex=", stdout);
    print_hex(executable);
    for (int index = 0; index < argc; ++index) {
        printf("argv[%d].hex=", index);
        print_hex(argv[index]);
    }
    if (fflush(stdout) != 0)
        fixture_error();
    return (int)result;
}
