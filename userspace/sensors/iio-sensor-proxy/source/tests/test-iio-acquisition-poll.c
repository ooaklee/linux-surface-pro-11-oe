/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Actual polling driver, private parsers and callback path in its own TU. */
#include "../src/drv-iio-poll-accel.c"
#include "../src/utils.h"

GUdevDevice *acquisition_fixture_begin (void);
void acquisition_fixture_end (void);
void acquisition_fixture_attribute (const char *name, const char *value, gboolean uncached);
void acquisition_fixture_clear_attributes (void);
void acquisition_fixture_name_present (gboolean present);
void acquisition_fixture_disk_attribute (const char *name, const char *value, gssize length);
void acquisition_fixture_dangling_attribute (const char *name);
void acquisition_fixture_read_fault (const char *name, int file_error);
void acquisition_fixture_clear_read_faults (void);
guint acquisition_fixture_read_count (const char *name);
void acquisition_fixture_sysfs_path (const char *path, gboolean overridden);
void acquisition_fixture_remove_empty_sysfs_dir (void);
void acquisition_fixture_mount_matrix (const char *matrix);
void acquisition_fixture_fixup_result (gboolean result);
void acquisition_fixture_fixup_count (guint expected);
void acquisition_fixture_raw_read_count (guint expected);
void acquisition_fixture_device_refs (guint expected);
void register_iio_acquisition_poll_tests (void);

static void
test_raw_finite_decimal_domains (void)
{
	const struct { const char *text; gdouble expected; } cases[] = {
		{ "0", 0 }, { "-0", 0 }, { "+0", 0 }, { " 42\n", 42 },
		{ "+42", 42 }, { "-42", -42 },
		{ "0.125", 0.125 }, { "-25.6", -25.6 }, { "72.4", 72.4 },
		{ "1e2", 100 }, { "1e20", 1e20 }, { "1e-310", 1e-310 },
		{ "9223372036854775807", (gdouble) G_MAXINT64 },
		{ "-9223372036854775808", (gdouble) G_MININT64 },
		{ "18446744073709551615", (gdouble) G_MAXUINT64 },
		{ "18446744073709551616", 18446744073709551616.0 },
		{ "-9223372036854775809", -9223372036854775809.0 },
		{ "1.7976931348623157e308", G_MAXDOUBLE }
	};

	for (guint i = 0; i < G_N_ELEMENTS (cases); i++) {
		gdouble value = 0.125;
		g_assert_true (parse_raw_axis (cases[i].text, &value));
		g_assert_cmpfloat (value, ==, cases[i].expected);
	}
}

static void
test_raw_invalid_preserves_output (void)
{
	const char *invalid[] = { NULL, "", " ", "+", "-", "0x10", "0X1p0", "+0x1", "-0x1",
		"12junk", "1.5units", "nan", "inf", "-inf", "1e309", "-1e309",
		"1e-9999", "-1e-9999", "++1", "+-1", "1 2", "0b10" };

	for (guint i = 0; i < G_N_ELEMENTS (invalid); i++) {
		gdouble value = 0.125;
		g_assert_false (parse_raw_axis (invalid[i], &value));
		g_assert_cmpfloat (value, ==, 0.125);
	}
}

static void
test_offset_precedence_and_units (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	gdouble value = -99;

	g_assert_true (read_axis_offset (device, "in_accel_x_offset", &value));
	g_assert_cmpfloat (value, ==, 0);
	acquisition_fixture_attribute ("in_accel_x_offset", "0.25", FALSE);
	acquisition_fixture_attribute ("in_accel_offset", "999", FALSE);
	acquisition_fixture_attribute ("offset", "888", FALSE);
	g_assert_true (read_axis_offset (device, "in_accel_x_offset", &value));
	g_assert_cmpfloat (value, ==, 0.25);
	acquisition_fixture_attribute ("in_accel_x_offset", NULL, FALSE);
	acquisition_fixture_attribute ("in_accel_offset", "-1.5", FALSE);
	g_assert_true (read_axis_offset (device, "in_accel_x_offset", &value));
	g_assert_cmpfloat (value, ==, -1.5);
	acquisition_fixture_attribute ("in_accel_offset", NULL, FALSE);
	acquisition_fixture_attribute ("offset", "+0.125\n", FALSE);
	g_assert_true (read_axis_offset (device, "in_accel_x_offset", &value));
	g_assert_cmpfloat (value, ==, 0.125);
	acquisition_fixture_attribute ("in_accel_x_offset", "0", FALSE);
	g_assert_true (read_axis_offset (device, "in_accel_x_offset", &value));
	g_assert_cmpfloat (value, ==, 0);
	acquisition_fixture_attribute ("in_accel_x_offset", "1e-310", FALSE);
	g_assert_true (read_axis_offset (device, "in_accel_x_offset", &value));
	g_assert_true (isfinite (value) && value > 0);
	acquisition_fixture_end ();
}

