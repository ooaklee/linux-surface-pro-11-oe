/*
 * Modified from industrialio buffer test code, and Lenovo Yoga (2 Pro) orientation helper
 * Copyright (c) 2008 Jonathan Cameron
 * Copyright (c) 2014 Peter F. Patel-Schneider
 * Copyright (c) 2014, 2021 Bastien Nocera <hadess@hadess.net>
 * Copyright (c) 2015 Elad Alfassa <elad@fedoraproject.org>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3 as published by
 * the Free Software Foundation.
 */

#include "iio-buffer-utils.h"
#include "utils.h"

#include <ctype.h>
#include <fcntl.h>
#include <float.h>
#include <math.h>
#include <string.h>
#include <errno.h>
#include <stdio.h>
#include <glib/gstdio.h>

#define IIO_MIN_SAMPLING_FREQUENCY	10 /* Hz */

/**
 * iio_channel_info - information about a given channel
 * @name: channel name
 * @generic_name: the generic name of the channel
 * @scale: scale factor to be applied for conversion to SI units
 * @offset: offset to be applied for conversion to SI units
 * @index: the channel index in the buffer output
 * @is_signed: signed or unsigned
 * @bits_used: number of valid bits of data
 * @bytes: number of bytes occupied in buffer output (bits_used + padding)
 * @shift: shift right by this before masking out bits_used
 * @mask: a bit mask for the raw output
 * @be: little or big endian
 * @enabled: is this channel enabled
 * @location: data offset for this channel inside the buffer (in bytes)
 **/
struct iio_channel_info {
	char *name;
	char *generic_name;
	gdouble scale;
	gdouble offset;
	unsigned index;
	unsigned is_signed;
	unsigned bits_used;
	unsigned bytes;
	unsigned shift;
	guint64 mask;
	unsigned be;
	unsigned enabled;
	unsigned location;
};

static gboolean
channel_format_valid (const iio_channel_info *channel)
{
	unsigned storage;
	guint64 mask;

	if (!channel || (channel->bytes != 1 && channel->bytes != 2 &&
	                 channel->bytes != 4 && channel->bytes != 8) ||
	    channel->is_signed > 1 || channel->be > 1)
		return FALSE;
	storage = channel->bytes * 8;
	if (!channel->bits_used || channel->bits_used > storage || channel->shift >= storage ||
	    channel->bits_used > storage - channel->shift)
		return FALSE;
	mask = channel->bits_used == 64 ? G_MAXUINT64 :
	       (G_GUINT64_CONSTANT (1) << channel->bits_used) - 1;
	return channel->mask == mask;
}

static char *
iioutils_break_up_name (const char *name)
{
	g_auto(GStrv) items = NULL;
	guint i;

	items = g_strsplit (name, "_", -1);
	for (i = 0; items[i] != NULL; i++) {
		if (items[i + 1] == NULL) {
			g_clear_pointer (&items[i], g_free);
			break;
		}
	}

	return g_strjoinv ("_", items);
}

/* Read an ASCII sysfs token without silently accepting an embedded NUL.
 * Absence is distinct from every other failure: only absence permits a
 * generic-name fallback or the documented scale/offset defaults. */
static int
read_metadata (const char *filename, char **text)
{
	g_autofree char *contents = NULL;
	g_autoptr(GError) error = NULL;
	gsize length;

	if (!g_file_get_contents (filename, &contents, &length, &error))
		return g_error_matches (error, G_FILE_ERROR, G_FILE_ERROR_NOENT) ? -ENOENT : -EINVAL;
	if (strlen (contents) != length)
		return -EINVAL;
	*text = g_steal_pointer (&contents);
	return 0;
}

static int
read_channel_metadata (const char *directory, const char *name,
		       const char *generic_name, const char *suffix, char **text)
{
	g_autofree char *leaf = g_strdup_printf ("%s_%s", name, suffix);
	g_autofree char *filename = g_build_filename (directory, leaf, NULL);
	int result = read_metadata (filename, text);

	if (result != -ENOENT || !generic_name || g_str_equal (name, generic_name))
		return result;
	g_clear_pointer (&leaf, g_free);
	g_clear_pointer (&filename, g_free);
	leaf = g_strdup_printf ("%s_%s", generic_name, suffix);
	filename = g_build_filename (directory, leaf, NULL);
	return read_metadata (filename, text);
}

