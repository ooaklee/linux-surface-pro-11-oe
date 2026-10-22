/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Actual private IIO utility implementation, compiled only into this test TU.
 * No provider, device, transport, production test hook or alternate decoder.
 * File fixtures are created only below a fresh g_dir_make_tmp directory. */
#include <float.h>
#include <limits.h>
#include <string.h>

#include "../src/iio-buffer-utils.c"

typedef struct {
	char *directory;
	GPtrArray *files;
} MetadataFixture;

static MetadataFixture
metadata_new (void)
{
	g_autoptr(GError) error = NULL;
	MetadataFixture fixture;
	g_autofree char *scan = NULL;

	fixture.directory = g_dir_make_tmp ("iio-unit-XXXXXX", &error);
	g_assert_no_error (error);
	g_assert_nonnull (fixture.directory);
	fixture.files = g_ptr_array_new_with_free_func (g_free);
	scan = g_build_filename (fixture.directory, "scan_elements", NULL);
	g_assert_cmpint (g_mkdir (scan, 0700), ==, 0);
	return fixture;
}

static void
metadata_write (MetadataFixture *fixture, const char *name, const char *value)
{
	g_autoptr(GError) error = NULL;
	g_autofree char *path = g_build_filename (fixture->directory, name, NULL);

	if (!g_file_test (path, G_FILE_TEST_EXISTS))
		g_ptr_array_add (fixture->files, g_strdup (path));
	g_assert_true (g_file_set_contents (path, value, -1, &error));
	g_assert_no_error (error);
}

static void
metadata_clear (MetadataFixture *fixture)
{
	g_autofree char *scan = g_build_filename (fixture->directory, "scan_elements", NULL);

	for (guint i = 0; i < fixture->files->len; i++)
		g_assert_cmpint (g_remove (g_ptr_array_index (fixture->files, i)), ==, 0);
	g_ptr_array_unref (fixture->files);
	g_assert_cmpint (g_rmdir (scan), ==, 0);
	g_assert_cmpint (g_rmdir (fixture->directory), ==, 0);
	g_free (fixture->directory);
}

static void
metadata_channel (MetadataFixture *fixture, const char *name,
		  const char *index, const char *type)
{
	g_autofree char *enabled = g_strdup_printf ("scan_elements/%s_en", name);
	g_autofree char *number = g_strdup_printf ("scan_elements/%s_index", name);
	g_autofree char *format = g_strdup_printf ("scan_elements/%s_type", name);

	metadata_write (fixture, enabled, "1");
	metadata_write (fixture, number, index);
	metadata_write (fixture, format, type);
}

static void
channels_free (iio_channel_info **channels, int count)
{
	for (int i = 0; i < count; i++)
		channel_info_free (channels[i]);
	g_free (channels);
}

static void
test_metadata_numbers (void)
{
	MetadataFixture fixture = metadata_new ();
	const char *invalid[] = { "", " ", "nan", "inf", "-Infinity", "1junk",
		"1 2", "1e9999", "1e-9999", "-1e-9999", "0x1p0" };
	double output = 123.5;
	char subnormal[G_ASCII_DTOSTR_BUF_SIZE];

	g_assert_cmpint (iioutils_get_param_double (&output, "scale", fixture.directory,
	                                           "in_accel_x", "in_accel"), ==, -ENOENT);
	g_assert_cmpfloat (output, ==, 123.5);
	metadata_write (&fixture, "in_accel_scale", "2");
	g_assert_cmpint (iioutils_get_param_double (&output, "scale", fixture.directory,
	                                           "in_accel_x", "in_accel"), ==, 0);
	g_assert_cmpfloat (output, ==, 2.0);
	metadata_write (&fixture, "in_accel_x_scale", " \t1.25 \n");
	g_assert_cmpint (iioutils_get_param_double (&output, "scale", fixture.directory,
	                                           "in_accel_x", "in_accel"), ==, 0);
	g_assert_cmpfloat (output, ==, 1.25);
	for (guint i = 0; i < G_N_ELEMENTS (invalid); i++) {
		metadata_write (&fixture, "in_accel_x_scale", invalid[i]);
		output = 123.5;
		/* Explicit bad metadata must not fall back to the valid generic 2. */
		g_assert_cmpint (iioutils_get_param_double (&output, "scale", fixture.directory,
		                                           "in_accel_x", "in_accel"), ==, -EINVAL);
		g_assert_cmpfloat (output, ==, 123.5);
	}
	g_ascii_dtostr (subnormal, sizeof subnormal, DBL_MIN / 2.0);
	metadata_write (&fixture, "in_accel_x_scale", subnormal);
	g_assert_cmpint (iioutils_get_param_double (&output, "scale", fixture.directory,
	                                           "in_accel_x", "in_accel"), ==, 0);
	g_assert_cmpfloat (output, ==, DBL_MIN / 2.0);
	metadata_write (&fixture, "in_accel_x_scale", "-0.125");
	g_assert_cmpint (iioutils_get_param_double (&output, "scale", fixture.directory,
	                                           "in_accel_x", "in_accel"), ==, 0);
	g_assert_cmpfloat (output, ==, -0.125);
	metadata_write (&fixture, "in_accel_offset", "2");
	metadata_write (&fixture, "in_accel_x_offset", "0");
	g_assert_cmpint (iioutils_get_param_double (&output, "offset", fixture.directory,
	                                           "in_accel_x", "in_accel"), ==, 0);
	g_assert_cmpfloat (output, ==, 0.0);
	metadata_write (&fixture, "in_accel_x_offset", "-4294967294.875");
	g_assert_cmpint (iioutils_get_param_double (&output, "offset", fixture.directory,
	                                           "in_accel_x", "in_accel"), ==, 0);
	g_assert_cmpfloat (output, ==, -4294967294.875);
	metadata_write (&fixture, "in_accel_x_offset", "1e-9999");
	output = 123.5;
	g_assert_cmpint (iioutils_get_param_double (&output, "offset", fixture.directory,
	                                           "in_accel_x", "in_accel"), ==, -EINVAL);
	g_assert_cmpfloat (output, ==, 123.5);
	metadata_clear (&fixture);
}