static void
test_offset_malformed_never_falls_back (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	const char *invalid[] = { "", " ", "1.5units", "NaN", "Inf", "-Inf", "1e9999", "1e-9999", "-1e-9999",
		"0x1p0", "+0X1", "-0x10", "0X.8p2" };

	acquisition_fixture_attribute ("in_accel_offset", "1.0", FALSE);
	acquisition_fixture_attribute ("offset", "2.0", FALSE);
	for (guint i = 0; i < G_N_ELEMENTS (invalid); i++) {
		gdouble value = 0.125;
		acquisition_fixture_attribute ("in_accel_x_offset", invalid[i], FALSE);
		g_assert_false (read_axis_offset (device, "in_accel_x_offset", &value));
		g_assert_cmpfloat (value, ==, 0.125);
	}
	acquisition_fixture_attribute ("in_accel_x_offset", NULL, FALSE);
	acquisition_fixture_attribute ("in_accel_offset", "junk", FALSE);
	gdouble value = 0.125;
	g_assert_false (read_axis_offset (device, "in_accel_x_offset", &value));
	g_assert_cmpfloat (value, ==, 0.125);
	acquisition_fixture_end ();
}

static void
assert_scale (AccelScale value, gdouble x, gdouble y, gdouble z)
{
	g_assert_cmpfloat (value.x, ==, x);
	g_assert_cmpfloat (value.y, ==, y);
	g_assert_cmpfloat (value.z, ==, z);
}

static void
test_mixed_scale_precedence (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	AccelScale scale;

	acquisition_fixture_attribute ("in_accel_x_scale", "10", FALSE);
	acquisition_fixture_attribute ("in_accel_scale", "1", FALSE);
	g_assert_true (get_accel_scale (device, &scale));
	assert_scale (scale, 10, 1, 1);
	scale = (AccelScale) { 11, 12, 13 };
	acquisition_fixture_attribute ("in_accel_y_scale", "junk", FALSE);
	g_assert_false (get_accel_scale (device, &scale));
	assert_scale (scale, 11, 12, 13);
	acquisition_fixture_attribute ("in_accel_y_scale", NULL, FALSE);
	acquisition_fixture_attribute ("in_accel_scale", "NaN", FALSE);
	g_assert_false (get_accel_scale (device, &scale));
	assert_scale (scale, 11, 12, 13);
	acquisition_fixture_attribute ("in_accel_x_scale", "2", FALSE);
	acquisition_fixture_attribute ("in_accel_y_scale", "3", FALSE);
	acquisition_fixture_attribute ("in_accel_z_scale", "4", FALSE);
	g_assert_true (get_accel_scale (device, &scale));
	assert_scale (scale, 2, 3, 4);
	acquisition_fixture_clear_attributes ();
	g_assert_true (get_accel_scale (device, &scale));
	assert_scale (scale, 1, 1, 1);
	acquisition_fixture_attribute ("in_accel_x_scale", "10", FALSE);
	acquisition_fixture_attribute ("scale", "0.5", FALSE);
	g_assert_true (get_accel_scale (device, &scale));
	assert_scale (scale, 10, 0.5, 0.5);
	acquisition_fixture_end ();
}

typedef struct { guint count; SensorDevice *sensor; AccelReadings last; } PollCapture;

static gboolean
unexpected_poll_timer (gpointer data)
{
	(void) data;
	g_assert_not_reached ();
	return G_SOURCE_REMOVE;
}