static const char *
skip_ascii_space (const char *text)
{
	while (g_ascii_isspace (*text))
		text++;
	return text;
}

static gboolean
parse_unsigned (const char **cursor, unsigned *value)
{
	const char *text = *cursor;
	unsigned parsed = 0;

	if (!g_ascii_isdigit (*text))
		return FALSE;
	while (g_ascii_isdigit (*text)) {
		unsigned digit = *text++ - '0';
		if (parsed > (G_MAXUINT - digit) / 10)
			return FALSE;
		parsed = parsed * 10 + digit;
	}
	*cursor = text;
	*value = parsed;
	return TRUE;
}

static gboolean
parse_unsigned_token (const char *text, unsigned *value)
{
	unsigned parsed;

	text = skip_ascii_space (text);
	if (!parse_unsigned (&text, &parsed) || *skip_ascii_space (text))
		return FALSE;
	*value = parsed;
	return TRUE;
}

/**
 * iioutils_get_type() - find and process _type attribute data
 * @is_signed: output whether channel is signed
 * @bytes: output how many bytes the channel storage occupies
 * @mask: output a bit mask for the raw data
 * @be: big endian
 * @device_dir: the iio device directory
 * @name: the channel name
 *
 * See `struct iio_chan_spec` in the kernel headers.
 **/
static gboolean
iioutils_get_type (unsigned   *is_signed,
		   unsigned   *bytes,
		   unsigned   *bits_used,
		   unsigned   *shift,
		   guint64    *mask,
		   unsigned   *be,
		   const char *device_dir,
		   const char *name,
		   const char *generic_name)
{
	g_autofree char *directory = g_build_filename (device_dir, "scan_elements", NULL);
	g_autofree char *contents = NULL;
	const char *text;
	unsigned used, storage, shifted = 0, big_endian, signed_value;

	if (read_channel_metadata (directory, name, generic_name, "type", &contents) < 0)
		goto invalid;
	text = skip_ascii_space (contents);
	if (g_str_has_prefix (text, "be:"))
		big_endian = TRUE;
	else if (g_str_has_prefix (text, "le:"))
		big_endian = FALSE;
	else
		goto invalid;
	text += 3;
	if (*text != 's' && *text != 'u')
		goto invalid;
	signed_value = *text++ == 's';
	if (!parse_unsigned (&text, &used) || *text++ != '/' ||
	    !parse_unsigned (&text, &storage))
		goto invalid;
	if (g_str_has_prefix (text, ">>")) {
		text += 2;
		if (!parse_unsigned (&text, &shifted))
			goto invalid;
	}
	if (*skip_ascii_space (text) ||
	    (storage != 8 && storage != 16 && storage != 32 && storage != 64) ||
	    used == 0 || used > storage || shifted >= storage || used > storage - shifted)
		goto invalid;
	/* Repeated storage elements are not supported; the full-token test above
	 * rejects them instead of guessing a layout or terminating the daemon. */
	*be = big_endian;
	*bytes = storage / 8;
	*bits_used = used;
	*shift = shifted;
	*mask = used == 64 ? G_MAXUINT64 : (G_GUINT64_CONSTANT (1) << used) - 1;
	*is_signed = signed_value;

	g_debug ("Got type for %s: is signed: %u, bytes: %u, bits_used: %u, shift: %u, mask: %" G_GUINT64_FORMAT ", be: %u",
		 name, *is_signed, *bytes, *bits_used, *shift, *mask, *be);

	return TRUE;

invalid:
	g_debug ("Invalid or unsupported scan type for IIO channel '%s'", name);
	return FALSE;
}

static int
iioutils_get_param_double (double     *output,
			  const char *param_name,
			  const char *device_dir,
			  const char *name,
			  const char *generic_name)
{
	g_autofree char *contents = NULL;
	char *end;
	const char *number;
	double parsed;
	int parse_errno;
	int result = read_channel_metadata (device_dir, name, generic_name, param_name, &contents);

	if (result < 0)
		return result;
	number = skip_ascii_space (contents);
	if (*number == '+' || *number == '-')
		number++;
	if (g_ascii_strncasecmp (number, "0x", 2) == 0)
		return -EINVAL;
	errno = 0;
	parsed = g_ascii_strtod (contents, &end);
	parse_errno = errno;
	if (end == contents || *skip_ascii_space (end) || !isfinite (parsed) ||
	    (parse_errno == ERANGE && parsed == 0.0))
		return -EINVAL;
	*output = parsed;
	return 0;
}