static void
test_type_metadata (void)
{
	MetadataFixture fixture = metadata_new ();
	const char *invalid[] = { "", "le:s0/16>>0", "le:s17/16>>0", "le:s8/24>>0",
		"le:s64/64>>64", "le:s2/64>>63", "le:s8/8>>8", "le:s8/8>>1",
		"xe:s8/8>>0", "le:q8/8>>0", "le:s8/8>>0junk", "le:s8/8X2>>0",
		"le:s8/8>>0X2", "le:s-1/8>>0", "le:s+1/8>>0", "le:s8/0>>0",
		"le:s8/128>>0", "le:s4294967296/64>>0", "le:s8/8>>-1" };
	const struct {
		const char *text;
		unsigned sign, bytes, used, shift, big;
		guint64 mask;
	} valid[] = {
		{ "le:u8/8>>0", 0, 1, 8, 0, 0, 0xff },
		{ "le:s16/16", 1, 2, 16, 0, 0, 0xffff },
		{ "be:s16/32>>8", 1, 4, 16, 8, 1, 0xffff },
		{ "le:u1/64>>63", 0, 8, 1, 63, 0, 1 },
		{ " \tle:s64/64>>0 \n", 1, 8, 64, 0, 0, G_MAXUINT64 }
	};
	unsigned sign, bytes, used, shift, big;
	guint64 mask;

	metadata_write (&fixture, "scan_elements/in_accel_type", "le:u8/8>>0");
	g_assert_true (iioutils_get_type (&sign, &bytes, &used, &shift, &mask, &big,
	                                 fixture.directory, "in_accel_x", "in_accel"));
	g_assert_cmpuint (bytes, ==, 1);
	for (guint i = 0; i < G_N_ELEMENTS (valid); i++) {
		metadata_write (&fixture, "scan_elements/in_accel_x_type", valid[i].text);
		g_assert_true (iioutils_get_type (&sign, &bytes, &used, &shift, &mask, &big,
		                                 fixture.directory, "in_accel_x", "in_accel"));
		g_assert_cmpuint (sign, ==, valid[i].sign);
		g_assert_cmpuint (bytes, ==, valid[i].bytes);
		g_assert_cmpuint (used, ==, valid[i].used);
		g_assert_cmpuint (shift, ==, valid[i].shift);
		g_assert_cmpuint (big, ==, valid[i].big);
		g_assert_true (mask == valid[i].mask);
	}
	for (guint i = 0; i < G_N_ELEMENTS (invalid); i++) {
		metadata_write (&fixture, "scan_elements/in_accel_x_type", invalid[i]);
		/* Valid generic metadata does not hide an explicit invalid type. */
		g_assert_false (iioutils_get_type (&sign, &bytes, &used, &shift, &mask, &big,
		                                  fixture.directory, "in_accel_x", "in_accel"));
	}
	metadata_clear (&fixture);
}