static void
capture_reading (SensorDevice *sensor, gpointer readings, gpointer user_data)
{
	PollCapture *capture = user_data;
	g_assert_true (sensor == capture->sensor);
	capture->last = *(AccelReadings *) readings;
	capture->count++;
}

static void
test_poll_scaled_before_mount_and_recovery (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	SensorDevice *sensor = g_new0 (SensorDevice, 1);
	DrvData *data = g_new0 (DrvData, 1);
	PollCapture capture = { .sensor = sensor };
	guint timeout_id;

	sensor->name = g_strdup ("polled synthetic raw axes");
	sensor->priv = data;
	sensor->callback_func = capture_reading;
	sensor->user_data = &capture;
	data->dev = g_object_ref (device);
	data->scale = (AccelScale) { 2, 3, 0.5 };
	data->offset = (AccelVec3) { 0.25, -0.5, 1.5 };
	g_assert_true (parse_mount_matrix ("0,-1,0;1,0,0;0,0,1", &data->mount_matrix));
	acquisition_fixture_attribute ("in_accel_x_raw", "0.125", TRUE);
	acquisition_fixture_attribute ("in_accel_y_raw", "4", TRUE);
	acquisition_fixture_attribute ("in_accel_z_raw", "-3", TRUE);
	g_assert_true (poll_orientation (sensor));
	g_assert_cmpuint (capture.count, ==, 1);
	g_assert_cmpfloat (capture.last.accel_x, ==, -10.5);
	g_assert_cmpfloat (capture.last.accel_y, ==, 0.75);
	g_assert_cmpfloat (capture.last.accel_z, ==, -0.75);
	assert_scale (capture.last.scale, 1, 1, 1);
	acquisition_fixture_attribute ("in_accel_y_raw", NULL, TRUE);
	g_assert_true (poll_orientation (sensor));
	g_assert_cmpuint (capture.count, ==, 1);
	acquisition_fixture_attribute ("in_accel_y_raw", "4", TRUE);
	acquisition_fixture_attribute ("in_accel_x_raw", "1.5junk", TRUE);
	g_assert_true (poll_orientation (sensor));
	g_assert_cmpuint (capture.count, ==, 1);
	data->offset = (AccelVec3) { 0, 0, 0 };
	acquisition_fixture_attribute ("in_accel_x_raw", "0", TRUE);
	acquisition_fixture_attribute ("in_accel_y_raw", "0", TRUE);
	acquisition_fixture_attribute ("in_accel_z_raw", "0", TRUE);
	g_assert_true (poll_orientation (sensor));
	g_assert_cmpuint (capture.count, ==, 2);
	g_assert_cmpfloat (capture.last.accel_x, ==, 0);
	g_assert_cmpfloat (capture.last.accel_y, ==, 0);
	g_assert_cmpfloat (capture.last.accel_z, ==, 0);
	assert_scale (capture.last.scale, 1, 1, 1);
	reset_accel_scale (&data->scale);
	acquisition_fixture_attribute ("in_accel_x_raw", "18446744073709551615", TRUE);
	acquisition_fixture_attribute ("in_accel_z_raw", "-9223372036854775808", TRUE);
	g_assert_true (poll_orientation (sensor));
	g_assert_cmpuint (capture.count, ==, 3);
	g_assert_cmpfloat (capture.last.accel_x, ==, 0);
	g_assert_cmpfloat (capture.last.accel_y, ==, (gdouble) G_MAXUINT64);
	g_assert_cmpfloat (capture.last.accel_z, ==, (gdouble) G_MININT64);
	assert_scale (capture.last.scale, 1, 1, 1);
	data->timeout_id = timeout_id = g_timeout_add (1, unexpected_poll_timer, sensor);
	g_assert_nonnull (g_main_context_find_source_by_id (NULL, timeout_id));
	iio_poll_accel_close (sensor);
	g_assert_null (g_main_context_find_source_by_id (NULL, timeout_id));
	while (g_main_context_iteration (NULL, FALSE))
		;
	acquisition_fixture_end ();
}

