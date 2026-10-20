/*
 * Copyright (c) 2016 Bastien Nocera <hadess@hadess.net>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3 as published by
 * the Free Software Foundation.
 *
 */

#include <glib.h>
#include <errno.h>
#include <float.h>
#include <limits.h>
#include <locale.h>
#include <math.h>
#include "orientation.h"
#include "accel-mount-matrix.h"

#define ONEG 256

static void
test_orientation (void)
{
	static struct {
		int x;
		int y;
		int z;
		OrientationUp expected;
	} orientations[] = {
		{ 0, -ONEG, 0, ORIENTATION_NORMAL },
		{ -ONEG, 0, 0, ORIENTATION_RIGHT_UP },
		{ ONEG, 0, 0, ORIENTATION_LEFT_UP },
		{ 0, ONEG, 0, ORIENTATION_BOTTOM_UP }
	};
	guint i, num_failures;

	num_failures = 0;

	for (i = 0; i < G_N_ELEMENTS (orientations); i++) {
		OrientationUp o;
		const char *expected, *result;
		AccelScale scale;

		set_accel_scale (&scale, 9.81 / ONEG);
		o = orientation_calc (ORIENTATION_UNDEFINED,
				      orientations[i].x,
				      orientations[i].y,
				      orientations[i].z,
				      scale);
		result = orientation_to_string (o);
		expected = orientation_to_string (orientations[i].expected);
		/* Fail straight away when not verbose */
		if (g_test_verbose ()) {
			if (g_strcmp0 (result, expected) != 0) {
				g_test_message ("Expected %s, got %s", expected, result);
				num_failures++;
			}
		} else {
			g_assert_cmpstr (result, ==, expected);
		}
	}

	if (num_failures > 0)
		g_test_fail ();
}

static void
test_orientation_threshold (void)
{
	static struct {
		int x;
		int y;
		int z;
		OrientationUp expected;
	} orientations[] = {
		{ 0, -ONEG, 0, ORIENTATION_NORMAL },
		{ 183, -ONEG, 0, ORIENTATION_NORMAL },
		{ 176, -ONEG, 0, ORIENTATION_NORMAL },
		{ 183, -ONEG, 0, ORIENTATION_NORMAL },
	};
	guint i, num_failures;
	OrientationUp prev;

	num_failures = 0;
	prev = ORIENTATION_UNDEFINED;

	for (i = 0; i < G_N_ELEMENTS (orientations); i++) {
		OrientationUp o;
		const char *expected, *result;
		AccelScale scale;

		set_accel_scale (&scale, 9.81 / ONEG);
		o = orientation_calc (prev,
				      orientations[i].x,
				      orientations[i].y,
				      orientations[i].z,
				      scale);
		result = orientation_to_string (o);
		expected = orientation_to_string (orientations[i].expected);
		/* Fail straight away when not verbose */
		if (g_test_verbose ()) {
			if (g_strcmp0 (result, expected) != 0) {
				g_test_message ("Expected %s, got %s (orientation #%d)", expected, result, i);
				num_failures++;
			}
		} else {
			g_assert_cmpstr (result, ==, expected);
		}
		g_assert_cmpstr (result, ==, expected);
		prev = orientations[i].expected;
	}

	if (num_failures > 0)
		g_test_fail ();
}

static void
test_mount_matrix_orientation (void)
{
	guint i;
	struct {
		AccelVec3 readings;
		gdouble scale;
		const char *mount_matrix;
		OrientationUp expected;
	} tests[] = {
		/* Onda v975 quirking */
		{ { 523, 13, 5 }, 0.019163, "0, -1, 0; -1, 0, 0; 0, 0, 1", ORIENTATION_NORMAL },
		{ { 8, 521, -67 }, 0.019163, "0, -1, 0; -1, 0, 0; 0, 0, 1", ORIENTATION_RIGHT_UP },
		/* Winbook TW100 quirking */
		{ { 24, 0, -21 }, 0.306457, "0, -1, 0; -1, 0, 0; 0, 0, 1", ORIENTATION_NORMAL },
		{ { 15, -25, -14 }, 0.306457, "0, -1, 0; -1, 0, 0; 0, 0, 1", ORIENTATION_LEFT_UP }
	};

	for (i = 0; i < G_N_ELEMENTS (tests); i++) {
		AccelVec3 *vecs;
		const char *result, *expected;
		OrientationUp o;
		AccelScale scale;

		g_assert_true (parse_mount_matrix (tests[i].mount_matrix, &vecs));
		g_assert_true (apply_mount_matrix (vecs, &tests[i].readings));
		set_accel_scale (&scale, tests[i].scale);
		o = orientation_calc (ORIENTATION_UNDEFINED,
				      tests[i].readings.x,
				      tests[i].readings.y,
				      tests[i].readings.z,
				      scale);
		result = orientation_to_string (o);
		expected = orientation_to_string (tests[i].expected);
		g_assert_cmpstr (result, ==, expected);
		g_free (vecs);
	}
}

