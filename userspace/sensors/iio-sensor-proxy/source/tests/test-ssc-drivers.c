/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * Lifecycle regression tests of the four actual drv-ssc-*.c translation
 * units and actual installed public libssc GObject types.
 *
 * This is not a transport or hardware test. Twelve --wrap seams intercept
 * every constructor/OPEN/CLOSE call from those driver units. Constructor
 * wrappers create bare typed GObjects without GAsyncInitable INIT; OPEN and
 * CLOSE only record fixture effects. Two additional metadata-only seams
 * supply identity/display fixtures instead of consulting a udev device. A
 * fifteenth, forwarding g_signal_lookup seam hides only stream-error for
 * the explicit missing-capability case; all other lookups remain real.
 * Synthetic measurement and inherited stream-error signals below test local
 * handler/error ownership, not DSP data or the native transport state machine.
 * The local startup-failure cases invoke each typed descriptor hook directly;
 * they emit no provider stream-error and do not exercise the proxy's timer.
 * The fixture marks failed admitted OPEN/CLOSE effects as FAULTED: another
 * OPEN is forbidden until an observed successful CLOSE. PENDING is rejected
 * admission, not a fabricated successful operation or a quiescence receipt.
 */

#include <gio/gio.h>
#include <math.h>
#include <string.h>
#include <libssc-sensor-accelerometer.h>
#include <libssc-sensor-light.h>
#include <libssc-sensor-compass.h>
#include <libssc-sensor-proximity.h>

#include "../src/drivers.h"
#include "../src/accel-mount-matrix.h"

extern SensorDriver ssc_accel;
extern SensorDriver ssc_light;
extern SensorDriver ssc_compass;
extern SensorDriver ssc_proximity;

typedef enum {
	KIND_ACCEL,
	KIND_LIGHT,
	KIND_COMPASS,
	KIND_PROXIMITY
} SensorKind;

typedef enum {
	CASE_CONSTRUCTOR_ERROR,
	CASE_CONSTRUCTOR_NO_ERROR,
	CASE_OPEN_ERROR,
	CASE_OPEN_NO_ERROR,
	CASE_IDEMPOTENT,
	CASE_OPEN_REENTRANT_CLOSE,
	CASE_OPEN_REENTRANT_RESTART,
	CASE_FULL_OPEN_ERROR,
	CASE_FULL_OPEN_NO_ERROR,
	CASE_FULL_OPEN_PENDING,
	CASE_FULL_CLOSE_ERROR,
	CASE_FULL_CLOSE_NO_ERROR,
	CASE_FULL_CLOSE_PENDING,
	CASE_FULL_PRIMARY_AND_CLEANUP_ERRORS,
	CASE_FULL_NESTED_STOP,
	CASE_FULL_NESTED_RESTART,
	CASE_STREAM_BEFORE_READING,
	CASE_STREAM_AFTER_READING,
	CASE_STREAM_DUPLICATE,
	CASE_STREAM_CLOSE_ERROR,
	CASE_STREAM_OPEN_TRUE,
	CASE_STREAM_OPEN_ERROR,
	CASE_STREAM_OPEN_CLOSE_ERROR,
	CASE_STREAM_OPEN_PENDING,
	CASE_STREAM_OPEN_DISPATCH,
	CASE_STREAM_STOP_BEFORE_IDLE,
	CASE_STREAM_DETACH_BEFORE_IDLE,
	CASE_STREAM_CALLBACK_DETACH,
	CASE_STREAM_CALLBACK_REENTRY,
	CASE_STREAM_MISSING_SIGNAL,
	CASE_STARTUP_TIMEOUT,
	CASE_STARTUP_DUPLICATE,
	CASE_STARTUP_CLOSE_ERROR,
	CASE_STARTUP_CALLBACK_DETACH,
	CASE_STARTUP_CALLBACK_REENTRY,
	CASE_STARTUP_DETACH_BEFORE_IDLE,
	N_CASES
} CaseKind;

typedef enum {
	NATIVE_OK,
	NATIVE_ERROR,
	NATIVE_NO_ERROR,
	NATIVE_PENDING
} NativeResult;

typedef struct {
	SensorKind kind;
	const char *name;
	const char *log_name;
	SensorDriver *driver;
} DriverSpec;

typedef struct {
	const DriverSpec *spec;
	CaseKind kind;
} TestCase;

typedef struct {
	const TestCase *test_case;
	GMainContext *context;
	SensorDevice *device;
	GObject *sensor; /* weak: the actual driver owns the constructor result */
	guint constructor_calls;
	guint open_calls;
	guint close_calls;
	guint constructed;
	guint finalized;
	guint measurements;
	guint matrix_calls;
	guint location_calls;
	NativeResult open_result;
	NativeResult close_result;
	gboolean native_faulted;
	gboolean in_native_open;
	gboolean in_native_close;
	gboolean reentered;
	guint nested_stops;
	guint nested_starts;
	guint stream_signals;
	guint error_notifications;
	guint ready_notifications;
	guint hidden_signal_lookups;
	gboolean capture_numeric;
	const AccelVec3 *numeric_matrix;
	AccelVec3 *provided_matrix; /* borrowed: the actual accel driver owns it */
	AccelReadings accel_reading;
	LightReadings light_reading;
	CompassReadings compass_reading;
	ProximityReadings proximity_reading;
	gboolean missing_stream_signal;
	gboolean fault_during_close;
	GError *first_notified_error; /* preserves the initial borrowed-error copy */
	GError *notified_error; /* owned callback copy, never the borrowed argument */
	GString *effects;
} Fixture;

static Fixture *active_fixture;

static void emit_fixture_measurement (Fixture *fixture);
static void emit_fixture_stream_error (Fixture *fixture);

static const DriverSpec driver_specs[] = {
	{ KIND_ACCEL, "accel", "accelerometer", &ssc_accel },
	{ KIND_LIGHT, "light", "light", &ssc_light },
	{ KIND_COMPASS, "compass", "compass", &ssc_compass },
	{ KIND_PROXIMITY, "proximity", "proximity", &ssc_proximity }
};

static void
sensor_finalized_cb (gpointer data, GObject *where_object_was)
{
	Fixture *fixture = data;
	(void) where_object_was;
	fixture->finalized++;
}

static void
assert_effect_arguments (SensorKind kind, GCancellable *cancellable, GError **error)
{
	g_assert_nonnull (active_fixture);
	g_assert_cmpint (active_fixture->test_case->spec->kind, ==, kind);
	g_assert_null (cancellable);
	g_assert_nonnull (error);
	g_assert_null (*error);
}

static gpointer
fixture_constructor (SensorKind kind, GType type, const char *data_type,
		     GCancellable *cancellable, GError **error)
{
	Fixture *fixture = active_fixture;
	GObject *sensor;

	assert_effect_arguments (kind, cancellable, error);
	fixture->constructor_calls++;
	if (fixture->test_case->kind == CASE_CONSTRUCTOR_ERROR ||
	    fixture->test_case->kind == CASE_CONSTRUCTOR_NO_ERROR) {
		if (fixture->test_case->kind == CASE_CONSTRUCTOR_ERROR)
			g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
			                     "fixture constructor failure");
		return NULL;
	}

	/* No async INIT: these are the genuine public types, not fake sensors. */
	sensor = g_object_new (type, SSC_SENSOR_DATA_TYPE, data_type, NULL);
	g_assert_null (fixture->sensor);
	fixture->sensor = sensor;
	fixture->constructed++;
	g_object_add_weak_pointer (sensor, (gpointer *) &fixture->sensor);
	g_object_weak_ref (sensor, sensor_finalized_cb, fixture);
	return sensor;
}

static GQuark
fixture_native_error_quark (void)
{
	return g_quark_from_static_string ("ssc-driver-fixture-native-error");
}

static gboolean
fixture_native_result (NativeResult result, gboolean opening, GError **error)
{
	if (result == NATIVE_OK)
		return TRUE;
	if (result == NATIVE_PENDING)
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PENDING,
		                     "fixture native operation pending");
	else if (result == NATIVE_ERROR)
		g_set_error_literal (error, fixture_native_error_quark (), opening ? 73 : 74,
		                     opening ? "fixture open failure" : "fixture close failure");
	return FALSE; /* NATIVE_NO_ERROR deliberately leaves the sink untouched. */
}

static void
fixture_nested_stop (Fixture *fixture, gboolean restart)
{
	g_autoptr(GError) error = NULL;

	fixture->nested_stops++;
	g_assert_false (driver_set_polling_full (fixture->device, FALSE, &error));
	g_assert_error (error, G_IO_ERROR, G_IO_ERROR_PENDING);
	g_assert_cmpstr (error->message, ==, "An SSC polling operation is still pending");
	g_clear_error (&error);
	if (restart) {
		fixture->nested_starts++;
		g_assert_false (driver_set_polling_full (fixture->device, TRUE, &error));
		g_assert_error (error, G_IO_ERROR, G_IO_ERROR_PENDING);
	}
}

