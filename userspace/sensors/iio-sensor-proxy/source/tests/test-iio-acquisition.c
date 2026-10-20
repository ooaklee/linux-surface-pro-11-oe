/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Noninstalled fixture: no udev discovery, device I/O or DSP activity.
 * A plain, real GObject is a lifetime stand-in, NOT a native GUdevDevice.
 * Every GUdev query used here is wrapped and rejects a foreign pointer.
 * Actual driver code, metadata parsing and object ref/unref remain real. */
#include "drivers.h"
#include "iio-buffer-utils.h"
#include <glib/gstdio.h>
#include <string.h>
#include <unistd.h>

void register_iio_acquisition_input_tests (void);
void register_iio_acquisition_poll_tests (void);
void register_iio_acquisition_buffer_tests (void);
GUdevDevice *acquisition_fixture_begin (void);
void acquisition_fixture_end (void);
void acquisition_fixture_attribute (const char *name, const char *value, gboolean uncached);
void acquisition_fixture_clear_attributes (void);
void acquisition_fixture_name_present (gboolean present);
void acquisition_fixture_buffer_usable (gboolean usable);
void acquisition_fixture_buffer_enable_succeeds (gboolean succeeds);
void acquisition_fixture_buffer_counts (guint created, guint enabled, guint disabled, guint probed);
void acquisition_fixture_disk_attribute (const char *name, const char *value, gssize length);
void acquisition_fixture_dangling_attribute (const char *name);
void acquisition_fixture_read_fault (const char *name, int file_error);
void acquisition_fixture_clear_read_faults (void);
guint acquisition_fixture_read_count (const char *name);
void acquisition_fixture_sysfs_path (const char *path, gboolean overridden);
void acquisition_fixture_remove_empty_sysfs_dir (void);
void acquisition_fixture_mount_matrix (const char *matrix);
void acquisition_fixture_fixup_result (gboolean result);
void acquisition_fixture_fixup_count (guint expected);
void acquisition_fixture_raw_read_count (guint expected);
void acquisition_fixture_device_refs (guint expected);

const gchar *__wrap_g_udev_device_get_property (GUdevDevice *, const gchar *);
const gchar *__wrap_g_udev_device_get_name (GUdevDevice *);
const gchar *__wrap_g_udev_device_get_sysfs_path (GUdevDevice *);
const gchar *__wrap_g_udev_device_get_device_file (GUdevDevice *);
const gchar *__wrap_g_udev_device_get_sysfs_attr (GUdevDevice *, const gchar *);
const gchar *__wrap_g_udev_device_get_sysfs_attr_uncached (GUdevDevice *, const gchar *);
BufferDrvData *__wrap_buffer_drv_data_new (GUdevDevice *);
void __wrap_buffer_drv_data_free (BufferDrvData *);
gboolean __wrap_enable_ring_buffer (BufferDrvData *);
void __wrap_disable_ring_buffer (BufferDrvData *);
gboolean __wrap_is_buffer_usable (char *);
gboolean __wrap_g_file_get_contents (const gchar *, gchar **, gsize *, GError **);
gboolean __real_g_file_get_contents (const gchar *, gchar **, gsize *, GError **);
gboolean __wrap_iio_fixup_sampling_frequency (GUdevDevice *);

static GUdevDevice *fixture_device;
static GHashTable *cached_attributes, *uncached_attributes;
static BufferDrvData *fixture_buffer;
static gboolean name_present, buffer_usable, buffer_enabled, buffer_enable_succeeds;
static guint finalized, created_count, freed_count, enabled_count, disabled_count, probed_count;
static char *sysfs_directory, *reported_path, *fixture_matrix;
static GHashTable *disk_attributes, *read_faults, *read_counts;
static gboolean path_overridden, directory_removed, fixup_succeeds;
static guint fixup_count, raw_read_count;

static void
object_finalized (gpointer data, GObject *object)
{
	(void) data;
	(void) object;
	finalized++;
}

static void
require_device (GUdevDevice *device)
{
	g_assert_nonnull (fixture_device);
	g_assert_true (device == fixture_device);
}