static void
test_optional_cached_value_is_owned (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	const char *cached;
	char *value = NULL;

	acquisition_fixture_attribute ("in_accel_x_offset", "0.25", FALSE);
	cached = g_udev_device_get_sysfs_attr (device, "in_accel_x_offset");
	acquisition_fixture_read_fault ("in_accel_x_offset", G_FILE_ERROR_IO);
	g_assert_true (read_optional_sysfs_attr (device, "in_accel_x_offset", &value));
	g_assert_nonnull (value);
	g_assert_true (value != cached);
	acquisition_fixture_attribute ("in_accel_x_offset", "7", FALSE);
	g_assert_cmpstr (value, ==, "0.25");
	g_free (value);
	value = NULL;
	g_assert_true (read_optional_sysfs_attr (device, "in_accel_x_offset", &value));
	g_assert_cmpstr (value, ==, "7");
	g_assert_cmpuint (acquisition_fixture_read_count ("in_accel_x_offset"), ==, 0);
	g_free (value);
	acquisition_fixture_end ();
}

static void
test_optional_direct_read_and_absence (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	char *value = NULL;
	gdouble parsed = -99;
	char sentinel[] = "untouched";

	acquisition_fixture_disk_attribute ("in_accel_x_offset", "0.125\n", -1);
	g_assert_true (read_optional_sysfs_attr (device, "in_accel_x_offset", &value));
	g_assert_true (parse_raw_axis (value, &parsed));
	g_assert_cmpfloat (parsed, ==, 0.125);
	g_free (value);
	value = sentinel;
	acquisition_fixture_read_fault ("in_accel_x_offset", G_FILE_ERROR_NOENT);
	/* An error code alone does not prove absence while the entry exists. */
	g_assert_false (read_optional_sysfs_attr (device, "in_accel_x_offset", &value));
	g_assert_true (value == sentinel);
	acquisition_fixture_clear_read_faults ();
	value = NULL;
	acquisition_fixture_disk_attribute ("in_accel_x_offset", NULL, 0);
	g_assert_true (read_optional_sysfs_attr (device, "in_accel_x_offset", &value));
	g_assert_null (value);
	acquisition_fixture_read_fault ("in_accel_x_offset", G_FILE_ERROR_NOENT);
	g_assert_true (read_optional_sysfs_attr (device, "in_accel_x_offset", &value));
	g_assert_null (value);
	g_assert_cmpuint (acquisition_fixture_read_count ("in_accel_x_offset"), ==, 4);
	acquisition_fixture_end ();
}

static void
test_optional_read_errors_preserve_output (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	const int errors[] = { G_FILE_ERROR_ACCES, G_FILE_ERROR_IO, G_FILE_ERROR_ISDIR,
		G_FILE_ERROR_NXIO, G_FILE_ERROR_FAILED, -1 };
	char sentinel[] = "untouched";

	for (guint i = 0; i < G_N_ELEMENTS (errors); i++) {
		char *value = sentinel;
		acquisition_fixture_read_fault ("in_accel_x_offset", errors[i]);
		g_assert_false (read_optional_sysfs_attr (device, "in_accel_x_offset", &value));
		g_assert_true (value == sentinel);
	}
	g_assert_cmpuint (acquisition_fixture_read_count ("in_accel_x_offset"), ==, G_N_ELEMENTS (errors));
	acquisition_fixture_end ();
}

static void
test_optional_nul_dangling_and_gone_path (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	const char invalid[] = { '1', '\0', 'x' };
	char sentinel[] = "untouched";
	char *value = sentinel;

	acquisition_fixture_disk_attribute ("in_accel_x_offset", invalid, sizeof (invalid));
	g_assert_false (read_optional_sysfs_attr (device, "in_accel_x_offset", &value));
	g_assert_true (value == sentinel);
	acquisition_fixture_dangling_attribute ("in_accel_x_offset");
	g_assert_false (read_optional_sysfs_attr (device, "in_accel_x_offset", &value));
	g_assert_true (value == sentinel);
	acquisition_fixture_disk_attribute ("in_accel_x_offset", NULL, 0);
	acquisition_fixture_remove_empty_sysfs_dir ();
	/* NOENT after the device directory vanished is not optional absence.
	 * This bounded parent check is not a removal-atomicity/freshness proof. */
	g_assert_false (read_optional_sysfs_attr (device, "in_accel_x_offset", &value));
	g_assert_true (value == sentinel);
	acquisition_fixture_end ();
}

