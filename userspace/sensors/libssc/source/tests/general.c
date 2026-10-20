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
#include "libssc-sensor-light.h"
#include "libssc-sensor-accelerometer.h"
#include "libssc-sensor-magnetometer.h"
#include "libssc-sensor-compass.h"

#define TIMEOUT 2

typedef struct {
	SSCSensor *sensor;
	GArray *measurements;
	GMainLoop *loop;
} SensorData;

static void
sensor_unavailable_open_ready (SSCSensor *self, GAsyncResult *result, gpointer user_data)
{
	GError *error = NULL;
	GMainLoop *loop = user_data;
	gboolean success = FALSE;

	success = ssc_sensor_open_finish (self, result, &error);
	g_assert_false (success);

	g_main_loop_quit (loop);
}

static void
sensor_unavailable_ready (SSCClient *self, GAsyncResult *result, gpointer user_data)
{
	GError *error = NULL;
	SSCSensor *sensor = NULL;

	sensor = ssc_sensor_new_finish (result, &error);
	g_assert_no_error (error);
	ssc_sensor_open (sensor, NULL, (GAsyncReadyCallback) sensor_unavailable_open_ready, user_data);
}

static void
test_libssc_sensor_unavailable (void)
{
	GMainLoop *loop = g_main_loop_new (NULL, FALSE);

	/* Create a sensor which is unavailable according to attribute */
	ssc_sensor_new ("unavailable", NULL, (GAsyncReadyCallback) sensor_unavailable_ready, loop);

	/* Run main loop to process signals and timers */
	g_main_loop_run (loop);
}

static void
sensor_unsupported_ready (SSCClient *self, GAsyncResult *result, gpointer user_data)
{
	GMainLoop *loop = user_data;
	GError *error = NULL;
	SSCSensor *sensor = NULL;

	sensor = ssc_sensor_new_finish (result, &error);
	g_assert_true (sensor == NULL);

	g_main_loop_quit (loop);
}

static void
test_libssc_sensor_unsupported (void)
{
	GMainLoop *loop = g_main_loop_new (NULL, FALSE);

	/* Discover a sensor which is unsupported by DSP */
	ssc_sensor_new ("unsupported", NULL, (GAsyncReadyCallback) sensor_unsupported_ready, loop);

	/* Run main loop to process signals and timers */
	g_main_loop_run (loop);
}

static void
sensor_no_sample_rate_open_ready (SSCSensor *self, GAsyncResult *result, gpointer user_data)
{
	GError *error = NULL;
	GMainLoop *loop = user_data;
	gboolean success = FALSE;

	success = ssc_sensor_open_finish (self, result, &error);
	g_assert_false (success);

	g_main_loop_quit (loop);
}

static void
sensor_no_sample_rate_ready (SSCClient *self, GAsyncResult *result, gpointer user_data)
{
	GError *error = NULL;
	SSCSensor *sensor = NULL;

	sensor = ssc_sensor_new_finish (result, &error);
	g_assert_no_error (error);
	ssc_sensor_open (sensor, NULL, (GAsyncReadyCallback) sensor_no_sample_rate_open_ready, user_data);
}

static void
test_libssc_sensor_no_sample_rate (void)
{
	GMainLoop *loop = g_main_loop_new (NULL, FALSE);

	/* Discover a sensor in continuous mode with missing required sample rate */
	ssc_sensor_new ("no-sample-rate", NULL, (GAsyncReadyCallback) sensor_no_sample_rate_ready, loop);

	/* Run main loop to process signals and timers */
	g_main_loop_run (loop);
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
	g_test_add_func("/libssc/sensor/unsupported", test_libssc_sensor_unsupported);
	g_test_add_func("/libssc/sensor/unavailable", test_libssc_sensor_unavailable);
	g_test_add_func("/libssc/sensor/no-sample-rate", test_libssc_sensor_no_sample_rate);

	/* Execute tests */
	return g_test_run();
}