static void
channel_info_free (iio_channel_info *ci)
{
	g_free (ci->name);
	g_free (ci->generic_name);
	g_free (ci);
}

static int
compare_channel_index (gconstpointer a, gconstpointer b)
{
	const iio_channel_info *info_1 = *(iio_channel_info **) a;
	const iio_channel_info *info_2 = *(iio_channel_info **) b;

	return (info_1->index > info_2->index) - (info_1->index < info_2->index);
}

G_DEFINE_AUTOPTR_CLEANUP_FUNC(iio_channel_info, channel_info_free)

/* build_channel_array() - function to figure out what channels are present */
static iio_channel_info **
build_channel_array (const char        *device_dir,
		     int               *counter)
{
	GDir *dp;
	int ret;
	const char *name;
	char *scan_el_dir;
	GPtrArray *array;
	iio_channel_info **ret_array;
	int i;
	const char *reason = "invalid enable flag";

	*counter = 0;
	scan_el_dir = g_build_filename (device_dir, "scan_elements", NULL);

	dp = g_dir_open (scan_el_dir, 0, NULL);
	if (dp == NULL) {
		ret = -errno;
		g_debug ("Could not open scan_elements dir '%s'", scan_el_dir);
		g_free (scan_el_dir);
		return NULL;
	}

	array = g_ptr_array_new_full (0, (GDestroyNotify) channel_info_free);

	while ((name = g_dir_read_name (dp)) != NULL) {
		if (g_str_has_suffix (name, "_en")) {
			g_autofree char *filename = NULL;
			g_autofree char *index_name = NULL;
			g_autofree char *contents = NULL;
			g_autoptr(iio_channel_info) current = NULL;
			unsigned enabled;

			reason = "empty scan channel name";
			if (g_str_equal (name, "_en"))
				goto error;
			reason = "invalid enable flag";
			filename = g_build_filename (scan_el_dir, name, NULL);
			if (read_metadata (filename, &contents) < 0 ||
			    !parse_unsigned_token (contents, &enabled) || enabled > 1)
				goto error;
			if (!enabled)
				continue;

			current = g_new0 (iio_channel_info, 1);

			current->scale = 1.0;
			current->offset = 0;
			current->enabled = TRUE;
			current->name = g_strndup (name, strlen(name) - strlen("_en"));
			current->generic_name = iioutils_break_up_name (current->name);
			if (g_strcmp0(current->generic_name, "in_rot_from_north_magnetic_tilt") == 0) {
				g_free (current->generic_name);
				current->generic_name = g_strdup ("in_rot");
			}

			index_name = g_strdup_printf ("%s_index", current->name);
			g_clear_pointer (&filename, g_free);
			filename = g_build_filename (scan_el_dir, index_name, NULL);

			g_clear_pointer (&contents, g_free);
			reason = "invalid scan index";
			if (read_metadata (filename, &contents) < 0 ||
			    !parse_unsigned_token (contents, &current->index))
				goto error;

			/* Find the scale */
			reason = "invalid scale";
			ret = iioutils_get_param_double (&current->scale,
							"scale",
							device_dir,
							current->name,
							current->generic_name);
			if ((ret < 0) && (ret != -ENOENT))
				goto error;
			if (current->scale == 0.0)
				goto error;

			reason = "invalid offset";
			ret = iioutils_get_param_double (&current->offset,
							"offset",
							device_dir,
							current->name,
							current->generic_name);
			if ((ret < 0) && (ret != -ENOENT))
				goto error;

			reason = "invalid or unsupported scan type";
			ret = iioutils_get_type (&current->is_signed,
						 &current->bytes,
						 &current->bits_used,
						 &current->shift,
						 &current->mask,
						 &current->be,
						 device_dir,
						 current->name,
						 current->generic_name);

			if (!ret)
				goto error;
			if (array->len >= G_MAXINT / 127) {
				reason = "too many scan channels";
				goto error;
			}
			g_ptr_array_add (array, g_steal_pointer (&current));
		}
	}
	reason = "no enabled channels";
	if (array->len == 0)
		goto error;
	g_ptr_array_sort (array, compare_channel_index);
	for (guint j = 1; j < array->len; j++) {
		const iio_channel_info *previous = g_ptr_array_index (array, j - 1);
		const iio_channel_info *current = g_ptr_array_index (array, j);
		if (previous->index == current->index) {
			reason = "duplicate scan index";
			goto error;
		}
	}
	g_dir_close (dp);
	g_free (scan_el_dir);

	*counter = array->len;
	ret_array = (iio_channel_info **) g_ptr_array_free (array, FALSE);

	for (i = 0; i < *counter; i++) {
		iio_channel_info *ci = ret_array[i];

		g_debug ("Built channel array for %s: index: %u, is signed: %u, bytes: %u, bits_used: %u, shift: %u, mask: %" G_GUINT64_FORMAT ", be: %u",
			 ci->name, ci->index, ci->is_signed, ci->bytes, ci->bits_used, ci->shift, ci->mask, ci->be);
	}

	return ret_array;

error:
	g_debug ("Invalid IIO scan metadata in '%s': %s", device_dir, reason);
	g_ptr_array_free (array, TRUE);
	g_dir_close (dp);
	g_free (scan_el_dir);
	return NULL;
}

