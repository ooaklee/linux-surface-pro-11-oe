/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Only this noninstalled TU replaces input-device I/O. System headers precede
 * the macros so no libc declarations are changed. The actual driver's IioFd
 * automatic cleanup is defined under the close seam, and closes a real owned
 * duplicate of a regular temporary file. No input device or native ioctl is
 * reached; the driver's acquisition, state transitions and callbacks are real. */
#include <glib.h>
#include <gio/gio.h>
#include <gudev/gudev.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <linux/input.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static int input_fixture_open (const char *path, int flags, ...);
static int input_fixture_ioctl (int fd, unsigned long request, ...);
static int input_fixture_close (int fd);

#define open input_fixture_open
#define ioctl input_fixture_ioctl
#define close input_fixture_close
#include "../src/drv-input-accel.c"
#undef open
#undef ioctl
#undef close

GUdevDevice *acquisition_fixture_begin (void);
void acquisition_fixture_end (void);
void register_iio_acquisition_input_tests (void);

typedef struct {
	FILE *backing;
	int active_fd;
	gboolean fail_open;
	int fail_axis;
	int values[3];
	guint opened, acquired, requested, closed, next_axis;
} InputIo;

static InputIo input_io;

static void
input_io_begin (void)
{
	struct stat st;

	g_assert_null (input_io.backing);
	input_io = (InputIo) { .active_fd = -1, .fail_axis = -1,
		.values = { 0, -256, 0 } };
	input_io.backing = tmpfile ();
	g_assert_nonnull (input_io.backing);
	g_assert_cmpint (fstat (fileno (input_io.backing), &st), ==, 0);
	g_assert_true (S_ISREG (st.st_mode));
}

static void
input_io_end (void)
{
	g_assert_nonnull (input_io.backing);
	g_assert_cmpint (input_io.active_fd, ==, -1);
	g_assert_cmpuint (input_io.acquired, ==, input_io.closed);
	g_assert_cmpint (fclose (input_io.backing), ==, 0);
	input_io.backing = NULL;
}

static int
input_fixture_open (const char *path, int flags, ...)
{
	g_assert_nonnull (input_io.backing);
	g_assert_cmpstr (path, ==, "/fixture/no-device-io");
	g_assert_cmpint (flags, ==, O_RDONLY | O_CLOEXEC);
	g_assert_cmpint (input_io.active_fd, ==, -1);
	input_io.opened++;
	if (input_io.fail_open) {
		errno = EACCES;
		return -1;
	}
	input_io.active_fd = fcntl (fileno (input_io.backing), F_DUPFD_CLOEXEC, 3);
	g_assert_cmpint (input_io.active_fd, >=, 3);
	g_assert_true ((fcntl (input_io.active_fd, F_GETFD) & FD_CLOEXEC) != 0);
	input_io.next_axis = 0;
	input_io.acquired++;
	return input_io.active_fd;
}

static int
input_fixture_ioctl (int fd, unsigned long request, ...)
{
	const unsigned long requests[] = {
		EVIOCGABS (ABS_X), EVIOCGABS (ABS_Y), EVIOCGABS (ABS_Z)
	};
	struct input_absinfo *result;
	struct input_absinfo zero = { 0 };
	va_list args;
	guint axis;

	g_assert_nonnull (input_io.backing);
	g_assert_cmpint (fd, ==, input_io.active_fd);
	g_assert_cmpint (fcntl (fd, F_GETFD), >=, 0);
	g_assert_cmpuint (input_io.next_axis, <, G_N_ELEMENTS (requests));
	axis = input_io.next_axis++;
	g_assert_cmpuint (request, ==, requests[axis]);
	va_start (args, request);
	result = va_arg (args, struct input_absinfo *);
	va_end (args);
	g_assert_nonnull (result);
	g_assert_cmpmem (result, sizeof (*result), &zero, sizeof (zero));
	input_io.requested++;
	if ((int) axis == input_io.fail_axis) {
		result->value = 123456; /* No partial failed acquisition may be sent. */
		errno = EIO;
		return -1;
	}
	result->value = input_io.values[axis];
	return 0;
}

