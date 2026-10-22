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
#include "libssc-sensor-light.h"

#define TIMEOUT 2

typedef struct {
	SSCSensor *sensor;
	GArray *measurements;
	GMainLoop *loop;
} SensorData;

static gboolean
light_close_cb (SensorData *data)
{
	SSCSensorLight *self = SSC_SENSOR_LIGHT (data->sensor);
	GArray *measurements = data->measurements;
	GMainLoop *loop = data->loop;
	g_autoptr (GError) error = NULL;

	/* Close sensor */
	g_assert_true (ssc_sensor_light_close_sync (self, NULL, &error));

	/* Check measurements */
	g_assert_cmpint (measurements->len, >=, 8);
	g_assert_cmpfloat (g_array_index (measurements, gfloat, 0), ==, 5.0);
	g_assert_cmpfloat (g_array_index (measurements, gfloat, 1), ==, 7.0);
	g_assert_cmpfloat (g_array_index (measurements, gfloat, 2), ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, gfloat, 3), ==, 0.0);
	g_assert_cmpfloat (g_array_index (measurements, gfloat, 4), ==, 5.0);
	g_assert_cmpfloat (g_array_index (measurements, gfloat, 5), ==, 5.0);
	g_assert_cmpfloat (g_array_index (measurements, gfloat, 6), ==, 5.0);
	g_assert_cmpfloat (g_array_index (measurements, gfloat, 7), ==, 5.0);

	g_main_loop_quit (loop);

	return G_SOURCE_REMOVE;
}

static void
light_measurement (SSCSensorLight *sensor, gfloat intensity, gpointer user_data)
{
	GArray *measurements = user_data;

	g_test_message("Intensity: %f Lux", intensity);

	/* Collect measurement */
	g_array_append_val (measurements, intensity);
}

static void
test_libssc_sensor_light(void)
{
	g_autoptr (GError) error = NULL;
	GArray *measurements = g_array_new (FALSE, FALSE, sizeof (gfloat));
	GMainLoop *loop = g_main_loop_new (NULL, FALSE);
	SensorData data;

	/* Test information */
	g_test_summary ("Test `light sensor operations`");

	/* Create sensor */
	SSCSensorLight *sensor = ssc_sensor_light_new_sync (NULL, &error);

	/* Connect measurement signal */
	g_signal_connect (sensor, "measurement", G_CALLBACK (light_measurement), measurements);

	/* Wait until all mocking measurements are received */
	data.sensor = SSC_SENSOR (sensor);
	data.measurements = measurements;
	data.loop = loop;
	g_timeout_add_seconds (TIMEOUT, (GSourceFunc)light_close_cb, &data);

	/* Open sensor */
	g_assert_true (ssc_sensor_light_open_sync (sensor, NULL, &error));

	/* Run main loop to process signals and timers */
	g_main_loop_run (loop);
}

static void
test_libssc_sensor_light_probe_sync (void)
{
	g_autoptr (GError) error = NULL;

	/* Test information */
	g_test_summary ("Test `probing light sensor with open_sync and close_sync`");

	/* Create sensor */
	SSCSensorLight *sensor = ssc_sensor_light_new_sync (NULL, &error);

	/* Open sensor */
	g_assert_true (ssc_sensor_light_open_sync (sensor, NULL, &error));

	/* Close sensor */
	g_assert_true (ssc_sensor_light_close_sync (sensor, NULL, &error));
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
	g_test_add_func("/libssc/sensor/light/measurements", test_libssc_sensor_light);
	g_test_add_func("/libssc/sensor/light/probe-sync", test_libssc_sensor_light_probe_sync);

	/* Execute tests */
	return g_test_run();
}
