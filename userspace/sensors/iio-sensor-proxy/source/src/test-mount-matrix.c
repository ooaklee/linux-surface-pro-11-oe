/*
 * Copyright (c) 2014-2016 Bastien Nocera <hadess@hadess.net>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3 as published by
 * the Free Software Foundation.
 *
 */

#include <locale.h>
#include <float.h>
#include <limits.h>
#include <math.h>
#include <string.h>
#include "accel-mount-matrix.h"

#define SWAP_Y_Z_MATRIX "1, 0, 0; 0, 0, 1; 0, 1, 0"
#define INVALID_MATRIX "0, 1, 0; 1, 0, 0; 0, 0, 0"
#define DEFAULT_MATRIX "1, 0, 0; 0, 1, 0; 0, 0, 1"

static void
print_vecs (AccelVec3 vecs[3])
{
	g_test_message ("%f, %f, %f; %f, %f, %f; %f, %f, %f",
			(double) vecs[0].x, (double) vecs[0].y, (double) vecs[0].z,
			(double) vecs[1].x, (double) vecs[1].y, (double) vecs[1].z,
			(double) vecs[2].x, (double) vecs[2].y, (double) vecs[2].z);
}

static void
test_mount_matrix (void)
{
	AccelVec3 *vecs;
	AccelVec3 test;

	/* Swap Y/Z matrix */
	g_assert_true (parse_mount_matrix (SWAP_Y_Z_MATRIX, &vecs));

	print_vecs (vecs);

	test.x = test.z = 0.0;
	test.y = -256.0;
	g_assert_true (apply_mount_matrix (vecs, &test));

	g_assert_cmpfloat (test.x, ==, 0.0);
	g_assert_cmpfloat (test.z, ==, -256.0);
	g_assert_cmpfloat (test.y, ==, 0.0);
	g_free (vecs);

	/* Identity matrix */
	g_assert_true (parse_mount_matrix ("", &vecs));

	print_vecs (vecs);

	test.x = test.z = 0.0;
	test.y = -256.0;
	g_assert_true (apply_mount_matrix (vecs, &test));

	g_assert_cmpfloat (test.x, ==, 0.0);
	g_assert_cmpfloat (test.z, ==, 0.0);
	g_assert_cmpfloat (test.y, ==, -256.0);
	g_free (vecs);

	/* Invalid matrix */
	g_test_expect_message (NULL, G_LOG_LEVEL_WARNING, "In mount matrix '0, 1, 0; 1, 0, 0; 0, 0, 0', axis z is all zeroes, which is invalid");
	g_assert_false (parse_mount_matrix (INVALID_MATRIX, &vecs));
	g_test_assert_expected_messages ();
}

static void
test_comma_decimal_separator (void)
{
	const char *fr_locale = "fr_FR.UTF-8";
	g_autofree char *old_locale = g_strdup (setlocale (LC_ALL, NULL));
	AccelVec3 *vecs;

	/* French locale not available? */
	if (!setlocale (LC_ALL, fr_locale)) {
		g_test_skip_printf ("Local %s not available", fr_locale);
		return;
	}

	/* Default matrix */
	g_assert_true (parse_mount_matrix (DEFAULT_MATRIX, &vecs));
	g_free (vecs);

	setlocale (LC_ALL, old_locale);
}

static void
test_fractional_transform (void)
{
	AccelVec3 *matrix = NULL;
	AccelVec3 input = { 0.5, -0.25, 0.125 };

	g_assert_true (parse_mount_matrix ("0.5, 0.25, 0; 0, -0.5, 0.125; 0, 0, 1", &matrix));
	g_assert_true (apply_mount_matrix (matrix, &input));
	g_assert_cmpfloat (input.x, ==, 0.1875);
	g_assert_cmpfloat (input.y, ==, 0.140625);
	g_assert_cmpfloat (input.z, ==, 0.125);
	g_free (matrix);
}