static void
test_optional_invalid_paths_and_attributes (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	const char *paths[] = { NULL, "", "relative-device" };
	const char *attributes[] = { NULL, "", ".", "..", "../in_accel_x_offset", "x/y", "/in_accel_x_offset" };
	char sentinel[] = "untouched";
	char *value = sentinel;

	for (guint i = 0; i < G_N_ELEMENTS (paths); i++) {
		acquisition_fixture_sysfs_path (paths[i], TRUE);
		g_assert_false (read_optional_sysfs_attr (device, "in_accel_x_offset", &value));
		g_assert_true (value == sentinel);
	}
	acquisition_fixture_sysfs_path (NULL, FALSE);
	for (guint i = 0; i < G_N_ELEMENTS (attributes); i++) {
		g_assert_false (read_optional_sysfs_attr (device, attributes[i], &value));
		g_assert_true (value == sentinel);
	}
	g_assert_cmpuint (acquisition_fixture_read_count ("in_accel_x_offset"), ==, 0);
	acquisition_fixture_end ();
}

static void
test_calibration_read_error_precedence_is_atomic (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	AccelScale scale = { 11, 12, 13 };
	gdouble offset = 0.125;

	acquisition_fixture_attribute ("in_accel_x_scale", "10", FALSE);
	acquisition_fixture_attribute ("in_accel_scale", "1", FALSE);
	acquisition_fixture_read_fault ("in_accel_y_scale", G_FILE_ERROR_IO);
	g_assert_false (get_accel_scale (device, &scale));
	assert_scale (scale, 11, 12, 13);
	acquisition_fixture_clear_read_faults ();
	acquisition_fixture_attribute ("in_accel_x_scale", "2", FALSE);
	acquisition_fixture_attribute ("in_accel_y_scale", "3", FALSE);
	acquisition_fixture_attribute ("in_accel_z_scale", "4", FALSE);
	acquisition_fixture_attribute ("in_accel_scale", NULL, FALSE);
	acquisition_fixture_read_fault ("in_accel_scale", G_FILE_ERROR_IO);
	acquisition_fixture_read_fault ("scale", G_FILE_ERROR_ACCES);
	g_assert_true (get_accel_scale (device, &scale));
	assert_scale (scale, 2, 3, 4);
	g_assert_cmpuint (acquisition_fixture_read_count ("in_accel_scale"), ==, 0);
	g_assert_cmpuint (acquisition_fixture_read_count ("scale"), ==, 0);
	acquisition_fixture_clear_attributes ();
	acquisition_fixture_attribute ("scale", "0.5", FALSE);
	scale = (AccelScale) { 11, 12, 13 };
	g_assert_false (get_accel_scale (device, &scale));
	assert_scale (scale, 11, 12, 13); /* Bad selected common cannot use valid legacy. */
	acquisition_fixture_clear_read_faults ();
	g_assert_true (get_accel_scale (device, &scale));
	assert_scale (scale, 0.5, 0.5, 0.5);
	acquisition_fixture_attribute ("in_accel_x_offset", "0.25", FALSE);
	acquisition_fixture_read_fault ("in_accel_offset", G_FILE_ERROR_IO);
	acquisition_fixture_read_fault ("offset", G_FILE_ERROR_ACCES);
	g_assert_true (read_axis_offset (device, "in_accel_x_offset", &offset));
	g_assert_cmpfloat (offset, ==, 0.25);
	g_assert_cmpuint (acquisition_fixture_read_count ("in_accel_offset"), ==, 0);
	g_assert_cmpuint (acquisition_fixture_read_count ("offset"), ==, 0);
	acquisition_fixture_attribute ("in_accel_x_offset", NULL, FALSE);
	acquisition_fixture_attribute ("offset", "2", FALSE);
	offset = 0.125;
	g_assert_false (read_axis_offset (device, "in_accel_x_offset", &offset));
	g_assert_cmpfloat (offset, ==, 0.125);
	acquisition_fixture_clear_read_faults ();
	acquisition_fixture_attribute ("in_accel_offset", "1", FALSE);
	acquisition_fixture_read_fault ("offset", G_FILE_ERROR_IO);
	g_assert_true (read_axis_offset (device, "in_accel_x_offset", &offset));
	g_assert_cmpfloat (offset, ==, 1);
	acquisition_fixture_end ();
}