static void
test_fractional_vectors (void)
{
	const struct {
		gdouble x, y, z;
		OrientationUp orientation;
		Tilt tilt;
	} cases[] = {
		{ 0.0, -0.125, 0.0, ORIENTATION_NORMAL, TILT_VERTICAL },
		{ -0.125, 0.0, 0.0, ORIENTATION_RIGHT_UP, TILT_VERTICAL },
		{ 0.125, 0.0, 0.0, ORIENTATION_LEFT_UP, TILT_VERTICAL },
		{ 0.0, 0.125, 0.0, ORIENTATION_BOTTOM_UP, TILT_VERTICAL },
		{ 0.0, 0.0, 0.125, ORIENTATION_UNDEFINED, FACE_UP },
		{ 0.0, 0.0, -0.125, ORIENTATION_UNDEFINED, FACE_DOWN },
		{ 0.125, 0.0, 0.125, ORIENTATION_LEFT_UP, TILT_UP },
		{ 0.125, 0.0, -0.125, ORIENTATION_LEFT_UP, TILT_DOWN }
	};
	AccelScale scale;

	set_accel_scale (&scale, 1.0);
	for (guint i = 0; i < G_N_ELEMENTS (cases); i++) {
		g_assert_cmpint (orientation_calc (ORIENTATION_UNDEFINED, cases[i].x,
		                                    cases[i].y, cases[i].z, scale),
		                 ==, cases[i].orientation);
		g_assert_cmpint (tilt_calc (TILT_UNDEFINED, cases[i].x, cases[i].y,
		                            cases[i].z, scale), ==, cases[i].tilt);
	}
}

static void
test_finite_extremes (void)
{
	const struct {
		gdouble x, y, z;
		AccelScale scale;
		OrientationUp orientation;
		Tilt tilt;
	} cases[] = {
		{ INT_MIN, 0.0, 0.0, { 1.0, 1.0, 1.0 }, ORIENTATION_RIGHT_UP, TILT_VERTICAL },
		{ INT_MAX, 0.0, 0.0, { 1.0, 1.0, 1.0 }, ORIENTATION_LEFT_UP, TILT_VERTICAL },
		{ 0.0, -FLT_MAX, 0.0, { 1.0, 1.0, 1.0 }, ORIENTATION_NORMAL, TILT_VERTICAL },
		{ 0.0, DBL_MAX, 0.0, { 1.0, 1.0, 1.0 }, ORIENTATION_BOTTOM_UP, TILT_VERTICAL },
		{ -DBL_MAX, 0.0, 0.0, { DBL_MAX, 1.0, 1.0 }, ORIENTATION_RIGHT_UP, TILT_VERTICAL },
		{ 0.0, -DBL_MIN, 0.0, { 1.0, DBL_MIN, 1.0 }, ORIENTATION_NORMAL, TILT_VERTICAL },
		{ DBL_MAX, 0.0, 0.0, { DBL_MIN, 1.0, 1.0 }, ORIENTATION_LEFT_UP, TILT_VERTICAL },
		{ DBL_MIN, 0.0, 0.0, { DBL_MAX, 1.0, 1.0 }, ORIENTATION_LEFT_UP, TILT_VERTICAL },
		/* A global input/scale maximum would lose one of these products. */
		{ DBL_MIN, -DBL_MAX, 0.0, { DBL_MAX / 4.0, DBL_MIN, 1.0 }, ORIENTATION_NORMAL, TILT_VERTICAL },
		{ DBL_MAX, DBL_MIN, 0.0, { DBL_MIN, DBL_MAX, 1.0 }, ORIENTATION_UNDEFINED, TILT_VERTICAL },
		{ 0.0, 0.0, DBL_MAX, { 1.0, 1.0, DBL_MAX }, ORIENTATION_UNDEFINED, FACE_UP },
		{ 0.0, 0.0, -DBL_MIN, { 1.0, 1.0, DBL_MIN }, ORIENTATION_UNDEFINED, FACE_DOWN },
		{ 0.125, 0.0, 0.0, { -1.0, 1.0, 1.0 }, ORIENTATION_RIGHT_UP, TILT_VERTICAL },
		{ FLT_MAX, -0.125, 0.0, { 0.0, 1.0, 1.0 }, ORIENTATION_NORMAL, TILT_VERTICAL },
		{ 0.0, 0.0, 0.125, { 1.0, 1.0, -1.0 }, ORIENTATION_UNDEFINED, FACE_DOWN }
	};
	gdouble subnormal = scalbn (1.0, DBL_MIN_EXP - DBL_MANT_DIG);
	AccelScale scale;

	for (guint i = 0; i < G_N_ELEMENTS (cases); i++) {
		g_test_message ("finite extreme case %u", i);
		g_assert_cmpint (orientation_calc (ORIENTATION_UNDEFINED, cases[i].x,
		                                    cases[i].y, cases[i].z, cases[i].scale),
		                 ==, cases[i].orientation);
		g_assert_cmpint (tilt_calc (TILT_UNDEFINED, cases[i].x, cases[i].y,
		                            cases[i].z, cases[i].scale), ==, cases[i].tilt);
	}
	g_assert_cmpfloat (subnormal, >, 0.0);
	set_accel_scale (&scale, subnormal);
	g_assert_cmpint (orientation_calc (ORIENTATION_UNDEFINED, subnormal, 0.0, 0.0,
	                                    scale), ==, ORIENTATION_LEFT_UP);
	g_assert_cmpint (tilt_calc (TILT_UNDEFINED, 0.0, 0.0, -subnormal, scale),
	                 ==, FACE_DOWN);
}