static int
input_fixture_close (int fd)
{
	g_assert_nonnull (input_io.backing);
	g_assert_cmpint (fd, ==, input_io.active_fd);
	g_assert_cmpint (fcntl (fd, F_GETFD), >=, 0);
	g_assert_cmpint (close (fd), ==, 0); /* Real libc close, macros ended above. */
	input_io.active_fd = -1;
	input_io.closed++;
	errno = 0;
	g_assert_cmpint (fcntl (fd, F_GETFD), ==, -1);
	g_assert_cmpint (errno, ==, EBADF);
	return 0;
}

typedef struct {
	SensorDevice *sensor;
	guint count;
	AccelReadings last;
	gboolean detach;
	gboolean enabled_at_delivery, event_at_delivery;
	guint source_at_delivery;
	gboolean *emitter_finalized;
	gboolean emitter_alive_after_detach;
} InputCapture;

static void
capture_input_reading (SensorDevice *sensor, gpointer reading, gpointer user_data)
{
	InputCapture *capture = user_data;
	DrvData *data = sensor->priv;

	g_assert_true (sensor == capture->sensor);
	/* The input fd must already be closed, including destructive delivery. */
	g_assert_cmpint (input_io.active_fd, ==, -1);
	g_assert_cmpuint (input_io.acquired, ==, input_io.closed);
	capture->last = *(AccelReadings *) reading;
	capture->count++;
	capture->enabled_at_delivery = data->enabled;
	capture->event_at_delivery = data->sends_kevent;
	capture->source_at_delivery = data->timeout_id;
	if (capture->detach) {
		capture->sensor = NULL;
		input_accel_close (sensor);
		if (capture->emitter_finalized) {
			g_assert_false (*capture->emitter_finalized);
			capture->emitter_alive_after_detach = TRUE;
		}
	}
}

static SensorDevice *
new_input_sensor (GUdevDevice *device, InputCapture *capture)
{
	SensorDevice *sensor = g_new0 (SensorDevice, 1);
	DrvData *data = g_new0 (DrvData, 1);

	sensor->name = g_strdup ("owned synthetic input acquisition");
	sensor->priv = data;
	sensor->callback_func = capture_input_reading;
	sensor->user_data = capture;
	data->dev = g_object_ref (device);
	data->parent = g_object_ref (device);
	data->dev_path = "/fixture/no-device-io";
	g_assert_true (parse_mount_matrix (NULL, &data->mount_matrix));
	capture->sensor = sensor;
	return sensor;
}

static guint
assert_poll_source (SensorDevice *sensor)
{
	DrvData *data = sensor->priv;
	g_assert_true (data->enabled);
	g_assert_false (data->sends_kevent);
	g_assert_cmpuint (data->timeout_id, >, 0);
	g_assert_nonnull (g_main_context_find_source_by_id (NULL, data->timeout_id));
	return data->timeout_id;
}

static void
assert_input_reading (InputCapture *capture, guint count, int x, int y, int z)
{
	g_assert_cmpuint (capture->count, ==, count);
	g_assert_cmpfloat (capture->last.accel_x, ==, x);
	g_assert_cmpfloat (capture->last.accel_y, ==, y);
	g_assert_cmpfloat (capture->last.accel_z, ==, z);
	g_assert_cmpfloat (capture->last.scale.x, ==, 1.0 / 256 * 9.81);
	g_assert_cmpfloat (capture->last.scale.y, ==, 1.0 / 256 * 9.81);
	g_assert_cmpfloat (capture->last.scale.z, ==, 1.0 / 256 * 9.81);
	g_assert_true (capture->enabled_at_delivery);
}