static SensorDevice *
open_actual_poll_driver (GUdevDevice *device, PollCapture *capture)
{
	SensorDevice *sensor = driver_open (&iio_poll_accel, device, capture_reading, capture);
	capture->sensor = sensor;
	return sensor;
}

static void
assert_constructor_rejected (GUdevDevice *device, PollCapture *capture, gboolean scale)
{
	g_test_expect_message (NULL, G_LOG_LEVEL_WARNING, scale ?
		"*Invalid accelerometer scale for*" : "*Invalid accelerometer offset for*");
	g_assert_null (open_actual_poll_driver (device, capture));
	g_test_assert_expected_messages ();
	g_assert_cmpuint (capture->count, ==, 0);
	acquisition_fixture_fixup_count (0);
	acquisition_fixture_raw_read_count (0);
	acquisition_fixture_device_refs (1);
}

static void
test_constructor_invalid_offsets_do_not_fixup (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	const struct { const char *attribute, *value; } invalid[] = {
		{ "in_accel_x_offset", "NaN" }, { "in_accel_y_offset", "junk" },
		{ "in_accel_z_offset", "1e9999" }, { "in_accel_offset", "0x1" },
		{ "offset", "1e-9999" }
	};
	PollCapture capture = { 0 };

	for (guint i = 0; i < G_N_ELEMENTS (invalid); i++) {
		acquisition_fixture_clear_attributes ();
		acquisition_fixture_attribute ("in_accel_scale", "1", FALSE);
		if (i < 3) {
			acquisition_fixture_attribute ("in_accel_x_offset", "1", FALSE);
			acquisition_fixture_attribute ("in_accel_y_offset", "2", FALSE);
			acquisition_fixture_attribute ("in_accel_z_offset", "3", FALSE);
			acquisition_fixture_attribute ("in_accel_offset", "4", FALSE);
		} else if (i == 3) {
			acquisition_fixture_attribute ("offset", "5", FALSE);
		}
		acquisition_fixture_attribute (invalid[i].attribute, invalid[i].value, FALSE);
		assert_constructor_rejected (device, &capture, FALSE);
	}
	acquisition_fixture_end ();
}

static void
test_constructor_invalid_scales_do_not_fixup (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	const struct { const char *attribute, *value; } invalid[] = {
		{ "in_accel_x_scale", "NaN" }, { "in_accel_y_scale", "junk" },
		{ "in_accel_z_scale", "0" }, { "in_accel_scale", "Inf" },
		{ "scale", "1e-9999" }
	};
	PollCapture capture = { 0 };

	for (guint i = 0; i < G_N_ELEMENTS (invalid); i++) {
		acquisition_fixture_clear_attributes ();
		if (i < 3)
			acquisition_fixture_attribute ("in_accel_scale", "1", FALSE);
		else if (i == 3)
			acquisition_fixture_attribute ("scale", "1", FALSE);
		acquisition_fixture_attribute (invalid[i].attribute, invalid[i].value, FALSE);
		assert_constructor_rejected (device, &capture, TRUE);
	}
	acquisition_fixture_end ();
}

static void
test_constructor_read_errors_do_not_admit_defaults (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	const char *attributes[] = { "in_accel_x_scale", "in_accel_scale", "scale",
		"in_accel_x_offset", "in_accel_offset", "offset", "in_accel_z_offset" };
	const char nul_value[] = { '1', '\0', 'x' };
	PollCapture capture = { 0 };

	for (guint i = 0; i < G_N_ELEMENTS (attributes); i++) {
		acquisition_fixture_clear_attributes ();
		acquisition_fixture_clear_read_faults ();
		if (i == 0 || i >= 3)
			acquisition_fixture_attribute ("in_accel_scale", "1", FALSE);
		if (i == 1)
			acquisition_fixture_attribute ("scale", "1", FALSE);
		if (i == 3)
			acquisition_fixture_attribute ("in_accel_offset", "1", FALSE);
		if (i == 4)
			acquisition_fixture_attribute ("offset", "2", FALSE);
		if (i == 6) {
			acquisition_fixture_attribute ("in_accel_x_offset", "1", FALSE);
			acquisition_fixture_attribute ("in_accel_y_offset", "2", FALSE);
		}
		acquisition_fixture_read_fault (attributes[i], i == 6 ? -1 : G_FILE_ERROR_IO);
		assert_constructor_rejected (device, &capture, i < 3);
	}
	acquisition_fixture_clear_attributes ();
	acquisition_fixture_clear_read_faults ();
	acquisition_fixture_attribute ("in_accel_scale", "1", FALSE);
	acquisition_fixture_attribute ("in_accel_offset", "2", FALSE);
	acquisition_fixture_disk_attribute ("in_accel_x_offset", nul_value, sizeof (nul_value));
	assert_constructor_rejected (device, &capture, FALSE);
	acquisition_fixture_dangling_attribute ("in_accel_x_offset");
	assert_constructor_rejected (device, &capture, FALSE);
	acquisition_fixture_end ();
}