static void
test_invalid_numeric_inputs (void)
{
	const gdouble invalid[] = { NAN, INFINITY, -INFINITY };
	const OrientationUp previous[] = { ORIENTATION_UNDEFINED, ORIENTATION_NORMAL,
		ORIENTATION_BOTTOM_UP, ORIENTATION_LEFT_UP, ORIENTATION_RIGHT_UP };
	const Tilt tilts[] = { TILT_UNDEFINED, TILT_VERTICAL, TILT_UP, TILT_DOWN,
		FACE_UP, FACE_DOWN };
	AccelScale scale;

	set_accel_scale (&scale, 1.0);
	for (guint i = 0; i < G_N_ELEMENTS (invalid); i++) {
		for (guint axis = 0; axis < 3; axis++) {
			gdouble values[] = { 0.125, -0.25, 0.5 };
			AccelScale invalid_scale = scale;

			values[axis] = invalid[i];
			if (axis == 0)
				invalid_scale.x = invalid[i];
			else if (axis == 1)
				invalid_scale.y = invalid[i];
			else
				invalid_scale.z = invalid[i];
			for (guint j = 0; j < G_N_ELEMENTS (previous); j++) {
				g_assert_cmpint (orientation_calc (previous[j], values[0], values[1],
				                                    values[2], scale), ==, previous[j]);
				g_assert_cmpint (orientation_calc (previous[j], 0.125, -0.25, 0.5,
				                                    invalid_scale), ==, previous[j]);
			}
			for (guint j = 0; j < G_N_ELEMENTS (tilts); j++) {
				g_assert_cmpint (tilt_calc (tilts[j], values[0], values[1], values[2],
				                            scale), ==, tilts[j]);
				g_assert_cmpint (tilt_calc (tilts[j], 0.125, -0.25, 0.5,
				                            invalid_scale), ==, tilts[j]);
			}
		}
	}
	for (guint i = 0; i < G_N_ELEMENTS (previous); i++) {
		AccelScale one_zero = { 0.0, 1.0, 1.0 };

		g_assert_cmpint (orientation_calc (previous[i], 0.0, 0.0, 0.0, scale),
		                 ==, previous[i]);
		g_assert_cmpint (orientation_calc (previous[i], 0.125, 0.0, 0.0, one_zero),
		                 ==, previous[i]);
		scale = (AccelScale) { 0.0, 0.0, 0.0 };
		g_assert_cmpint (orientation_calc (previous[i], 0.125, -0.25, 0.5, scale),
		                 ==, previous[i]);
		set_accel_scale (&scale, 1.0);
	}
	for (guint i = 0; i < G_N_ELEMENTS (tilts); i++) {
		AccelScale one_zero = { 0.0, 1.0, 1.0 };

		g_assert_cmpint (tilt_calc (tilts[i], 0.0, 0.0, 0.0, scale), ==, tilts[i]);
		g_assert_cmpint (tilt_calc (tilts[i], 0.125, 0.0, 0.0, one_zero), ==, tilts[i]);
		scale = (AccelScale) { 0.0, 0.0, 0.0 };
		g_assert_cmpint (tilt_calc (tilts[i], 0.125, -0.25, 0.5, scale), ==, tilts[i]);
		set_accel_scale (&scale, 1.0);
	}
}