/* stdio return values are not errno numbers. Preserve the first real errno
 * before cleanup or logging can replace it, and include delayed close/flush
 * failures even when no readback was requested. GLib readback errors do not
 * expose a portable errno; retain their message and report EIO explicitly. */
static int
write_sysfs_value (const char *filename,
		   const char *basedir,
		   const char *value,
		   gboolean    verify)
{
	g_autofree char *path = g_build_filename (basedir, filename, NULL);
	g_autofree char *contents = NULL;
	g_autoptr(GError) error = NULL;
	FILE *stream;
	gsize length;
	int written, failure = 0;

	stream = fopen (path, "w");
	if (!stream) {
		failure = errno ? errno : EIO;
		g_warning ("Could not open for write '%s': %s", path, g_strerror (failure));
		return -failure;
	}
	errno = 0;
	written = fprintf (stream, "%s", value);
	if (written < 0 || (gsize) written != strlen (value))
		failure = errno ? errno : EIO;
	errno = 0;
	if (fclose (stream) != 0 && !failure)
		failure = errno ? errno : EIO;
	if (failure) {
		g_warning ("Could not write to '%s': %s", path, g_strerror (failure));
		return -failure;
	}
	if (!verify)
		return 0;
	if (!g_file_get_contents (path, &contents, &length, &error)) {
		g_warning ("Could not verify sysfs write '%s': %s", path,
			   error ? error->message : "readback failed");
		return -EIO;
	}
	if (strlen (contents) != length || g_strcmp0 (g_strchomp (contents), value) != 0) {
		g_warning ("Sysfs write readback mismatch for '%s'", path);
		return -EIO;
	}
	return 0;
}

static int
_write_sysfs_int (const char *filename,
		  const char *basedir,
		  int         val,
		  int         verify,
		  int         type,
		  int         val2)
{
	g_autofree char *value = type ? g_strdup_printf ("%d %d", val, val2) :
				       g_strdup_printf ("%d", val);

	return write_sysfs_value (filename, basedir, value, verify);
}

static int write_sysfs_int(const char *filename, const char *basedir, int val) {
	return _write_sysfs_int(filename, basedir, val, 0, 0, 0);
}

static int write_sysfs_int_and_verify(const char *filename, const char *basedir, int val) {
	return _write_sysfs_int(filename, basedir, val, 1, 0, 0);
}

static int
_write_sysfs_string (const char *filename,
		     const char *basedir,
		     const char *val,
		     int         verify)
{
	return write_sysfs_value (filename, basedir, val, verify);
}

/**
 * write_sysfs_string_and_verify() - string write, readback and verify
 * @filename: name of file to write to
 * @basedir: the sysfs directory in which the file is to be found
 * @val: the string to write
 **/
static int write_sysfs_string_and_verify(const char *filename, const char *basedir, const char *val) {
	return _write_sysfs_string(filename, basedir, val, 1);
}

static int write_sysfs_string(const char *filename, const char *basedir, const char *val) {
	return _write_sysfs_string(filename, basedir, val, 0);
}