static void
test_constructor_absent_defaults_and_best_effort_fixup (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	PollCapture capture = { 0 };
	SensorDevice *sensor;
	DrvData *data;
	guint source;

	acquisition_fixture_fixup_result (FALSE);
	sensor = open_actual_poll_driver (device, &capture);
	g_assert_nonnull (sensor);
	data = sensor->priv;
	assert_scale (data->scale, 1, 1, 1);
	g_assert_cmpfloat (data->offset.x, ==, 0);
	g_assert_cmpfloat (data->offset.y, ==, 0);
	g_assert_cmpfloat (data->offset.z, ==, 0);
	acquisition_fixture_fixup_count (1);
	acquisition_fixture_raw_read_count (0);
	g_assert_cmpuint (capture.count, ==, 0);
	acquisition_fixture_attribute ("in_accel_x_raw", "1", TRUE);
	acquisition_fixture_attribute ("in_accel_y_raw", "2", TRUE);
	acquisition_fixture_attribute ("in_accel_z_raw", "3", TRUE);
	driver_set_polling (sensor, TRUE);
	source = data->timeout_id;
	g_assert_nonnull (g_main_context_find_source_by_id (NULL, source));
	g_assert_cmpuint (capture.count, ==, 1);
	g_assert_cmpfloat (capture.last.accel_x, ==, 1);
	g_assert_cmpfloat (capture.last.accel_y, ==, 2);
	g_assert_cmpfloat (capture.last.accel_z, ==, 3);
	assert_scale (capture.last.scale, 1, 1, 1);
	driver_close (sensor);
	g_assert_null (g_main_context_find_source_by_id (NULL, source));
	acquisition_fixture_device_refs (1);
	acquisition_fixture_end ();
}

static void
test_constructor_calibration_before_mount (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	PollCapture capture = { 0 };
	SensorDevice *sensor;
	DrvData *data;
	guint source;

	acquisition_fixture_attribute ("in_accel_x_scale", "2", FALSE);
	acquisition_fixture_attribute ("in_accel_z_scale", "0.5", FALSE);
	acquisition_fixture_disk_attribute ("in_accel_scale", "3\n", -1);
	acquisition_fixture_attribute ("in_accel_x_offset", "0.25", FALSE);
	acquisition_fixture_disk_attribute ("in_accel_y_offset", "-0.5\n", -1);
	acquisition_fixture_attribute ("in_accel_offset", "1.5", FALSE);
	acquisition_fixture_mount_matrix ("0,-1,0;1,0,0;0,0,1");
	acquisition_fixture_attribute ("in_accel_x_raw", "0.125", TRUE);
	acquisition_fixture_attribute ("in_accel_y_raw", "4", TRUE);
	acquisition_fixture_attribute ("in_accel_z_raw", "-3", TRUE);
	sensor = open_actual_poll_driver (device, &capture);
	g_assert_nonnull (sensor);
	data = sensor->priv;
	assert_scale (data->scale, 2, 3, 0.5);
	acquisition_fixture_fixup_count (1);
	acquisition_fixture_raw_read_count (0);
	g_assert_cmpuint (capture.count, ==, 0);
	g_assert_cmpuint (acquisition_fixture_read_count ("in_accel_scale"), ==, 1);
	g_assert_cmpuint (acquisition_fixture_read_count ("in_accel_y_offset"), ==, 1);
	driver_set_polling (sensor, TRUE);
	source = data->timeout_id;
	g_assert_nonnull (g_main_context_find_source_by_id (NULL, source));
	g_assert_cmpuint (capture.count, ==, 1);
	g_assert_cmpfloat (capture.last.accel_x, ==, -10.5);
	g_assert_cmpfloat (capture.last.accel_y, ==, 0.75);
	g_assert_cmpfloat (capture.last.accel_z, ==, -0.75);
	assert_scale (capture.last.scale, 1, 1, 1);
	driver_set_polling (sensor, TRUE);
	g_assert_cmpuint (capture.count, ==, 1);
	acquisition_fixture_raw_read_count (3);
	driver_set_polling (sensor, FALSE);
	g_assert_null (g_main_context_find_source_by_id (NULL, source));
	driver_close (sensor);
	acquisition_fixture_device_refs (1);
	acquisition_fixture_end ();
}