static void
test_fractional_thresholds (void)
{
	const gdouble magnitudes[] = { 1.0, 1e-250, 1e250 };
	AccelScale scale;

	set_accel_scale (&scale, 1.0);
	for (guint i = 0; i < G_N_ELEMENTS (magnitudes); i++) {
		gdouble m = magnitudes[i];

		/* All base components are below one. Preserve degree thresholds,
		 * without quantizing them through the old integer/1G conversion. */
		g_assert_cmpint (orientation_calc (ORIENTATION_LEFT_UP, 0.0067 * m,
		                                    -0.01 * m, 0.0, scale), ==, ORIENTATION_NORMAL);
		g_assert_cmpint (orientation_calc (ORIENTATION_LEFT_UP, 0.0073 * m,
		                                    -0.01 * m, 0.0, scale), ==, ORIENTATION_LEFT_UP);
		g_assert_cmpint (tilt_calc (TILT_UNDEFINED, 0.01 * m, 0.0,
		                            0.0034 * m, scale), ==, TILT_VERTICAL);
		g_assert_cmpint (tilt_calc (TILT_UNDEFINED, 0.01 * m, 0.0,
		                            0.0041 * m, scale), ==, TILT_UP);
		g_assert_cmpint (tilt_calc (TILT_UNDEFINED, 0.01 * m, 0.0,
		                            0.025 * m, scale), ==, TILT_UP);
		g_assert_cmpint (tilt_calc (TILT_UNDEFINED, 0.01 * m, 0.0,
		                            0.031 * m, scale), ==, FACE_UP);
	}
}

static gboolean
parse_finite_cli_number (const char *text, gdouble *result)
{
	char *end;
	gdouble value;

	if (!text)
		return FALSE;
	errno = 0;
	value = g_ascii_strtod (text, &end);
	if (end == text || !isfinite (value) || (errno == ERANGE && value == 0.0))
		return FALSE;
	while (g_ascii_isspace (*end))
		end++;
	if (*end != '\0')
		return FALSE;
	*result = value;
	return TRUE;
}

static void
test_cli_number_parser (void)
{
	const char *invalid[] = { "", " ", "nan", "NaN", "inf", "-Infinity",
		"1junk", "1 2", "1e9999", "1e-9999", "-1e-9999", "--1" };
	const gdouble valid[] = { 0.0, -0.125, 1.0, DBL_MIN / 2.0, DBL_MIN, DBL_MAX };
	gdouble result = 23.0;
	char text[G_ASCII_DTOSTR_BUF_SIZE];

	g_assert_false (parse_finite_cli_number (NULL, &result));
	for (guint i = 0; i < G_N_ELEMENTS (invalid); i++) {
		g_assert_false (parse_finite_cli_number (invalid[i], &result));
		g_assert_cmpfloat (result, ==, 23.0);
	}
	for (guint i = 0; i < G_N_ELEMENTS (valid); i++) {
		g_ascii_dtostr (text, sizeof text, valid[i]);
		g_assert_true (parse_finite_cli_number (text, &result));
		g_assert_cmpfloat (result, ==, valid[i]);
	}
	g_assert_true (parse_finite_cli_number (" 0.125 \t", &result));
	g_assert_cmpfloat (result, ==, 0.125);
}