/**
 * size_from_channelarray() - calculate the storage size of a scan
 * @channels:           the channel info array
 * @num_channels:       number of channels
 *
 * Has the side effect of filling the channels[i].location values used
 * in processing the buffer output.
 **/
static int
size_from_channelarray (iio_channel_info **channels,
			int                num_channels)
{
	gsize bytes = 0, maximum_alignment = 1;
	const gsize limit = G_MAXINT / 127; /* fixed maximum batch in all consumers */

	if (!channels || num_channels <= 0 || (gsize) num_channels > limit)
		return -1;
	for (int i = 0; i < num_channels; i++) {
		iio_channel_info *channel = channels[i];
		gsize padding;
		if (!channel_format_valid (channel))
			return -1;
		padding = (channel->bytes - bytes % channel->bytes) % channel->bytes;
		if (bytes > limit - padding || bytes + padding > limit - channel->bytes)
			return -1;
		bytes += padding;
		channel->location = bytes;
		bytes += channel->bytes;
		maximum_alignment = MAX (maximum_alignment, channel->bytes);
	}
	/* The kernel also pads the end of every scan to its largest alignment. */
	gsize padding = (maximum_alignment - bytes % maximum_alignment) % maximum_alignment;
	if (bytes > limit - padding)
		return -1;
	return bytes + padding;
}

/**
 * process_scan_1() - decode one channel as raw plus offset, before scale
 * @data: pointer to the start of the scan
 * @length: available bytes, including the complete declared scan
 *
 * Outputs are committed only for a valid present channel. Missing, malformed,
 * truncated or non-finite input changes only ch_present to FALSE.
 */
void
process_scan_1 (const char        *data,
		gsize              length,
		BufferDrvData     *buffer_data,
		const char        *ch_name,
		gdouble           *ch_val,
		gdouble           *ch_scale,
		gboolean          *ch_present)
{
	g_return_if_fail (ch_present != NULL);
	*ch_present = FALSE;
	if (!data || !buffer_data || !ch_name || !ch_val || !ch_scale ||
	    !buffer_data->channels || buffer_data->channels_count <= 0 ||
	    buffer_data->channels_count > G_MAXINT / 127 ||
	    buffer_data->scan_size <= 0 || buffer_data->scan_size > G_MAXINT / 127 ||
	    length < (gsize) buffer_data->scan_size)
		return;

	for (int k = 0; k < buffer_data->channels_count; k++) {
		const iio_channel_info *info = buffer_data->channels[k];
		guint64 input = 0, mask;
		double value;

		if (!info || !info->name)
			return;
		if (strcmp (info->name, ch_name) != 0)
			continue;
		if (!channel_format_valid (info))
			return;
		if (info->location > length || info->bytes > length - info->location ||
		    info->location > (gsize) buffer_data->scan_size ||
		    info->bytes > (gsize) buffer_data->scan_size - info->location ||
		    !isfinite (info->offset) || !isfinite (info->scale) || info->scale == 0.0)
			return;
		mask = info->bits_used == 64 ? G_MAXUINT64 :
		       (G_GUINT64_CONSTANT (1) << info->bits_used) - 1;
		if (info->mask != mask)
			return;
		/* Byte loads work on unaligned buffers and on either host endian. */
		for (unsigned i = 0; i < info->bytes; i++) {
			gsize byte = info->be ? i : info->bytes - 1 - i;
			input = (input << 8) | (guint8) data[info->location + byte];
		}
		input = (input >> info->shift) & mask;
		if (info->is_signed && (input & (G_GUINT64_CONSTANT (1) << (info->bits_used - 1)))) {
			/* Two's-complement magnitude stays unsigned, even at INT64_MIN.
			 * Never narrow through a signed integer or the former int output. */
			guint64 magnitude = ((~input) & mask) + 1;
			value = -(double) magnitude;
		} else
			value = (double) input;
		/* Integers through 2^53 are exact; wider 64-bit raw values may round
		 * to a neighbouring double. Never clip or cast the result back. */
		value += info->offset;
		if (!isfinite (value))
			return;

		*ch_val = value;
		*ch_scale = info->scale;
		*ch_present = TRUE;
		return;
	}
	g_debug ("IIO channel '%s' could not be found", ch_name);
}