static gboolean
fixture_open (SensorKind kind, gpointer sensor, GCancellable *cancellable, GError **error)
{
	Fixture *fixture = active_fixture;
	gboolean success;

	assert_effect_arguments (kind, cancellable, error);
	g_assert_true (sensor == fixture->sensor);
	fixture->open_calls++;
	g_string_append_c (fixture->effects, 'O');
	/* A real native FAULTED stream cannot be retried by handler bookkeeping. */
	g_assert_false (fixture->native_faulted);
	g_assert_false (fixture->in_native_open);
	fixture->in_native_open = TRUE;
	if (!fixture->reentered &&
	    fixture->test_case->kind == CASE_OPEN_REENTRANT_CLOSE) {
		SensorDevice *device = fixture->device;
		g_autofree char *message = g_strdup_printf ("Closing SSC %s sensor failed: *",
		                                           fixture->test_case->spec->log_name);

		fixture->reentered = TRUE;
		fixture->device = NULL;
		/* The real generic close logs its rejected nested STOP and detaches. */
		g_test_expect_message (G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, message);
		driver_close (device);
		g_test_assert_expected_messages ();
	} else if (!fixture->reentered &&
	           (fixture->test_case->kind == CASE_OPEN_REENTRANT_RESTART ||
	            fixture->test_case->kind == CASE_FULL_NESTED_STOP ||
	            fixture->test_case->kind == CASE_FULL_NESTED_RESTART)) {
		fixture->reentered = TRUE;
		fixture_nested_stop (fixture,
		                     fixture->test_case->kind != CASE_FULL_NESTED_STOP);
	}
	if (!fixture->reentered &&
	    (fixture->test_case->kind == CASE_STREAM_OPEN_TRUE ||
	    fixture->test_case->kind == CASE_STREAM_OPEN_ERROR ||
	    fixture->test_case->kind == CASE_STREAM_OPEN_CLOSE_ERROR ||
	    fixture->test_case->kind == CASE_STREAM_OPEN_PENDING ||
	    fixture->test_case->kind == CASE_STREAM_OPEN_DISPATCH)) {
		fixture->reentered = TRUE;
		/* A measurement is allowed before the native OPEN wrapper returns.
		 * It must not turn a subsequent stream fault into successful OPEN. */
		emit_fixture_measurement (fixture);
		emit_fixture_stream_error (fixture);
		if (fixture->test_case->kind == CASE_STREAM_OPEN_DISPATCH) {
			for (guint i = 0; i < 128 && g_main_context_pending (fixture->context); i++)
				g_main_context_iteration (fixture->context, FALSE);
			g_assert_false (g_main_context_pending (fixture->context));
			/* A queued callback must not enter CLOSE through this sync wait. */
			g_assert_cmpuint (fixture->close_calls, ==, 0);
		}
	}
	fixture->in_native_open = FALSE;
	success = fixture_native_result (fixture->open_result, TRUE, error);
	if (!success && fixture->open_result != NATIVE_PENDING)
		fixture->native_faulted = TRUE;
	return success;
}

static gboolean
fixture_close (SensorKind kind, gpointer sensor, GCancellable *cancellable, GError **error)
{
	Fixture *fixture = active_fixture;
	gboolean success;

	assert_effect_arguments (kind, cancellable, error);
	g_assert_true (sensor == fixture->sensor);
	fixture->close_calls++;
	g_string_append_c (fixture->effects, 'C');
	/* The common adapter must not enter native CLOSE while native OPEN runs. */
	g_assert_false (fixture->in_native_open);
	g_assert_false (fixture->in_native_close);
	fixture->in_native_close = TRUE;
	if (fixture->fault_during_close)
		emit_fixture_stream_error (fixture);
	success = fixture_native_result (fixture->close_result, FALSE, error);
	if (success)
		fixture->native_faulted = FALSE;
	else if (fixture->close_result != NATIVE_PENDING)
		fixture->native_faulted = TRUE;
	fixture->in_native_close = FALSE;
	return success;
}

#define WRAP_SENSOR(Type, suffix, kind, type_id, data_type) \
Type *__wrap_ssc_sensor_##suffix##_new_sync (GCancellable *, GError **); \
gboolean __wrap_ssc_sensor_##suffix##_open_sync (Type *, GCancellable *, GError **); \
gboolean __wrap_ssc_sensor_##suffix##_close_sync (Type *, GCancellable *, GError **); \
Type *__wrap_ssc_sensor_##suffix##_new_sync (GCancellable *c, GError **e) \
{ return fixture_constructor (kind, type_id, data_type, c, e); } \
gboolean __wrap_ssc_sensor_##suffix##_open_sync (Type *s, GCancellable *c, GError **e) \
{ return fixture_open (kind, s, c, e); } \
gboolean __wrap_ssc_sensor_##suffix##_close_sync (Type *s, GCancellable *c, GError **e) \
{ return fixture_close (kind, s, c, e); }

WRAP_SENSOR (SSCSensorAccelerometer, accelerometer, KIND_ACCEL,
	     SSC_TYPE_SENSOR_ACCELEROMETER, "accel")
WRAP_SENSOR (SSCSensorLight, light, KIND_LIGHT,
	     SSC_TYPE_SENSOR_LIGHT, "ambient_light")
WRAP_SENSOR (SSCSensorCompass, compass, KIND_COMPASS,
	     SSC_TYPE_SENSOR_COMPASS, "rotv")
WRAP_SENSOR (SSCSensorProximity, proximity, KIND_PROXIMITY,
	     SSC_TYPE_SENSOR_PROXIMITY, "proximity")

guint __real_g_signal_lookup (const gchar *name, GType itype);
guint __wrap_g_signal_lookup (const gchar *name, GType itype);

guint
__wrap_g_signal_lookup (const gchar *name, GType itype)
{
	if (active_fixture && active_fixture->missing_stream_signal &&
	    g_str_equal (name, "stream-error")) {
		g_assert_nonnull (active_fixture->sensor);
		g_assert_true (itype == G_OBJECT_TYPE (active_fixture->sensor));
		active_fixture->hidden_signal_lookups++;
		return 0;
	}
	return __real_g_signal_lookup (name, itype);
}

AccelVec3 *__wrap_setup_mount_matrix (GUdevDevice *device);
AccelLocation __wrap_setup_accel_location (GUdevDevice *device);

AccelVec3 *
__wrap_setup_mount_matrix (GUdevDevice *device)
{
	AccelVec3 *matrix = NULL;

	g_assert_null (device);
	g_assert_nonnull (active_fixture);
	g_assert_cmpint (active_fixture->test_case->spec->kind, ==, KIND_ACCEL);
	active_fixture->matrix_calls++;
	if (active_fixture->numeric_matrix) {
		/* Test-only metadata may deliberately bypass the parser to prove that
		 * the actual measurement boundary rejects an invalid transform. */
		matrix = g_new (AccelVec3, 3);
		memcpy (matrix, active_fixture->numeric_matrix, 3 * sizeof (*matrix));
	} else
		g_assert_true (parse_mount_matrix (NULL, &matrix));
	active_fixture->provided_matrix = matrix;
	return matrix;
}

AccelLocation
__wrap_setup_accel_location (GUdevDevice *device)
{
	g_assert_null (device);
	g_assert_nonnull (active_fixture);
	g_assert_cmpint (active_fixture->test_case->spec->kind, ==, KIND_ACCEL);
	active_fixture->location_calls++;
	return ACCEL_LOCATION_DISPLAY;
}

static guint
measurement_handler_count (Fixture *fixture)
{
	guint signal_id;
	guint blocked, unblocked;
	GSignalMatchType mask = G_SIGNAL_MATCH_ID | G_SIGNAL_MATCH_DATA;

	g_assert_nonnull (fixture->sensor);
	g_assert_nonnull (fixture->device);
	signal_id = g_signal_lookup ("measurement", G_OBJECT_TYPE (fixture->sensor));
	g_assert_cmpuint (signal_id, !=, 0);
	blocked = g_signal_handlers_block_matched (fixture->sensor, mask, signal_id, 0,
	                                           NULL, NULL, fixture->device);
	unblocked = g_signal_handlers_unblock_matched (fixture->sensor, mask, signal_id, 0,
	                                               NULL, NULL, fixture->device);
	g_assert_cmpuint (blocked, ==, unblocked);
	return blocked;
}

