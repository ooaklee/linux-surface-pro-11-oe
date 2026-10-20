/*
 * Copyright (c) 2014 Bastien Nocera <hadess@hadess.net>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3 as published by
 * the Free Software Foundation.
 */

#include "drivers.h"
#include "iio-buffer-utils.h"
#include "accel-mount-matrix.h"
#include "utils.h"

#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

typedef struct DrvData {
	guint               timeout_id;
	GUdevDevice        *dev;
	AccelVec3          *mount_matrix;
	AccelLocation       location;
	AccelScale          scale;
	AccelVec3           offset;
} DrvData;

/* IIO read_raw results pass through iio_format_value(), which can publish
 * fractional decimal formats as well as integers. Preserve finite scalar
 * values instead of using the GUdev integer getter or inventing zero on
 * parse failure. Values beyond double precision round normally; exact
 * preservation of every 64-bit integer is not claimed. */
static gboolean
parse_raw_axis (const char *text, gdouble *value)
{
	const char *start;
	char *end;
	gdouble parsed;

	if (!text)
		return FALSE;
	start = text;
	while (g_ascii_isspace (*start))
		start++;
	if (*start == '-' || *start == '+')
		start++;
	if (start[0] == '0' && (start[1] == 'x' || start[1] == 'X'))
		return FALSE;
	errno = 0;
	parsed = g_ascii_strtod (text, &end);
	if (end == text || !isfinite (parsed) || (errno == ERANGE && parsed == 0.0))
		return FALSE;
	while (g_ascii_isspace (*end))
		end++;
	if (*end != '\0')
		return FALSE;
	*value = parsed;
	return TRUE;
}

static gboolean
read_axis_offset (GUdevDevice *device, const char *attribute, gdouble *offset)
{
	const char *attributes[] = { attribute, "in_accel_offset", "offset" };

	for (guint i = 0; i < G_N_ELEMENTS (attributes); i++) {
		g_autofree char *text = NULL;

		if (!read_optional_sysfs_attr (device, attributes[i], &text))
			return FALSE;
		if (text)
			return parse_raw_axis (text, offset);
	}
	*offset = 0.0;
	return TRUE;
}

static gboolean
poll_orientation (gpointer user_data)
{
	SensorDevice *sensor_device = user_data;
	DrvData *drv_data = (DrvData *) sensor_device->priv;
	gdouble accel_x, accel_y, accel_z;
	AccelReadings readings;
	AccelVec3 tmp;

	if (!parse_raw_axis (g_udev_device_get_sysfs_attr_uncached (drv_data->dev, "in_accel_x_raw"), &accel_x) ||
	    !parse_raw_axis (g_udev_device_get_sysfs_attr_uncached (drv_data->dev, "in_accel_y_raw"), &accel_y) ||
	    !parse_raw_axis (g_udev_device_get_sysfs_attr_uncached (drv_data->dev, "in_accel_z_raw"), &accel_z)) {
		g_debug ("Ignoring accelerometer reading with invalid raw axis");
		return G_SOURCE_CONTINUE;
	}

	g_debug ("Accel read from IIO on '%s': %g, %g, %g (scale %lf,%lf,%lf)", sensor_device->name,
		 accel_x, accel_y, accel_z,
		 drv_data->scale.x, drv_data->scale.y, drv_data->scale.z);

	/* IIO ABI: (raw + offset) * scale in the sensor frame, then the mount
	 * transform into the display frame. Anisotropic scales cannot be moved
	 * after a rotation, so publish the resulting SI vector with unity scale. */
	tmp.x = (accel_x + drv_data->offset.x) * drv_data->scale.x;
	tmp.y = (accel_y + drv_data->offset.y) * drv_data->scale.y;
	tmp.z = (accel_z + drv_data->offset.z) * drv_data->scale.z;

	if (!apply_mount_matrix (drv_data->mount_matrix, &tmp)) {
		g_warning ("Could not apply mount matrix");
		return G_SOURCE_CONTINUE;
	}

	//FIXME report errors
	readings.accel_x = tmp.x;
	readings.accel_y = tmp.y;
	readings.accel_z = tmp.z;
	reset_accel_scale (&readings.scale);

	sensor_device->callback_func (sensor_device, (gpointer) &readings, sensor_device->user_data);

	return G_SOURCE_CONTINUE;
}