static void
require_attribute (const char *name)
{
	const char *allowed[] = {
		"in_accel_x_raw", "in_accel_y_raw", "in_accel_z_raw",
		"in_accel_x_offset", "in_accel_y_offset", "in_accel_z_offset",
		"in_accel_offset", "offset", "in_accel_x_scale", "in_accel_y_scale",
		"in_accel_z_scale", "in_accel_scale", "scale", "label", "location",
		"mount_matrix", "in_accel_mount_matrix", "in_mount_matrix", NULL
	};
	g_assert_true (g_strv_contains (allowed, name));
}

GUdevDevice *
acquisition_fixture_begin (void)
{
	g_assert_null (fixture_device);
	g_assert_null (fixture_buffer);
	g_assert_null (sysfs_directory);
	g_assert_null (g_getenv ("UMOCKDEV_DIR"));
	sysfs_directory = g_dir_make_tmp ("iio-acquisition-calibration-XXXXXX", NULL);
	g_assert_nonnull (sysfs_directory);
	disk_attributes = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
	read_faults = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
	read_counts = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
	path_overridden = directory_removed = FALSE;
	fixup_succeeds = TRUE;
	fixup_count = raw_read_count = 0;
	fixture_matrix = g_strdup ("1,0,0;0,1,0;0,0,1");
	fixture_device = (GUdevDevice *) g_object_new (G_TYPE_OBJECT, NULL);
	g_object_weak_ref (G_OBJECT (fixture_device), object_finalized, NULL);
	cached_attributes = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
	uncached_attributes = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, g_free);
	name_present = buffer_usable = TRUE;
	buffer_enable_succeeds = TRUE;
	buffer_enabled = FALSE;
	finalized = created_count = freed_count = enabled_count = disabled_count = probed_count = 0;
	return fixture_device;
}

void
acquisition_fixture_end (void)
{
	GHashTableIter iter;
	gpointer key;

	g_assert_null (fixture_buffer);
	g_assert_false (buffer_enabled);
	g_assert_cmpuint (created_count, ==, freed_count);
	g_clear_object (&fixture_device);
	g_assert_cmpuint (finalized, ==, 1);
	g_clear_pointer (&cached_attributes, g_hash_table_unref);
	g_clear_pointer (&uncached_attributes, g_hash_table_unref);
	/* Only exact, whitelisted attributes registered by this test are removed.
	 * No recursive cleanup, external directory or hardware path is involved. */
	g_hash_table_iter_init (&iter, disk_attributes);
	while (g_hash_table_iter_next (&iter, &key, NULL)) {
		g_autofree char *path = g_build_filename (sysfs_directory, key, NULL);
		require_attribute (key);
		g_assert_cmpint (g_unlink (path), ==, 0);
	}
	if (!directory_removed)
		g_assert_cmpint (g_rmdir (sysfs_directory), ==, 0);
	g_clear_pointer (&disk_attributes, g_hash_table_unref);
	g_clear_pointer (&read_faults, g_hash_table_unref);
	g_clear_pointer (&read_counts, g_hash_table_unref);
	g_clear_pointer (&sysfs_directory, g_free);
	g_clear_pointer (&reported_path, g_free);
	g_clear_pointer (&fixture_matrix, g_free);
}

void
acquisition_fixture_attribute (const char *name, const char *value, gboolean uncached)
{
	GHashTable *attributes = uncached ? uncached_attributes : cached_attributes;
	g_assert_nonnull (fixture_device);
	require_attribute (name);
	if (value)
		g_hash_table_replace (attributes, g_strdup (name), g_strdup (value));
	else
		g_hash_table_remove (attributes, name);
}

void
acquisition_fixture_clear_attributes (void)
{
	g_hash_table_remove_all (cached_attributes);
	g_hash_table_remove_all (uncached_attributes);
}

void acquisition_fixture_name_present (gboolean present) { name_present = present; }
void acquisition_fixture_buffer_usable (gboolean usable) { buffer_usable = usable; }
void acquisition_fixture_buffer_enable_succeeds (gboolean succeeds) { buffer_enable_succeeds = succeeds; }