static void
test_input_direct_close (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();

	/* The old close body leaked the SensorDevice and its duplicated name.
	 * Repetition makes that old-body postimage a strong LSan negative control;
	 * these are real allocations/refcounts, not mocked free bookkeeping. */
	for (guint i = 0; i < 128; i++) {
		SensorDevice *sensor = g_new0 (SensorDevice, 1);
		DrvData *data = g_new0 (DrvData, 1);

		sensor->name = g_strdup_printf ("owned-input-name-%u", i);
		sensor->priv = data;
		data->dev = g_object_ref (device);
		data->parent = g_object_ref (device);
		g_assert_true (parse_mount_matrix (NULL, &data->mount_matrix));
		input_accel_close (sensor);
	}
	acquisition_fixture_end ();
}

static gboolean
unexpected_input_timer (gpointer data)
{
	(void) data;
	g_assert_not_reached ();
	return G_SOURCE_REMOVE;
}

static void
test_input_close_stops_owned_timer (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	SensorDevice *sensor = g_new0 (SensorDevice, 1);
	DrvData *data = g_new0 (DrvData, 1);
	guint id;

	sensor->name = g_strdup ("input with an owned timeout");
	sensor->priv = data;
	data->dev = g_object_ref (device);
	data->parent = g_object_ref (device);
	g_assert_true (parse_mount_matrix (NULL, &data->mount_matrix));
	data->timeout_id = id = g_timeout_add (1, unexpected_input_timer, sensor);
	g_assert_nonnull (g_main_context_find_source_by_id (NULL, id));
	input_accel_close (sensor);
	g_assert_null (g_main_context_find_source_by_id (NULL, id));
	while (g_main_context_iteration (NULL, FALSE))
		;
	acquisition_fixture_end ();
}

static void
test_parentless_change_keeps_polling (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	SensorDevice *sensor = g_new0 (SensorDevice, 1);
	DrvData *data = g_new0 (DrvData, 1);
	guint id;

	sensor->name = g_strdup ("parentless input");
	sensor->priv = data;
	data->dev = g_object_ref (device);
	data->dev_path = "/fixture/no-device-io"; /* borrowed, never opened */
	data->enabled = TRUE; /* Reach the parent guard, not the authorization guard. */
	g_assert_null (data->parent);
	data->timeout_id = id = g_timeout_add (60000, unexpected_input_timer, sensor);
	g_assert_nonnull (g_main_context_find_source_by_id (NULL, id));
	/* Exercise the real handler. The existing exact-device GUdev wrappers
	 * reject a NULL query; the old body therefore cannot pass silently. No
	 * parent means no event match, native read, or switch away from polling. */
	uevent_received (NULL, "change", device, sensor);
	g_assert_false (data->sends_kevent);
	g_assert_cmpuint (data->timeout_id, ==, id);
	g_assert_nonnull (g_main_context_find_source_by_id (NULL, id));
	input_accel_close (sensor);
	g_assert_null (g_main_context_find_source_by_id (NULL, id));
	acquisition_fixture_end ();
}

static void
test_unclaimed_and_released_events_do_not_acquire (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { 0 };
	SensorDevice *sensor;
	DrvData *data;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	data = sensor->priv;
	uevent_received (NULL, "change", device, sensor);
	g_assert_cmpuint (input_io.opened, ==, 0);
	g_assert_cmpuint (capture.count, ==, 0);
	g_assert_false (data->sends_kevent);
	g_assert_false (data->enabled);
	g_assert_false (read_accel_poll (sensor));
	g_assert_cmpuint (input_io.opened, ==, 0);
	input_accel_set_polling (sensor, TRUE);
	assert_input_reading (&capture, 1, 0, -256, 0);
	uevent_received (NULL, "add", device, sensor);
	g_assert_cmpuint (input_io.opened, ==, 1);
	uevent_received (NULL, "change", device, sensor);
	g_assert_true (data->sends_kevent);
	g_assert_cmpuint (data->timeout_id, ==, 0);
	input_accel_set_polling (sensor, FALSE);
	g_assert_false (data->enabled); /* Release must work with no timer ID. */
	uevent_received (NULL, "change", device, sensor);
	g_assert_false (read_accel_poll (sensor));
	g_assert_cmpuint (input_io.opened, ==, 2);
	g_assert_cmpuint (input_io.requested, ==, 6);
	assert_input_reading (&capture, 2, 0, -256, 0);
	input_accel_close (sensor);
	input_io_end ();
	acquisition_fixture_end ();
}

