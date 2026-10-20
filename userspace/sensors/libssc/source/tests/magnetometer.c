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
#include "libssc-sensor-magnetometer.h"

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
magnetometer_close_cb (SensorData *data)
{
	SSCSensorMagnetometer *self = SSC_SENSOR_MAGNETOMETER (data->sensor);
	GArray *measurements = data->measurements;
	GMainLoop *loop = data->loop;
	g_autoptr (GError) error = NULL;

	/* Close sensor */
	g_assert_true (ssc_sensor_magnetometer_close_sync (self, NULL, &error));

	/* Check measurements */
	g_assert_cmpint (measurements->len, >=, 8);

	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 0).x, 0.1, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 0).y, 0.2, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 0).z, 0.3, 0.01);

	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 1).x, 0.3, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 1).y, 0.2, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 1).z, 0.1, 0.01);

	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 2).x, 0.3, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 2).y, 0.2, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 2).z, 0.1, 0.01);

	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 3).x, 0.0, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 3).y, 0.0, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 3).z, 0.0, 0.01);

	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 4).x, 0.0, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 4).y, 0.0, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 4).z, 0.0, 0.01);

	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 5).x, 1.0, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 5).y, 1.0, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 5).z, 1.0, 0.01);

	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 6).x, 1.0, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 6).y, 1.0, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 6).z, 1.0, 0.01);

	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 7).x, 1.0, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 7).y, 1.0, 0.01);
	g_assert_cmpfloat_with_epsilon (g_array_index (measurements, XYZMeasurement, 7).z, 1.0, 0.01);

	g_main_loop_quit (loop);

	return G_SOURCE_REMOVE;
}

static void
magnetometer_measurement (SSCSensorMagnetometer *sensor, gfloat magn_x, gfloat magn_y, gfloat magn_z, gpointer user_data)
{
	GArray *measurements = user_data;
	XYZMeasurement measurement;

	g_test_message("Magnetic field: X%f Y%f Z%f", magn_x, magn_y, magn_z);
	measurement.x = magn_x;
	measurement.y = magn_y;
	measurement.z = magn_z;

	/* Collect measurement */
	g_array_append_val (measurements, measurement);
}

static void
test_libssc_sensor_magnetometer(void)
{
	g_autoptr (GError) error = NULL;
	GArray *measurements = g_array_new (FALSE, FALSE, sizeof (XYZMeasurement));
	GMainLoop *loop = g_main_loop_new (NULL, FALSE);
	SensorData data;

	/* Test information */
	g_test_summary ("Test `magnetometer sensor operations`");

	/* Create sensor */
	SSCSensorMagnetometer *sensor = ssc_sensor_magnetometer_new_sync (NULL, &error);

	/* Connect measurement signal */
	g_signal_connect (sensor, "measurement", G_CALLBACK (magnetometer_measurement), measurements);

	data.sensor = SSC_SENSOR (sensor);
	data.measurements = measurements;
	data.loop = loop;
	g_timeout_add_seconds (TIMEOUT, (GSourceFunc)magnetometer_close_cb, &data);

	/* Open sensor */
	g_assert_true (ssc_sensor_magnetometer_open_sync (sensor, NULL, &error));

	/* Run main loop to process signals and timers */
	g_main_loop_run (loop);
}

static void
test_libssc_sensor_magnetometer_probe_sync (void)
{
	g_autoptr (GError) error = NULL;

	/* Test information */
	g_test_summary ("Test `probing magnetometer sensor with open_sync and close_sync`");

	/* Create sensor */
	SSCSensorMagnetometer *sensor = ssc_sensor_magnetometer_new_sync (NULL, &error);

	/* Open sensor */
	g_assert_true (ssc_sensor_magnetometer_open_sync (sensor, NULL, &error));

	/* Close sensor */
	g_assert_true (ssc_sensor_magnetometer_close_sync (sensor, NULL, &error));
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
	g_test_add_func("/libssc/sensor/magnetometer/measurements", test_libssc_sensor_magnetometer);
	g_test_add_func("/libssc/sensor/magnetometer/probe-sync", test_libssc_sensor_magnetometer_probe_sync);

	/* Execute tests */
	return g_test_run();
}