static guint
stream_error_handler_count (Fixture *fixture)
{
	guint signal_id;
	guint blocked, unblocked;

	g_assert_nonnull (fixture->sensor);
	/* Bypass only the deliberate capability seam for this observer query. */
	signal_id = __real_g_signal_lookup ("stream-error", G_OBJECT_TYPE (fixture->sensor));
	g_assert_cmpuint (signal_id, !=, 0);
	blocked = g_signal_handlers_block_matched (fixture->sensor, G_SIGNAL_MATCH_ID,
	                                           signal_id, 0, NULL, NULL, NULL);
	unblocked = g_signal_handlers_unblock_matched (fixture->sensor, G_SIGNAL_MATCH_ID,
	                                               signal_id, 0, NULL, NULL, NULL);
	g_assert_cmpuint (blocked, ==, unblocked);
	return blocked;
}

static void
readings_cb (SensorDevice *device, gpointer data, gpointer user_data)
{
	Fixture *fixture = user_data;

	g_assert_true (device == fixture->device);
	g_assert_nonnull (data);
	fixture->measurements++;
	if (fixture->capture_numeric) {
		switch (fixture->test_case->spec->kind) {
		case KIND_ACCEL:
			fixture->accel_reading = *(AccelReadings *) data;
			break;
		case KIND_LIGHT:
			fixture->light_reading = *(LightReadings *) data;
			break;
		case KIND_COMPASS:
			fixture->compass_reading = *(CompassReadings *) data;
			break;
		case KIND_PROXIMITY:
			fixture->proximity_reading = *(ProximityReadings *) data;
			break;
		}
		return;
	}
	switch (fixture->test_case->spec->kind) {
	case KIND_ACCEL: {
		AccelReadings *readings = data;
		g_assert_cmpfloat (readings->accel_x, ==, 4.0);
		g_assert_cmpfloat (readings->accel_y, ==, -5.0);
		g_assert_cmpfloat (readings->accel_z, ==, 6.0);
		g_assert_cmpfloat (readings->scale.x, ==, 1.0);
		g_assert_cmpfloat (readings->scale.y, ==, 1.0);
		g_assert_cmpfloat (readings->scale.z, ==, 1.0);
		break;
	}
	case KIND_LIGHT: {
		LightReadings *readings = data;
		g_assert_cmpfloat (readings->level, ==, 12.25);
		g_assert_true (readings->uses_lux);
		break;
	}
	case KIND_COMPASS:
		g_assert_cmpfloat (((CompassReadings *) data)->heading, ==, 42.5);
		break;
	case KIND_PROXIMITY:
		g_assert_cmpint (((ProximityReadings *) data)->is_near, ==, PROXIMITY_NEAR_TRUE);
		break;
	}
}

static void
emit_fixture_measurement (Fixture *fixture)
{
	switch (fixture->test_case->spec->kind) {
	case KIND_ACCEL:
		g_signal_emit_by_name (fixture->sensor, "measurement", 4.0, -5.0, 6.0);
		break;
	case KIND_LIGHT:
		g_signal_emit_by_name (fixture->sensor, "measurement", 12.25);
		break;
	case KIND_COMPASS:
		g_signal_emit_by_name (fixture->sensor, "measurement", 42.5);
		break;
	case KIND_PROXIMITY:
		g_signal_emit_by_name (fixture->sensor, "measurement", TRUE);
		break;
	}
}

static GQuark
fixture_stream_error_quark (void)
{
	return g_quark_from_static_string ("ssc-driver-fixture-stream-error");
}

static void
emit_fixture_stream_error (Fixture *fixture)
{
	/* Match the provider's retained instance and borrowed emission error.
	 * No private factory, stream ticket, client or transport is involved. */
	g_autoptr(GObject) retained = g_object_ref (fixture->sensor);
	g_autoptr(GError) error = g_error_new_literal (fixture_stream_error_quark (), 81,
	                                             "fixture stream failure");

	fixture->native_faulted = TRUE;
	fixture->stream_signals++;
	g_signal_emit_by_name (retained, "stream-error", error);
}

static void
state_cb (SensorDevice *device, const GError *error, gpointer user_data)
{
	Fixture *fixture = user_data;
	guint open_calls = fixture->open_calls;
	guint close_calls = fixture->close_calls;

	g_assert_true (device == fixture->device);
	if (!error) {
		fixture->ready_notifications++;
		return;
	}
	fixture->error_notifications++;
	if (!fixture->first_notified_error)
		fixture->first_notified_error = g_error_copy (error);
	g_clear_error (&fixture->notified_error);
	fixture->notified_error = g_error_copy (error);
	/* A consumer must copy, not free or retain the borrowed callback pointer. */
	g_assert_true (fixture->notified_error != error);
	if (fixture->test_case->kind == CASE_STREAM_CALLBACK_DETACH) {
		g_autofree char *message = g_strdup_printf ("Closing SSC %s sensor failed: *",
		                                           fixture->test_case->spec->log_name);

		fixture->device = NULL;
		g_test_expect_message (G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, message);
		driver_close (device);
		g_test_assert_expected_messages ();
	} else if (fixture->test_case->kind == CASE_STREAM_CALLBACK_REENTRY) {
		/* Reentrant consumers cannot enter either native operation here. */
		fixture_nested_stop (fixture, TRUE);
		/* A synchronous consumer may also dispatch this exact context while
		 * the common controller is notifying. No native work may enter, and
		 * the borrowed error must remain usable throughout the callback. */
		for (guint i = 0; i < 128; i++) {
			g_main_context_iteration (fixture->context, FALSE);
			g_assert_cmpuint (fixture->open_calls, ==, open_calls);
			g_assert_cmpuint (fixture->close_calls, ==, close_calls);
			if (!g_main_context_pending (fixture->context))
				break;
		}
		g_assert_false (g_main_context_pending (fixture->context));
		g_assert_error (error, fixture_stream_error_quark (), 81);
		g_assert_cmpstr (error->message, ==, "fixture stream failure");
	}
	g_assert_cmpuint (fixture->open_calls, ==, open_calls);
	g_assert_cmpuint (fixture->close_calls, ==, close_calls);
}

static void
assert_stream_error (const GError *error)
{
	g_assert_error (error, fixture_stream_error_quark (), 81);
	g_assert_cmpstr (error->message, ==, "fixture stream failure");
}

static void
assert_stream_cleanup_error (const GError *error)
{
	g_assert_error (error, fixture_stream_error_quark (), 81);
	g_assert_nonnull (strstr (error->message, "fixture stream failure"));
	g_assert_nonnull (strstr (error->message, "SSC recovery CLOSE failed"));
	g_assert_nonnull (strstr (error->message, "fixture close failure"));
}

static void
drain_fixture_context (Fixture *fixture)
{
	/* Deterministic finite local sources only; this is not a sensor timeout. */
	for (guint i = 0; i < 128 && g_main_context_pending (fixture->context); i++)
		g_main_context_iteration (fixture->context, FALSE);
	g_assert_false (g_main_context_pending (fixture->context));
}

static void
expect_failure (const DriverSpec *spec, const char *operation, const char *detail)
{
	g_autofree char *message = g_strdup_printf ("%s SSC %s sensor failed: %s",
	                                            operation, spec->log_name, detail);
	g_test_expect_message (G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, message);
}

static void
assert_native_error (const GError *error, NativeResult result, gboolean opening)
{
	const gint expected_code = opening ? 73 : 74;

	g_assert_nonnull (error);
	if (result == NATIVE_PENDING) {
		g_assert_error (error, G_IO_ERROR, G_IO_ERROR_PENDING);
		g_assert_cmpstr (error->message, ==, "fixture native operation pending");
	} else if (result == NATIVE_NO_ERROR) {
		g_assert_error (error, G_IO_ERROR, G_IO_ERROR_FAILED);
		g_assert_cmpstr (error->message, ==, "unknown error");
	} else {
		g_assert_error (error, fixture_native_error_quark (), expected_code);
		g_assert_nonnull (strstr (error->message,
		                         opening ? "fixture open failure" : "fixture close failure"));
	}
}

static void
assert_poll_ok (Fixture *fixture, gboolean state)
{
	g_autoptr(GError) error = NULL;

	g_assert_true (driver_set_polling_full (fixture->device, state, &error));
	g_assert_no_error (error);
}

static void
cleanup_fixture (Fixture *fixture)
{
	if (fixture->device) {
		SensorDevice *device = fixture->device;

		/* Permit the explicit final teardown, without bypassing needs_close. */
		fixture->close_result = NATIVE_OK;
		fixture->device = NULL;
		driver_close (device);
	}
	/* Bare objects have no transport. Drain only their local disposal work. */
	drain_fixture_context (fixture);
	g_assert_null (fixture->sensor);
	g_assert_cmpuint (fixture->constructed, ==, fixture->finalized);
	g_clear_error (&fixture->first_notified_error);
	g_clear_error (&fixture->notified_error);
	g_string_free (fixture->effects, TRUE);
	g_main_context_pop_thread_default (fixture->context);
	g_main_context_unref (fixture->context);
	active_fixture = NULL;
}

