/*
 * Copyright (c) 2021 Bastien Nocera <hadess@hadess.net>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3 as published by
 * the Free Software Foundation.
 *
 */

#include "utils.h"

#include <errno.h>
#include <glib/gstdio.h>
#include <string.h>

char *
get_device_file (GUdevDevice *device)
{
	if (!IS_TEST)
		return g_strdup (g_udev_device_get_device_file (device));

	return g_build_filename (g_getenv ("UMOCKDEV_DIR"),
				 "iio-dev-data.bin",
				 NULL);
}

gboolean
read_optional_sysfs_attr (GUdevDevice *device,
                          const char  *attribute,
                          char       **value)
{
	const char *cached, *device_path;
	g_autofree char *path = NULL;
	g_autofree char *contents = NULL;
	g_autoptr(GError) error = NULL;
	gsize length = 0;

	g_return_val_if_fail (device != NULL, FALSE);
	g_return_val_if_fail (value != NULL, FALSE);
	/* All callers select a single constant attribute, never a relative path. */
	if (!attribute || !*attribute || strchr (attribute, G_DIR_SEPARATOR) ||
	    g_str_equal (attribute, ".") || g_str_equal (attribute, ".."))
		return FALSE;

	cached = g_udev_device_get_sysfs_attr (device, attribute);
	if (cached) {
		*value = g_strdup (cached);
		return TRUE;
	}

	/* GUdev's NULL alone cannot distinguish missing metadata from a read
	 * error. Retry with an error-bearing read rather than defaulting scale
	 * or offset after an inaccessible, higher-priority attribute. */
	device_path = g_udev_device_get_sysfs_path (device);
	if (!device_path || !*device_path || !g_path_is_absolute (device_path))
		return FALSE;
	path = g_build_filename (device_path, attribute, NULL);
	if (!g_file_get_contents (path, &contents, &length, &error)) {
		GStatBuf info;

		/* A missing device directory must not look like optional metadata.
		 * A dangling attribute symlink also is not absent metadata. Check
		 * the entry itself, not exists(), which follows that broken link.
		 * These fail-closed checks are not an atomic hot-unplug guarantee. */
		if (g_error_matches (error, G_FILE_ERROR, G_FILE_ERROR_NOENT) &&
		    g_lstat (path, &info) < 0 && errno == ENOENT &&
		    g_file_test (device_path, G_FILE_TEST_IS_DIR)) {
			*value = NULL;
			return TRUE;
		}
		g_debug ("Could not read optional attribute '%s': %s", path,
			 error ? error->message : "read failed without an error");
		return FALSE;
	}
	/* Numeric parsers consume strings; never accept a valid prefix of a
	 * length-bearing file that contains embedded NUL bytes. */
	if (!contents || memchr (contents, '\0', length))
		return FALSE;
	*value = g_steal_pointer (&contents);
	return TRUE;
}
