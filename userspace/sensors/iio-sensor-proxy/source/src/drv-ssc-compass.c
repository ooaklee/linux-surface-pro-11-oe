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
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <gio/gio.h>
#include <libssc-sensor.h>
#include <libssc-sensor-compass.h>

typedef struct DrvData {
	SSCSensorCompass *sensor;
} DrvData;

static gboolean
ssc_compass_discover (GUdevDevice *device)
{
	g_autoptr(SSCSensorCompass) sensor = NULL;

	/* Verify presence of FastRPC device */
	if (!drv_check_udev_sensor_type (device, "ssc-compass", NULL))
		return FALSE;

	/* Open and close SSC compass for discovering */
	sensor = ssc_sensor_compass_new_sync (NULL, NULL);
	if (!sensor)
		return FALSE;

	if (!ssc_sensor_compass_close_sync (sensor, NULL, NULL))
		return FALSE;

	g_debug ("Found SSC compass at %s", g_udev_device_get_sysfs_path (device));
	return TRUE;
}

static void
measurement_cb (SSCSensorCompass *sensor, gfloat azimuth, gpointer user_data)
{
	SensorDevice *sensor_device = user_data;
	CompassReadings readings;

	if (!isfinite (azimuth) || azimuth < 0.0f || azimuth > 360.0f) {
		g_warning ("Ignoring invalid SSC compass measurement");
		return;
	}

	/* A float heading can round up to a full turn. North has one canonical
	 * value; also avoid forwarding negative zero to desktop consumers. */
	readings.heading = azimuth == 360.0f || azimuth == 0.0f ? 0.0 : azimuth;

	sensor_device->callback_func (sensor_device, (gpointer) &readings, sensor_device->user_data);
}

static SensorDevice *
ssc_compass_open (GUdevDevice *device)
{
	g_autoptr(GError) error = NULL;
	SensorDevice *sensor_device;
	DrvData *drv_data;

	sensor_device = g_new0 (SensorDevice, 1);
	sensor_device->priv = g_new0 (DrvData, 1);

	drv_data = (DrvData *) sensor_device->priv;
	drv_data->sensor = ssc_sensor_compass_new_sync (NULL, &error);
	if (!drv_data->sensor) {
		g_warning ("Creating SSC compass sensor failed: %s",
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
ssc_compass_polling_open (SSCSensor *sensor, GError **error)
{
	return ssc_sensor_compass_open_sync (SSC_SENSOR_COMPASS (sensor), NULL, error);
}

static gboolean
ssc_compass_polling_close (SSCSensor *sensor, GError **error)
{
	return ssc_sensor_compass_close_sync (SSC_SENSOR_COMPASS (sensor), NULL, error);
}

static gboolean
ssc_compass_set_polling_full (SensorDevice *sensor_device, gboolean state, GError **error)
{
	DrvData *drv_data = (DrvData *) sensor_device->priv;

	/* The shared helper retains the sensor and owns polling state through
	 * nested dispatch; no driver-private state is accessed after this call. */
	return ssc_driver_set_polling_full (sensor_device, SSC_SENSOR (drv_data->sensor),
	                                    G_CALLBACK (measurement_cb),
	                                    ssc_compass_polling_open,
	                                    ssc_compass_polling_close, state, error);
}

static void
ssc_compass_startup_failed (SensorDevice *sensor_device, const GError *error)
{
	DrvData *drv_data = sensor_device->priv;
	ssc_driver_startup_failed (sensor_device, SSC_SENSOR (drv_data->sensor), error);
}

static void
ssc_compass_set_polling (SensorDevice *sensor_device, gboolean state)
{
	g_autoptr(GError) error = NULL;

	if (!ssc_compass_set_polling_full (sensor_device, state, &error))
		g_warning ("%s SSC compass sensor failed: %s",
		           state ? "Opening" : "Closing",
		           error ? error->message : "unknown error");
}

static void
ssc_compass_close (SensorDevice *sensor_device)
{
	DrvData *drv_data = (DrvData *) sensor_device->priv;

	ssc_driver_polling_detach (SSC_SENSOR (drv_data->sensor));
	g_clear_object (&drv_data->sensor);
	g_clear_pointer (&sensor_device->name, g_free);
	g_clear_pointer (&sensor_device->priv, g_free);
	g_free (sensor_device);
}

SensorDriver ssc_compass = {
	.driver_name = "SSC compass sensor",
	.type = DRIVER_TYPE_COMPASS,

	.discover = ssc_compass_discover,
	.open = ssc_compass_open,
	.set_polling = ssc_compass_set_polling,
	.close = ssc_compass_close,
	.set_polling_full = ssc_compass_set_polling_full,
	.startup_failed = ssc_compass_startup_failed,
};