static void
exercise_active_handler (Fixture *fixture, gboolean legacy)
{
	guint open_calls = fixture->open_calls;
	guint close_calls = fixture->close_calls;

	g_assert_cmpuint (measurement_handler_count (fixture), ==, 1);
	emit_fixture_measurement (fixture);
	g_assert_cmpuint (fixture->measurements, ==, 1);
	if (legacy)
		driver_set_polling (fixture->device, TRUE);
	else
		assert_poll_ok (fixture, TRUE);
	g_assert_cmpuint (fixture->open_calls, ==, open_calls);
	g_assert_cmpuint (measurement_handler_count (fixture), ==, 1);
	emit_fixture_measurement (fixture);
	g_assert_cmpuint (fixture->measurements, ==, 2);
	if (legacy)
		driver_set_polling (fixture->device, FALSE);
	else
		assert_poll_ok (fixture, FALSE);
	g_assert_cmpuint (fixture->close_calls, ==, close_calls + 1);
	g_assert_cmpuint (measurement_handler_count (fixture), ==, 0);
	emit_fixture_measurement (fixture);
	g_assert_cmpuint (fixture->measurements, ==, 2);
	if (legacy)
		driver_set_polling (fixture->device, FALSE);
	else
		assert_poll_ok (fixture, FALSE);
	g_assert_cmpuint (fixture->close_calls, ==, close_calls + 1);
	if (legacy)
		driver_set_polling (fixture->device, TRUE);
	else
		assert_poll_ok (fixture, TRUE);
	g_assert_cmpuint (fixture->open_calls, ==, open_calls + 1);
	g_assert_cmpuint (measurement_handler_count (fixture), ==, 1);
	emit_fixture_measurement (fixture);
	g_assert_cmpuint (fixture->measurements, ==, 3);
}

static void
assert_stream_muted (Fixture *fixture)
{
	guint measurements = fixture->measurements;

	g_assert_cmpuint (measurement_handler_count (fixture), ==, 0);
	emit_fixture_measurement (fixture);
	g_assert_cmpuint (fixture->measurements, ==, measurements);
}

static void
test_stream_driver (Fixture *fixture)
{
	CaseKind kind = fixture->test_case->kind;
	g_autoptr(GError) error = NULL;
	guint measurements;

	fixture->device->state_callback = state_cb;
	if (kind == CASE_STREAM_MISSING_SIGNAL) {
		fixture->missing_stream_signal = TRUE;
		g_assert_false (driver_set_polling_full (fixture->device, TRUE, &error));
		g_assert_error (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED);
		g_assert_cmpstr (error->message, ==, "SSC provider lacks the required stream-error signal");
		g_assert_cmpuint (fixture->hidden_signal_lookups, ==, 1);
		g_assert_cmpuint (fixture->open_calls, ==, 0);
		g_assert_cmpuint (fixture->close_calls, ==, 0);
		g_assert_cmpuint (fixture->error_notifications, ==, 0);
		g_assert_cmpuint (stream_error_handler_count (fixture), ==, 0);
		assert_stream_muted (fixture);
		drain_fixture_context (fixture);
		g_assert_cmpstr (fixture->effects->str, ==, "");
		fixture->missing_stream_signal = FALSE;
		g_clear_error (&error);
		assert_poll_ok (fixture, TRUE);
		g_assert_cmpstr (fixture->effects->str, ==, "O");
		g_assert_cmpuint (measurement_handler_count (fixture), ==, 1);
		g_assert_cmpuint (stream_error_handler_count (fixture), ==, 1);
		return;
	}

	if (kind == CASE_STREAM_OPEN_TRUE || kind == CASE_STREAM_OPEN_ERROR ||
	    kind == CASE_STREAM_OPEN_CLOSE_ERROR ||
	    kind == CASE_STREAM_OPEN_PENDING || kind == CASE_STREAM_OPEN_DISPATCH) {
		fixture->open_result = kind == CASE_STREAM_OPEN_ERROR ? NATIVE_ERROR :
		                       kind == CASE_STREAM_OPEN_PENDING ? NATIVE_PENDING : NATIVE_OK;
		if (kind == CASE_STREAM_OPEN_CLOSE_ERROR)
			fixture->close_result = NATIVE_ERROR;
		g_assert_false (driver_set_polling_full (fixture->device, TRUE, &error));
		if (kind == CASE_STREAM_OPEN_CLOSE_ERROR) {
			/* The outer consumer may already have invalidated its OPEN token.
			 * The state callback must still retain and expose failed cleanup. */
			assert_stream_cleanup_error (error);
			g_assert_cmpuint (fixture->measurements, ==, 1);
			g_assert_cmpuint (fixture->stream_signals, ==, 1);
			g_assert_cmpuint (fixture->error_notifications, ==, 2);
			g_assert_cmpuint (fixture->ready_notifications, ==, 0);
			assert_stream_error (fixture->first_notified_error);
			assert_stream_cleanup_error (fixture->notified_error);
			assert_stream_muted (fixture);
			g_assert_true (fixture->native_faulted);
			g_assert_cmpstr (fixture->effects->str, ==, "OC");
			g_assert_cmpuint (stream_error_handler_count (fixture), ==, 0);
			drain_fixture_context (fixture);
			g_assert_cmpuint (fixture->close_calls, ==, 1);
			g_assert_cmpuint (fixture->open_calls, ==, 1);
			g_clear_error (&error);
			/* A manual retry still owes CLOSE; failure cannot start OPEN. */
			g_assert_false (driver_set_polling_full (fixture->device, TRUE, &error));
			assert_native_error (error, NATIVE_ERROR, FALSE);
			g_assert_cmpstr (fixture->effects->str, ==, "OCC");
			g_assert_cmpuint (fixture->error_notifications, ==, 2);
			assert_stream_cleanup_error (fixture->notified_error);
			drain_fixture_context (fixture);
			g_assert_cmpuint (fixture->close_calls, ==, 2);
			g_assert_cmpuint (fixture->open_calls, ==, 1);
			fixture->close_result = NATIVE_OK;
			g_clear_error (&error);
			assert_poll_ok (fixture, TRUE);
			g_assert_cmpstr (fixture->effects->str, ==, "OCCCO");
			g_assert_cmpuint (fixture->ready_notifications, ==, 1);
			g_assert_cmpuint (measurement_handler_count (fixture), ==, 1);
			g_assert_cmpuint (stream_error_handler_count (fixture), ==, 1);
			g_assert_false (fixture->native_faulted);
			return;
		}
		if (kind == CASE_STREAM_OPEN_ERROR || kind == CASE_STREAM_OPEN_PENDING)
			assert_native_error (error, fixture->open_result, TRUE);
		else
			assert_stream_error (error);
		g_assert_cmpuint (fixture->measurements, ==, 1);
		g_assert_cmpuint (fixture->stream_signals, ==, 1);
		g_assert_cmpuint (fixture->error_notifications, ==, 1);
		assert_stream_error (fixture->notified_error);
		assert_stream_muted (fixture);
		/* Rejected native admission with a distinct observed fault keeps a
		 * CLOSE obligation, but must not CLOSE inside the rejected OPEN. */
		g_assert_cmpstr (fixture->effects->str, ==,
		                 kind == CASE_STREAM_OPEN_PENDING ? "O" : "OC");
		g_assert_cmpuint (fixture->close_calls, ==,
		                  kind == CASE_STREAM_OPEN_PENDING ? 0 : 1);
		drain_fixture_context (fixture);
		g_assert_cmpstr (fixture->effects->str, ==, "OC");
		g_assert_cmpuint (fixture->close_calls, ==, 1);
		g_assert_cmpuint (fixture->ready_notifications, ==, 1);
		g_assert_cmpuint (stream_error_handler_count (fixture), ==, 0);
		g_assert_false (fixture->native_faulted);
		fixture->open_result = NATIVE_OK;
		g_clear_error (&error);
		assert_poll_ok (fixture, TRUE);
		g_assert_cmpstr (fixture->effects->str, ==, "OCO");
		g_assert_cmpuint (measurement_handler_count (fixture), ==, 1);
		return;
	}

	assert_poll_ok (fixture, TRUE);
	g_assert_cmpstr (fixture->effects->str, ==, "O");
	g_assert_cmpuint (stream_error_handler_count (fixture), ==, 1);
	if (kind == CASE_STREAM_AFTER_READING)
		emit_fixture_measurement (fixture);
	measurements = fixture->measurements;
	g_assert_cmpuint (measurements, ==, kind == CASE_STREAM_AFTER_READING ? 1 : 0);
	if (kind == CASE_STREAM_CLOSE_ERROR) {
		fixture->close_result = NATIVE_ERROR;
		/* Even a real inherited signal during failed CLOSE must not cause
		 * recursive recovery: common disconnects before the native effect. */
		fixture->fault_during_close = TRUE;
	}
	emit_fixture_stream_error (fixture);
	g_assert_cmpuint (fixture->error_notifications, ==, 1);
	assert_stream_error (fixture->notified_error);
	g_assert_cmpuint (fixture->close_calls, ==, 0);
	g_assert_cmpstr (fixture->effects->str, ==, "O");

	if (kind == CASE_STREAM_CALLBACK_DETACH) {
		g_assert_null (fixture->device);
		g_assert_null (fixture->sensor);
		drain_fixture_context (fixture);
		g_assert_cmpuint (fixture->ready_notifications, ==, 0);
		g_assert_cmpuint (fixture->close_calls, ==, 0);
		return;
	}
	assert_stream_muted (fixture);
	g_assert_cmpuint (fixture->measurements, ==, measurements);
	if (kind == CASE_STREAM_DUPLICATE) {
		emit_fixture_stream_error (fixture);
		g_assert_cmpuint (fixture->stream_signals, ==, 2);
		g_assert_cmpuint (fixture->error_notifications, ==, 1);
		g_assert_cmpuint (fixture->close_calls, ==, 0);
	}
	if (kind == CASE_STREAM_DETACH_BEFORE_IDLE) {
		SensorDevice *device = fixture->device;

		/* Exercise the real destructor's detach, deliberately bypassing
		 * generic STOP. This proves source cancellation, not remote CLOSE. */
		fixture->device = NULL;
		g_clear_pointer (&device->name, g_free);
		fixture->test_case->spec->driver->close (device);
		g_assert_null (fixture->sensor);
		drain_fixture_context (fixture);
		g_assert_cmpuint (fixture->close_calls, ==, 0);
		g_assert_cmpuint (fixture->ready_notifications, ==, 0);
		return;
	}
	if (kind == CASE_STREAM_STOP_BEFORE_IDLE) {
		assert_poll_ok (fixture, FALSE);
		g_assert_cmpstr (fixture->effects->str, ==, "OC");
		g_assert_cmpuint (fixture->ready_notifications, ==, 1);
	}
	if (kind == CASE_STREAM_CALLBACK_REENTRY) {
		g_assert_cmpuint (fixture->nested_stops, ==, 1);
		g_assert_cmpuint (fixture->nested_starts, ==, 1);
	}
	drain_fixture_context (fixture);
	g_assert_cmpstr (fixture->effects->str, ==, "OC");
	g_assert_cmpuint (fixture->open_calls, ==, 1);
	g_assert_cmpuint (fixture->close_calls, ==, 1);
	g_assert_cmpuint (stream_error_handler_count (fixture), ==, 0);
	assert_stream_muted (fixture);
	if (kind == CASE_STREAM_CLOSE_ERROR) {
		/* Preserve the stream primary plus the actual cleanup failure after
		 * the borrowed callback returns; no silent replacement or retry. */
		g_assert_cmpuint (fixture->error_notifications, ==, 2);
		g_assert_error (fixture->notified_error, fixture_stream_error_quark (), 81);
		g_assert_nonnull (strstr (fixture->notified_error->message, "fixture stream failure"));
		g_assert_nonnull (strstr (fixture->notified_error->message, "SSC recovery CLOSE failed"));
		g_assert_nonnull (strstr (fixture->notified_error->message, "fixture close failure"));
		g_assert_cmpuint (fixture->ready_notifications, ==, 0);
		g_assert_cmpuint (fixture->stream_signals, ==, 2);
		g_assert_true (fixture->native_faulted);
		drain_fixture_context (fixture);
		g_assert_cmpuint (fixture->close_calls, ==, 1);
		g_assert_false (driver_set_polling_full (fixture->device, TRUE, &error));
		assert_native_error (error, NATIVE_ERROR, FALSE);
		g_assert_cmpstr (fixture->effects->str, ==, "OCC");
		g_assert_cmpuint (fixture->open_calls, ==, 1);
		drain_fixture_context (fixture);
		g_assert_cmpuint (fixture->close_calls, ==, 2);
		fixture->fault_during_close = FALSE;
		fixture->close_result = NATIVE_OK;
		g_clear_error (&error);
		assert_poll_ok (fixture, TRUE);
		g_assert_cmpstr (fixture->effects->str, ==, "OCCCO");
	} else {
		g_assert_cmpuint (fixture->error_notifications, ==, 1);
		g_assert_cmpuint (fixture->ready_notifications, ==, 1);
		g_assert_false (fixture->native_faulted);
		/* Recovery makes retry possible; it does not automatically OPEN. */
		assert_poll_ok (fixture, TRUE);
		g_assert_cmpstr (fixture->effects->str, ==, "OCO");
	}
	g_assert_cmpuint (fixture->ready_notifications, ==, 1);
	g_assert_cmpuint (measurement_handler_count (fixture), ==, 1);
	g_assert_cmpuint (stream_error_handler_count (fixture), ==, 1);
	g_assert_false (fixture->native_faulted);
}