static void
test_event_mode_reclaim_gets_fresh_reading (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { 0 };
	SensorDevice *sensor;
	DrvData *data;
	guint old_source;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	data = sensor->priv;
	input_accel_set_polling (sensor, TRUE);
	old_source = assert_poll_source (sensor);
	uevent_received (NULL, "change", device, sensor);
	assert_input_reading (&capture, 2, 0, -256, 0);
	g_assert_true (capture.event_at_delivery);
	g_assert_cmpuint (capture.source_at_delivery, ==, 0);
	g_assert_null (g_main_context_find_source_by_id (NULL, old_source));
	input_accel_set_polling (sensor, FALSE);
	g_assert_false (data->enabled);
	input_io.values[0] = 256;
	input_io.values[1] = 0;
	input_accel_set_polling (sensor, TRUE);
	assert_input_reading (&capture, 3, 256, 0, 0);
	g_assert_true (data->enabled);
	g_assert_true (data->sends_kevent);
	g_assert_cmpuint (data->timeout_id, ==, 0);
	input_accel_set_polling (sensor, TRUE);
	g_assert_cmpuint (capture.count, ==, 3);
	g_assert_cmpuint (input_io.opened, ==, 3);
	g_assert_cmpuint (input_io.requested, ==, 9);
	input_accel_close (sensor);
	input_io_end ();
	acquisition_fixture_end ();
}

static void
test_duplicate_poll_start_is_idempotent (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { 0 };
	SensorDevice *sensor;
	DrvData *data;
	guint first, second;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	data = sensor->priv;
	input_accel_set_polling (sensor, TRUE);
	first = assert_poll_source (sensor);
	input_accel_set_polling (sensor, TRUE);
	g_assert_cmpuint (assert_poll_source (sensor), ==, first);
	g_assert_cmpuint (capture.count, ==, 1);
	g_assert_cmpuint (input_io.opened, ==, 1);
	input_accel_set_polling (sensor, FALSE);
	g_assert_false (data->enabled);
	g_assert_cmpuint (data->timeout_id, ==, 0);
	g_assert_null (g_main_context_find_source_by_id (NULL, first));
	input_accel_set_polling (sensor, FALSE);
	input_accel_set_polling (sensor, TRUE);
	second = assert_poll_source (sensor);
	assert_input_reading (&capture, 2, 0, -256, 0);
	input_accel_close (sensor);
	g_assert_null (g_main_context_find_source_by_id (NULL, second));
	g_assert_cmpuint (input_io.opened, ==, 2);
	input_io_end ();
	acquisition_fixture_end ();
}

