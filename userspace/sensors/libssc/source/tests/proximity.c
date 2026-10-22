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
#include "libssc-sensor-proximity.h"

#define TIMEOUT 2

typedef struct {
	SSCSensor *sensor;
	GArray *measurements;
	GMainLoop *loop;
} SensorData;

static gboolean
proximity_close_cb (SensorData *data)
{
	SSCSensorProximity *self = SSC_SENSOR_PROXIMITY (data->sensor);
	GArray *measurements = data->measurements;
	GMainLoop *loop = data->loop;
	g_autoptr (GError) error = NULL;

	/* Close sensor */
	g_assert_true (ssc_sensor_proximity_close_sync (self, NULL, &error));

	/* 
	 * Check measurements: proximity sensor measurements which are
	 * the same as the previous value are skipped by libssc
	 */
	g_assert_cmpint (measurements->len, >=, 8);
	g_assert_true (g_array_index (measurements, gboolean, 0) == FALSE);
	g_assert_true (g_array_index (measurements, gboolean, 1) == TRUE);
	g_assert_true (g_array_index (measurements, gboolean, 2) == FALSE);
	g_assert_true (g_array_index (measurements, gboolean, 3) == TRUE);
	g_assert_true (g_array_index (measurements, gboolean, 4) == FALSE);
	g_assert_true (g_array_index (measurements, gboolean, 5) == TRUE);
	g_assert_true (g_array_index (measurements, gboolean, 6) == FALSE);
	g_assert_true (g_array_index (measurements, gboolean, 7) == TRUE);

	g_main_loop_quit (loop);

	return G_SOURCE_REMOVE;
}

static void
proximity_measurement (SSCSensorProximity *sensor, gboolean near, gpointer user_data)
{
	GArray *measurements = user_data;

	g_test_message("NEAR: %d", near);

	/* Collect measurement */
	g_array_append_val (measurements, near);
}

static void
test_libssc_sensor_proximity(void)
{
	g_autoptr (GError) error = NULL;
	GArray *measurements = g_array_new (FALSE, FALSE, sizeof (gboolean));
	GMainLoop *loop = g_main_loop_new (NULL, FALSE);
	SensorData data;

	/* Test information */
	g_test_summary ("Test `proximity sensor operations`");

	/* Create sensor */
	SSCSensorProximity *sensor = ssc_sensor_proximity_new_sync (NULL, &error);

	/* Connect measurement signal */
	g_signal_connect (sensor, "measurement", G_CALLBACK (proximity_measurement), measurements);

	/* Wait until all mocking measurements are received */
	data.sensor = SSC_SENSOR (sensor);
	data.measurements = measurements;
	data.loop = loop;
	g_timeout_add_seconds (TIMEOUT, (GSourceFunc)proximity_close_cb, &data);

	/* Open sensor */
	g_assert_true (ssc_sensor_proximity_open_sync (sensor, NULL, &error));

	/* Run main loop to process signals and timers */
	g_main_loop_run (loop);
}

static void
test_libssc_sensor_proximity_probe_sync (void)
{
	g_autoptr (GError) error = NULL;

	/* Test information */
	g_test_summary ("Test `probing proximity sensor with open_sync and close_sync`");

	/* Create sensor */
	SSCSensorProximity *sensor = ssc_sensor_proximity_new_sync (NULL, &error);

	/* Open sensor */
	g_assert_true (ssc_sensor_proximity_open_sync (sensor, NULL, &error));

	/* Close sensor */
	g_assert_true (ssc_sensor_proximity_close_sync (sensor, NULL, &error));
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
	g_test_add_func("/libssc/sensor/proximity/measurements", test_libssc_sensor_proximity);
	g_test_add_func("/libssc/sensor/proximity/probe-sync", test_libssc_sensor_proximity_probe_sync);

	/* Execute tests */
	return g_test_run();
}