static void
startup_state_cb (SensorDevice *device, const GError *error, gpointer user_data)
{
	Fixture *fixture = user_data;
	guint open_calls = fixture->open_calls;
	guint close_calls = fixture->close_calls;

	/* Reuse the real borrowed-error observer and its independent copies. */
	state_cb (device, error, user_data);
	if (!error)
		return;
	if (fixture->test_case->kind == CASE_STARTUP_CALLBACK_DETACH) {
		g_autofree char *message = g_strdup_printf ("Closing SSC %s sensor failed: *",
		                                           fixture->test_case->spec->log_name);
		fixture->device = NULL;
		g_test_expect_message (G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, message);
		driver_close (device);
		g_test_assert_expected_messages ();
	} else if (fixture->test_case->kind == CASE_STARTUP_CALLBACK_REENTRY) {
		fixture_nested_stop (fixture, TRUE);
		drain_fixture_context (fixture);
		g_assert_error (error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT);
		g_assert_cmpstr (error->message, ==, "SSC first valid reading deadline expired");
	}
	/* Neither the notification nor nested context dispatch may enter native
	 * CLOSE/OPEN; recovery must wait until after this callback returns. */
	g_assert_cmpuint (fixture->open_calls, ==, open_calls);
	g_assert_cmpuint (fixture->close_calls, ==, close_calls);
}

