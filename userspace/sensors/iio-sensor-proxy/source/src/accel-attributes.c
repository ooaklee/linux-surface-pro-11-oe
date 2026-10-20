/*
 * Copyright (c) 2019 Luís Ferreira <luis@aurorafoss.org>
 * Copyright (c) 2019 Daniel Stuart <daniel.stuart@pucpr.edu.br>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3 as published by
 * the Free Software Foundation.
 *
 */

#include "accel-attributes.h"
#include "utils.h"

AccelLocation
setup_accel_location (GUdevDevice *device)
{
	AccelLocation ret;
	const char *location;

	location = g_udev_device_get_property (device, "ACCEL_LOCATION");
	if (location) {
		if (parse_accel_location (location, &ret))
			return ret;

		g_warning ("Failed to parse ACCEL_LOCATION ('%s') from udev",
			   location);
	}
	location = g_udev_device_get_sysfs_attr (device, "label");
	if (location) {
		if (parse_accel_label (location, &ret))
			return ret;
	}
	location = g_udev_device_get_sysfs_attr (device, "location");
	if (location) {
		if (parse_accel_location (location, &ret))
			return ret;

		g_warning ("Failed to parse location ('%s') from sysfs",
			   location);
	}
	g_debug ("No auto-detected location, falling back to display location");

	ret = ACCEL_LOCATION_DISPLAY;
	return ret;
}

gboolean
parse_accel_label (const char *location, AccelLocation *value)
{
	if (location == NULL ||
	    *location == '\0')
		return FALSE;
	if (g_str_equal (location, "accel-base")) {
		*value = ACCEL_LOCATION_BASE;
		return TRUE;
	} else if (g_str_equal (location, "accel-display")) {
		*value = ACCEL_LOCATION_DISPLAY;
		return TRUE;
	}
	g_debug ("Failed to parse label '%s' as a location", location);
	return FALSE;
}

gboolean
parse_accel_location (const char *location, AccelLocation *value)
{
	/* Empty string means we use the display location */
	if (location == NULL ||
	    *location == '\0' ||
	    g_str_equal (location, "display") ||
	    g_str_equal (location, "lid")) {
		*value = ACCEL_LOCATION_DISPLAY;
		return TRUE;
	} else if (g_str_equal (location, "base")) {
		*value = ACCEL_LOCATION_BASE;
		return TRUE;
	} else {
		g_warning ("Failed to parse '%s' as a location", location);
		return FALSE;
	}
}

gboolean
get_accel_scale (GUdevDevice *device,
		 AccelScale  *scale_vec)
{
	gdouble scale = 1.0;
	const char *attributes[] = { "in_accel_x_scale", "in_accel_y_scale", "in_accel_z_scale" };
	g_autofree char *x_text = NULL, *y_text = NULL, *z_text = NULL;
	char **slots[] = { &x_text, &y_text, &z_text };
	const char *text[3];
	g_autofree char *uniform = NULL;
	AccelScale candidate;
	gdouble values[3];
	gboolean any_axis;

	g_return_val_if_fail (scale_vec != NULL, FALSE);

	for (guint i = 0; i < G_N_ELEMENTS (attributes); i++) {
		if (!read_optional_sysfs_attr (device, attributes[i], slots[i]))
			return FALSE;
		text[i] = *slots[i];
	}
	any_axis = text[0] || text[1] || text[2];
	/* An axis-specific attribute overrides only that axis. Resolve missing
	 * axes via the common metadata rather than discarding valid calibration
	 * from a partially axis-specific device. Never hide an explicit bad value. */
	if (!text[0] || !text[1] || !text[2]) {
		if (!read_optional_sysfs_attr (device, "in_accel_scale", &uniform))
			return FALSE;
		if (!uniform && !read_optional_sysfs_attr (device, "scale", &uniform))
			return FALSE;
		if (uniform && !parse_accel_scale (uniform, &scale))
			return FALSE;
	}
	for (guint i = 0; i < G_N_ELEMENTS (attributes); i++) {
		values[i] = scale;
		if (text[i] && !parse_accel_scale (text[i], &values[i]))
			return FALSE;
	}
	candidate = (AccelScale) { values[0], values[1], values[2] };
	*scale_vec = candidate;
	if (any_axis)
		g_debug ("Attribute in_accel_{x,y,z}_scale (%f,%f,%f) found in sysfs",
			 scale_vec->x, scale_vec->y, scale_vec->z);
	else if (uniform)
		g_debug ("Attribute uniform accelerometer scale ('%f') found in sysfs", scale);
	else
		g_debug ("Failed to auto-detect scale, falling back to 1.0");
	return TRUE;
}

const char *
accel_location_to_string (AccelLocation location)
{
	switch (location) {
	case ACCEL_LOCATION_DISPLAY:
		return "display";
	case ACCEL_LOCATION_BASE:
		return "base";
	default:
		g_assert_not_reached ();
	}
}