static void
test_channel_construction (void)
{
	MetadataFixture fixture = metadata_new ();
	iio_channel_info **channels;
	int count = 23;
	const char *bad_en[] = { "", "2", "-1", "1junk", "1 0" };
	const char *bad_index[] = { "", "-1", "+1", "1junk", "4294967296" };

	channels = build_channel_array (fixture.directory, &count);
	g_assert_null (channels);
	g_assert_cmpint (count, ==, 0);
	metadata_channel (&fixture, "in_accel_x", "4294967295", "le:u8/8>>0");
	metadata_channel (&fixture, "in_accel_y", "0", "le:s16/16>>0");
	metadata_write (&fixture, "scan_elements/in_disabled_en", "0");
	channels = build_channel_array (fixture.directory, &count);
	g_assert_nonnull (channels);
	g_assert_cmpint (count, ==, 2);
	g_assert_cmpuint (channels[0]->index, ==, 0);
	g_assert_cmpuint (channels[1]->index, ==, G_MAXUINT);
	g_assert_cmpfloat (channels[0]->scale, ==, 1.0);
	g_assert_cmpfloat (channels[0]->offset, ==, 0.0);
	channels_free (channels, count);
	metadata_write (&fixture, "scan_elements/in_accel_x_index", "0");
	channels = build_channel_array (fixture.directory, &count);
	g_assert_null (channels);
	g_assert_cmpint (count, ==, 0);
	metadata_write (&fixture, "scan_elements/in_accel_x_index", "1");
	for (guint i = 0; i < G_N_ELEMENTS (bad_en); i++) {
		metadata_write (&fixture, "scan_elements/in_accel_x_en", bad_en[i]);
		channels = build_channel_array (fixture.directory, &count);
		g_assert_null (channels);
		g_assert_cmpint (count, ==, 0);
	}
	metadata_write (&fixture, "scan_elements/in_accel_x_en", "1");
	for (guint i = 0; i < G_N_ELEMENTS (bad_index); i++) {
		metadata_write (&fixture, "scan_elements/in_accel_x_index", bad_index[i]);
		channels = build_channel_array (fixture.directory, &count);
		g_assert_null (channels);
		g_assert_cmpint (count, ==, 0);
	}
	metadata_write (&fixture, "scan_elements/in_accel_x_index", "1");
	/* Zero is a valid parsed number (and offset), but never a scale.
	 * These construction checks include the scale-specific domain gate. */
	const char *bad_scale[] = { "0", "nan", "inf", "1junk", "1e-9999" };
	for (guint i = 0; i < G_N_ELEMENTS (bad_scale); i++) {
		metadata_write (&fixture, "in_accel_x_scale", bad_scale[i]);
		channels = build_channel_array (fixture.directory, &count);
		g_assert_null (channels);
		g_assert_cmpint (count, ==, 0);
	}
	metadata_write (&fixture, "in_accel_x_scale", "1");
	metadata_write (&fixture, "in_accel_offset", "2");
	metadata_write (&fixture, "in_accel_x_offset", "1junk");
	channels = build_channel_array (fixture.directory, &count);
	g_assert_null (channels);
	g_assert_cmpint (count, ==, 0);
	metadata_clear (&fixture);
}

static iio_channel_info
channel_for (unsigned bytes)
{
	iio_channel_info channel = { 0 };

	channel.name = "in_accel_x";
	channel.scale = 1.0;
	channel.bytes = bytes;
	channel.bits_used = bytes * 8;
	channel.mask = bytes == 8 ? G_MAXUINT64 : (G_GUINT64_CONSTANT (1) << (bytes * 8)) - 1;
	return channel;
}

static void
test_empty_channel_name (void)
{
	MetadataFixture fixture = metadata_new ();
	iio_channel_info **channels;
	int count = 23;

	/* Supply otherwise valid metadata so failure cannot be attributed to
	 * missing type/index files instead of the empty stripped channel name. */
	metadata_channel (&fixture, "", "0", "le:u8/8>>0");
	channels = build_channel_array (fixture.directory, &count);
	g_assert_null (channels);
	g_assert_cmpint (count, ==, 0);
	metadata_clear (&fixture);
}

