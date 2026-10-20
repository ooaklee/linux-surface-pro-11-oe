/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Software provider seam for the actual proxy test daemon, never installed.
 * Only typed SSC construction/OPEN/CLOSE are wrapped. Claim bookkeeping,
 * D-Bus, udev, polling ownership and driver callbacks are production code. */
#include <gio/gio.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include <libssc-sensor-accelerometer.h>
#include <libssc-sensor-light.h>
#include <libssc-sensor-compass.h>
#include <libssc-sensor-proximity.h>

typedef enum { FIXTURE_CLOSED, FIXTURE_OPENING, FIXTURE_OPEN, FIXTURE_FAULTED } FixtureState;
typedef struct {
	guint id;
	FixtureState state;
	guint trigger_id;
} FixtureSensor;

static guint next_id;
static guint error_emit_depth;

static const char *
fixture_directory (void)
{
	const char *directory = g_getenv ("SSC_CLAIM_FIXTURE_DIR");
	if (!directory || !g_file_test (directory, G_FILE_TEST_IS_DIR))
		g_error ("The test-only SSC provider requires its explicit fixture directory");
	return directory;
}

static void
trace (FixtureSensor *sensor, const char *event, const char *detail)
{
	g_autofree char *path = g_build_filename (fixture_directory (), "trace", NULL);
	FILE *stream = fopen (path, "a");
	if (!stream)
		g_error ("Cannot write test-only provider trace");
	fprintf (stream, "%u %s %s\n", sensor->id, event, detail ? detail : "-");
	if (fclose (stream) != 0)
		g_error ("Cannot finish test-only provider trace");
}

static FixtureSensor *
fixture_state (GObject *sensor)
{
	FixtureSensor *state = g_object_get_data (sensor, "ssc-claim-test-provider");
	g_assert (state != NULL);
	return state;
}

static GObject *
fixture_new (GType type);

static gboolean
wait_gate (FixtureSensor *state, const char *prefix, GError **error)
{
	g_autofree char *leaf = g_strdup_printf ("%s-%u", prefix, state->id);
	g_autofree char *release = g_build_filename (fixture_directory (), leaf, NULL);
	gint64 deadline = g_get_monotonic_time () + 10 * G_USEC_PER_SEC;
	while (!g_file_test (release, G_FILE_TEST_EXISTS)) {
		if (g_get_monotonic_time () >= deadline) {
			trace (state, "GATE_TIMEOUT", prefix);
			g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
				"Test fixture gate was not released");
			return FALSE;
		}
		g_main_context_iteration (NULL, FALSE);
		g_usleep (1000);
	}
	return TRUE;
}

static GObject *
fixture_new (GType type)
{
	GObject *sensor = g_object_new (type, NULL);
	FixtureSensor *state = g_new0 (FixtureSensor, 1);
	g_autofree char *block_path = g_build_filename (fixture_directory (), "construct-block-id", NULL);
	g_autofree char *block = NULL;
	state->id = ++next_id;
	g_object_set_data_full (sensor, "ssc-claim-test-provider", state, g_free);
	trace (state, "NEW", g_type_name (type));
	g_file_get_contents (block_path, &block, NULL, NULL);
	if (block && g_ascii_strtoull (block, NULL, 10) == state->id) {
		trace (state, "CONSTRUCT_BEGIN", NULL);
		if (!wait_gate (state, "construct-release", NULL))
			g_error ("Test constructor gate timed out");
		trace (state, "CONSTRUCT_OK", NULL);
	}
	return sensor;
}

static void
emit_reading (GObject *sensor)
{
	if (SSC_IS_SENSOR_LIGHT (sensor))
		g_signal_emit_by_name (sensor, "measurement", (gfloat) 42.0);
	else if (SSC_IS_SENSOR_ACCELEROMETER (sensor))
		g_signal_emit_by_name (sensor, "measurement", (gfloat) 0.0, (gfloat) -9.8, (gfloat) 0.0);
	else if (SSC_IS_SENSOR_COMPASS (sensor))
		g_signal_emit_by_name (sensor, "measurement", (gfloat) 31.0);
	else if (SSC_IS_SENSOR_PROXIMITY (sensor))
		g_signal_emit_by_name (sensor, "measurement", TRUE);
	else
		g_assert_not_reached ();
}

static void
emit_stream_error (GObject *sensor)
{
	FixtureSensor *state = fixture_state (sensor);
	GError *error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "Injected SSC stream error");
	state->state = FIXTURE_FAULTED;
	trace (state, "STREAM_ERROR", NULL);
	error_emit_depth++;
	g_signal_emit_by_name (sensor, "stream-error", error);
	error_emit_depth--;
	g_error_free (error); /* The production adapter must own its deferred copy. */
	if (SSC_IS_SENSOR_LIGHT (sensor))
		g_signal_emit_by_name (sensor, "measurement", (gfloat) 99.0);
	trace (state, "POST_FAULT_SAMPLE", "99");
}