void
acquisition_fixture_disk_attribute (const char *name, const char *value, gssize length)
{
	g_autofree char *path = NULL;
	g_assert_nonnull (fixture_device);
	g_assert_false (directory_removed);
	require_attribute (name);
	path = g_build_filename (sysfs_directory, name, NULL);
	if (value) {
		g_assert_true (g_file_set_contents (path, value, length, NULL));
		g_hash_table_add (disk_attributes, g_strdup (name));
	} else if (g_hash_table_contains (disk_attributes, name)) {
		g_assert_cmpint (g_unlink (path), ==, 0);
		g_hash_table_remove (disk_attributes, name);
	}
}

void
acquisition_fixture_dangling_attribute (const char *name)
{
	g_autofree char *path = NULL;
	g_assert_nonnull (fixture_device);
	g_assert_false (directory_removed);
	require_attribute (name);
	path = g_build_filename (sysfs_directory, name, NULL);
	if (g_hash_table_contains (disk_attributes, name))
		g_assert_cmpint (g_unlink (path), ==, 0);
	/* Relative target stays inside the owned directory and is never created. */
	g_assert_cmpint (symlink ("missing-owned-target", path), ==, 0);
	g_hash_table_add (disk_attributes, g_strdup (name));
}

void
acquisition_fixture_read_fault (const char *name, int file_error)
{
	require_attribute (name);
	/* -1 means FALSE without GError; other values are actual G_FILE_ERROR
	 * codes. Encode both distinctly from a missing hash-table entry. */
	g_assert_cmpint (file_error, >=, -1);
	g_hash_table_replace (read_faults, g_strdup (name), GINT_TO_POINTER (file_error + 2));
}

void acquisition_fixture_clear_read_faults (void) { g_hash_table_remove_all (read_faults); }
guint acquisition_fixture_read_count (const char *name)
{ require_attribute (name); return GPOINTER_TO_UINT (g_hash_table_lookup (read_counts, name)); }
void acquisition_fixture_mount_matrix (const char *matrix)
{ g_free (fixture_matrix); fixture_matrix = g_strdup (matrix); }
void acquisition_fixture_fixup_result (gboolean result) { fixup_succeeds = result; }
void acquisition_fixture_fixup_count (guint expected) { g_assert_cmpuint (fixup_count, ==, expected); }
void acquisition_fixture_raw_read_count (guint expected) { g_assert_cmpuint (raw_read_count, ==, expected); }
void acquisition_fixture_device_refs (guint expected)
{ require_device (fixture_device); g_assert_cmpuint (G_OBJECT (fixture_device)->ref_count, ==, expected); }

void
acquisition_fixture_sysfs_path (const char *path, gboolean overridden)
{
	g_assert_nonnull (fixture_device);
	g_free (reported_path);
	reported_path = g_strdup (path);
	path_overridden = overridden;
}

void
acquisition_fixture_remove_empty_sysfs_dir (void)
{
	g_assert_nonnull (fixture_device);
	g_assert_cmpuint (g_hash_table_size (disk_attributes), ==, 0);
	g_assert_false (directory_removed);
	g_assert_cmpint (g_rmdir (sysfs_directory), ==, 0);
	directory_removed = TRUE;
}

void
acquisition_fixture_buffer_counts (guint created, guint enabled, guint disabled, guint probed)
{
	g_assert_cmpuint (created_count, ==, created);
	g_assert_cmpuint (freed_count, ==, created);
	g_assert_cmpuint (enabled_count, ==, enabled);
	g_assert_cmpuint (disabled_count, ==, disabled);
	g_assert_cmpuint (probed_count, ==, probed);
}

const gchar *
__wrap_g_udev_device_get_property (GUdevDevice *device, const gchar *key)
{
	require_device (device);
	if (g_str_equal (key, "NAME"))
		return name_present ? "fixture allocated sensor name" : NULL;
	if (g_str_equal (key, "IIO_SENSOR_PROXY_TYPE"))
		return "iio-buffer-accel";
	if (g_str_equal (key, "ACCEL_MOUNT_MATRIX"))
		return fixture_matrix;
	if (g_str_equal (key, "ACCEL_LOCATION"))
		return "display";
	g_assert_not_reached ();
}