/**
 * iio_round_sampling_frequency: Round sampling_frequency to a supported value
 * @dev: the IIO device to round the sampling frequency for
 * @name: name of the *sampling_frequency attribute for which to round value
 * @desired: desired value
 *
 * Check "<name>_available" and if that attribute exists round the desired
 * value to a supported value, rounding up where possible.
 */
static double
iio_round_sampling_frequency (GUdevDevice *dev, const char *name, double desired)
{
	g_autofree char *available_attr = NULL;
	const char *available_str;
	char *endptr;
	double closest_higher = DBL_MAX;
	double closest_lower = 0.0;
	double available;

	available_attr = g_strconcat (name, "_available", NULL);
	available_str = g_udev_device_get_sysfs_attr (dev, available_attr);

	if (!available_str)
		return desired;

	while (*available_str) {
		available = g_ascii_strtod (available_str, &endptr);
		if (available_str == endptr || (*endptr && !isspace (*endptr)))
			break;

		available_str = endptr;

		/* 0 disables sampling, skip */
		if (available == 0.0)
			continue;

		if (available >= desired) {
			if (available < closest_higher)
				closest_higher = available;
		} else {
			if (available > closest_lower)
				closest_lower = available;
		}
	}

	/* Prefer higher values */
	if (closest_higher != DBL_MAX)
		return closest_higher;

	if (closest_lower != 0.0)
		return closest_lower;

	return desired;
}

/**
 * iio_fixup_sampling_frequency: Fixup devices *sampling_frequency attributes
 * @dev: the IIO device to fix the sampling frequencies for
 *
 * Make sure devices with *sampling_frequency attributes are sampling at
 * 10Hz or more. This fixes 2 problems:
 * 1) Some buffered devices default their sampling_frequency to 0Hz and then
 * never produce any readings.
 * 2) Some polled devices default to 1Hz and wait for a fresh sample before
 * returning from sysfs *_raw reads, blocking all of iio-sensor-proxy for
 * multiple seconds
 **/
gboolean
iio_fixup_sampling_frequency (GUdevDevice *dev)
{
	GDir *dir;
	const char *device_dir;
	const char *name;
	g_autoptr(GError) error = NULL;
	char sample_freq_str[G_ASCII_DTOSTR_BUF_SIZE];
	double sample_freq;

	device_dir = g_udev_device_get_sysfs_path (dev);
	dir = g_dir_open (g_udev_device_get_sysfs_path (dev), 0, &error);
	if (!dir) {
		g_warning ("Failed to open directory '%s': %s", device_dir, error->message);
		return FALSE;
	}

	while ((name = g_dir_read_name (dir))) {
		if (g_str_has_suffix (name, "sampling_frequency") == FALSE)
			continue;

		sample_freq = g_udev_device_get_sysfs_attr_as_double (dev, name);
		if (sample_freq >= IIO_MIN_SAMPLING_FREQUENCY)
			continue; /* Continue with pre-set sample freq. */

		/* Sample freq too low, set it to a supported freq close to 10Hz */
		sample_freq = iio_round_sampling_frequency (dev, name, IIO_MIN_SAMPLING_FREQUENCY);

		/*
		 * Some sample_freq IIO sysfs attr only accept integers, most will
		 * accept floats but not all. g_ascii_dtostr() uses the shortest
		 * possible representation, omitting the "." for whole numbers.
		 */
		g_ascii_dtostr (sample_freq_str, G_ASCII_DTOSTR_BUF_SIZE, sample_freq);
		if (write_sysfs_string (name, device_dir, sample_freq_str) < 0)
			g_warning ("Could not fix sample-freq for %s/%s", device_dir, name);
	}
	g_dir_close (dir);
	return TRUE;
}

/**
 * enable_sensors: enable all the sensors in a device
 * @device_dir: the IIO device directory in sysfs
 * @
 **/