static void
test_startup_driver (Fixture *fixture)
{
	CaseKind kind = fixture->test_case->kind;
	const DriverSpec *spec = fixture->test_case->spec;
	g_autoptr(GError) timeout = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
		"SSC first valid reading deadline expired");
	g_autoptr(GError) error = NULL;

	g_assert_nonnull (spec->driver->startup_failed);
	fixture->device->state_callback = startup_state_cb;
	assert_poll_ok (fixture, TRUE);
	g_assert_cmpstr (fixture->effects->str, ==, "O");
	g_assert_cmpuint (fixture->measurements, ==, 0);
	g_assert_cmpuint (measurement_handler_count (fixture), ==, 1);
	g_assert_cmpuint (stream_error_handler_count (fixture), ==, 1);
	if (kind == CASE_STARTUP_CLOSE_ERROR)
		fixture->close_result = NATIVE_ERROR;
	/* Exercise each actual typed descriptor hook after successful OPEN.
	 * This is a local startup failure, not an emitted provider stream-error. */
	spec->driver->startup_failed (fixture->device, timeout);
	g_assert_cmpuint (fixture->error_notifications, ==, 1);
	g_assert_error (fixture->notified_error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT);
	g_assert_cmpstr (fixture->notified_error->message, ==, timeout->message);
	g_assert_true (fixture->notified_error != timeout);
	g_assert_true (fixture->first_notified_error != timeout);
	g_assert_cmpuint (fixture->stream_signals, ==, 0);
	g_assert_cmpuint (fixture->open_calls, ==, 1);
	g_assert_cmpuint (fixture->close_calls, ==, 0);
	g_assert_cmpstr (fixture->effects->str, ==, "O");
	if (kind == CASE_STARTUP_CALLBACK_DETACH) {
		g_assert_null (fixture->device);
		g_assert_null (fixture->sensor);
		drain_fixture_context (fixture);
		g_assert_cmpuint (fixture->ready_notifications, ==, 0);
		g_assert_cmpuint (fixture->close_calls, ==, 0);
		return;
	}
	assert_stream_muted (fixture);
	if (kind == CASE_STARTUP_DUPLICATE) {
		spec->driver->startup_failed (fixture->device, timeout);
		g_assert_cmpuint (fixture->error_notifications, ==, 1);
		g_assert_cmpuint (fixture->close_calls, ==, 0);
	}
	if (kind == CASE_STARTUP_DETACH_BEFORE_IDLE) {
		SensorDevice *device = fixture->device;
		fixture->device = NULL;
		g_clear_pointer (&device->name, g_free);
		spec->driver->close (device);
		g_assert_null (fixture->sensor);
		drain_fixture_context (fixture);
		g_assert_cmpuint (fixture->close_calls, ==, 0);
		g_assert_cmpuint (fixture->ready_notifications, ==, 0);
		return;
	}
	if (kind == CASE_STARTUP_CALLBACK_REENTRY) {
		g_assert_cmpuint (fixture->nested_stops, ==, 1);
		g_assert_cmpuint (fixture->nested_starts, ==, 1);
	}
	drain_fixture_context (fixture);
	g_assert_cmpstr (fixture->effects->str, ==, "OC");
	g_assert_cmpuint (fixture->close_calls, ==, 1);
	g_assert_cmpuint (fixture->open_calls, ==, 1);
	g_assert_cmpuint (stream_error_handler_count (fixture), ==, 0);
	assert_stream_muted (fixture);
	if (kind == CASE_STARTUP_CLOSE_ERROR) {
		/* Deferred cleanup must retain both the local timeout and actual
		 * failed CLOSE, and a manual retry must pay CLOSE before new OPEN. */
		g_assert_cmpuint (fixture->error_notifications, ==, 2);
		g_assert_error (fixture->notified_error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT);
		g_assert_nonnull (strstr (fixture->notified_error->message, timeout->message));
		g_assert_nonnull (strstr (fixture->notified_error->message, "SSC recovery CLOSE failed"));
		g_assert_nonnull (strstr (fixture->notified_error->message, "fixture close failure"));
		g_assert_error (fixture->first_notified_error, G_IO_ERROR, G_IO_ERROR_TIMED_OUT);
		g_assert_cmpstr (fixture->first_notified_error->message, ==, timeout->message);
		g_assert_cmpuint (fixture->ready_notifications, ==, 0);
		g_assert_true (fixture->native_faulted);
		drain_fixture_context (fixture);
		g_assert_cmpuint (fixture->close_calls, ==, 1);
		g_assert_false (driver_set_polling_full (fixture->device, TRUE, &error));
		assert_native_error (error, NATIVE_ERROR, FALSE);
		g_assert_cmpstr (fixture->effects->str, ==, "OCC");
		g_assert_cmpuint (fixture->open_calls, ==, 1);
		fixture->close_result = NATIVE_OK;
		g_clear_error (&error);
		assert_poll_ok (fixture, TRUE);
		g_assert_cmpstr (fixture->effects->str, ==, "OCCCO");
	} else {
		g_assert_cmpuint (fixture->error_notifications, ==, 1);
		g_assert_cmpuint (fixture->ready_notifications, ==, 1);
		assert_poll_ok (fixture, TRUE);
		g_assert_cmpstr (fixture->effects->str, ==, "OCO");
	}
	g_assert_cmpuint (fixture->ready_notifications, ==, 1);
	g_assert_cmpuint (measurement_handler_count (fixture), ==, 1);
	g_assert_cmpuint (stream_error_handler_count (fixture), ==, 1);
	g_assert_cmpuint (fixture->stream_signals, ==, 0);
	g_assert_false (fixture->native_faulted);
	emit_fixture_measurement (fixture);
	g_assert_cmpuint (fixture->measurements, ==, 1);
}

static void
test_driver (gconstpointer data)
{
	const TestCase *test_case = data;
	const DriverSpec *spec = test_case->spec;
	Fixture fixture = { 0 };
	g_autoptr(GError) error = NULL;

	fixture.test_case = test_case;
	fixture.context = g_main_context_new ();
	fixture.effects = g_string_new (NULL);
	g_main_context_push_thread_default (fixture.context);
	g_assert_null (active_fixture);
	active_fixture = &fixture;

	if (test_case->kind == CASE_CONSTRUCTOR_ERROR ||
	    test_case->kind == CASE_CONSTRUCTOR_NO_ERROR) {
		expect_failure (spec, "Creating", test_case->kind == CASE_CONSTRUCTOR_ERROR ?
		                "fixture constructor failure" : "unknown error");
		g_assert_null (spec->driver->open (NULL));
		g_test_assert_expected_messages ();
		g_assert_cmpuint (fixture.constructor_calls, ==, 1);
		g_assert_cmpuint (fixture.open_calls, ==, 0);
		g_assert_cmpuint (fixture.close_calls, ==, 0);
		g_assert_cmpuint (fixture.matrix_calls, ==, 0);
		g_assert_cmpuint (fixture.location_calls, ==, 0);
		cleanup_fixture (&fixture);
		return;
	}

	/* Direct descriptor entry bypasses only generic GUdev admission. */
	fixture.device = spec->driver->open (NULL);
	g_assert_nonnull (fixture.device);
	g_assert_nonnull (spec->driver->set_polling_full);
	fixture.device->drv = spec->driver;
	fixture.device->callback_func = readings_cb;
	fixture.device->user_data = &fixture;
	g_assert_cmpuint (fixture.constructor_calls, ==, 1);
	g_assert_cmpuint (fixture.matrix_calls, ==, spec->kind == KIND_ACCEL ? 1 : 0);
	g_assert_cmpuint (fixture.location_calls, ==, spec->kind == KIND_ACCEL ? 1 : 0);
	g_assert_cmpuint (measurement_handler_count (&fixture), ==, 0);
	if (test_case->kind >= CASE_STARTUP_TIMEOUT) {
		test_startup_driver (&fixture);
		cleanup_fixture (&fixture);
		return;
	}
	if (test_case->kind >= CASE_STREAM_BEFORE_READING) {
		test_stream_driver (&fixture);
		cleanup_fixture (&fixture);
		return;
	}

	if (test_case->kind == CASE_OPEN_REENTRANT_CLOSE) {
		fixture.open_result = NATIVE_ERROR;
		g_assert_false (driver_set_polling_full (fixture.device, TRUE, &error));
		assert_native_error (error, NATIVE_ERROR, TRUE);
		g_assert_true (fixture.reentered);
		g_assert_null (fixture.device);
		g_assert_null (fixture.sensor);
		g_assert_cmpuint (fixture.open_calls, ==, 1);
		g_assert_cmpuint (fixture.close_calls, ==, 1);
		g_assert_cmpstr (fixture.effects->str, ==, "OC");
		cleanup_fixture (&fixture);
		return;
	}

	if (test_case->kind == CASE_IDEMPOTENT) {
		driver_set_polling (fixture.device, TRUE);
		g_assert_cmpuint (fixture.open_calls, ==, 1);
		g_assert_cmpuint (fixture.close_calls, ==, 0);
		exercise_active_handler (&fixture, TRUE);
		cleanup_fixture (&fixture);
		return;
	}

	if (test_case->kind == CASE_OPEN_ERROR || test_case->kind == CASE_OPEN_NO_ERROR) {
		fixture.open_result = test_case->kind == CASE_OPEN_ERROR ? NATIVE_ERROR : NATIVE_NO_ERROR;
		expect_failure (spec, "Opening", fixture.open_result == NATIVE_ERROR ?
		                "fixture open failure" : "unknown error");
		driver_set_polling (fixture.device, TRUE);
		g_test_assert_expected_messages ();
		g_assert_cmpuint (fixture.open_calls, ==, 1);
		g_assert_cmpuint (fixture.close_calls, ==, 1);
		g_assert_cmpstr (fixture.effects->str, ==, "OC");
		g_assert_cmpuint (measurement_handler_count (&fixture), ==, 0);
		emit_fixture_measurement (&fixture);
		g_assert_cmpuint (fixture.measurements, ==, 0);
		fixture.open_result = NATIVE_OK;
		driver_set_polling (fixture.device, TRUE);
		g_assert_cmpstr (fixture.effects->str, ==, "OCO");
		exercise_active_handler (&fixture, TRUE);
		cleanup_fixture (&fixture);
		return;
	}

	switch (test_case->kind) {
	case CASE_OPEN_REENTRANT_RESTART:
		fixture.open_result = NATIVE_ERROR;
		g_assert_false (driver_set_polling_full (fixture.device, TRUE, &error));
		assert_native_error (error, NATIVE_ERROR, TRUE);
		g_assert_cmpuint (fixture.nested_stops, ==, 1);
		g_assert_cmpuint (fixture.nested_starts, ==, 1);
		g_assert_cmpuint (fixture.open_calls, ==, 1);
		g_assert_cmpuint (fixture.close_calls, ==, 1);
		g_assert_cmpstr (fixture.effects->str, ==, "OC");
		break;
	case CASE_FULL_OPEN_ERROR:
	case CASE_FULL_OPEN_NO_ERROR:
	case CASE_FULL_OPEN_PENDING:
		fixture.open_result = test_case->kind == CASE_FULL_OPEN_ERROR ? NATIVE_ERROR :
		                      test_case->kind == CASE_FULL_OPEN_NO_ERROR ? NATIVE_NO_ERROR : NATIVE_PENDING;
		g_assert_false (driver_set_polling_full (fixture.device, TRUE, &error));
		assert_native_error (error, fixture.open_result, TRUE);
		g_assert_cmpuint (fixture.open_calls, ==, 1);
		g_assert_cmpuint (fixture.close_calls, ==, fixture.open_result == NATIVE_PENDING ? 0 : 1);
		g_assert_cmpstr (fixture.effects->str, ==, fixture.open_result == NATIVE_PENDING ? "O" : "OC");
		break;
	case CASE_FULL_CLOSE_ERROR:
	case CASE_FULL_CLOSE_NO_ERROR:
	case CASE_FULL_CLOSE_PENDING:
		assert_poll_ok (&fixture, TRUE);
		fixture.close_result = test_case->kind == CASE_FULL_CLOSE_ERROR ? NATIVE_ERROR :
		                       test_case->kind == CASE_FULL_CLOSE_NO_ERROR ? NATIVE_NO_ERROR : NATIVE_PENDING;
		g_assert_false (driver_set_polling_full (fixture.device, FALSE, &error));
		assert_native_error (error, fixture.close_result, FALSE);
		g_assert_cmpuint (measurement_handler_count (&fixture), ==, 0);
		g_assert_cmpstr (fixture.effects->str, ==, "OC");
		fixture.close_result = NATIVE_OK;
		assert_poll_ok (&fixture, FALSE);
		g_assert_cmpstr (fixture.effects->str, ==, "OCC");
		g_assert_cmpuint (fixture.open_calls, ==, 1);
		g_assert_cmpuint (fixture.close_calls, ==, 2);
		break;
	case CASE_FULL_PRIMARY_AND_CLEANUP_ERRORS:
		fixture.open_result = NATIVE_ERROR;
		fixture.close_result = NATIVE_ERROR;
		g_assert_false (driver_set_polling_full (fixture.device, TRUE, &error));
		assert_native_error (error, NATIVE_ERROR, TRUE);
		g_assert_nonnull (strstr (error->message, "SSC recovery CLOSE failed"));
		g_assert_nonnull (strstr (error->message, "fixture close failure"));
		g_assert_true (fixture.native_faulted);
		g_assert_cmpstr (fixture.effects->str, ==, "OC");
		g_clear_error (&error);
		/* A still-failing required CLOSE must prevent another native OPEN. */
		g_assert_false (driver_set_polling_full (fixture.device, TRUE, &error));
		assert_native_error (error, NATIVE_ERROR, FALSE);
		g_assert_cmpuint (fixture.open_calls, ==, 1);
		g_assert_cmpuint (fixture.close_calls, ==, 2);
		g_assert_cmpstr (fixture.effects->str, ==, "OCC");
		fixture.close_result = NATIVE_OK;
		break;
	case CASE_FULL_NESTED_STOP:
	case CASE_FULL_NESTED_RESTART:
		g_assert_false (driver_set_polling_full (fixture.device, TRUE, &error));
		g_assert_error (error, G_IO_ERROR, G_IO_ERROR_CANCELLED);
		g_assert_cmpstr (error->message, ==, "SSC start was cancelled before completion");
		g_assert_cmpuint (fixture.nested_stops, ==, 1);
		g_assert_cmpuint (fixture.nested_starts, ==,
		                  test_case->kind == CASE_FULL_NESTED_RESTART ? 1 : 0);
		g_assert_cmpuint (fixture.open_calls, ==, 1);
		g_assert_cmpuint (fixture.close_calls, ==, 1);
		g_assert_cmpstr (fixture.effects->str, ==, "OC");
		break;
	default:
		g_assert_not_reached ();
	}

	g_assert_cmpuint (measurement_handler_count (&fixture), ==, 0);
	emit_fixture_measurement (&fixture);
	g_assert_cmpuint (fixture.measurements, ==, 0);
	g_clear_error (&error);
	fixture.open_result = NATIVE_OK;
	assert_poll_ok (&fixture, TRUE);
	if (test_case->kind == CASE_FULL_PRIMARY_AND_CLEANUP_ERRORS)
		g_assert_cmpstr (fixture.effects->str, ==, "OCCCO");
	g_assert_false (fixture.native_faulted);
	exercise_active_handler (&fixture, FALSE);
	cleanup_fixture (&fixture);
}