const gchar *__wrap_g_udev_device_get_name (GUdevDevice *device)
{ require_device (device); return "fixture-name-fallback"; }
const gchar *__wrap_g_udev_device_get_sysfs_path (GUdevDevice *device)
{ require_device (device); return path_overridden ? reported_path : sysfs_directory; }
const gchar *__wrap_g_udev_device_get_device_file (GUdevDevice *device)
{ require_device (device); return "/fixture/no-device-io"; }

const gchar *
__wrap_g_udev_device_get_sysfs_attr (GUdevDevice *device, const gchar *name)
{
	require_device (device);
	require_attribute (name);
	return g_hash_table_lookup (cached_attributes, name);
}

const gchar *
__wrap_g_udev_device_get_sysfs_attr_uncached (GUdevDevice *device, const gchar *name)
{
	require_device (device);
	require_attribute (name);
	raw_read_count++;
	return g_hash_table_lookup (uncached_attributes, name);
}

gboolean
__wrap_g_file_get_contents (const gchar *filename, gchar **contents, gsize *length, GError **error)
{
	const char *attribute;
	gpointer fault;
	guint count;

	g_assert_nonnull (fixture_device);
	g_assert_nonnull (sysfs_directory);
	g_assert_true (g_str_has_prefix (filename, sysfs_directory));
	g_assert_cmpint (filename[strlen (sysfs_directory)], ==, G_DIR_SEPARATOR);
	attribute = filename + strlen (sysfs_directory) + 1;
	require_attribute (attribute); /* Reject foreign paths and nested traversal. */
	count = acquisition_fixture_read_count (attribute);
	g_hash_table_replace (read_counts, g_strdup (attribute), GUINT_TO_POINTER (count + 1));
	fault = g_hash_table_lookup (read_faults, attribute);
	if (fault) {
		int code = GPOINTER_TO_INT (fault) - 2;
		if (code >= 0)
			g_set_error_literal (error, G_FILE_ERROR, code, "Injected owned calibration read failure");
		return FALSE;
	}
	/* Ordinary successful/missing reads use real GLib file I/O, but only on
	 * this fixture's own regular files and optional-attribute paths. */
	return __real_g_file_get_contents (filename, contents, length, error);
}

gboolean
__wrap_iio_fixup_sampling_frequency (GUdevDevice *device)
{
	require_device (device);
	fixup_count++;
	/* This proves constructor ordering only, not actual IIO frequency writes. */
	return fixup_succeeds;
}

BufferDrvData *
__wrap_buffer_drv_data_new (GUdevDevice *device)
{
	require_device (device);
	g_assert_null (fixture_buffer);
	fixture_buffer = g_new0 (BufferDrvData, 1);
	fixture_buffer->device = g_object_ref (device);
	fixture_buffer->trigger_name = g_strdup ("fixture-trigger");
	fixture_buffer->dev_dir_name = sysfs_directory;
	fixture_buffer->scan_size = 8;
	created_count++;
	return fixture_buffer;
}

void
__wrap_buffer_drv_data_free (BufferDrvData *data)
{
	g_assert_true (data == fixture_buffer);
	require_device (data->device);
	g_assert_false (buffer_enabled);
	g_clear_object (&data->device);
	g_clear_pointer (&data->trigger_name, g_free);
	g_free (data);
	fixture_buffer = NULL;
	freed_count++;
}

gboolean
__wrap_enable_ring_buffer (BufferDrvData *data)
{
	g_assert_true (data == fixture_buffer);
	enabled_count++;
	if (!buffer_enable_succeeds)
		return FALSE;
	buffer_enabled = TRUE;
	return TRUE;
}

void
__wrap_disable_ring_buffer (BufferDrvData *data)
{
	g_assert_true (data == fixture_buffer);
	buffer_enabled = FALSE;
	disabled_count++;
}

gboolean
__wrap_is_buffer_usable (char *path)
{
	g_assert_cmpstr (path, ==, "/fixture/no-device-io");
	g_assert_true (buffer_enabled);
	probed_count++;
	return buffer_usable;
}

int
main (int argc, char **argv)
{
	g_test_init (&argc, &argv, NULL);
	register_iio_acquisition_input_tests ();
	register_iio_acquisition_poll_tests ();
	register_iio_acquisition_buffer_tests ();
	return g_test_run ();
}
