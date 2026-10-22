/* SPDX-License-Identifier: BSD-3-Clause */
#ifndef SP11_COMPUTE_CHECKED_H
#define SP11_COMPUTE_CHECKED_H

#include "sp11_native_compute_v1.h"
#include "sp11_compute_limits.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Checked entry points for the actual QAIC-generated interface. They add only
 * local count/null admission checks: they do not validate the opaque handle,
 * implement arithmetic, copy a vector, or substitute another backend.
 *
 * A locally rejected call returns AEE_EBADPARM without invoking the generated
 * function, reading input elements, or reading/writing an output object.
 * For admitted calls, every argument is forwarded unchanged exactly once;
 * the raw function's status and any output modification are left unchanged.
 *
 * The caller must still provide readable storage for valuesLen input elements
 * and writable storage for the output. Null/count checks cannot establish a
 * non-null pointer's validity, extent, lifetime, alignment, or remote mapping.
 */

/*
 * Admit counts 0..SP11_NATIVE_COMPUTE_MAX_VALUES and a non-null total.
 * values may be null only when valuesLen is zero. Empty sum is forwarded,
 * rather than implemented locally, so its raw status/output semantics remain.
 */
int sp11_native_compute_v1_sum_checked(remote_handle64 handle,
                                     const int32_t *values, int valuesLen,
                                     int64_t *total);

/*
 * Admit counts 1..SP11_NATIVE_COMPUTE_MAX_VALUES and non-null values/maximum.
 * Empty maximum is rejected locally without invoking the generated function.
 */
int sp11_native_compute_v1_max_checked(remote_handle64 handle,
                                     const int32_t *values, int valuesLen,
                                     int32_t *maximum);

#ifdef __cplusplus
}
#endif

#endif /* SP11_COMPUTE_CHECKED_H */
