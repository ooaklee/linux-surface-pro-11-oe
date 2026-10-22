/*
 * Copyright (c) 2023-2025 Dylan Van Assche
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3 as published by
 * the Free Software Foundation.
 */

#include "drivers.h"
#include "drv-ssc-polling.h"
#include "accel-mount-matrix.h"

#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <gio/gio.h>
#include <libssc-sensor.h>
#include <libssc-sensor-accelerometer.h>

typedef struct DrvData {
	SSCSensorAccelerometer *sensor;
	AccelVec3 *mount_matrix;
	AccelLocation location;
	AccelScale scale;
} DrvData;

static gboolean
ssc_accelerometer_discover (GUdevDevice *device)
{
	g_autoptr(SSCSensorAccelerometer) sensor = NULL;

	/* Verify presence of FastRPC device */
	if (!drv_check_udev_sensor_type (device, "ssc-accel", NULL))
		return FALSE;

	/* Open and close SSC accelerometer for discovering */
	sensor = ssc_sensor_accelerometer_new_sync (NULL, NULL);
	if (!sensor)
		return FALSE;

	if (!ssc_sensor_accelerometer_close_sync (sensor, NULL, NULL))
		return FALSE;

	g_debug ("Found SSC accelerometer at %s", g_udev_device_get_sysfs_path (device));
	return TRUE;
}

static void
measurement_cb (SSCSensorAccelerometer *sensor, gfloat accel_x, gfloat accel_y, gfloat accel_z, gpointer user_data)
{
	SensorDevice *sensor_device = user_data;
	DrvData *drv_data = (DrvData *) sensor_device->priv;
	AccelReadings readings;
	AccelVec3 tmp;

	tmp.x = accel_x;
	tmp.y = accel_y;
	tmp.z = accel_z;

	if (!apply_mount_matrix (drv_data->mount_matrix, &tmp)) {
		g_warning ("Could not apply mount matrix");
		return;
	}

	readings.accel_x = tmp.x;
	readings.accel_y = tmp.y;
	readings.accel_z = tmp.z;
	copy_accel_scale (&readings.scale, drv_data->scale);

	sensor_device->callback_func (sensor_device, (gpointer) &readings, sensor_device->user_data);
}

static SensorDevice *
ssc_accelerometer_open (GUdevDevice *device)
{
	g_autoptr(GError) error = NULL;
	SensorDevice *sensor_device;
	DrvData *drv_data;

	sensor_device = g_new0 (SensorDevice, 1);
	sensor_device->priv = g_new0 (DrvData, 1);

	drv_data = (DrvData *) sensor_device->priv;
	drv_data->sensor = ssc_sensor_accelerometer_new_sync (NULL, &error);
	if (!drv_data->sensor) {
		g_warning ("Creating SSC accelerometer sensor failed: %s",
		           error ? error->message : "unknown error");
		g_free (drv_data);
		g_free (sensor_device);
		return NULL;
	}
	g_object_get (drv_data->sensor,
	              SSC_SENSOR_NAME, &sensor_device->name,
	              NULL);

	/* Setup accel attributes */
	drv_data->mount_matrix = setup_mount_matrix (device);
	drv_data->location = setup_accel_location (device);
	set_accel_scale (&drv_data->scale, 1.0);

	return sensor_device;
}

static gboolean
ssc_accelerometer_polling_open (SSCSensor *sensor, GError **error)
{
	return ssc_sensor_accelerometer_open_sync (SSC_SENSOR_ACCELEROMETER (sensor), NULL, error);
}

static gboolean
ssc_accelerometer_polling_close (SSCSensor *sensor, GError **error)
{
	return ssc_sensor_accelerometer_close_sync (SSC_SENSOR_ACCELEROMETER (sensor), NULL, error);
}

static gboolean
ssc_accelerometer_set_polling_full (SensorDevice *sensor_device, gboolean state, GError **error)
{
	DrvData *drv_data = (DrvData *) sensor_device->priv;

	/* The shared helper retains the sensor and owns polling state through
	 * nested dispatch; no driver-private state is accessed after this call. */
	return ssc_driver_set_polling_full (sensor_device, SSC_SENSOR (drv_data->sensor),
	                                    G_CALLBACK (measurement_cb),
	                                    ssc_accelerometer_polling_open,
	                                    ssc_accelerometer_polling_close, state, error);
}

static void
ssc_accelerometer_startup_failed (SensorDevice *sensor_device, const GError *error)
{
	DrvData *drv_data = sensor_device->priv;
	ssc_driver_startup_failed (sensor_device, SSC_SENSOR (drv_data->sensor), error);
}

static void
ssc_accelerometer_set_polling (SensorDevice *sensor_device, gboolean state)
{
	g_autoptr(GError) error = NULL;

	if (!ssc_accelerometer_set_polling_full (sensor_device, state, &error))
		g_warning ("%s SSC accelerometer sensor failed: %s",
		           state ? "Opening" : "Closing",
		           error ? error->message : "unknown error");
}

static void
ssc_accelerometer_close (SensorDevice *sensor_device)
{
	g_autoptr(GError) error = NULL;
	DrvData *drv_data = (DrvData *) sensor_device->priv;

	ssc_driver_polling_detach (SSC_SENSOR (drv_data->sensor));
	g_clear_object (&drv_data->sensor);
	g_clear_pointer (&drv_data->mount_matrix, g_free);
	g_clear_pointer (&sensor_device->priv, g_free);
	g_free (sensor_device);
}

SensorDriver ssc_accel = {
	.driver_name = "SSC accelerometer sensor",
	.type = DRIVER_TYPE_ACCEL,

	.discover = ssc_accelerometer_discover,
	.open = ssc_accelerometer_open,
	.set_polling = ssc_accelerometer_set_polling,
	.close = ssc_accelerometer_close,
	.set_polling_full = ssc_accelerometer_set_polling_full,
	.startup_failed = ssc_accelerometer_startup_failed,
};