static void
test_failed_initial_open_keeps_polling_and_recovers (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { 0 };
	SensorDevice *sensor;
	guint source;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	input_io.fail_open = TRUE;
	g_test_expect_message (NULL, G_LOG_LEVEL_WARNING, "*Could not open input accel*");
	input_accel_set_polling (sensor, TRUE);
	g_test_assert_expected_messages ();
	source = assert_poll_source (sensor);
	g_assert_cmpuint (capture.count, ==, 0);
	g_assert_cmpuint (input_io.opened, ==, 1);
	g_assert_cmpuint (input_io.acquired, ==, 0);
	g_assert_cmpuint (input_io.requested, ==, 0);
	g_assert_cmpuint (input_io.closed, ==, 0);
	input_io.fail_open = FALSE;
	g_assert_true (read_accel_poll (sensor));
	assert_input_reading (&capture, 1, 0, -256, 0);
	g_assert_cmpuint (assert_poll_source (sensor), ==, source);
	uevent_received (NULL, "change", device, sensor);
	assert_input_reading (&capture, 2, 0, -256, 0);
	g_assert_true (capture.event_at_delivery);
	g_assert_cmpuint (capture.source_at_delivery, ==, 0);
	g_assert_null (g_main_context_find_source_by_id (NULL, source));
	input_accel_close (sensor);
	g_assert_cmpuint (input_io.opened, ==, 3);
	g_assert_cmpuint (input_io.acquired, ==, 2);
	g_assert_cmpuint (input_io.requested, ==, 6);
	input_io_end ();
	acquisition_fixture_end ();
}

static void
test_failed_event_keeps_existing_poll_fallback (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { 0 };
	SensorDevice *sensor;
	guint source;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	input_accel_set_polling (sensor, TRUE);
	source = assert_poll_source (sensor);
	input_io.fail_axis = 1;
	uevent_received (NULL, "change", device, sensor);
	g_assert_cmpuint (capture.count, ==, 1);
	g_assert_cmpuint (input_io.opened, ==, 2);
	g_assert_cmpuint (input_io.requested, ==, 5);
	g_assert_cmpuint (input_io.closed, ==, 2);
	g_assert_cmpuint (assert_poll_source (sensor), ==, source);
	input_io.fail_axis = -1;
	input_io.values[2] = 256;
	g_assert_true (read_accel_poll (sensor));
	assert_input_reading (&capture, 2, 0, -256, 256);
	g_assert_cmpuint (assert_poll_source (sensor), ==, source);
	uevent_received (NULL, "change", device, sensor);
	assert_input_reading (&capture, 3, 0, -256, 256);
	g_assert_true (capture.event_at_delivery);
	g_assert_cmpuint (capture.source_at_delivery, ==, 0);
	g_assert_null (g_main_context_find_source_by_id (NULL, source));
	input_accel_close (sensor);
	g_assert_cmpuint (input_io.opened, ==, 4);
	g_assert_cmpuint (input_io.requested, ==, 11);
	input_io_end ();
	acquisition_fixture_end ();
}

static void
test_failed_event_restarts_missing_poll_fallback (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { 0 };
	SensorDevice *sensor;
	DrvData *data;
	guint source;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	data = sensor->priv;
	input_accel_set_polling (sensor, TRUE);
	uevent_received (NULL, "change", device, sensor);
	g_assert_true (data->sends_kevent);
	g_assert_cmpuint (data->timeout_id, ==, 0);
	input_io.fail_axis = 2;
	uevent_received (NULL, "change", device, sensor);
	g_assert_cmpuint (capture.count, ==, 2);
	g_assert_cmpuint (input_io.closed, ==, 3);
	source = assert_poll_source (sensor);
	input_io.fail_axis = -1;
	input_io.values[0] = -256;
	g_assert_true (read_accel_poll (sensor));
	assert_input_reading (&capture, 3, -256, -256, 0);
	g_assert_cmpuint (assert_poll_source (sensor), ==, source);
	uevent_received (NULL, "change", device, sensor);
	assert_input_reading (&capture, 4, -256, -256, 0);
	g_assert_true (capture.event_at_delivery);
	g_assert_cmpuint (capture.source_at_delivery, ==, 0);
	g_assert_null (g_main_context_find_source_by_id (NULL, source));
	input_accel_close (sensor);
	g_assert_cmpuint (input_io.opened, ==, 5);
	g_assert_cmpuint (input_io.requested, ==, 15);
	input_io_end ();
	acquisition_fixture_end ();
}