static void
test_constructor_late_rejection_releases_owned_state (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	PollCapture capture = { 0 };

	acquisition_fixture_attribute ("in_accel_scale", "1", FALSE);
	acquisition_fixture_attribute ("in_accel_x_offset", "0.25", FALSE);
	acquisition_fixture_attribute ("in_accel_y_offset", "-0.5", FALSE);
	acquisition_fixture_attribute ("in_accel_z_offset", "malformed", FALSE);
	/* Every attempt reaches the final calibration axis after real name,
	 * private-data, matrix and device-reference acquisition. LSan observes
	 * actual allocation lifetime; the fixup seam is only an ordering oracle. */
	for (guint i = 0; i < 128; i++) {
		acquisition_fixture_name_present (i % 2 == 0);
		assert_constructor_rejected (device, &capture, FALSE);
	}
	acquisition_fixture_end ();
}

void
register_iio_acquisition_poll_tests (void)
{
	g_test_add_func ("/iio-acquisition/poll/raw-finite-decimal-domains", test_raw_finite_decimal_domains);
	g_test_add_func ("/iio-acquisition/poll/raw-invalid-preserves-output", test_raw_invalid_preserves_output);
	g_test_add_func ("/iio-acquisition/poll/offset-precedence-and-raw-units", test_offset_precedence_and_units);
	g_test_add_func ("/iio-acquisition/poll/offset-malformed-no-fallback", test_offset_malformed_never_falls_back);
	g_test_add_func ("/iio-acquisition/poll/mixed-scale-precedence", test_mixed_scale_precedence);
	g_test_add_func ("/iio-acquisition/poll/scaled-before-mount-and-recovery", test_poll_scaled_before_mount_and_recovery);
	g_test_add_func ("/iio-acquisition/poll/optional/cached-owned-copy", test_optional_cached_value_is_owned);
	g_test_add_func ("/iio-acquisition/poll/optional/direct-read-and-absence", test_optional_direct_read_and_absence);
	g_test_add_func ("/iio-acquisition/poll/optional/read-errors-preserve-output", test_optional_read_errors_preserve_output);
	g_test_add_func ("/iio-acquisition/poll/optional/nul-dangling-and-gone-path", test_optional_nul_dangling_and_gone_path);
	g_test_add_func ("/iio-acquisition/poll/optional/invalid-paths-and-attributes", test_optional_invalid_paths_and_attributes);
	g_test_add_func ("/iio-acquisition/poll/calibration-read-error-precedence-atomic", test_calibration_read_error_precedence_is_atomic);
	g_test_add_func ("/iio-acquisition/poll/constructor/invalid-offsets-no-fixup", test_constructor_invalid_offsets_do_not_fixup);
	g_test_add_func ("/iio-acquisition/poll/constructor/invalid-scales-no-fixup", test_constructor_invalid_scales_do_not_fixup);
	g_test_add_func ("/iio-acquisition/poll/constructor/read-errors-no-default-admission", test_constructor_read_errors_do_not_admit_defaults);
	g_test_add_func ("/iio-acquisition/poll/constructor/absent-defaults-best-effort-fixup", test_constructor_absent_defaults_and_best_effort_fixup);
	g_test_add_func ("/iio-acquisition/poll/constructor/calibration-before-mount", test_constructor_calibration_before_mount);
	g_test_add_func ("/iio-acquisition/poll/constructor/late-rejection-owned-cleanup", test_constructor_late_rejection_releases_owned_state);
}
