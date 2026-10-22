/*
 * Copyright (c) 2023-2025 Dylan Van Assche
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3 as published by
 * the Free Software Foundation.
 */

#include "drivers.h"
#include "drv-ssc-polling.h"

#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <gio/gio.h>
#include <libssc-sensor.h>
#include <libssc-sensor-proximity.h>

typedef struct DrvData {
	SSCSensorProximity *sensor;
} DrvData;

static gboolean
ssc_proximity_discover (GUdevDevice *device)
{
	SSCSensorProximity *sensor = NULL;

	/* Verify presence of FastRPC device */
	if (!drv_check_udev_sensor_type (device, "ssc-proximity", NULL))
		return FALSE;

	/* Open and close SSC proximity sensor for discovering */
	sensor = ssc_sensor_proximity_new_sync (NULL, NULL);
	if (!sensor)
		return FALSE;

	if (!ssc_sensor_proximity_close_sync (sensor, NULL, NULL)) {
		g_clear_object (&sensor);
		return FALSE;
	}

	g_clear_object (&sensor);

	g_debug ("Found SSC proximity at %s", g_udev_device_get_sysfs_path (device));
	return TRUE;
}

static void
measurement_cb (SSCSensorProximity *sensor, gboolean near, gpointer user_data)
{
	SensorDevice *sensor_device = user_data;
	ProximityReadings readings;

	readings.is_near = near ? PROXIMITY_NEAR_TRUE : PROXIMITY_NEAR_FALSE;
	sensor_device->callback_func (sensor_device, (gpointer) &readings, sensor_device->user_data);
}

static SensorDevice *
ssc_proximity_open (GUdevDevice *device)
{
	g_autoptr(GError) error = NULL;
	SensorDevice *sensor_device;
	DrvData *drv_data;

	sensor_device = g_new0 (SensorDevice, 1);
	sensor_device->priv = g_new0 (DrvData, 1);
	drv_data = (DrvData *) sensor_device->priv;
	drv_data->sensor = ssc_sensor_proximity_new_sync (NULL, &error);
	if (!drv_data->sensor) {
		g_warning ("Creating SSC proximity sensor failed: %s",
		           error ? error->message : "unknown error");
		g_free (drv_data);
		g_free (sensor_device);
		return NULL;
	}
	g_object_get (drv_data->sensor,
	              SSC_SENSOR_NAME, &sensor_device->name,
	              NULL);

	return sensor_device;
}

static gboolean
ssc_proximity_polling_open (SSCSensor *sensor, GError **error)
{
	return ssc_sensor_proximity_open_sync (SSC_SENSOR_PROXIMITY (sensor), NULL, error);
}

static gboolean
ssc_proximity_polling_close (SSCSensor *sensor, GError **error)
{
	return ssc_sensor_proximity_close_sync (SSC_SENSOR_PROXIMITY (sensor), NULL, error);
}

static gboolean
ssc_proximity_set_polling_full (SensorDevice *sensor_device, gboolean state, GError **error)
{
	DrvData *drv_data = (DrvData *) sensor_device->priv;

	/* The shared helper retains the sensor and owns polling state through
	 * nested dispatch; no driver-private state is accessed after this call. */
	return ssc_driver_set_polling_full (sensor_device, SSC_SENSOR (drv_data->sensor),
	                                    G_CALLBACK (measurement_cb),
	                                    ssc_proximity_polling_open,
	                                    ssc_proximity_polling_close, state, error);
}

static void
ssc_proximity_startup_failed (SensorDevice *sensor_device, const GError *error)
{
	DrvData *drv_data = sensor_device->priv;
	ssc_driver_startup_failed (sensor_device, SSC_SENSOR (drv_data->sensor), error);
}

static void
ssc_proximity_set_polling (SensorDevice *sensor_device, gboolean state)
{
	g_autoptr(GError) error = NULL;

	if (!ssc_proximity_set_polling_full (sensor_device, state, &error))
		g_warning ("%s SSC proximity sensor failed: %s",
		           state ? "Opening" : "Closing",
		           error ? error->message : "unknown error");
}

static void
ssc_proximity_close (SensorDevice *sensor_device)
{
	DrvData *drv_data = (DrvData *) sensor_device->priv;

	ssc_driver_polling_detach (SSC_SENSOR (drv_data->sensor));
	g_clear_object (&drv_data->sensor);
	g_clear_pointer (&sensor_device->priv, g_free);
	g_free (sensor_device);
}

SensorDriver ssc_proximity = {
	.driver_name = "SSC proximity sensor",
	.type = DRIVER_TYPE_PROXIMITY,

	.discover = ssc_proximity_discover,
	.open = ssc_proximity_open,
	.set_polling = ssc_proximity_set_polling,
	.close = ssc_proximity_close,
	.set_polling_full = ssc_proximity_set_polling_full,
	.startup_failed = ssc_proximity_startup_failed,
};