static gboolean
fault_trigger (gpointer user_data)
{
	GObject *sensor = user_data;
	FixtureSensor *state = fixture_state (sensor);
	g_autofree char *leaf = g_strdup_printf ("fault-%u", state->id);
	g_autofree char *path = g_build_filename (fixture_directory (), leaf, NULL);
	if (!g_file_test (path, G_FILE_TEST_EXISTS))
		return G_SOURCE_CONTINUE;
	state->trigger_id = 0;
	emit_stream_error (sensor);
	return G_SOURCE_REMOVE;
}

static gboolean
reading_trigger (gpointer user_data)
{
	GObject *sensor = user_data;
	FixtureSensor *state = fixture_state (sensor);
	g_autofree char *leaf = g_strdup_printf ("sample-%u", state->id);
	g_autofree char *path = g_build_filename (fixture_directory (), leaf, NULL);
	if (!g_file_test (path, G_FILE_TEST_EXISTS))
		return G_SOURCE_CONTINUE;
	state->trigger_id = 0;
	emit_reading (sensor);
	trace (state, "FRESH_SAMPLE", "42");
	return G_SOURCE_REMOVE;
}

static void
emit_invalid_light_readings (GObject *sensor)
{
	FixtureSensor *state = fixture_state (sensor);
	g_assert_true (SSC_IS_SENSOR_LIGHT (sensor));
	g_signal_emit_by_name (sensor, "measurement", (gfloat) NAN);
	trace (state, "INVALID_SAMPLE", "nan");
	g_signal_emit_by_name (sensor, "measurement", (gfloat) INFINITY);
	trace (state, "INVALID_SAMPLE", "+inf");
	g_signal_emit_by_name (sensor, "measurement", (gfloat) -INFINITY);
	trace (state, "INVALID_SAMPLE", "-inf");
	g_signal_emit_by_name (sensor, "measurement", (gfloat) -0.25f);
	trace (state, "INVALID_SAMPLE", "negative");
}

static gboolean
invalid_reading_trigger (gpointer user_data)
{
	GObject *sensor = user_data;
	FixtureSensor *state = fixture_state (sensor);
	g_assert_cmpint (state->state, ==, FIXTURE_OPEN);
	/* Repeated invalid public signals cannot satisfy or reset the proxy's
	 * deadline. No native decoder failure or stream-error is fabricated. */
	g_signal_emit_by_name (sensor, "measurement", (gfloat) NAN);
	trace (state, "INVALID_SAMPLE", "nan-repeat");
	return G_SOURCE_CONTINUE;
}

static gboolean
fixture_open (GObject *sensor, GError **error)
{
	FixtureSensor *state = fixture_state (sensor);
	g_autofree char *mode_path = g_build_filename (fixture_directory (), "mode", NULL);
	g_autofree char *mode = NULL;
	gboolean failure;
	gboolean stream_fault;

	if (state->state == FIXTURE_FAULTED) {
		trace (state, "OPEN_REJECTED", "requires-CLOSE");
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Fixture fault requires CLOSE before retry");
		return FALSE;
	}
	if (state->state == FIXTURE_OPENING) {
		trace (state, "OPEN_REJECTED", "pending");
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PENDING, "Fixture OPEN still pending");
		return FALSE;
	}
	if (!g_file_get_contents (mode_path, &mode, NULL, NULL))
		mode = g_strdup ("success");
	g_strstrip (mode);
	failure = g_str_has_prefix (mode, "fail") || g_str_has_prefix (mode, "sample-fail");
	stream_fault = g_str_has_prefix (mode, "stream-fault") || g_str_has_prefix (mode, "sample-stream-fault");
	state->state = FIXTURE_OPENING;
	trace (state, "OPEN_BEGIN", mode);
	if (g_str_has_prefix (mode, "sample-fail") || g_str_has_prefix (mode, "sample-stream-fault")) {
		emit_reading (sensor);
		trace (state, "EARLY_SAMPLE", NULL);
	}
	if (stream_fault)
		emit_stream_error (sensor);
	if (g_str_has_suffix (mode, "block")) {
		if (!wait_gate (state, "release", error)) {
			state->state = FIXTURE_FAULTED;
			return FALSE;
		}
	}
	if (failure) {
		state->state = FIXTURE_FAULTED;
		trace (state, "OPEN_FAILED", NULL);
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Injected SSC OPEN failure");
		return FALSE;
	}
	if (stream_fault) {
		/* Native ACK success is not stream success after the emitted fault. */
		trace (state, "OPEN_ACK_TRUE_AFTER_FAULT", NULL);
		return TRUE;
	}
	state->state = FIXTURE_OPEN;
	if (g_str_equal (mode, "invalid-first-trigger") || g_str_equal (mode, "invalid-only-trigger")) {
		/* Deliberately bypass the native decoder through the public signal:
		 * this proves the adapter/proxy first-valid-reading boundary only. */
		emit_invalid_light_readings (sensor);
		trace (state, "OPEN_OK_NO_VALID_SAMPLE", NULL);
		g_assert (state->trigger_id == 0);
		if (g_str_equal (mode, "invalid-only-trigger")) {
			state->trigger_id = g_timeout_add_full (G_PRIORITY_DEFAULT, 40,
				invalid_reading_trigger, g_object_ref (sensor), g_object_unref);
			trace (state, "INVALID_TRIGGER_ARMED", NULL);
		} else {
			state->trigger_id = g_timeout_add_full (G_PRIORITY_DEFAULT, 10,
				reading_trigger, g_object_ref (sensor), g_object_unref);
			trace (state, "READING_TRIGGER_ARMED", NULL);
		}
	} else if (g_str_has_prefix (mode, "silent-reading-trigger")) {
		trace (state, "OPEN_OK_NO_SAMPLE", NULL);
		g_assert (state->trigger_id == 0);
		state->trigger_id = g_timeout_add_full (G_PRIORITY_DEFAULT, 10,
			reading_trigger, g_object_ref (sensor), g_object_unref);
		trace (state, "READING_TRIGGER_ARMED", NULL);
	} else if (g_str_equal (mode, "silent-fault-trigger"))
		trace (state, "OPEN_OK_NO_SAMPLE", NULL);
	else {
		emit_reading (sensor);
		trace (state, "OPEN_OK", NULL);
	}
	if (g_str_equal (mode, "success-fault-trigger") || g_str_equal (mode, "silent-fault-trigger")) {
		g_assert (state->trigger_id == 0);
		state->trigger_id = g_timeout_add_full (G_PRIORITY_DEFAULT, 10,
			fault_trigger, g_object_ref (sensor), g_object_unref);
		trace (state, "FAULT_TRIGGER_ARMED", NULL);
	}
	if (g_str_has_prefix (mode, "silent-reading-trigger") || g_str_equal (mode, "invalid-only-trigger"))
		trace (state, "HEALTHY_OPEN_RETURN", mode);
	return TRUE;
}