static gboolean
enable_sensors (GUdevDevice *dev,
                int          enable)
{
	GDir *dir;
	char *device_dir;
	const char *name;
	gboolean ret = FALSE;
	gboolean failed = FALSE;
	g_autoptr(GError) error = NULL;

	g_debug ("%s sensors for device '%s'", enable ? "Enabling" : "Disabling",
		 g_udev_device_get_sysfs_path (dev));

	device_dir = g_build_filename (g_udev_device_get_sysfs_path (dev), "scan_elements", NULL);
	dir = g_dir_open (device_dir, 0, &error);
	if (!dir) {
		g_warning ("Failed to open directory '%s': %s", device_dir, error->message);
		g_free (device_dir);
		return FALSE;
	}

	while ((name = g_dir_read_name (dir))) {
		g_autofree char *filename = NULL;
		g_autofree char *contents = NULL;
		unsigned enabled;

		if (g_str_has_suffix (name, "_en") == FALSE)
			continue;
		if (g_str_equal (name, "_en")) {
			g_debug ("Empty IIO scan channel name in '%s'", device_dir);
			failed = TRUE;
			continue;
		}

		/* Validate the actual flag before writing it. A malformed explicit
		 * value must not be hidden by blindly replacing it with 0 or 1. */
		filename = g_build_filename (device_dir, name, NULL);
		if (read_metadata (filename, &contents) < 0 ||
		    !parse_unsigned_token (contents, &enabled) || enabled > 1) {
			g_debug ("Invalid IIO enable flag '%s'", filename);
			failed = TRUE;
			continue;
		}
		if (enabled == (unsigned) enable) {
			g_debug ("Already enabled sensor %s/%s", device_dir, name);
			ret = TRUE;
			continue;
		}

		/* Enable */
		if (write_sysfs_int (name, device_dir, enable) < 0) {
			g_warning ("Could not write %d to %s/%s",
				   enable, device_dir, name);
			failed = TRUE;
			continue;
		}

		ret = TRUE;
		g_debug ("%s sensor %s/%s", enable ? "Enabled" : "Disabled",
			 device_dir, name);
	}
	g_dir_close (dir);
	g_free (device_dir);

	if (!ret || failed) {
		g_warning ("Failed to %s any sensors for device '%s'",
			   enable ? "enable" : "disable",
			   g_udev_device_get_sysfs_path (dev));
	}

	return ret && !failed;
}

gboolean
enable_ring_buffer (BufferDrvData *data)
{
	int ret;

	/* Setup ring buffer parameters */
	ret = write_sysfs_int("buffer/length", data->dev_dir_name, 128);
	if (ret < 0) {
		g_warning ("Failed to set ring buffer length for %s", data->dev_dir_name);
		return FALSE;
	}
	/* Enable the buffer */
	ret = write_sysfs_int_and_verify("buffer/enable", data->dev_dir_name, 1);
	if (ret < 0) {
		g_warning ("Unable to enable ring buffer for %s", data->dev_dir_name);
		return FALSE;
	}

	return TRUE;
}

void
disable_ring_buffer (BufferDrvData *data)
{
	/* Stop the buffer */
	write_sysfs_int ("buffer/enable", data->dev_dir_name, 0);
}

static void
disable_trigger (BufferDrvData *data)
{
	/* Disconnect the trigger - just write a dummy name. */
	if (data->trigger_name)
		write_sysfs_string ("trigger/current_trigger", data->dev_dir_name, "NULL");
}

static gboolean
enable_trigger (BufferDrvData *data)
{
	int ret;

	/* Set the device trigger to be the data ready trigger */
	ret = write_sysfs_string_and_verify("trigger/current_trigger",
			data->dev_dir_name, data->trigger_name);
	if (ret < 0) {
		g_warning ("Failed to write current_trigger file %s", g_strerror(-ret));
		return FALSE;
	}

	return TRUE;
}

static gboolean
build_channels (BufferDrvData *data)
{
	/* Parse the files in scan_elements to identify what channels are present */
	data->channels = build_channel_array (data->dev_dir_name, &(data->channels_count));
	if (data->channels == NULL) {
		g_warning ("Problem reading scan element information: %s", data->dev_dir_name);
		return FALSE;
	}
	data->scan_size = size_from_channelarray (data->channels, data->channels_count);
	if (data->scan_size <= 0) {
		g_warning ("Invalid or oversized IIO scan layout: %s", data->dev_dir_name);
		return FALSE;
	}
	return TRUE;
}