static gboolean
iio_poll_accel_discover (GUdevDevice *device)
{
	if (!drv_check_udev_sensor_type (device, "iio-poll-accel", NULL))
		return FALSE;

	g_debug ("Found IIO poll accelerometer at %s", g_udev_device_get_sysfs_path (device));
	return TRUE;
}

static void
iio_poll_accel_set_polling (SensorDevice *sensor_device,
			    gboolean state)
{
	DrvData *drv_data = (DrvData *) sensor_device->priv;

	if (drv_data->timeout_id > 0 && state)
		return;
	if (drv_data->timeout_id == 0 && !state)
		return;

	if (drv_data->timeout_id) {
		g_source_remove (drv_data->timeout_id);
		drv_data->timeout_id = 0;
	}

	if (state) {
		drv_data->timeout_id = g_timeout_add (700, poll_orientation, sensor_device);
		g_source_set_name_by_id (drv_data->timeout_id, "[iio_poll_accel_set_polling] poll_orientation");

		poll_orientation (sensor_device);
	}
}

static SensorDevice *
iio_poll_accel_open (GUdevDevice *device)
{

	SensorDevice *sensor_device;
	DrvData *drv_data;

	sensor_device = g_new0 (SensorDevice, 1);
	sensor_device->name = g_strdup (g_udev_device_get_property (device, "NAME"));
	if (!sensor_device->name)
		sensor_device->name = g_strdup (g_udev_device_get_name (device));
	sensor_device->priv = g_new0 (DrvData, 1);
	drv_data = (DrvData *) sensor_device->priv;
	drv_data->dev = g_object_ref (device);
	drv_data->mount_matrix = setup_mount_matrix (device);
	drv_data->location = setup_accel_location (device);
	if (!get_accel_scale (device, &drv_data->scale)) {
		g_warning ("Invalid accelerometer scale for '%s'", sensor_device->name);
		goto invalid_metadata;
	}
	if (!read_axis_offset (device, "in_accel_x_offset", &drv_data->offset.x) ||
	    !read_axis_offset (device, "in_accel_y_offset", &drv_data->offset.y) ||
	    !read_axis_offset (device, "in_accel_z_offset", &drv_data->offset.z)) {
		g_warning ("Invalid accelerometer offset for '%s'", sensor_device->name);
		goto invalid_metadata;
	}

	/* Do not mutate sampling policy for a device we will reject. Retain the
	 * existing best-effort fixup semantics once calibration is accepted. */
	iio_fixup_sampling_frequency (device);

	return sensor_device;

invalid_metadata:
	g_clear_object (&drv_data->dev);
	g_clear_pointer (&drv_data->mount_matrix, g_free);
	g_clear_pointer (&sensor_device->name, g_free);
	g_clear_pointer (&sensor_device->priv, g_free);
	g_free (sensor_device);
	return NULL;
}

static void
iio_poll_accel_close (SensorDevice *sensor_device)
{
	DrvData *drv_data = (DrvData *) sensor_device->priv;

	/* Generic driver_close already stops polling. Also make the driver's
	 * own close safe for a direct owner releasing an active timer. */
	iio_poll_accel_set_polling (sensor_device, FALSE);
	g_clear_object (&drv_data->dev);
	g_clear_pointer (&drv_data->mount_matrix, g_free);
	g_clear_pointer (&sensor_device->priv, g_free);
	g_clear_pointer (&sensor_device->name, g_free);
	g_free (sensor_device);
}

SensorDriver iio_poll_accel = {
	.driver_name = "IIO Poll accelerometer",
	.type = DRIVER_TYPE_ACCEL,

	.discover = iio_poll_accel_discover,
	.open = iio_poll_accel_open,
	.set_polling = iio_poll_accel_set_polling,
	.close = iio_poll_accel_close,
};