static gboolean
fixture_close (GObject *sensor, GError **error)
{
	FixtureSensor *state = fixture_state (sensor);
	g_autofree char *fail_path = g_build_filename (fixture_directory (), "close-fail", NULL);
	g_autofree char *fail_mode = NULL;
	g_autofree char *block_path = g_build_filename (fixture_directory (), "close-block-id", NULL);
	g_autofree char *block = NULL;
	if (error_emit_depth) {
		trace (state, "CLOSE_INSIDE_ERROR", NULL);
		g_error ("Recovery must not issue native CLOSE inside stream-error emission");
	}
	if (state->trigger_id) {
		g_source_remove (state->trigger_id);
		state->trigger_id = 0;
	}
	if (state->state == FIXTURE_OPENING) {
		trace (state, "CLOSE_PENDING", NULL);
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PENDING, "Fixture OPEN still pending");
		return FALSE;
	}
	g_file_get_contents (block_path, &block, NULL, NULL);
	if ((state->state == FIXTURE_FAULTED || state->state == FIXTURE_OPEN) &&
	    block && g_ascii_strtoull (block, NULL, 10) == state->id) {
		trace (state, "CLOSE_BEGIN", NULL);
		if (!wait_gate (state, "close-release", error))
			return FALSE;
	}
	g_file_get_contents (fail_path, &fail_mode, NULL, NULL);
	if ((state->state == FIXTURE_FAULTED || state->state == FIXTURE_OPEN) &&
	    fail_mode && g_str_equal (g_strstrip (fail_mode), "yes")) {
		trace (state, "CLOSE_FAILED", NULL);
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Injected SSC CLOSE failure");
		return FALSE;
	}
	state->state = FIXTURE_CLOSED;
	trace (state, "CLOSE_OK", NULL);
	return TRUE;
}

#define WRAP_SENSOR(lower, Type, type_id) \
Type *__wrap_ssc_sensor_##lower##_new_sync (GCancellable *cancellable, GError **error) \
{ (void) cancellable; (void) error; return (Type *) fixture_new (type_id); } \
gboolean __wrap_ssc_sensor_##lower##_open_sync (Type *sensor, GCancellable *cancellable, GError **error) \
{ (void) cancellable; return fixture_open (G_OBJECT (sensor), error); } \
gboolean __wrap_ssc_sensor_##lower##_close_sync (Type *sensor, GCancellable *cancellable, GError **error) \
{ (void) cancellable; return fixture_close (G_OBJECT (sensor), error); }

WRAP_SENSOR (accelerometer, SSCSensorAccelerometer, SSC_TYPE_SENSOR_ACCELEROMETER)
WRAP_SENSOR (light, SSCSensorLight, SSC_TYPE_SENSOR_LIGHT)
WRAP_SENSOR (compass, SSCSensorCompass, SSC_TYPE_SENSOR_COMPASS)
WRAP_SENSOR (proximity, SSCSensorProximity, SSC_TYPE_SENSOR_PROXIMITY)