static void
test_finite_extremes (void)
{
	AccelVec3 *identity = NULL;
	AccelVec3 inputs[] = {
		{ INT_MIN, INT_MAX, 0.125 },
		{ FLT_MAX, -FLT_MAX, FLT_MIN },
		{ DBL_MAX, -DBL_MAX, DBL_MIN },
		{ DBL_MIN / 2.0, -DBL_MIN / 2.0, DBL_MIN }
	};
	AccelVec3 inverse[3] = {
		{ DBL_MIN, 0.0, 0.0 },
		{ 0.0, DBL_MAX, 0.0 },
		{ 0.0, 0.0, -1.0 }
	};
	AccelVec3 cancellation[3] = {
		{ 1.0, -1.0, 0.0 },
		{ 1.0, -1.0, 0.0 },
		{ 1.0, -1.0, 0.0 }
	};
	AccelVec3 input = { DBL_MAX, DBL_MIN, -0.125 };

	g_assert_true (parse_mount_matrix (" \t1, 0, 0; 0, 1, 0; 0, 0, 1 \n", &identity));
	for (guint i = 0; i < G_N_ELEMENTS (inputs); i++) {
		AccelVec3 output = inputs[i];

		g_assert_true (apply_mount_matrix (identity, &output));
		g_assert_cmpfloat (output.x, ==, inputs[i].x);
		g_assert_cmpfloat (output.y, ==, inputs[i].y);
		g_assert_cmpfloat (output.z, ==, inputs[i].z);
	}
	g_free (identity);
	g_assert_true (apply_mount_matrix (inverse, &input));
	g_assert_cmpfloat (input.x, ==, DBL_MAX * DBL_MIN);
	g_assert_cmpfloat (input.y, ==, DBL_MIN * DBL_MAX);
	g_assert_cmpfloat (input.z, ==, 0.125);
	input.x = input.y = 0.125;
	input.z = 0.0;
	g_assert_true (apply_mount_matrix (cancellation, &input));
	g_assert_cmpfloat (input.x, ==, 0.0);
	g_assert_cmpfloat (input.y, ==, 0.0);
	g_assert_cmpfloat (input.z, ==, 0.0);
}

static void
test_invalid_matrix_tokens (void)
{
	const char *invalid[] = {
		"nan, 0, 0; 0, 1, 0; 0, 0, 1",
		"1, 0, 0; 0, NaN, 0; 0, 0, 1",
		"1, 0, 0; 0, 1, 0; 0, 0, inf",
		"-Infinity, 0, 0; 0, 1, 0; 0, 0, 1",
		"1e9999, 0, 0; 0, 1, 0; 0, 0, 1",
		/* The extra nonzero coefficient separates literal underflow rejection
		 * from the pre-existing all-zero-row rejection. */
		"1e-9999, 1, 0; 0, 1, 0; 0, 0, 1",
		"-1e-9999, 1, 0; 0, 1, 0; 0, 0, 1",
		"1junk, 0, 0; 0, 1, 0; 0, 0, 1",
		"1 2, 0, 0; 0, 1, 0; 0, 0, 1",
		"1, , 0; 0, 1, 0; 0, 0, 1",
		"1, 0; 0, 1, 0; 0, 0, 1",
		"1, 0, 0, 2; 0, 1, 0; 0, 0, 1",
		"1, 0, 0; 0, 1, 0",
		"1, 0, 0; 0, 1, 0; 0, 0, 1, 2",
		"1, 0, 0; 0, 1, 0; 0, 0, 1;"
	};
	AccelVec3 *sentinel = NULL;
	AccelVec3 saved[3];

	g_assert_true (parse_mount_matrix (DEFAULT_MATRIX, &sentinel));
	memcpy (saved, sentinel, sizeof saved);
	for (guint i = 0; i < G_N_ELEMENTS (invalid); i++) {
		AccelVec3 *output = sentinel;

		g_test_expect_message (NULL, G_LOG_LEVEL_WARNING, "*mount matrix*");
		g_assert_false (parse_mount_matrix (invalid[i], &output));
		g_test_assert_expected_messages ();
		g_assert_true (output == sentinel);
		g_assert_cmpmem (sentinel, sizeof saved, saved, sizeof saved);
	}
	g_free (sentinel);
}