static void
test_layout (void)
{
	iio_channel_info a = channel_for (8), b = channel_for (1), c = channel_for (2);
	iio_channel_info *channels[] = { &a, &b, &c };

	g_assert_cmpint (size_from_channelarray (channels, 3), ==, 16);
	g_assert_cmpuint (a.location, ==, 0);
	g_assert_cmpuint (b.location, ==, 8);
	g_assert_cmpuint (c.location, ==, 10);
	g_assert_cmpint (size_from_channelarray (channels, 0), ==, -1);
	/* Impossible count must be rejected before reading the pointer table:
	 * even one byte per entry exceeds the fixed127-batch integer bound. */
	g_assert_cmpint (size_from_channelarray (channels, G_MAXINT / 127 + 1), ==, -1);
	a.bytes = 3;
	g_assert_cmpint (size_from_channelarray (channels, 3), ==, -1);
	a.bytes = G_MAXUINT;
	g_assert_cmpint (size_from_channelarray (channels, 3), ==, -1);
	a = channel_for (1);
	b = channel_for (1);
	c = channel_for (1);
	g_assert_cmpint (size_from_channelarray (channels, 3), ==, 3);
	g_assert_cmpuint (a.location, ==, 0);
	g_assert_cmpuint (b.location, ==, 1);
	g_assert_cmpuint (c.location, ==, 2);
}

static void
encode_word (guint8 *data, unsigned bytes, guint64 value, gboolean big)
{
	for (unsigned i = 0; i < bytes; i++)
		data[big ? bytes - 1 - i : i] = (guint8) (value >> (i * 8));
}

static void
test_decode_values (void)
{
	const struct {
		unsigned bytes, used, shift;
		gboolean sign, big;
		guint64 stored;
		gdouble offset, scale, expected;
	} cases[] = {
		{ 1, 8, 0, TRUE, FALSE, 0x80, 0.0, 1.0, -128.0 },
		{ 1, 8, 0, FALSE, TRUE, 0xff, 0.0, 1.0, 255.0 },
		{ 1, 7, 1, TRUE, FALSE, 0x80, 0.0, 1.0, -64.0 },
		{ 2, 16, 0, TRUE, TRUE, 0x8000, 0.0, 1.0, -32768.0 },
		{ 4, 16, 8, TRUE, FALSE, 0x00800000, 0.0, 1.0, -32768.0 },
		{ 4, 32, 0, TRUE, FALSE, 0x80000000, 0.0, 1.0, -2147483648.0 },
		{ 4, 32, 0, TRUE, FALSE, 0x7fffffff, 0.0, 1.0, 2147483647.0 },
		{ 4, 32, 0, FALSE, TRUE, 0x80000000, 0.0, 1.0, 2147483648.0 },
		{ 4, 32, 0, FALSE, FALSE, 0xffffffff, 0.0, 1.0, 4294967295.0 },
		{ 4, 32, 0, FALSE, FALSE, 0xffffffff, -4294967294.875, 0.25, 0.125 },
		{ 8, 64, 0, TRUE, TRUE, G_GUINT64_CONSTANT (0x8000000000000000), 0.0, 1.0, -0x1p63 },
		{ 8, 64, 0, TRUE, FALSE, G_GUINT64_CONSTANT (0x7fffffffffffffff), 0.0, 1.0, 0x1p63 },
		{ 8, 64, 0, FALSE, TRUE, G_MAXUINT64, 0.0, 1.0, 0x1p64 },
		{ 8, 1, 63, FALSE, FALSE, G_GUINT64_CONSTANT (0x8000000000000000), 0.0, 1.0, 1.0 },
		{ 8, 1, 63, TRUE, TRUE, G_GUINT64_CONSTANT (0x8000000000000000), 0.0, 1.0, -1.0 },
		{ 1, 8, 0, TRUE, FALSE, 0, -0.5, DBL_MIN / 2.0, -0.5 },
		{ 1, 8, 0, FALSE, FALSE, 1, 0.5, -2.0, 1.5 }
	};

	for (guint i = 0; i < G_N_ELEMENTS (cases); i++) {
		union { guint64 alignment; guint8 bytes[32]; } storage = { 0 };
		guint8 *unaligned = storage.bytes + 1;
		iio_channel_info channel = channel_for (cases[i].bytes);
		iio_channel_info *channels[] = { &channel };
		BufferDrvData buffer = { 0 };
		gdouble raw = 123.5, scale = 456.25;
		gboolean present = FALSE;

		channel.bits_used = cases[i].used;
		channel.shift = cases[i].shift;
		channel.is_signed = cases[i].sign;
		channel.be = cases[i].big;
		channel.offset = cases[i].offset;
		channel.scale = cases[i].scale;
		channel.mask = channel.bits_used == 64 ? G_MAXUINT64 :
			(G_GUINT64_CONSTANT (1) << channel.bits_used) - 1;
		buffer.channels_count = 1;
		buffer.channels = channels;
		buffer.scan_size = (int) channel.bytes;
		encode_word (unaligned, channel.bytes, cases[i].stored, channel.be);
		process_scan_1 ((const char *) unaligned, channel.bytes, &buffer,
		                "in_accel_x", &raw, &scale, &present);
		g_assert_true (present);
		/* Values above 2^53 may round as gdouble; no narrow integer cast. */
		g_assert_cmpfloat (raw, ==, cases[i].expected);
		g_assert_cmpfloat (scale, ==, cases[i].scale);
	}
	/* Nonzero channel location and nonzero offset/scale: decode only the
	 * requested bytes, not the prefix/padding, on an unaligned scan base. */
	{
		union { guint64 alignment; guint8 bytes[16]; } storage = {
			.bytes = { 0xff, 0xaa, 0xbb, 0xcc, 0xdd, 0x03, 0x00 }
		};
		iio_channel_info channel = channel_for (2);
		iio_channel_info *channels[] = { &channel };
		BufferDrvData buffer = { 0 };
		gdouble value = -99, scale = -99;
		gboolean present = FALSE;

		channel.location = 4;
		channel.offset = 0.5;
		channel.scale = 0.25;
		buffer.channels = channels;
		buffer.channels_count = 1;
		buffer.scan_size = 6;
		process_scan_1 ((const char *) storage.bytes + 1, 6, &buffer, "in_accel_x", &value, &scale, &present);
		g_assert_true (present);
		g_assert_cmpfloat (value, ==, 3.5);
		g_assert_cmpfloat (scale, ==, 0.25);
	}
}

