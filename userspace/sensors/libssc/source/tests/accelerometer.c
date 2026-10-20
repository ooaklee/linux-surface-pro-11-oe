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
#include "libssc-sensor-accelerometer.h"

#define TIMEOUT 2

typedef struct {
	SSCSensor *sensor;
	GArray *measurements;
	GMainLoop *loop;
} SensorData;

typedef struct {
	gfloat x;
	gfloat y;
	gfloat z;
} XYZMeasurement;

static gboolean
accelerometer_close_cb (SensorData *data)
{
	SSCSensorAccelerometer *self = SSC_SENSOR_ACCELEROMETER (data->sensor);
	GArray *measurements = data->measurements;
	GMainLoop *loop = data->loop;
	g_autoptr (GError) error = NULL;

	/* Close sensor */
	g_assert_true (ssc_sensor_accelerometer_close_sync (self, NULL, &error));

	/* Check measurements */
	g_assert_cmpint (measurements->len, >=, 8);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 0).x, ==, 0.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 0).y, ==, 0.0);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 0).z, -9.81, 0.001);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 1).x, ==, 2.5);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 1).y, ==, 1.5);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 1).z, ==, 0.0);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 2).x, ==, -2.5);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 2).y, ==, -1.5);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 2).z, ==, 0.0);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 3).x, ==, 0.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 3).y, ==, 0.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 3).z, ==, 0.0);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 4).x, ==, 0.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 4).y, ==, 0.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 4).z, ==, 0.0);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 5).x, ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 5).y, ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 5).z, ==, 1.0);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 6).x, ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 6).z, ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 6).y, ==, 1.0);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 7).x, ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 7).y, ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 7).z, ==, 1.0);

	g_main_loop_quit (loop);

	return G_SOURCE_REMOVE;
}

static void
accelerometer_measurement (SSCSensorAccelerometer *sensor, gfloat accel_x, gfloat accel_y, gfloat accel_z, gpointer user_data)
{
	GArray *measurements = user_data;
	XYZMeasurement measurement;

	g_test_message("Acceleration: X%f Y%f Z%f", accel_x, accel_y, accel_z);
	measurement.x = accel_x;
	measurement.y = accel_y;
	measurement.z = accel_z;

	/* Collect measurement */
	g_array_append_val (measurements, measurement);
}

static void
test_libssc_sensor_accelerometer(void)
{
	g_autoptr (GError) error = NULL;
	GArray *measurements = g_array_new (FALSE, FALSE, sizeof (XYZMeasurement));
	GMainLoop *loop = g_main_loop_new (NULL, FALSE);
	SensorData data;

	/* Test information */
	g_test_summary ("Test `accelerometer sensor operations`");

	/* Create sensor */
	SSCSensorAccelerometer *sensor = ssc_sensor_accelerometer_new_sync (NULL, &error);

	/* Connect measurement signal */
	g_signal_connect (sensor, "measurement", G_CALLBACK (accelerometer_measurement), measurements);

	/* Wait until all mocking measurements are received */
	data.sensor = SSC_SENSOR (sensor);
	data.measurements = measurements;
	data.loop = loop;
	g_timeout_add_seconds (TIMEOUT, (GSourceFunc)accelerometer_close_cb, &data);

	/* Open sensor */
	g_assert_true (ssc_sensor_accelerometer_open_sync (sensor, NULL, &error));

	/* Run main loop to process signals and timers */
	g_main_loop_run (loop);
}

static void
test_libssc_sensor_accelerometer_probe_sync (void)
{
	g_autoptr (GError) error = NULL;

	/* Test information */
	g_test_summary ("Test `probing accelerometer sensor with open_sync and close_sync`");

	/* Create sensor */
	SSCSensorAccelerometer *sensor = ssc_sensor_accelerometer_new_sync (NULL, &error);

	/* Open sensor */
	g_assert_true (ssc_sensor_accelerometer_open_sync (sensor, NULL, &error));

	/* Close sensor */
	g_assert_true (ssc_sensor_accelerometer_close_sync (sensor, NULL, &error));
}

static gboolean
accelerometer_mount_matrix_close_cb (SensorData *data)
{
	SSCSensorAccelerometer *self = SSC_SENSOR_ACCELEROMETER (data->sensor);
	GArray *measurements = data->measurements;
	GMainLoop *loop = data->loop;
	g_autoptr (GError) error = NULL;

	/* Close sensor */
	g_assert_true (ssc_sensor_accelerometer_close_sync (self, NULL, &error));

	/* Check measurements */
	g_assert_cmpint (measurements->len, >=, 8);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 0).x, ==, 0.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 0).y, ==, 0.0);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 0).z, -9.81, 0.001);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 1).x, ==, 2.5);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 1).y, ==, 1.5);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 1).z, ==, 0.0);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 2).x, ==, -2.5);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 2).y, ==, -1.5);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 2).z, ==, 0.0);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 3).x, ==, 0.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 3).y, ==, 0.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 3).z, ==, 0.0);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 4).x, ==, 0.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 4).y, ==, 0.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 4).z, ==, 0.0);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 5).x, ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 5).y, ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 5).z, ==, 1.0);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 6).x, ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 6).z, ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 6).y, ==, 1.0);

	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 7).x, ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 7).y, ==, 1.0);
	g_assert_cmpfloat (g_array_index (measurements, XYZMeasurement, 7).z, ==, 1.0);

	g_main_loop_quit (loop);

	return G_SOURCE_REMOVE;
}

static void
accelerometer_mount_matrix_measurement (SSCSensorAccelerometer *sensor, gfloat accel_x, gfloat accel_y, gfloat accel_z, gpointer user_data)
{
	GArray *measurements = user_data;
	XYZMeasurement measurement;

	g_test_message("Acceleration: X%f Y%f Z%f", accel_x, accel_y, accel_z);
	measurement.x = accel_x;
	measurement.y = accel_y;
	measurement.z = accel_z;

	/* Collect measurement */
	g_array_append_val (measurements, measurement);
}

static void
test_libssc_sensor_accelerometer_mount_matrix (void)
{
	g_autoptr (GError) error = NULL;
	GArray *measurements = g_array_new (FALSE, FALSE, sizeof (XYZMeasurement));
	GMainLoop *loop = g_main_loop_new (NULL, FALSE);
	SensorData data;

	/* Test information */
	g_test_summary ("Test `accelerometer sensor operations with mount matrix`");

	/* Create sensor */
	SSCSensorAccelerometer *sensor = ssc_sensor_accelerometer_new_sync (NULL, &error);

	/* Connect measurement signal */
	g_signal_connect (sensor, "measurement", G_CALLBACK (accelerometer_mount_matrix_measurement), measurements);

	/* Wait until all mocking measurements are received */
	data.sensor = SSC_SENSOR (sensor);
	data.measurements = measurements;
	data.loop = loop;
	g_timeout_add_seconds (TIMEOUT, (GSourceFunc)accelerometer_mount_matrix_close_cb, &data);

	/* Open sensor */
	g_assert_true (ssc_sensor_accelerometer_open_sync (sensor, NULL, &error));

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
	g_test_add_func("/libssc/sensor/accelerometer/measurements", test_libssc_sensor_accelerometer);
	g_test_add_func("/libssc/sensor/accelerometer/probe-sync", test_libssc_sensor_accelerometer_probe_sync);
	g_test_add_func("/libssc/sensor/accelerometer/mount-matrix", test_libssc_sensor_accelerometer_mount_matrix);

	/* Execute tests */
	return g_test_run();
}