static void
test_subnormal_matrix_tokens (void)
{
	const gdouble values[] = { DBL_MIN / 2.0,
		scalbn (1.0, DBL_MIN_EXP - DBL_MANT_DIG) };

	for (guint i = 0; i < G_N_ELEMENTS (values); i++) {
		AccelVec3 *matrix = NULL;
		char number[G_ASCII_DTOSTR_BUF_SIZE];
		g_autofree char *text = NULL;

		g_assert_cmpfloat (values[i], >, 0.0);
		g_ascii_dtostr (number, sizeof number, values[i]);
		text = g_strdup_printf ("%s, 0, 0; 0, 1, 0; 0, 0, 1", number);
		g_assert_true (parse_mount_matrix (text, &matrix));
		g_assert_cmpfloat (matrix[0].x, ==, values[i]);
		g_free (matrix);
	}
}

static void
assert_apply_unchanged (const AccelVec3 matrix[3], AccelVec3 *input)
{
	AccelVec3 before;

	memcpy (&before, input, sizeof before);
	g_assert_false (apply_mount_matrix (matrix, input));
	/* Preserve all bits, including signed zero and a quiet-NaN payload. */
	g_assert_cmpmem (input, sizeof *input, &before, sizeof before);
}

static void
set_component (AccelVec3 *value, guint axis, gdouble number)
{
	if (axis == 0)
		value->x = number;
	else if (axis == 1)
		value->y = number;
	else
		value->z = number;
}

static void
test_invalid_apply_unchanged (void)
{
	const AccelVec3 identity[3] = {
		{ 1.0, 0.0, 0.0 }, { 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 }
	};
	guint64 nan_bits = G_GUINT64_CONSTANT (0x7ff8000000001234);
	gdouble payload_nan;
	gdouble invalid[] = { NAN, INFINITY, -INFINITY };
	AccelVec3 product_overflow[3] = {
		{ 2.0, 0.0, 0.0 }, { 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 }
	};
	AccelVec3 sum_overflow[3] = {
		{ DBL_MAX, DBL_MAX, 0.0 }, { 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 }
	};
	AccelVec3 input = { DBL_MAX, -0.0, 1.0 };

	g_assert_cmpuint (sizeof payload_nan, ==, sizeof nan_bits);
	memcpy (&payload_nan, &nan_bits, sizeof payload_nan);
	invalid[0] = payload_nan;
	for (guint i = 0; i < G_N_ELEMENTS (invalid); i++) {
		for (guint axis = 0; axis < 3; axis++) {
			AccelVec3 value = { -0.0, 1.25, -2.5 };

			set_component (&value, axis, invalid[i]);
			assert_apply_unchanged (identity, &value);
		}
		for (guint row = 0; row < 3; row++) {
			for (guint axis = 0; axis < 3; axis++) {
				AccelVec3 matrix[3];
				AccelVec3 value = { -0.0, 1.25, -2.5 };

				memcpy (matrix, identity, sizeof matrix);
				set_component (&matrix[row], axis, invalid[i]);
				assert_apply_unchanged (matrix, &value);
			}
		}
	}
	assert_apply_unchanged (product_overflow, &input);
	input.x = input.y = input.z = 1.0;
	assert_apply_unchanged (sum_overflow, &input);
}

int main (int argc, char **argv)
{
	setlocale(LC_ALL, "");
	g_test_init (&argc, &argv, NULL);

	g_test_add_func ("/iio-sensor-proxy/mount-matrix", test_mount_matrix);
	g_test_add_func ("/iio-sensor-proxy/comma-decimal-separator", test_comma_decimal_separator);
	g_test_add_func ("/iio-sensor-proxy/numeric/fractional-matrix", test_fractional_transform);
	g_test_add_func ("/iio-sensor-proxy/numeric/matrix-finite-extremes", test_finite_extremes);
	g_test_add_func ("/iio-sensor-proxy/numeric/matrix-invalid-tokens", test_invalid_matrix_tokens);
	g_test_add_func ("/iio-sensor-proxy/numeric/matrix-subnormal-tokens", test_subnormal_matrix_tokens);
	g_test_add_func ("/iio-sensor-proxy/numeric/matrix-invalid-apply-unchanged", test_invalid_apply_unchanged);

	return g_test_run ();
}