char *
get_trigger_name (GUdevDevice *device)
{
	GList *devices, *l;
	GUdevClient *client;
	gboolean has_trigger = FALSE;
	char *trigger_name;
	const gchar * const subsystems[] = { "iio", NULL };

	client = g_udev_client_new (subsystems);
	devices = g_udev_client_query_by_subsystem (client, "iio");

	/*
	 * Find the associated trigger using <device_name>-dev<device_number>
	 * pattern, such as found on sensors using Intel HID Sensor Hub drivers
	 */
	trigger_name = g_strdup_printf ("%s-dev%s",
					g_udev_device_get_sysfs_attr (device, "name"),
					g_udev_device_get_number (device));
	for (l = devices; l != NULL; l = l->next) {
		GUdevDevice *dev = l->data;

		if (g_strcmp0 (trigger_name, g_udev_device_get_sysfs_attr (dev, "name")) == 0) {
			g_debug ("Found associated trigger (%s) at %s", trigger_name, g_udev_device_get_sysfs_path (dev));
			has_trigger = TRUE;
			break;
		}
	}

	/*
	 * If not found, search for trigger using the alternative <device_name>-trigger
	 * naming convention
	 */
	if (!has_trigger) {
		g_free (trigger_name);
		trigger_name = g_strdup_printf ("%s-trigger", g_udev_device_get_sysfs_attr (device, "name"));
		for (l = devices; l != NULL; l = l->next) {
			GUdevDevice *dev = l->data;

			if (g_strcmp0 (trigger_name, g_udev_device_get_sysfs_attr (dev, "name")) == 0) {
				g_debug ("Found associated trigger (%s) at %s", trigger_name, g_udev_device_get_sysfs_path (dev));
				has_trigger = TRUE;
				break;
			}
		}
	}

	g_list_free_full (devices, g_object_unref);
	g_clear_object (&client);

	if (has_trigger)
		return trigger_name;

	g_warning ("Could not find trigger name associated with %s",
		   g_udev_device_get_sysfs_path (device));
	g_free (trigger_name);
	return NULL;
}

void
buffer_drv_data_free (BufferDrvData *buffer_data)
{
	int i;

	if (buffer_data == NULL)
		return;

	/* A buffer should be disabled before scan elements to avoid a
	 * "Device or resource busy" error */
	disable_ring_buffer (buffer_data);
	disable_trigger (buffer_data);
	g_free (buffer_data->trigger_name);

	enable_sensors (buffer_data->device, 0);
	g_clear_object (&buffer_data->device);

	for (i = 0; i < buffer_data->channels_count; i++)
		channel_info_free (buffer_data->channels[i]);
	g_free (buffer_data->channels);
	g_free (buffer_data);
}

BufferDrvData *
buffer_drv_data_new (GUdevDevice *device)
{
	BufferDrvData *buffer_data;
	g_autofree char *trigger_name = NULL;

	buffer_data = g_new0 (BufferDrvData, 1);
	buffer_data->dev_dir_name = g_udev_device_get_sysfs_path (device);
	trigger_name = get_trigger_name (device);
	if (trigger_name)
		buffer_data->trigger_name = g_strdup (trigger_name);
	buffer_data->device = g_object_ref (device);

	if (!iio_fixup_sampling_frequency (device) ||
	    !enable_sensors (device, 1) ||
	    !build_channels (buffer_data) ||
	    (buffer_data->trigger_name && !enable_trigger (buffer_data)) ||
	    !enable_ring_buffer (buffer_data)) {
		buffer_drv_data_free (buffer_data);
		return NULL;
	}

	return buffer_data;
}

gboolean
is_buffer_usable (char *path)
{
	gboolean buffer_usable = FALSE;
	g_autofd int fp = -1;
	GPollFD fds;

	/* Attempt to read from the sensor buffer */
	fp = g_open (path, O_RDONLY | O_NONBLOCK);
	if (fp == -1) {
	        g_warning ("Failed to open '%s': %s", path, g_strerror (errno));
	} else {
	        fds.fd = fp;
	        fds.events = G_IO_IN | G_IO_ERR;
	        g_poll (&fds, 1, 500);

	        if (fds.revents & G_IO_IN)
	                buffer_usable = TRUE;
	        else
	                g_warning ("Buffer '%s' did not have data within 0.5s", path);
	}

	return buffer_usable;
}

IIOSensorData *
iio_sensor_data_new (gsize size)
{
	IIOSensorData *data;

	g_return_val_if_fail (size != 0, NULL);

	data = g_new0 (IIOSensorData, 1);
	data->data = g_malloc0 (size);
	return data;
}

void
iio_sensor_data_free (IIOSensorData *data)
{
	if (data == NULL)
		return;
	g_free (data->data);
	g_free (data);
}