static void
test_failed_reclaim_read_restarts_poll_fallback (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { 0 };
	SensorDevice *sensor;
	guint source;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	input_accel_set_polling (sensor, TRUE);
	uevent_received (NULL, "change", device, sensor);
	input_accel_set_polling (sensor, FALSE);
	input_io.fail_open = TRUE;
	g_test_expect_message (NULL, G_LOG_LEVEL_WARNING, "*Could not open input accel*");
	input_accel_set_polling (sensor, TRUE);
	g_test_assert_expected_messages ();
	g_assert_cmpuint (capture.count, ==, 2);
	source = assert_poll_source (sensor);
	input_io.fail_open = FALSE;
	input_io.values[1] = 256;
	g_assert_true (read_accel_poll (sensor));
	assert_input_reading (&capture, 3, 0, 256, 0);
	g_assert_cmpuint (assert_poll_source (sensor), ==, source);
	input_accel_close (sensor);
	g_assert_null (g_main_context_find_source_by_id (NULL, source));
	g_assert_cmpuint (input_io.opened, ==, 4);
	g_assert_cmpuint (input_io.acquired, ==, 3);
	g_assert_cmpuint (input_io.requested, ==, 9);
	input_io_end ();
	acquisition_fixture_end ();
}

static void
test_axis_error_closes_fd_without_delivery (gconstpointer argument)
{
	int failed_axis = GPOINTER_TO_INT (argument);
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { 0 };
	SensorDevice *sensor;
	guint source;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	input_io.fail_axis = failed_axis;
	input_accel_set_polling (sensor, TRUE);
	source = assert_poll_source (sensor);
	g_assert_cmpuint (capture.count, ==, 0);
	g_assert_cmpuint (input_io.opened, ==, 1);
	g_assert_cmpuint (input_io.requested, ==, (guint) failed_axis + 1);
	g_assert_cmpuint (input_io.closed, ==, 1);
	input_io.fail_axis = -1;
	g_assert_true (read_accel_poll (sensor));
	assert_input_reading (&capture, 1, 0, -256, 0);
	g_assert_cmpuint (assert_poll_source (sensor), ==, source);
	input_accel_close (sensor);
	g_assert_null (g_main_context_find_source_by_id (NULL, source));
	g_assert_cmpuint (input_io.requested, ==, (guint) failed_axis + 4);
	input_io_end ();
	acquisition_fixture_end ();
}

static void
test_callback_can_detach_during_start (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { .detach = TRUE };
	SensorDevice *sensor;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	input_accel_set_polling (sensor, TRUE);
	g_assert_null (capture.sensor);
	assert_input_reading (&capture, 1, 0, -256, 0);
	g_assert_false (capture.event_at_delivery);
	g_assert_cmpuint (capture.source_at_delivery, >, 0);
	g_assert_null (g_main_context_find_source_by_id (NULL, capture.source_at_delivery));
	g_assert_cmpuint (input_io.opened, ==, 1);
	input_io_end ();
	acquisition_fixture_end ();
}

static void
test_callback_can_detach_during_poll (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { 0 };
	SensorDevice *sensor;
	guint source;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	input_accel_set_polling (sensor, TRUE);
	source = assert_poll_source (sensor);
	capture.detach = TRUE;
	g_assert_true (read_accel_poll (sensor));
	g_assert_null (capture.sensor);
	assert_input_reading (&capture, 2, 0, -256, 0);
	g_assert_cmpuint (capture.source_at_delivery, ==, source);
	g_assert_null (g_main_context_find_source_by_id (NULL, source));
	g_assert_cmpuint (input_io.opened, ==, 2);
	input_io_end ();
	acquisition_fixture_end ();
}

