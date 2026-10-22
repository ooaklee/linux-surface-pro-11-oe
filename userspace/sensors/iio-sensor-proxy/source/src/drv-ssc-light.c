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
#include <libssc-sensor-light.h>

typedef struct DrvData {
	SSCSensorLight *sensor;
} DrvData;

static gboolean
ssc_light_discover (GUdevDevice *device)
{
	g_autoptr(SSCSensorLight) sensor = NULL;

	/* Verify presence of FastRPC device */
	if (!drv_check_udev_sensor_type (device, "ssc-light", NULL))
		return FALSE;

	/* Open and close SSC light sensor for discovering */
	sensor = ssc_sensor_light_new_sync (NULL, NULL);
	if (!sensor)
		return FALSE;

	if (!ssc_sensor_light_close_sync (sensor, NULL, NULL))
		return FALSE;

	g_debug ("Found SSC light at %s", g_udev_device_get_sysfs_path (device));
	return TRUE;
}

static void
measurement_cb (SSCSensorLight *sensor, gfloat intensity, gpointer user_data)
{
	SensorDevice *sensor_device = user_data;
	LightReadings readings;

	if (!isfinite (intensity) || intensity < 0.0f) {
		g_warning ("Ignoring invalid SSC light measurement");
		return;
	}

	readings.level = intensity;
	readings.uses_lux = TRUE;
	sensor_device->callback_func (sensor_device, (gpointer) &readings, sensor_device->user_data);
}

static SensorDevice *
ssc_light_open (GUdevDevice *device)
{
	g_autoptr(GError) error = NULL;
	SensorDevice *sensor_device;
	DrvData *drv_data;

	sensor_device = g_new0 (SensorDevice, 1);
	sensor_device->priv = g_new0 (DrvData, 1);

	drv_data = (DrvData *) sensor_device->priv;
	drv_data->sensor = ssc_sensor_light_new_sync (NULL, &error);
	if (!drv_data->sensor) {
		g_warning ("Creating SSC light sensor failed: %s",
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
ssc_light_polling_open (SSCSensor *sensor, GError **error)
{
	return ssc_sensor_light_open_sync (SSC_SENSOR_LIGHT (sensor), NULL, error);
}

static gboolean
ssc_light_polling_close (SSCSensor *sensor, GError **error)
{
	return ssc_sensor_light_close_sync (SSC_SENSOR_LIGHT (sensor), NULL, error);
}

static gboolean
ssc_light_set_polling_full (SensorDevice *sensor_device, gboolean state, GError **error)
{
	DrvData *drv_data = (DrvData *) sensor_device->priv;

	/* The shared helper retains the sensor and owns polling state through
	 * nested dispatch; no driver-private state is accessed after this call. */
	return ssc_driver_set_polling_full (sensor_device, SSC_SENSOR (drv_data->sensor),
	                                    G_CALLBACK (measurement_cb),
	                                    ssc_light_polling_open,
	                                    ssc_light_polling_close, state, error);
}

static void
ssc_light_startup_failed (SensorDevice *sensor_device, const GError *error)
{
	DrvData *drv_data = sensor_device->priv;
	ssc_driver_startup_failed (sensor_device, SSC_SENSOR (drv_data->sensor), error);
}

static void
ssc_light_set_polling (SensorDevice *sensor_device, gboolean state)
{
	g_autoptr(GError) error = NULL;

	if (!ssc_light_set_polling_full (sensor_device, state, &error))
		g_warning ("%s SSC light sensor failed: %s",
		           state ? "Opening" : "Closing",
		           error ? error->message : "unknown error");
}

static void
ssc_light_close (SensorDevice *sensor_device)
{
	g_autoptr(GError) error = NULL;
	DrvData *drv_data = (DrvData *) sensor_device->priv;

	ssc_driver_polling_detach (SSC_SENSOR (drv_data->sensor));
	g_clear_object (&drv_data->sensor);
	g_clear_pointer (&sensor_device->priv, g_free);
	g_free (sensor_device);
}

SensorDriver ssc_light = {
	.driver_name = "SSC light sensor",
	.type = DRIVER_TYPE_LIGHT,

	.discover = ssc_light_discover,
	.open = ssc_light_open,
	.set_polling = ssc_light_set_polling,
	.close = ssc_light_close,
	.set_polling_full = ssc_light_set_polling_full,
	.startup_failed = ssc_light_startup_failed,
};
