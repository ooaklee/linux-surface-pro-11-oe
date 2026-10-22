/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Include the actual helpers. Only this TU's four named external I/O calls
 * are redirected; no link wraps, global preload or real sysfs access occurs.
 * Real tmpfile FILEs make stdio cleanup safe and are always actually closed.
 * Successful no-op helpers cannot pass: call counts and formatted bytes are
 * asserted, as well as return values and expected diagnostic context. */
#include <stdio.h>
#include <stdarg.h>
#include <errno.h>
#include <string.h>
#include <glib.h>
#include <glib/gstdio.h>

static FILE *fixture_fopen (const char *path, const char *mode);
static int fixture_fprintf (FILE *stream, const char *format, ...) G_GNUC_PRINTF (2, 3);
static int fixture_fclose (FILE *stream);
static gboolean fixture_get_contents (const gchar *path, gchar **contents,
                                      gsize *length, GError **error);

#define fopen fixture_fopen
#define fprintf fixture_fprintf
#define fclose fixture_fclose
#define g_file_get_contents fixture_get_contents
#include "../src/iio-buffer-utils.c"
#undef g_file_get_contents
#undef fclose
#undef fprintf
#undef fopen

typedef enum { VALUE_INT, VALUE_PAIR, VALUE_STRING, VALUE_COUNT } ValueKind;
typedef enum {
	PLAIN_SUCCESS, VERIFY_SUCCESS, OPEN_FAILURE, OPEN_NO_ERRNO,
	WRITE_ERROR_PRESERVES_FIRST, WRITE_ERROR_NO_ERRNO, WRITE_SHORT_NO_ERRNO,
	CLOSE_FAILURE, CLOSE_NO_ERRNO, VERIFY_READ_FAILURE, VERIFY_MISMATCH,
	VERIFY_JUNK, VERIFY_EMBEDDED_NUL, VERIFY_WHITESPACE, SCENARIO_COUNT
} Scenario;

typedef struct { ValueKind kind; Scenario scenario; } TestCase;
typedef struct {
	const char *expected_text;
	const char *readback;
	gsize readback_length;
	FILE *stream;
	gboolean fail_open, fail_write, short_write, fail_close, fail_read;
	int open_errno, write_errno, close_errno;
	guint opens, writes, closes, reads;
} Fixture;

static Fixture *active;

static FILE *
fixture_fopen (const char *path, const char *mode)
{
	g_assert_nonnull (active);
	g_assert_cmpstr (path, ==, "/fixture/sysfs/attribute");
	g_assert_cmpstr (mode, ==, "w");
	g_assert_null (active->stream);
	active->opens++;
	if (active->fail_open) {
		errno = active->open_errno;
		return NULL;
	}
	active->stream = tmpfile ();
	g_assert_nonnull (active->stream);
	errno = 0;
	return active->stream;
}

static int
fixture_fprintf (FILE *stream, const char *format, ...)
{
	va_list args;
	g_autofree char *text = NULL;
	gsize length, written;

	g_assert_nonnull (active);
	g_assert_true (stream == active->stream);
	va_start (args, format);
	text = g_strdup_vprintf (format, args);
	va_end (args);
	g_assert_cmpstr (text, ==, active->expected_text);
	active->writes++;
	if (active->fail_write) {
		errno = active->write_errno;
		return -1;
	}
	length = strlen (text);
	g_assert_cmpuint (length, >, 0);
	g_assert_cmpuint (length, <=, G_MAXINT);
	if (active->short_write)
		length--;
	written = fwrite (text, 1, length, stream);
	g_assert_cmpuint (written, ==, length);
	errno = 0;
	return (int) written;
}

static int
fixture_fclose (FILE *stream)
{
	int result;

	g_assert_nonnull (active);
	g_assert_true (stream == active->stream);
	active->closes++;
	active->stream = NULL;
	result = fclose (stream);
	g_assert_cmpint (result, ==, 0);
	errno = active->close_errno;
	return active->fail_close ? EOF : 0;
}

static gboolean
fixture_get_contents (const gchar *path, gchar **contents, gsize *length, GError **error)
{
	g_assert_nonnull (active);
	g_assert_cmpstr (path, ==, "/fixture/sysfs/attribute");
	g_assert_null (active->stream);
	g_assert_nonnull (contents);
	g_assert_nonnull (length);
	g_assert_nonnull (error);
	g_assert_null (*error);
	active->reads++;
	if (active->fail_read) {
		g_set_error_literal (error, G_FILE_ERROR, G_FILE_ERROR_ACCES,
		                     "fixture injected readback permission failure");
		/* Neither the GLib enum nor this ambient errno is a portable return
		 * contract for g_file_get_contents; the helper must report EIO. */
		errno = ENOTTY;
		return FALSE;
	}
	*contents = g_malloc (active->readback_length + 1);
	memcpy (*contents, active->readback, active->readback_length);
	(*contents)[active->readback_length] = '\0';
	*length = active->readback_length;
	errno = 0;
	return TRUE;
}

static int
call_actual_helper (ValueKind kind, gboolean verify)
{
	switch (kind) {
	case VALUE_INT:
		return verify ? write_sysfs_int_and_verify ("attribute", "/fixture/sysfs", 7) :
		                write_sysfs_int ("attribute", "/fixture/sysfs", 7);
	case VALUE_PAIR:
		return _write_sysfs_int ("attribute", "/fixture/sysfs", 7, verify, 1, 9);
	case VALUE_STRING:
		return verify ? write_sysfs_string_and_verify ("attribute", "/fixture/sysfs", "fixture-trigger") :
		                write_sysfs_string ("attribute", "/fixture/sysfs", "fixture-trigger");
	default:
		g_assert_not_reached ();
	}
}