static void
test_callback_can_detach_during_event (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { 0 };
	SensorDevice *sensor;
	guint source;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	input_accel_set_polling (sensor, TRUE);
	source = assert_poll_source (sensor);
	capture.detach = TRUE;
	uevent_received (NULL, "change", device, sensor);
	g_assert_null (capture.sensor);
	assert_input_reading (&capture, 2, 0, -256, 0);
	g_assert_true (capture.event_at_delivery);
	g_assert_cmpuint (capture.source_at_delivery, ==, 0);
	g_assert_null (g_main_context_find_source_by_id (NULL, source));
	g_assert_cmpuint (input_io.opened, ==, 2);
	input_io_end ();
	acquisition_fixture_end ();
}

/* GObject ownership/signal fixture, NOT a native GUdevClient or evidence about
 * its kernel monitor. Only generic g_object_ref/unref and signal APIs touch
 * this stand-in; the real input handler and real driver close remain in use. */
typedef struct { GObject parent_instance; } InputTestEmitter;
typedef struct { GObjectClass parent_class; } InputTestEmitterClass;
GType input_test_emitter_get_type (void);
G_DEFINE_TYPE (InputTestEmitter, input_test_emitter, G_TYPE_OBJECT)
static guint input_test_uevent_signal;

static void
input_test_emitter_class_init (InputTestEmitterClass *klass)
{
	input_test_uevent_signal = g_signal_new ("uevent", G_TYPE_FROM_CLASS (klass),
		G_SIGNAL_RUN_LAST, 0, NULL, NULL, g_cclosure_marshal_generic,
		G_TYPE_NONE, 2, G_TYPE_STRING, G_TYPE_POINTER);
}

static void
input_test_emitter_init (InputTestEmitter *self)
{
	(void) self;
}

static void
input_emitter_finalized (gpointer user_data, GObject *object)
{
	gboolean *finalized = user_data;
	(void) object;
	g_assert_false (*finalized);
	*finalized = TRUE;
}

static InputTestEmitter *
attach_input_emitter (SensorDevice *sensor, gboolean *finalized, gulong *handler)
{
	DrvData *data = sensor->priv;
	InputTestEmitter *emitter = g_object_new (input_test_emitter_get_type (), NULL);

	g_assert_null (data->client);
	*finalized = FALSE;
	g_object_weak_ref (G_OBJECT (emitter), input_emitter_finalized, finalized);
	/* Transfer the only initial reference to the driver's generic owner slot. */
	data->client = (GUdevClient *) emitter;
	*handler = g_signal_connect (emitter, "uevent", G_CALLBACK (uevent_received), sensor);
	g_assert_true (g_signal_handler_is_connected (emitter, *handler));
	return emitter; /* Borrowed until the real driver close drops its reference. */
}

static void
test_signal_emitter_survives_callback_detach (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { 0 };
	SensorDevice *sensor;
	InputTestEmitter *emitter;
	gboolean finalized;
	gulong handler;
	guint source;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	emitter = attach_input_emitter (sensor, &finalized, &handler);
	input_accel_set_polling (sensor, TRUE);
	source = assert_poll_source (sensor);
	capture.detach = TRUE;
	capture.emitter_finalized = &finalized;
	g_signal_emit (emitter, input_test_uevent_signal, 0, "change", device);
	/* emitter was only borrowed and is no longer dereferenced after emission. */
	g_assert_null (capture.sensor);
	g_assert_true (capture.emitter_alive_after_detach);
	g_assert_true (finalized);
	assert_input_reading (&capture, 2, 0, -256, 0);
	g_assert_true (capture.event_at_delivery);
	g_assert_cmpuint (capture.source_at_delivery, ==, 0);
	g_assert_null (g_main_context_find_source_by_id (NULL, source));
	g_assert_cmpuint (input_io.opened, ==, 2);
	input_io_end ();
	acquisition_fixture_end ();
}