typedef struct {
	SensorKind kind;
	const char *name;
	gfloat value[3];
	gdouble expected[3];
	gboolean valid;
	const AccelVec3 *matrix;
} NumericCase;

static const AccelVec3 numeric_identity[3] = {
	{ 1.0, 0.0, 0.0 }, { 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 }
};
static const AccelVec3 numeric_rotation[3] = {
	{ 0.0, 1.0, 0.0 }, { -1.0, 0.0, 0.0 }, { 0.0, 0.0, 1.0 }
};
static const AccelVec3 numeric_large_matrix[3] = {
	{ 1e200, 0.0, 0.0 }, { 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 }
};
static const AccelVec3 numeric_nan_matrix[3] = {
	{ NAN, 0.0, 0.0 }, { 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 }
};
static const AccelVec3 numeric_posinf_matrix[3] = {
	{ INFINITY, 0.0, 0.0 }, { 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 }
};
static const AccelVec3 numeric_neginf_matrix[3] = {
	{ -INFINITY, 0.0, 0.0 }, { 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 }
};
static const AccelVec3 numeric_overflow_matrix[3] = {
	{ G_MAXDOUBLE, 0.0, 0.0 }, { 0.0, 1.0, 0.0 }, { 0.0, 0.0, 1.0 }
};

static const NumericCase numeric_cases[] = {
	{ KIND_ACCEL, "fractional", { 4.25f, -5.5f, 6.75f }, { 4.25, -5.5, 6.75 }, TRUE, NULL },
	{ KIND_ACCEL, "subunit", { 0.125f, -0.25f, 0.5f }, { 0.125, -0.25, 0.5 }, TRUE, NULL },
	{ KIND_ACCEL, "large-finite", { G_MAXFLOAT, -G_MAXFLOAT, 1.0f }, { G_MAXFLOAT, -G_MAXFLOAT, 1.0 }, TRUE, NULL },
	{ KIND_ACCEL, "beyond-int32", { 2147483648.0f, -2147483648.0f, 2000.0f }, { 2147483648.0, -2147483648.0, 2000.0 }, TRUE, NULL },
	{ KIND_ACCEL, "zero", { 0.0f, 0.0f, 0.0f }, { 0.0, 0.0, 0.0 }, TRUE, NULL },
	{ KIND_ACCEL, "rotated-fractional", { 0.5f, -0.25f, 1.25f }, { -0.25, -0.5, 1.25 }, TRUE, numeric_rotation },
	{ KIND_ACCEL, "large-finite-transform", { G_MAXFLOAT, -0.25f, 1.25f }, { (gdouble) G_MAXFLOAT * 1e200, -0.25, 1.25 }, TRUE, numeric_large_matrix },
	{ KIND_ACCEL, "nan-x", { NAN, 1.0f, 2.0f }, { 0 }, FALSE, NULL },
	{ KIND_ACCEL, "nan-y", { 1.0f, NAN, 2.0f }, { 0 }, FALSE, NULL },
	{ KIND_ACCEL, "nan-z", { 1.0f, 2.0f, NAN }, { 0 }, FALSE, NULL },
	{ KIND_ACCEL, "positive-infinity", { INFINITY, 1.0f, 2.0f }, { 0 }, FALSE, NULL },
	{ KIND_ACCEL, "negative-infinity", { 1.0f, 2.0f, -INFINITY }, { 0 }, FALSE, NULL },
	{ KIND_ACCEL, "nan-matrix", { 1.0f, 2.0f, 3.0f }, { 0 }, FALSE, numeric_nan_matrix },
	{ KIND_ACCEL, "positive-infinity-matrix", { 1.0f, 2.0f, 3.0f }, { 0 }, FALSE, numeric_posinf_matrix },
	{ KIND_ACCEL, "negative-infinity-matrix", { 1.0f, 2.0f, 3.0f }, { 0 }, FALSE, numeric_neginf_matrix },
	{ KIND_ACCEL, "overflowing-transform", { 2.0f, 1.0f, 2.0f }, { 0 }, FALSE, numeric_overflow_matrix },
	{ KIND_LIGHT, "zero", { 0.0f }, { 0.0 }, TRUE, NULL },
	{ KIND_LIGHT, "negative-zero", { -0.0f }, { 0.0 }, TRUE, NULL },
	{ KIND_LIGHT, "fractional", { 0.125f }, { 0.125 }, TRUE, NULL },
	{ KIND_LIGHT, "large-finite", { G_MAXFLOAT }, { G_MAXFLOAT }, TRUE, NULL },
	{ KIND_LIGHT, "negative", { -0.125f }, { 0 }, FALSE, NULL },
	{ KIND_LIGHT, "nan", { NAN }, { 0 }, FALSE, NULL },
	{ KIND_LIGHT, "positive-infinity", { INFINITY }, { 0 }, FALSE, NULL },
	{ KIND_LIGHT, "negative-infinity", { -INFINITY }, { 0 }, FALSE, NULL },
	{ KIND_COMPASS, "zero", { 0.0f }, { 0.0 }, TRUE, NULL },
	{ KIND_COMPASS, "negative-zero", { -0.0f }, { 0.0 }, TRUE, NULL },
	{ KIND_COMPASS, "full-turn", { 360.0f }, { 0.0 }, TRUE, NULL },
	{ KIND_COMPASS, "fractional", { 42.5f }, { 42.5 }, TRUE, NULL },
	{ KIND_COMPASS, "below-full-turn", { 359.99f }, { (gdouble) 359.99f }, TRUE, NULL },
	{ KIND_COMPASS, "negative", { -0.125f }, { 0 }, FALSE, NULL },
	{ KIND_COMPASS, "above-full-turn", { 360.125f }, { 0 }, FALSE, NULL },
	{ KIND_COMPASS, "nan", { NAN }, { 0 }, FALSE, NULL },
	{ KIND_COMPASS, "positive-infinity", { INFINITY }, { 0 }, FALSE, NULL },
	{ KIND_COMPASS, "negative-infinity", { -INFINITY }, { 0 }, FALSE, NULL },
	{ KIND_PROXIMITY, "far", { FALSE }, { PROXIMITY_NEAR_FALSE }, TRUE, NULL },
	{ KIND_PROXIMITY, "near", { TRUE }, { PROXIMITY_NEAR_TRUE }, TRUE, NULL },
	{ KIND_PROXIMITY, "positive-nonzero", { 2 }, { PROXIMITY_NEAR_TRUE }, TRUE, NULL },
	{ KIND_PROXIMITY, "negative-nonzero", { -1 }, { PROXIMITY_NEAR_TRUE }, TRUE, NULL }
};