static void
test_write_case (gconstpointer pointer)
{
	const TestCase *test = pointer;
	const char *values[] = { "7", "7 9", "fixture-trigger" };
	Fixture fixture = { .expected_text = values[test->kind] };
	g_autofree char *readback = NULL;
	g_autofree char *warning = NULL;
	gboolean verify = test->scenario == VERIFY_SUCCESS ||
	                  test->scenario == WRITE_ERROR_PRESERVES_FIRST ||
	                  test->scenario >= VERIFY_READ_FAILURE;
	int expected = 0, result;
	guint expected_reads = test->scenario == VERIFY_SUCCESS ||
	                       test->scenario >= VERIFY_READ_FAILURE ? 1 : 0;

	g_assert_null (active);
	fixture.readback = fixture.expected_text;
	fixture.readback_length = strlen (fixture.readback);
	switch (test->scenario) {
	case OPEN_FAILURE:
		fixture.fail_open = TRUE;
		fixture.open_errno = test->kind == VALUE_INT ? EACCES : test->kind == VALUE_PAIR ? EROFS : EPERM;
		expected = -fixture.open_errno;
		break;
	case OPEN_NO_ERRNO:
		fixture.fail_open = TRUE;
		expected = -EIO;
		break;
	case WRITE_ERROR_PRESERVES_FIRST:
		fixture.fail_write = fixture.fail_close = TRUE;
		fixture.write_errno = ENOSPC;
		fixture.close_errno = EBADF;
		expected = -ENOSPC;
		break;
	case WRITE_ERROR_NO_ERRNO:
		fixture.fail_write = TRUE;
		expected = -EIO;
		break;
	case WRITE_SHORT_NO_ERRNO:
		fixture.short_write = TRUE;
		expected = -EIO;
		break;
	case CLOSE_FAILURE:
		fixture.fail_close = TRUE;
		fixture.close_errno = ENOSPC;
		expected = -ENOSPC;
		break;
	case CLOSE_NO_ERRNO:
		fixture.fail_close = TRUE;
		expected = -EIO;
		break;
	case VERIFY_READ_FAILURE:
		fixture.fail_read = TRUE;
		expected = -EIO;
		warning = g_strdup ("*Could not verify sysfs write*fixture injected readback permission failure*");
		break;
	case VERIFY_MISMATCH:
		fixture.readback = test->kind == VALUE_INT ? "8" : test->kind == VALUE_PAIR ? "7 8" : "other-trigger";
		fixture.readback_length = strlen (fixture.readback);
		expected = -EIO;
		break;
	case VERIFY_JUNK:
		readback = g_strconcat (fixture.expected_text, "junk", NULL);
		fixture.readback = readback;
		fixture.readback_length = strlen (readback);
		expected = -EIO;
		break;
	case VERIFY_EMBEDDED_NUL:
		fixture.readback_length = strlen (fixture.expected_text) + 5;
		readback = g_malloc (fixture.readback_length);
		memcpy (readback, fixture.expected_text, strlen (fixture.expected_text));
		readback[strlen (fixture.expected_text)] = '\0';
		memcpy (readback + strlen (fixture.expected_text) + 1, "junk", 4);
		fixture.readback = readback;
		expected = -EIO;
		break;
	case VERIFY_WHITESPACE:
		readback = g_strconcat (fixture.expected_text, " \n\t", NULL);
		fixture.readback = readback;
		fixture.readback_length = strlen (readback);
		break;
	case PLAIN_SUCCESS:
	case VERIFY_SUCCESS:
		break;
	default:
		g_assert_not_reached ();
	}
	if (expected < 0 && !warning) {
		if (test->scenario >= VERIFY_MISMATCH)
			warning = g_strdup ("*Sysfs write readback mismatch*");
		else
			warning = g_strdup_printf ("*%s*", g_strerror (-expected));
	}
	if (warning)
		g_test_expect_message (NULL, G_LOG_LEVEL_WARNING, warning);
	active = &fixture;
	result = call_actual_helper (test->kind, verify);
	g_assert_cmpint (result, ==, expected);
	if (warning)
		g_test_assert_expected_messages ();
	g_assert_cmpuint (fixture.opens, ==, 1);
	g_assert_cmpuint (fixture.writes, ==, fixture.fail_open ? 0 : 1);
	g_assert_cmpuint (fixture.closes, ==, fixture.fail_open ? 0 : 1);
	g_assert_cmpuint (fixture.reads, ==, expected_reads);
	g_assert_null (fixture.stream);
	active = NULL;
}

int
main (int argc, char **argv)
{
	const char *kinds[] = { "int", "pair", "string" };
	const char *scenarios[] = {
		"plain-success", "verify-success", "open-failure", "open-no-errno",
		"write-error-preserves-first", "write-error-no-errno", "write-short-no-errno",
		"close-failure", "close-no-errno", "verify-read-failure", "verify-mismatch",
		"verify-junk", "verify-embedded-nul", "verify-whitespace"
	};
	static TestCase cases[VALUE_COUNT][SCENARIO_COUNT];

	g_test_init (&argc, &argv, NULL);
	g_assert_cmpuint (G_N_ELEMENTS (scenarios), ==, SCENARIO_COUNT);
	for (guint kind = 0; kind < VALUE_COUNT; kind++) {
		for (guint scenario = 0; scenario < SCENARIO_COUNT; scenario++) {
			g_autofree char *path = g_strdup_printf ("/iio-sysfs-write/%s/%s", kinds[kind], scenarios[scenario]);
			cases[kind][scenario] = (TestCase) { kind, scenario };
			g_test_add_data_func (path, &cases[kind][scenario], test_write_case);
		}
	}
	return g_test_run ();
}
