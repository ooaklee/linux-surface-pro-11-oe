/*
 * libssc: Library to expose Qualcomm Sensor Core sensors
 * Copyright (C) 2022-2026 Dylan Van Assche
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include <glib.h>
#include <locale.h>
#include "libssc-client-private.h"
#include "libssc-sensor.h"
#include "libssc-sensor-compass.h"

#define TIMEOUT 2

typedef struct {
	SSCSensor *sensor;
	GArray *measurements;
	GMainLoop *loop;
} SensorData;

static gboolean
compass_close_cb (SensorData *data)
{
	SSCSensorCompass *self = SSC_SENSOR_COMPASS (data->sensor);
	GArray *measurements = data->measurements;
	GMainLoop *loop = data->loop;
	g_autoptr (GError) error = NULL;

	/* Close sensor */
	g_assert_true (ssc_sensor_compass_close_sync (self, NULL, &error));

	/* Check measurements */
	g_assert_cmpint (measurements->len, >=, 8);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, gfloat, 0), 226.468811, 0.1);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, gfloat, 1), 113.62372, 0.1);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, gfloat, 2), 0.0, 0.1);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, gfloat, 3), 226.468811, 0.1);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, gfloat, 4), 226.468811, 0.1);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, gfloat, 5), 226.468811, 0.1);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, gfloat, 6), 226.468811, 0.1);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, gfloat, 7), 226.468811, 0.1);

	g_main_loop_quit (loop);

	return G_SOURCE_REMOVE;
}

static void
compass_measurement (SSCSensorCompass *sensor, gfloat heading, gpointer user_data)
{
	GArray *measurements = user_data;

	g_test_message("Compass: %f degrees", heading);

	/* Collect measurement */
	g_array_append_val (measurements, heading);
}

static void
test_libssc_sensor_compass(void)
{
	g_autoptr (GError) error = NULL;
	GArray *measurements = g_array_new (FALSE, FALSE, sizeof (gfloat));
	GMainLoop *loop = g_main_loop_new (NULL, FALSE);
	SensorData data;

	/* Test information */
	g_test_summary ("Test `compass sensor operations`");

	/* Create sensor */
	SSCSensorCompass *sensor = ssc_sensor_compass_new_sync (NULL, &error);

	/* Connect measurement signal */
	g_signal_connect (sensor, "measurement", G_CALLBACK (compass_measurement), measurements);

	/* Wait until all mocking measurements are received */
	data.sensor = SSC_SENSOR (sensor);
	data.measurements = measurements;
	data.loop = loop;
	g_timeout_add_seconds (TIMEOUT, (GSourceFunc)compass_close_cb, &data);

	/* Open sensor */
	g_assert_true (ssc_sensor_compass_open_sync (sensor, NULL, &error));

	/* Run main loop to process signals and timers */
	g_main_loop_run (loop);
}

static void
test_libssc_sensor_compass_probe_sync (void)
{
	g_autoptr (GError) error = NULL;

	/* Test information */
	g_test_summary ("Test `probing compass sensor with open_sync and close_sync`");

	/* Create sensor */
	SSCSensorCompass *sensor = ssc_sensor_compass_new_sync (NULL, &error);

	/* Open sensor */
	g_assert_true (ssc_sensor_compass_open_sync (sensor, NULL, &error));

	/* Close sensor */
	g_assert_true (ssc_sensor_compass_close_sync (sensor, NULL, &error));
}

int main (int argc, char *argv[])
{
	GLogLevelFlags mask;

	setlocale (LC_ALL, "");

	/* Initialize test framework */
	g_test_init (&argc, &argv, NULL);

	/* Allow warnings */
	mask = (GLogLevelFlags) g_log_set_always_fatal ((GLogLevelFlags) G_LOG_FATAL_MASK);
	mask = (GLogLevelFlags) (mask & (~G_LOG_LEVEL_WARNING));
	g_log_set_always_fatal ((GLogLevelFlags) mask);

	/* Tests */
	g_test_add_func("/libssc/sensor/compass/measurements", test_libssc_sensor_compass);
	g_test_add_func("/libssc/sensor/compass/probe-sync", test_libssc_sensor_compass_probe_sync);

	/* Execute tests */
	return g_test_run();
}
