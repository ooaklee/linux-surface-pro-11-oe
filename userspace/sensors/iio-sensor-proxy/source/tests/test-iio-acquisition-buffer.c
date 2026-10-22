/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Actual buffer driver, isolated TU. Only its external device/buffer effects
 * are fixtures; discover/open/direct-close and metadata/name ownership run. */
#include "../src/drv-iio-buffer-accel.c"

GUdevDevice *acquisition_fixture_begin (void);
void acquisition_fixture_end (void);
void acquisition_fixture_name_present (gboolean present);
void acquisition_fixture_buffer_usable (gboolean usable);
void acquisition_fixture_buffer_enable_succeeds (gboolean succeeds);
void acquisition_fixture_buffer_counts (guint created, guint enabled, guint disabled, guint probed);
void register_iio_acquisition_buffer_tests (void);

static void
test_buffer_discovery_direct_close (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();

	for (guint i = 0; i < 128; i++) {
		gboolean usable = i % 2 == 0;

		acquisition_fixture_name_present (i % 4 < 2);
		acquisition_fixture_buffer_usable (usable);
		g_assert_cmpint (iio_buffer_accel_discover (device), ==, usable);
	}
	/* open disables once, discovery enables then disables before direct close. */
	acquisition_fixture_buffer_counts (128, 128, 256, 128);
	acquisition_fixture_end ();
}

static void
test_buffer_direct_close (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();

	for (guint i = 0; i < 128; i++) {
		SensorDevice *sensor;

		acquisition_fixture_name_present (i % 2 == 0);
		sensor = iio_buffer_accel_open (device);
		g_assert_nonnull (sensor);
		g_assert_cmpstr (sensor->name, ==, i % 2 == 0 ?
		                "fixture allocated sensor name" : "fixture-name-fallback");
		iio_buffer_accel_close (sensor);
	}
	acquisition_fixture_buffer_counts (128, 0, 128, 0);
	acquisition_fixture_end ();
}

static gboolean
unexpected_buffer_timer (gpointer data)
{
	(void) data;
	g_assert_not_reached ();
	return G_SOURCE_REMOVE;
}

static void
test_buffer_enable_failure (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	SensorDevice *sensor;
	DrvData *data;

	acquisition_fixture_buffer_enable_succeeds (FALSE);
	/* Failed discovery must not probe the device or retain an allocation. */
	g_assert_false (iio_buffer_accel_discover (device));
	acquisition_fixture_buffer_counts (1, 1, 2, 0);
	sensor = iio_buffer_accel_open (device);
	g_assert_nonnull (sensor);
	data = sensor->priv;
	iio_buffer_accel_set_polling (sensor, TRUE);
	g_assert_cmpuint (data->timeout_id, ==, 0);
	iio_buffer_accel_close (sensor);
	acquisition_fixture_buffer_counts (2, 2, 3, 0);
	/* A later enable succeeds through the actual discover/open/close flow. */
	acquisition_fixture_buffer_enable_succeeds (TRUE);
	g_assert_true (iio_buffer_accel_discover (device));
	acquisition_fixture_buffer_counts (3, 3, 5, 1);
	acquisition_fixture_end ();
}

static void
test_buffer_close_stops_owned_timer (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	SensorDevice *sensor = iio_buffer_accel_open (device);
	DrvData *data;
	guint id;

	g_assert_nonnull (sensor);
	data = sensor->priv;
	g_assert_true (enable_ring_buffer (data->buffer_data));
	data->timeout_id = id = g_timeout_add (1, unexpected_buffer_timer, sensor);
	g_assert_nonnull (g_main_context_find_source_by_id (NULL, id));
	iio_buffer_accel_close (sensor);
	g_assert_null (g_main_context_find_source_by_id (NULL, id));
	while (g_main_context_iteration (NULL, FALSE))
		;
	acquisition_fixture_buffer_counts (1, 1, 2, 0);
	acquisition_fixture_end ();
}

void
register_iio_acquisition_buffer_tests (void)
{
	g_test_add_func ("/iio-acquisition/buffer/discovery-direct-close-owned-name", test_buffer_discovery_direct_close);
	g_test_add_func ("/iio-acquisition/buffer/direct-close-owned-name", test_buffer_direct_close);
	g_test_add_func ("/iio-acquisition/buffer/enable-failure-cleans-up-and-retries", test_buffer_enable_failure);
	g_test_add_func ("/iio-acquisition/buffer/direct-close-stops-owned-timer", test_buffer_close_stops_owned_timer);
}