static void
assert_numeric_reading (Fixture *fixture, const gdouble expected[3])
{
	switch (fixture->test_case->spec->kind) {
	case KIND_ACCEL:
		g_assert_cmpfloat (fixture->accel_reading.accel_x, ==, expected[0]);
		g_assert_cmpfloat (fixture->accel_reading.accel_y, ==, expected[1]);
		g_assert_cmpfloat (fixture->accel_reading.accel_z, ==, expected[2]);
		g_assert_cmpfloat (fixture->accel_reading.scale.x, ==, 1.0);
		g_assert_cmpfloat (fixture->accel_reading.scale.y, ==, 1.0);
		g_assert_cmpfloat (fixture->accel_reading.scale.z, ==, 1.0);
		break;
	case KIND_LIGHT:
		g_assert_cmpfloat (fixture->light_reading.level, ==, expected[0]);
		g_assert_true (fixture->light_reading.uses_lux);
		break;
	case KIND_COMPASS:
		g_assert_cmpfloat (fixture->compass_reading.heading, ==, expected[0]);
		if (expected[0] == 0.0)
			g_assert_false (signbit (fixture->compass_reading.heading));
		break;
	case KIND_PROXIMITY:
		g_assert_cmpint (fixture->proximity_reading.is_near, ==, (int) expected[0]);
		break;
	}
}

static void
test_numeric_driver (gconstpointer data)
{
	const NumericCase *numeric = data;
	const DriverSpec *spec = &driver_specs[numeric->kind];
	const TestCase test_case = { spec, CASE_IDEMPOTENT };
	Fixture fixture = { 0 };
	static const gdouble baseline[][3] = {
		{ 4.0, -5.0, 6.0 }, { 12.25, 0, 0 }, { 42.5, 0, 0 }, { PROXIMITY_NEAR_TRUE, 0, 0 }
	};

	g_assert_cmpint (spec->kind, ==, numeric->kind);
	fixture.test_case = &test_case;
	fixture.capture_numeric = TRUE;
	fixture.numeric_matrix = numeric->matrix;
	fixture.context = g_main_context_new ();
	fixture.effects = g_string_new (NULL);
	g_main_context_push_thread_default (fixture.context);
	g_assert_null (active_fixture);
	active_fixture = &fixture;
	fixture.device = spec->driver->open (NULL);
	g_assert_nonnull (fixture.device);
	fixture.device->drv = spec->driver;
	fixture.device->callback_func = readings_cb;
	fixture.device->user_data = &fixture;
	assert_poll_ok (&fixture, TRUE);
	g_assert_cmpuint (fixture.measurements, ==, 0);
	if (!numeric->valid) {
		const char *message = numeric->kind == KIND_ACCEL ? "Could not apply mount matrix" :
		                      numeric->kind == KIND_LIGHT ? "Ignoring invalid SSC light measurement" :
		                      "Ignoring invalid SSC compass measurement";
		g_test_expect_message (G_LOG_DOMAIN, G_LOG_LEVEL_WARNING, message);
	}
	switch (numeric->kind) {
	case KIND_ACCEL:
		g_signal_emit_by_name (fixture.sensor, "measurement",
		                       numeric->value[0], numeric->value[1], numeric->value[2]);
		break;
	case KIND_LIGHT:
	case KIND_COMPASS:
		g_signal_emit_by_name (fixture.sensor, "measurement", numeric->value[0]);
		break;
	case KIND_PROXIMITY:
		/* G_TYPE_BOOLEAN's argument is an integer; unlike float signals it
		 * must not receive a promoted double through varargs. */
		g_signal_emit_by_name (fixture.sensor, "measurement", (gint) numeric->value[0]);
		break;
	}
	if (!numeric->valid)
		g_test_assert_expected_messages ();
	g_assert_cmpuint (fixture.measurements, ==, numeric->valid ? 1 : 0);
	if (numeric->valid)
		assert_numeric_reading (&fixture, numeric->expected);
	/* These are adapter-callback assertions, not D-Bus Claim completion.
	 * Invalid first data must not be forwarded or consume the next valid
	 * callback; no native restart is needed to receive that fresh reading. */
	if (fixture.provided_matrix)
		memcpy (fixture.provided_matrix, numeric_identity, sizeof (numeric_identity));
	emit_fixture_measurement (&fixture);
	g_assert_cmpuint (fixture.measurements, ==, numeric->valid ? 2 : 1);
	assert_numeric_reading (&fixture, baseline[numeric->kind]);
	g_assert_cmpuint (measurement_handler_count (&fixture), ==, 1);
	g_assert_cmpuint (fixture.open_calls, ==, 1);
	g_assert_cmpuint (fixture.close_calls, ==, 0);
	cleanup_fixture (&fixture);
}

int
main (int argc, char **argv)
{
	static const char *case_names[N_CASES] = {
		"constructor-error", "constructor-no-error",
		"open-error-retry", "open-no-error-retry", "idempotent",
		"open-reentrant-close", "open-reentrant-restart",
		"full-open-error-recovery-retry", "full-open-no-error-recovery-retry",
		"full-open-pending-no-close", "full-close-error-retry",
		"full-close-no-error-retry", "full-close-pending-retry",
		"full-primary-and-cleanup-errors", "full-nested-stop-pending",
		"full-nested-restart-pending",
		"stream-before-first-reading", "stream-after-first-reading",
		"stream-duplicate-one-close", "stream-close-error-manual-retry",
		"stream-open-true-is-failure", "stream-open-error-primary",
		"stream-open-close-error-retained",
		"stream-open-pending-retains-close", "stream-open-nested-dispatch",
		"stream-stop-before-idle", "stream-detach-before-idle",
		"stream-callback-detach", "stream-callback-reentry-pending",
		"stream-missing-signal-failclosed",
		"startup-local-timeout-deferred-close", "startup-local-timeout-duplicate",
		"startup-local-timeout-close-error-retry", "startup-local-timeout-callback-detach",
		"startup-local-timeout-callback-reentry", "startup-local-timeout-detach-before-idle"
	};
	TestCase cases[G_N_ELEMENTS (driver_specs) * N_CASES];
	guint next = 0;

	g_test_init (&argc, &argv, NULL);
	for (guint i = 0; i < G_N_ELEMENTS (driver_specs); i++) {
		for (guint j = 0; j < N_CASES; j++) {
			g_autofree char *name = g_strdup_printf ("/ssc-drivers/%s/%s",
			                                         driver_specs[i].name, case_names[j]);
			cases[next].spec = &driver_specs[i];
			cases[next].kind = (CaseKind) j;
			g_test_add_data_func (name, &cases[next], test_driver);
			next++;
		}
	}
	for (guint i = 0; i < G_N_ELEMENTS (numeric_cases); i++) {
		const NumericCase *numeric = &numeric_cases[i];
		g_autofree char *name = g_strdup_printf ("/ssc-drivers/%s/numeric/%s",
		                                         driver_specs[numeric->kind].name, numeric->name);
		g_test_add_data_func (name, numeric, test_numeric_driver);
	}
	return g_test_run ();
}