static void
assert_decode_rejected (const char *data, gsize length, BufferDrvData *buffer,
			const char *name)
{
	gdouble raw = 123.5, scale = 456.25;
	gboolean present = TRUE;

	process_scan_1 (data, length, buffer, name, &raw, &scale, &present);
	g_assert_false (present);
	g_assert_cmpfloat (raw, ==, 123.5);
	g_assert_cmpfloat (scale, ==, 456.25);
}

static void
test_decode_rejections (void)
{
	char bytes[16] = { 0 };
	iio_channel_info channel = channel_for (8);
	iio_channel_info *channels[] = { &channel };
	BufferDrvData buffer = { 0 };
	const gdouble invalid[] = { NAN, INFINITY, -INFINITY };

	buffer.channels_count = 1;
	buffer.channels = channels;
	buffer.scan_size = 8;
	assert_decode_rejected (bytes, 7, &buffer, "in_accel_x");
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_missing");
	channel.location = 1;
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
	channel.location = G_MAXUINT;
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
	channel.location = 0;
	buffer.scan_size = 0;
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
	buffer.scan_size = -1;
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
	buffer.scan_size = 8;
	for (guint i = 0; i < G_N_ELEMENTS (invalid); i++) {
		channel.offset = invalid[i];
		assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
		channel.offset = 0.0;
		channel.scale = invalid[i];
		assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
	}
	channel.scale = 0.0;
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
	channel = channel_for (8);
	channel.bits_used = 0;
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
	channel = channel_for (8);
	channel.shift = 64;
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
	channel = channel_for (8);
	channel.mask = 0xff;
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
	channel = channel_for (8);
	channel.bytes = 3;
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
	channel = channel_for (8);
	channel.bits_used = 2;
	channel.shift = 63;
	channel.mask = 3;
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
	channel = channel_for (8);
	channel.is_signed = 2;
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
	channel = channel_for (8);
	channel.be = 2;
	assert_decode_rejected (bytes, sizeof bytes, &buffer, "in_accel_x");
}

int
main (int argc, char **argv)
{
	g_test_init (&argc, &argv, NULL);
	g_test_add_func ("/iio-buffer/metadata/numbers", test_metadata_numbers);
	g_test_add_func ("/iio-buffer/metadata/types", test_type_metadata);
	g_test_add_func ("/iio-buffer/metadata/channels", test_channel_construction);
	g_test_add_func ("/iio-buffer/metadata/empty-name", test_empty_channel_name);
	g_test_add_func ("/iio-buffer/layout", test_layout);
	g_test_add_func ("/iio-buffer/decode/values", test_decode_values);
	g_test_add_func ("/iio-buffer/decode/rejections", test_decode_rejections);
	return g_test_run ();
}