static void
test_retained_emitter_disconnects_freed_sensor_handler (void)
{
	GUdevDevice *device = acquisition_fixture_begin ();
	InputCapture capture = { 0 };
	SensorDevice *sensor;
	InputTestEmitter *emitter, *external_owner;
	gboolean finalized;
	gulong handler;

	input_io_begin ();
	sensor = new_input_sensor (device, &capture);
	emitter = attach_input_emitter (sensor, &finalized, &handler);
	external_owner = g_object_ref (emitter);
	input_accel_set_polling (sensor, TRUE);
	g_signal_emit (emitter, input_test_uevent_signal, 0, "change", device);
	assert_input_reading (&capture, 2, 0, -256, 0);
	g_assert_true (g_signal_handler_is_connected (emitter, handler));
	input_accel_close (sensor);
	capture.sensor = NULL;
	g_assert_false (finalized);
	g_assert_false (g_signal_handler_is_connected (emitter, handler));
	/* The external emitter survives, but must not retain freed SensorDevice
	 * callback userdata. A second real signal must perform no input I/O/delivery. */
	g_signal_emit (external_owner, input_test_uevent_signal, 0, "change", device);
	g_assert_cmpuint (capture.count, ==, 2);
	g_assert_cmpuint (input_io.opened, ==, 2);
	g_assert_cmpuint (input_io.requested, ==, 6);
	g_object_unref (external_owner);
	g_assert_true (finalized);
	input_io_end ();
	acquisition_fixture_end ();
}

void
register_iio_acquisition_input_tests (void)
{
	g_test_add_func ("/iio-acquisition/input/direct-close-owned-allocations", test_input_direct_close);
	g_test_add_func ("/iio-acquisition/input/direct-close-stops-owned-timer", test_input_close_stops_owned_timer);
	g_test_add_func ("/iio-acquisition/input/parentless-change-keeps-polling", test_parentless_change_keeps_polling);
	g_test_add_func ("/iio-acquisition/input/unclaimed-and-released-events-no-io", test_unclaimed_and_released_events_do_not_acquire);
	g_test_add_func ("/iio-acquisition/input/event-mode-reclaim-fresh-reading", test_event_mode_reclaim_gets_fresh_reading);
	g_test_add_func ("/iio-acquisition/input/duplicate-poll-start-idempotent", test_duplicate_poll_start_is_idempotent);
	g_test_add_func ("/iio-acquisition/input/initial-open-failure-recovers", test_failed_initial_open_keeps_polling_and_recovers);
	g_test_add_func ("/iio-acquisition/input/failed-event-keeps-poll-fallback", test_failed_event_keeps_existing_poll_fallback);
	g_test_add_func ("/iio-acquisition/input/failed-event-restarts-poll-fallback", test_failed_event_restarts_missing_poll_fallback);
	g_test_add_func ("/iio-acquisition/input/failed-reclaim-restarts-poll-fallback", test_failed_reclaim_read_restarts_poll_fallback);
	g_test_add_data_func ("/iio-acquisition/input/x-ioctl-error-no-delivery", GINT_TO_POINTER (0), test_axis_error_closes_fd_without_delivery);
	g_test_add_data_func ("/iio-acquisition/input/y-ioctl-error-no-delivery", GINT_TO_POINTER (1), test_axis_error_closes_fd_without_delivery);
	g_test_add_data_func ("/iio-acquisition/input/z-ioctl-error-no-delivery", GINT_TO_POINTER (2), test_axis_error_closes_fd_without_delivery);
	g_test_add_func ("/iio-acquisition/input/callback-detach-start", test_callback_can_detach_during_start);
	g_test_add_func ("/iio-acquisition/input/callback-detach-poll", test_callback_can_detach_during_poll);
	g_test_add_func ("/iio-acquisition/input/callback-detach-event", test_callback_can_detach_during_event);
	g_test_add_func ("/iio-acquisition/input/signal-emitter-survives-detach", test_signal_emitter_survives_callback_detach);
	g_test_add_func ("/iio-acquisition/input/retained-emitter-disconnects-handler", test_retained_emitter_disconnects_freed_sensor_handler);
}