static void
test_scale_validation (void)
{
	const gdouble invalid_setter[] = { 0.0, -0.0, NAN, INFINITY, -INFINITY };
	const char *invalid_text[] = { "", " ", "0", "-0", "nan", "NaN", "inf",
		"-Infinity", "1junk", "1 2", "1e9999", "1e-9999", "-1e-9999", "--1" };
	const gdouble valid[] = { 1.0, -0.125, DBL_MIN / 2.0, DBL_MIN, DBL_MAX,
		scalbn (1.0, DBL_MIN_EXP - DBL_MANT_DIG) };
	const AccelScale original = { 0.125, -0.25, 0.5 };
	AccelScale scale = original;
	gdouble result = 23.0;
	char text[G_ASCII_DTOSTR_BUF_SIZE];

	for (guint i = 0; i < G_N_ELEMENTS (invalid_setter); i++) {
		g_test_expect_message (NULL, G_LOG_LEVEL_CRITICAL, "*set_accel_scale*assertion*failed*");
		set_accel_scale (&scale, invalid_setter[i]);
		g_test_assert_expected_messages ();
		g_assert_cmpfloat (scale.x, ==, original.x);
		g_assert_cmpfloat (scale.y, ==, original.y);
		g_assert_cmpfloat (scale.z, ==, original.z);
	}
	g_assert_false (parse_accel_scale (NULL, &result));
	g_assert_cmpfloat (result, ==, 23.0);
	for (guint i = 0; i < G_N_ELEMENTS (invalid_text); i++) {
		g_assert_false (parse_accel_scale (invalid_text[i], &result));
		g_assert_cmpfloat (result, ==, 23.0);
	}
	for (guint i = 0; i < G_N_ELEMENTS (valid); i++) {
		g_ascii_dtostr (text, sizeof text, valid[i]);
		g_assert_true (parse_accel_scale (text, &result));
		g_assert_cmpfloat (result, ==, valid[i]);
		set_accel_scale (&scale, result);
		g_assert_cmpfloat (scale.x, ==, valid[i]);
		g_assert_cmpfloat (scale.y, ==, valid[i]);
		g_assert_cmpfloat (scale.z, ==, valid[i]);
	}
	g_assert_true (parse_accel_scale (" \t-0.125 \n", &result));
	g_assert_cmpfloat (result, ==, -0.125);
}

static gboolean
print_orientation (const char *x_str,
		   const char *y_str,
		   const char *z_str,
		   const char *scale_str,
		   const char *mount_matrix)
{
	gdouble x, y, z;
	gdouble scale;
	OrientationUp o;
	AccelScale scale_vec;

	if (!parse_finite_cli_number (x_str, &x) ||
	    !parse_finite_cli_number (y_str, &y) ||
	    !parse_finite_cli_number (z_str, &z) ||
	    !parse_accel_scale (scale_str ? scale_str : "1.0", &scale)) {
		g_printerr ("Coordinates must be finite numbers and scale must be finite and nonzero, without trailing junk\n");
		return FALSE;
	}

	if (mount_matrix) {
		AccelVec3 *vecs;
		AccelVec3 readings;

		if (!parse_mount_matrix (mount_matrix, &vecs)) {
			g_printerr ("Could not parse mount matrix '%s'\n",
				    mount_matrix);
			return FALSE;
		}

		readings.x = x;
		readings.y = y;
		readings.z = z;

		if (!apply_mount_matrix (vecs, &readings)) {
			g_printerr ("Could not apply mount matrix '%s'\n",
				    mount_matrix);
			g_free (vecs);
			return FALSE;
		}

		x = readings.x;
		y = readings.y;
		z = readings.z;

		g_free (vecs);
	}

	set_accel_scale (&scale_vec, scale);
	o = orientation_calc (ORIENTATION_UNDEFINED, x, y, z, scale_vec);
	g_print ("Orientation for %g,%g,%g (scale: %g) is '%s'\n",
		 x, y, z, scale, orientation_to_string (o));

	return TRUE;
}

int main (int argc, char **argv)
{
	setlocale(LC_ALL, "");
	g_test_init (&argc, &argv, NULL);

	if (argc > 1) {
		gboolean ret;

		if (argc == 6) {
			ret = print_orientation (argv[1], argv[2], argv[3], argv[4], argv[5]);
		} else if (argc == 5) {
			ret = print_orientation (argv[1], argv[2], argv[3], argv[4], NULL);
		} else if (argc == 4) {
			ret = print_orientation (argv[1], argv[2], argv[3], "1.0", NULL);
		} else {
			g_printerr ("Usage: %s X Y Z [scale] [mount-matrix]\n", argv[0]);
			ret = FALSE;
		}
		return (ret == FALSE ? 1 : 0);
	}

	g_test_add_func ("/iio-sensor-proxy/orientation", test_orientation);
	g_test_add_func ("/iio-sensor-proxy/quirking", test_mount_matrix_orientation);
	g_test_add_func ("/iio-sensor-proxy/threshold", test_orientation_threshold);
	g_test_add_func ("/iio-sensor-proxy/numeric/fractional-vectors", test_fractional_vectors);
	g_test_add_func ("/iio-sensor-proxy/numeric/finite-extremes", test_finite_extremes);
	g_test_add_func ("/iio-sensor-proxy/numeric/invalid-preserves-state", test_invalid_numeric_inputs);
	g_test_add_func ("/iio-sensor-proxy/numeric/fractional-thresholds", test_fractional_thresholds);
	g_test_add_func ("/iio-sensor-proxy/numeric/cli-number-parser", test_cli_number_parser);
	g_test_add_func ("/iio-sensor-proxy/numeric/scale-validation", test_scale_validation);

	return g_test_run ();
}
