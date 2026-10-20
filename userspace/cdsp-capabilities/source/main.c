/* SPDX-License-Identifier: BSD-3-Clause */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cdsp-caps.h"

static void usage(FILE *stream)
{
    fputs("Usage: cdsp-capabilities --query-cdsp --device DEVICE\n"
          "DEVICE must be /dev/fastrpc-cdsp or /dev/fastrpc-cdsp-secure.\n"
          "ACTIVE: opening reserves a session; query and close can contact DSP firmware.\n"
          "Advertised capabilities only, not SDK/runtime or NPU qualification.\n",
          stream);
}

static void print_query(const struct cdsp_caps_query_status *status)
{
    if (status->attempted)
        printf("{\"attempted\":true,\"return\":%d,\"errno\":%d}",
               status->return_value, status->error_number);
    else
        fputs("{\"attempted\":false,\"return\":null,\"errno\":null}", stdout);
}

int main(int argc, char **argv)
{
    struct cdsp_caps_result result;
    if (argc == 2 && strcmp(argv[1], "--help") == 0) {
        usage(stdout);
        return fflush(stdout) == 0 && !ferror(stdout) ? EXIT_SUCCESS : EXIT_FAILURE;
    }
    if (argc != 4 || strcmp(argv[1], "--query-cdsp") != 0 ||
        strcmp(argv[2], "--device") != 0 || !cdsp_caps_device_allowed(argv[3])) {
        usage(stderr);
        return EXIT_FAILURE;
    }
    const int rc = cdsp_caps_query(argv[3], &result);
    printf("{\"schema\":\"sp11-cdsp-capabilities-v1\",\"status\":\"%s\","
           "\"device\":\"%s\",\"unsigned_pd_raw\":",
           rc == 0 ? "queried" : "failed", argv[3]);
    if (result.has_unsigned_pd)
        printf("%" PRIu32, result.unsigned_pd);
    else
        fputs("null", stdout);
    fputs(",\"architecture_raw\":", stdout);
    if (result.has_arch)
        printf("%" PRIu32, result.arch);
    else
        fputs("null", stdout);
    fputs(",\"unsigned_pd_query\":", stdout);
    print_query(&result.unsigned_query);
    fputs(",\"architecture_query\":", stdout);
    print_query(&result.arch_query);
    printf(",\"error_phase\":\"%s\",\"errno\":%d,\"close_errno\":%d,"
           "\"device_identity\":\"trusted-name-and-character-type-only\","
           "\"kernel_cache_freshness\":\"unknown\","
           "\"runtime_qualified\":false,\"live_control_rpc_possible\":true}\n",
           cdsp_caps_error_name(result.error), result.error_number,
           result.close_error_number);
    if (fflush(stdout) != 0 || ferror(stdout))
        return EXIT_FAILURE;
    return rc == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
