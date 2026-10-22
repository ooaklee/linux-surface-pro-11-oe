/*
 * Copyright (c) 2016 Bastien Nocera <hadess@hadess.net>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3 as published by
 * the Free Software Foundation.
 *
 */

#include <glib.h>
#include <stdio.h>
#include <errno.h>
#include <math.h>

#include "accel-mount-matrix.h"

/* The format is the same used in the iio core to export the values:
 * https://git.kernel.org/cgit/linux/kernel/git/torvalds/linux.git/tree/drivers/iio/industrialio-core.c?id=dfc57732ad38f93ae6232a3b4e64fd077383a0f1#n431
 */

static AccelVec3 id_matrix[3] = {
	{ 1.0, 0.0, 0.0 },
	{ 0.0, 1.0, 0.0 },
	{ 0.0, 0.0, 1.0 }
};

static char axis_names[] = "xyz";

AccelVec3 *
get_id_matrix (void)
{
#if GLIB_CHECK_VERSION(2, 68, 0)
	return g_memdup2 (id_matrix, sizeof(id_matrix));
#else
	return g_memdup (id_matrix, sizeof(id_matrix));
#endif
}

AccelVec3 *
setup_mount_matrix (GUdevDevice *device)
{
	AccelVec3 *ret = NULL;
	const char *mount_matrix;

	mount_matrix = g_udev_device_get_property (device, "ACCEL_MOUNT_MATRIX");
	if (mount_matrix) {
		if (parse_mount_matrix (mount_matrix, &ret))
			return ret;

		g_warning ("Failed to parse ACCEL_MOUNT_MATRIX ('%s') from udev",
			   mount_matrix);
		g_clear_pointer (&ret, g_free);
	}

	mount_matrix = g_udev_device_get_sysfs_attr (device, "mount_matrix");
	if (mount_matrix) {
		if (parse_mount_matrix (mount_matrix, &ret))
			return ret;

		g_warning ("Failed to parse mount_matrix ('%s') from sysfs",
			   mount_matrix);
		g_clear_pointer (&ret, g_free);
	}

	/* Some IIO drivers provide multiple sensors via the same sysfs path
	 * and thus they may have different matrices like in a case of
	 * accelerometer and angular velocity for example. The accelerometer
	 * mount matrix is named as in_accel_mount_matrix in that case.
	 *
	 * See https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-bus-iio
	 * for more details. */
	mount_matrix = g_udev_device_get_sysfs_attr (device, "in_accel_mount_matrix");
	if (mount_matrix) {
		if (parse_mount_matrix (mount_matrix, &ret))
			return ret;

		g_warning ("Failed to parse in_accel_mount_matrix ('%s') from sysfs",
			   mount_matrix);
		g_clear_pointer (&ret, g_free);
	}

	/* Linux kernel IIO accelerometer drivers provide mount matrix
	 * via standardized sysfs interface.
	 *
	 * See https://www.kernel.org/doc/Documentation/ABI/testing/sysfs-bus-iio
	 * for more details. */
	mount_matrix = g_udev_device_get_sysfs_attr (device, "in_mount_matrix");
	if (mount_matrix) {
		if (parse_mount_matrix (mount_matrix, &ret))
			return ret;

		g_warning ("Failed to parse in_mount_matrix ('%s') from sysfs",
			   mount_matrix);
		g_clear_pointer (&ret, g_free);
	}

	g_debug ("Failed to auto-detect mount matrix, falling back to identity");
	return get_id_matrix ();
}

static char **
strsplit_num_tokens (const gchar *string,
                     const gchar *delimiter,
                     gint         num_tokens)
{
	g_auto(GStrv) elems = NULL;
	guint i;

	elems = g_strsplit (string, delimiter, num_tokens);
	if (elems == NULL)
		return NULL;
	for (i = 0; i < num_tokens; i++) {
		if (elems[i] == NULL)
			return NULL;
	}
	return g_steal_pointer (&elems);
}

static gboolean
parse_coefficient (const char *text, double *value)
{
	char *end;
	double parsed;
	int parse_errno;

	errno = 0;
	parsed = g_ascii_strtod (text, &end);
	parse_errno = errno;
	if (end == text || !isfinite (parsed) ||
	    (parse_errno == ERANGE && parsed == 0.0))
		return FALSE;
	while (g_ascii_isspace (*end))
		end++;
	if (*end != '\0')
		return FALSE;
	/* A representable nonzero subnormal is valid, even if strtod set ERANGE. */
	*value = parsed;
	return TRUE;
}

gboolean
parse_mount_matrix (const char  *mtx,
		    AccelVec3  **vecs)
{
	AccelVec3 *ret;
	guint i;
	g_auto(GStrv) axis = NULL;

	g_return_val_if_fail (vecs != NULL, FALSE);

	/* Empty string means we use the identity matrix */
	if (mtx == NULL || *mtx == '\0') {
		*vecs = get_id_matrix ();
		return TRUE;
	}

	ret = g_new0 (AccelVec3, 3);
	axis = strsplit_num_tokens (mtx, ";", 3);
	if (!axis) {
		g_free (ret);
		g_warning ("Failed to parse '%s' as a mount matrix", mtx);
		return FALSE;
	}

	for (i = 0; i < G_N_ELEMENTS(id_matrix); i++) {
		g_auto(GStrv) elems = NULL;

		elems = strsplit_num_tokens (axis[i], ",", 3);
		if (elems == NULL) {
			g_free (ret);
			g_warning ("Failed to parse '%s' as a mount matrix", mtx);
			return FALSE;
		}

		if (!parse_coefficient (elems[0], &ret[i].x) ||
		    !parse_coefficient (elems[1], &ret[i].y) ||
		    !parse_coefficient (elems[2], &ret[i].z)) {
			g_free (ret);
			g_warning ("Failed to parse '%s' as a mount matrix", mtx);
			return FALSE;
		}
	}

	for (i = 0; i < G_N_ELEMENTS(id_matrix); i++) {
		if (ret[i].x == 0.0 &&
		    ret[i].y == 0.0 &&
		    ret[i].z == 0.0) {
			g_free (ret);
			g_warning ("In mount matrix '%s', axis %c is all zeroes, which is invalid",
				   mtx, axis_names[i]);
			return FALSE;
		}
	}

	*vecs = ret;

	return TRUE;
}

gboolean
apply_mount_matrix (const AccelVec3  vecs[3],
		    AccelVec3       *accel)
{
	AccelVec3 transformed;

	g_return_val_if_fail (vecs != NULL, FALSE);
	g_return_val_if_fail (accel != NULL, FALSE);

	if (!isfinite (accel->x) || !isfinite (accel->y) || !isfinite (accel->z))
		return FALSE;
	for (guint i = 0; i < 3; i++) {
		if (!isfinite (vecs[i].x) || !isfinite (vecs[i].y) || !isfinite (vecs[i].z))
			return FALSE;
	}
	transformed.x = accel->x * vecs[0].x + accel->y * vecs[0].y + accel->z * vecs[0].z;
	transformed.y = accel->x * vecs[1].x + accel->y * vecs[1].y + accel->z * vecs[1].z;
	transformed.z = accel->x * vecs[2].x + accel->y * vecs[2].y + accel->z * vecs[2].z;
	if (!isfinite (transformed.x) || !isfinite (transformed.y) || !isfinite (transformed.z))
		return FALSE;

	/* No partial update is visible if any input/coefficient/result is invalid. */
	*accel = transformed;

	return TRUE;
}
