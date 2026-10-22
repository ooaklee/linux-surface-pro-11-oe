/*
 * libssc: Library to expose Qualcomm Sensor Core sensors
 * Copyright (C) 2022-2026 Dylan Van Assche
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published
 * by the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <glib-unix.h>
#include "libssc-cli-private.h"

#define DEFAULT_ENABLE_SECONDS 10

static void request_stop (SSCCli *cli);
static void begin_close (SSCCli *cli);
static void begin_retire (SSCCli *cli);

static void
clear_source (GSource **source)
{
	if (*source) {
		g_source_destroy (*source);
		g_source_unref (*source);
		*source = NULL;
	}
}

static void
disconnect_observers (SSCCli *cli)
{
	if (cli->sensor) {
		if (cli->measurement_id)
			g_signal_handler_disconnect (cli->sensor, cli->measurement_id);
		if (cli->stream_error_id)
			g_signal_handler_disconnect (cli->sensor, cli->stream_error_id);
	}
	cli->measurement_id = cli->stream_error_id = 0;
}

static void
clear_sensor (SSCCli *cli)
{
	disconnect_observers (cli);
	g_clear_object (&cli->sensor);
	g_clear_object (&cli->retirement_subject);
	g_clear_object (&cli->pending);
	g_clear_object (&cli->diagnostic_result);
}

/* Only the actual terminal receipt callback calls this, after this CLI's
 * genuine logical callbacks/finishes have also been consumed. */
static void
complete (SSCCli *cli)
{
	g_assert (g_main_context_is_owner (cli->context));
	g_assert (cli->state == SSC_CLI_RETIRING && cli->retire_started &&
		cli->invocation == SSC_CLI_INVOCATION_NONE && !cli->pending);
	if (cli->inspect && !cli->inspection_ready) {
		g_printerr ("%s metadata inspection did not complete\n", cli->sensor_name);
		cli->exit_status = EXIT_FAILURE;
	}
	cli->state = SSC_CLI_DONE;
	clear_sensor (cli);
	g_main_loop_quit (cli->loop);
}

static void
error_wait (SSCCli *cli, GAsyncResult *result, const gchar *message)
{
	g_assert (g_main_context_is_owner (cli->context));
	/* Keep only the first diagnostic, without consuming/replacing the pending
	 * invocation. A later genuine callback can still reconcile that operation. */
	if (!cli->diagnostic_result && G_IS_ASYNC_RESULT (result))
		cli->diagnostic_result = g_object_ref (result);
	cli->exit_status = EXIT_FAILURE;
	cli->stop_requested = TRUE;
	cli->state = SSC_CLI_ERROR_WAIT;
	clear_source (&cli->timeout_source);
	disconnect_observers (cli);
	if (cli->discover) {
		g_autofree gchar *escaped = g_strescape (message, NULL);
		g_printerr ("Sensor UID discovery shutdown incomplete: %s; keeping owner dispatch active\n",
			escaped);
	} else
		g_printerr ("%s sensor shutdown incomplete: %s; keeping owner dispatch active\n",
			cli->sensor_name, message);
}

static void
finish_invocation (SSCCli *cli)
{
	cli->invocation = SSC_CLI_INVOCATION_NONE;
	cli->invocation_tag = NULL;
	g_clear_object (&cli->pending);
	g_clear_object (&cli->diagnostic_result);
}

static gboolean
validate_subject_result (SSCCli *cli, SSCCliInvocation invocation,
			 GObject *source, GAsyncResult *result)
{
	g_assert (g_main_context_is_owner (cli->context));
	if (cli->invocation != invocation || !cli->retirement_subject ||
	    !cli->invocation_tag || !G_IS_TASK (result) ||
	    source != G_OBJECT (cli->retirement_subject) ||
	    !g_task_is_valid (result, cli->retirement_subject) ||
	    g_task_get_cancellable (G_TASK (result)) != cli->pending ||
	    g_task_get_source_tag (G_TASK (result)) != cli->invocation_tag) {
		error_wait (cli, result, "unexpected callback invocation, source or task tag");
		return FALSE;
	}
	return TRUE;
}

static gboolean
parse_uid (const gchar *text, guint64 *value)
{
	gchar *end = NULL;
	guint64 parsed;

	if (!text || !*text)
		return FALSE;
	for (const gchar *cursor = text; *cursor; cursor++)
		if (*cursor < '0' || *cursor > '9')
			return FALSE;
	errno = 0;
	parsed = g_ascii_strtoull (text, &end, 10);
	if (errno == ERANGE || !end || *end)
		return FALSE;
	*value = parsed;
	return TRUE;
}

static const gchar *
selected_data_type (SSCCliSensorKind kind)
{
	/* Exact existing typed-constructor literals, not firmware/board guesses. */
	switch (kind) {
	case SSC_CLI_PROXIMITY: return "proximity";
	case SSC_CLI_LIGHT: return "ambient_light";
	case SSC_CLI_ACCELEROMETER: return "accel";
	case SSC_CLI_MAGNETOMETER: return "mag";
	case SSC_CLI_COMPASS: return "rotv";
	case SSC_CLI_GYROSCOPE: return "gyro";
	}
	return NULL;
}

static GType
expected_sensor_type (SSCCliSensorKind kind)
{
	switch (kind) {
	case SSC_CLI_PROXIMITY: return SSC_TYPE_SENSOR_PROXIMITY;
	case SSC_CLI_LIGHT: return SSC_TYPE_SENSOR_LIGHT;
	case SSC_CLI_ACCELEROMETER: return SSC_TYPE_SENSOR_ACCELEROMETER;
	case SSC_CLI_MAGNETOMETER: return SSC_TYPE_SENSOR_MAGNETOMETER;
	case SSC_CLI_COMPASS: return SSC_TYPE_SENSOR_COMPASS;
	case SSC_CLI_GYROSCOPE: return SSC_TYPE_SENSOR_GYROSCOPE;
	}
	return G_TYPE_INVALID;
}

static SSCSensor *
validate_constructor_result (SSCCli *cli, GObject *source, GAsyncResult *result)
{
	g_autoptr (GObject) original_source = NULL;
	g_assert (g_main_context_is_owner (cli->context));
	if (cli->invocation != SSC_CLI_INVOCATION_INIT ||
	    cli->retirement_subject || !G_IS_TASK (result)) {
		error_wait (cli, result, "unexpected constructor invocation or result");
		return NULL;
	}
	original_source = g_async_result_get_source_object (result);
	if (!original_source || source != original_source ||
	    !SSC_IS_SENSOR (original_source) ||
	    G_OBJECT_TYPE (original_source) != cli->expected_type ||
	    !G_IS_ASYNC_INITABLE (original_source) ||
	    !g_task_is_valid (result, original_source) ||
	    g_task_get_cancellable (G_TASK (result)) != cli->pending ||
	    !G_ASYNC_INITABLE_GET_IFACE (original_source)->init_async ||
	    g_task_get_source_tag (G_TASK (result)) !=
		G_ASYNC_INITABLE_GET_IFACE (original_source)->init_async) {
		error_wait (cli, result, "constructor source, exact type or original task tag mismatch");
		return NULL;
	}
	/* Own the genuine source even if the real finish reports an operational
	 * error; INVALID_ARGUMENT alone cannot identify an invalid task tag. */
	return SSC_SENSOR (g_steal_pointer (&original_source));
}

static void
retire_ready (GObject *source, GAsyncResult *result, gpointer user_data)
{
	SSCCli *cli = user_data;
	g_autoptr (GError) error = NULL;
	g_autoptr (GError) release_error = NULL;
	g_autoptr (GError) close_error = NULL;
	g_autoptr (SSCSensorRetirementReceipt) receipt = NULL;
	if (!validate_subject_result (cli, SSC_CLI_INVOCATION_RETIRE, source, result))
		return;
	receipt = ssc_sensor_retire_finish (cli->retirement_subject, result, &error);
	finish_invocation (cli);
	if (!receipt || !ssc_sensor_retirement_receipt_get_local_complete (receipt)) {
		error_wait (cli, result, error ? error->message : "no terminal retirement receipt");
		return;
	}
	cli->state = SSC_CLI_RETIRING;
	release_error = ssc_sensor_retirement_receipt_dup_release_error (receipt);
	close_error = ssc_sensor_retirement_receipt_dup_close_error (receipt);
	if (release_error) {
		if (cli->discover) {
			g_autofree gchar *escaped = g_strescape (release_error->message, NULL);
			g_printerr ("Sensor UID discovery locally retired with release error: %s; remote DSP state is UNKNOWN\n",
				escaped);
		} else
			g_printerr ("%s sensor locally retired with release error: %s; remote DSP state is UNKNOWN\n",
				cli->sensor_name, release_error->message);
		cli->exit_status = EXIT_FAILURE;
	}
	if (close_error) {
		if (cli->discover) {
			g_autofree gchar *escaped = g_strescape (close_error->message, NULL);
			g_printerr ("Sensor UID discovery locally retired with close error: %s; remote DSP state is UNKNOWN\n",
				escaped);
		} else
			g_printerr ("%s sensor locally retired with close error: %s; remote DSP state is UNKNOWN\n",
				cli->sensor_name, close_error->message);
		cli->exit_status = EXIT_FAILURE;
	}
	complete (cli);
}

static void
begin_retire (SSCCli *cli)
{
	g_assert (g_main_context_is_owner (cli->context));
	if (cli->retire_started || cli->state == SSC_CLI_DONE ||
	    cli->invocation != SSC_CLI_INVOCATION_NONE)
		return;
	if (!cli->retirement_subject || (cli->stream_requested && !cli->close_started)) {
		error_wait (cli, NULL, "no trusted subject or unreconciled logical close");
		return;
	}
	cli->stop_requested = TRUE;
	cli->retire_started = TRUE;
	cli->state = SSC_CLI_RETIRING;
	clear_source (&cli->timeout_source);
	disconnect_observers (cli);
	cli->invocation = SSC_CLI_INVOCATION_RETIRE;
	cli->invocation_tag = ssc_sensor_retire_async;
	g_main_context_push_thread_default (cli->context);
	ssc_sensor_retire_async (cli->retirement_subject, retire_ready, cli);
	g_main_context_pop_thread_default (cli->context);
}

/* Snapshot committed properties on the owner before retirement. The owned
 * text survives object cleanup; stdout is written only after terminal cleanup. */
static gboolean
prepare_inspection (SSCCli *cli)
{
	g_autofree gchar *name = NULL, *vendor = NULL, *data_type = NULL;
	g_autofree gchar *escaped_name = NULL, *escaped_vendor = NULL;
	g_autofree gchar *escaped_type = NULL;
	guint64 uid_high = 0, uid_low = 0;
	guint stream_type = 0;
	gfloat sample_rate = 0, matrix[3][3];
	gfloat (*borrowed_matrix)[3] = NULL;
	gboolean available = FALSE;
	GString *text;

	g_assert (g_main_context_is_owner (cli->context));
	g_return_val_if_fail (SSC_IS_SENSOR (cli->sensor), FALSE);
	g_object_get (cli->sensor,
		SSC_SENSOR_AVAILABLE, &available,
		SSC_SENSOR_NAME, &name,
		SSC_SENSOR_VENDOR, &vendor,
		SSC_SENSOR_DATA_TYPE, &data_type,
		SSC_SENSOR_UID_HIGH, &uid_high,
		SSC_SENSOR_UID_LOW, &uid_low,
		SSC_SENSOR_SAMPLE_RATE, &sample_rate,
		SSC_SENSOR_STREAM_TYPE, &stream_type,
		SSC_SENSOR_MOUNT_MATRIX, &borrowed_matrix, NULL);
	if (!borrowed_matrix) {
		g_printerr ("%s metadata has no effective mount matrix\n", cli->sensor_name);
		return FALSE;
	}
	/* The property is borrowed; copy before retirement/finalization. */
	for (guint row = 0; row < 3; row++)
		for (guint column = 0; column < 3; column++)
			matrix[row][column] = borrowed_matrix[row][column];
	if (name)
		escaped_name = g_strescape (name, NULL);
	if (vendor)
		escaped_vendor = g_strescape (vendor, NULL);
	if (data_type)
		escaped_type = g_strescape (data_type, NULL);

	g_assert (!cli->inspection_text && !cli->inspection_ready);
	text = g_string_new (NULL);
	g_string_append_printf (text, "Selected %s sensor metadata (INIT only; no stream requested):\n", cli->sensor_name);
	if (cli->selection_enabled)
		g_string_append (text, "  Selection: explicit UID pair verified for data-type during INIT; not a physical-role identification\n");
	else
		g_string_append (text, "  Selection: existing default-by-data-type API; not an enumeration\n");
	g_string_append_printf (text, "  Available attribute: %s (not a live sample observation)\n", available ? "true" : "false");
	g_string_append_printf (text, "  Name (escaped): %s%s%s\n", name ? "\"" : "", name ? escaped_name : "(not reported)", name ? "\"" : "");
	g_string_append_printf (text, "  Vendor (escaped): %s%s%s\n", vendor ? "\"" : "", vendor ? escaped_vendor : "(not reported)", vendor ? "\"" : "");
	g_string_append_printf (text, "  Requested data-type (escaped): %s%s%s\n", data_type ? "\"" : "", data_type ? escaped_type : "(not reported)", data_type ? "\"" : "");
	g_string_append_printf (text, "  %s SUID high: %" G_GUINT64_FORMAT "\n", cli->selection_enabled ? "Selected" : "Default", uid_high);
	g_string_append_printf (text, "  %s SUID low: %" G_GUINT64_FORMAT "\n", cli->selection_enabled ? "Selected" : "Default", uid_low);
	g_string_append_printf (text, "  Selected sample rate: %.9g Hz (not measured)\n", (double) sample_rate);
	g_string_append_printf (text, "  Stream type: %u (reported code)\n", stream_type);
	g_string_append_printf (text, "  Effective mount matrix (unqualified; may be identity fallback):\n");
	for (guint row = 0; row < 3; row++)
		g_string_append_printf (text, "    [%.9g, %.9g, %.9g]\n", (double) matrix[row][0],
			(double) matrix[row][1], (double) matrix[row][2]);
	g_string_append_printf (text, "  Board sensor instance, physical axes/calibration, timestamp clock and automatic rotation: UNKNOWN\n");
	cli->inspection_text = g_string_free (text, FALSE);
	cli->inspection_ready = TRUE;
	return TRUE;
}


/* The immutable inventory outlives the sensor. Only main calls this after the
 * genuine terminal receipt, logical finish and owner cleanup have completed. */
static gboolean
print_discovery (SSCCli *cli)
{
	g_autofree gchar *escaped_type = g_strescape (cli->discovery_type, NULL);
	gsize length = ssc_sensor_uid_list_get_length (cli->discovered_uids);

	g_printf ("Sensor UID inventory for requested data-type (escaped): \"%s\"\n", escaped_type);
	g_printf ("Unique UID count: %" G_GSIZE_FORMAT "\n", length);
	for (gsize i = 0; i < length; i++) {
		guint64 high = 0, low = 0;
		if (!ssc_sensor_uid_list_get_uid (cli->discovered_uids, i, &high, &low)) {
			g_printerr ("Unable to read discovered sensor UID\n");
			return FALSE;
		}
		g_printf ("  UID[%" G_GSIZE_FORMAT "]: high=%" G_GUINT64_FORMAT
			" low=%" G_GUINT64_FORMAT "\n", i, high, low);
	}
	g_printf ("Scope: one matching data-type report; no sensor INIT or stream requested.\n");
	g_printf ("Board instance, physical roles/axes, calibration, timestamp clock and automatic rotation: UNKNOWN\n");
	if (fflush (stdout) == EOF || ferror (stdout)) {
		g_printerr ("Unable to write sensor UID inventory\n");
		return FALSE;
	}
	return TRUE;
}

static void
discover_ready (GObject *source, GAsyncResult *result, gpointer user_data)
{
	SSCCli *cli = user_data;
	g_autoptr (GError) error = NULL;
	g_autoptr (SSCSensorUidList) uids = NULL;

	if (!validate_subject_result (cli, SSC_CLI_INVOCATION_DISCOVER, source, result))
		return;
	uids = ssc_sensor_discover_finish (cli->retirement_subject, result, &error);
	finish_invocation (cli);
	cli->state = SSC_CLI_DISCOVERING;
	if (!uids) {
		g_autofree gchar *escaped = g_strescape (error ? error->message : "UNKNOWN", NULL);
		g_printerr ("Unable to discover sensor UIDs: %s\n", escaped);
		cli->exit_status = EXIT_FAILURE;
	} else {
		/* Preserve the real logical result even if a user stop won the CLI
		 * outcome. Main independently suppresses output after interruption. */
		cli->discovery_succeeded = TRUE;
		cli->discovered_uids = g_steal_pointer (&uids);
	}
	/* No INIT, OPEN, measurement observers or fabricated sensor CLOSE. */
	begin_retire (cli);
}

static gboolean
may_print_measurement (SSCCli *cli)
{
	/* A base-owned frame can follow logical OPEN commit before the OPEN task
	 * callback runs. Do not discard that first frame by requiring CLI_OPEN. */
	return !cli->stop_requested && cli->state != SSC_CLI_CLOSING &&
		cli->state != SSC_CLI_RETIRING && cli->state != SSC_CLI_ERROR_WAIT &&
		cli->state != SSC_CLI_DONE;
}

static void
sample_metadata_failure (SSCCli *cli, const gchar *message)
{
	cli->exit_status = EXIT_FAILURE;
	g_printerr ("%s sample metadata failed: %s\n", cli->sensor_name, message);
	request_stop (cli);
}

static const gchar *
sample_kind_name (SSCSensorSampleKind kind)
{
	switch (kind) {
	case SSC_SENSOR_SAMPLE_KIND_ACCELEROMETER: return "accelerometer";
	case SSC_SENSOR_SAMPLE_KIND_COMPASS: return "compass";
	case SSC_SENSOR_SAMPLE_KIND_GYROSCOPE: return "gyroscope";
	case SSC_SENSOR_SAMPLE_KIND_LIGHT: return "light";
	case SSC_SENSOR_SAMPLE_KIND_MAGNETOMETER: return "magnetometer";
	case SSC_SENSOR_SAMPLE_KIND_PROXIMITY: return "proximity";
	}
	return NULL;
}

static void
sample_measurement (SSCSensor *sensor, const SSCSensorSample *sample, gpointer user_data)
{
	SSCCli *cli = user_data;
	SSCSensorSampleKind kind;
	const gchar *kind_name;
	g_autofree gchar *value = NULL, *text = NULL;
	gchar x_text[G_ASCII_DTOSTR_BUF_SIZE], y_text[G_ASCII_DTOSTR_BUF_SIZE];
	gchar z_text[G_ASCII_DTOSTR_BUF_SIZE];
	gfloat x, y, z, scalar;
	gboolean near;
	guint flags;
	(void) sensor;

	if (!may_print_measurement (cli))
		return;
	if (!sample) {
		sample_metadata_failure (cli, "missing semantic sample");
		return;
	}
	kind = ssc_sensor_sample_get_kind (sample);
	kind_name = sample_kind_name (kind);
	if (!kind_name) {
		sample_metadata_failure (cli, "unsupported semantic sample kind");
		return;
	}
	switch (kind) {
	case SSC_SENSOR_SAMPLE_KIND_ACCELEROMETER:
	case SSC_SENSOR_SAMPLE_KIND_GYROSCOPE:
	case SSC_SENSOR_SAMPLE_KIND_MAGNETOMETER:
		if (!ssc_sensor_sample_get_vector (sample, &x, &y, &z)) {
			sample_metadata_failure (cli, "semantic vector sample has no vector value");
			return;
		}
		value = g_strdup_printf ("vector=(x=%s,y=%s,z=%s)",
			g_ascii_dtostr (x_text, sizeof x_text, (gdouble) x),
			g_ascii_dtostr (y_text, sizeof y_text, (gdouble) y),
			g_ascii_dtostr (z_text, sizeof z_text, (gdouble) z));
		break;
	case SSC_SENSOR_SAMPLE_KIND_COMPASS:
	case SSC_SENSOR_SAMPLE_KIND_LIGHT:
		if (!ssc_sensor_sample_get_scalar (sample, &scalar)) {
			sample_metadata_failure (cli, "semantic scalar sample has no scalar value");
			return;
		}
		value = g_strdup_printf ("scalar=%s",
			g_ascii_dtostr (x_text, sizeof x_text, (gdouble) scalar));
		break;
	case SSC_SENSOR_SAMPLE_KIND_PROXIMITY:
		if (!ssc_sensor_sample_get_near (sample, &near)) {
			sample_metadata_failure (cli, "semantic proximity sample has no near value");
			return;
		}
		value = g_strdup_printf ("near=%s", near ? "true" : "false");
		break;
	default:
		sample_metadata_failure (cli, "unsupported semantic sample value shape");
		return;
	}
	flags = ssc_sensor_sample_get_flags (sample);
	/* The boxed value is borrowed only for this callback. Integer metadata is
	 * exact; floating values use locale-neutral GLib formatting. These are
	 * semantic samples, not wire packets or qualified clocks/physical roles. */
	text = g_strdup_printf ("Sensor semantic sample: kind=%s uid-high=%" G_GUINT64_FORMAT
		" uid-low=%" G_GUINT64_FORMAT " local-epoch=%" G_GUINT64_FORMAT
		" local-sequence=%" G_GUINT64_FORMAT " raw-timestamp=%" G_GUINT64_FORMAT
		" accuracy-raw=%" G_GINT32_FORMAT " accuracy-known=%s"
		" clock-unqualified=%s payload-valid=%s flags=%u %s\n",
		kind_name, ssc_sensor_sample_get_uid_high (sample),
		ssc_sensor_sample_get_uid_low (sample), ssc_sensor_sample_get_epoch (sample),
		ssc_sensor_sample_get_sequence (sample), ssc_sensor_sample_get_raw_timestamp (sample),
		ssc_sensor_sample_get_accuracy (sample),
		(flags & SSC_SENSOR_SAMPLE_ACCURACY_KNOWN) ? "true" : "false",
		(flags & SSC_SENSOR_SAMPLE_CLOCK_UNQUALIFIED) ? "true" : "false",
		(flags & SSC_SENSOR_SAMPLE_VALID_PAYLOAD) ? "true" : "false", flags, value);
	/* Ordinary stdio failures request the same logical close and terminal
	 * retirement path as other stops. Fatal signals such as SIGPIPE are not
	 * intercepted here, so this does not promise cleanup after such signals. */
	if (fputs (text, stdout) == EOF || fflush (stdout) == EOF || ferror (stdout))
		sample_metadata_failure (cli, "unable to write semantic sample to stdout");
}

static void
compass_measurement (SSCSensorCompass *sensor, gfloat heading, gpointer user_data)
{
	SSCCli *cli = user_data;
	(void) sensor;
	if (!may_print_measurement (cli))
		return;
	g_printf ("Compass sensor measurement: %f ° (heading calibration unqualified)\n", heading);
	fflush (stdout);
}

static void
magnetometer_measurement (SSCSensorMagnetometer *sensor, gfloat x, gfloat y,
			gfloat z, gpointer user_data)
{
	SSCCli *cli = user_data;
	(void) sensor;
	if (!may_print_measurement (cli))
		return;
	g_printf ("Magnetometer sensor measurement: X=%f Y=%f Z=%f μT (calibration unqualified)\n", x, y, z);
	fflush (stdout);
}

static void
accelerometer_measurement (SSCSensorAccelerometer *sensor, gfloat x, gfloat y,
			 gfloat z, gpointer user_data)
{
	SSCCli *cli = user_data;
	(void) sensor;
	if (!may_print_measurement (cli))
		return;
	g_printf ("Accelerometer sensor measurement: X=%f Y=%f Z=%f m/s² (calibration unqualified)\n", x, y, z);
	fflush (stdout);
}

static void
light_measurement (SSCSensorLight *sensor, gfloat intensity, gpointer user_data)
{
	SSCCli *cli = user_data;
	(void) sensor;
	if (!may_print_measurement (cli))
		return;
	g_printf ("Light sensor measurement: %f Lux (protocol convention; physical calibration unqualified)\n", intensity);
	fflush (stdout);
}

static void
proximity_measurement (SSCSensorProximity *sensor, gboolean near, gpointer user_data)
{
	SSCCli *cli = user_data;
	(void) sensor;
	if (!may_print_measurement (cli))
		return;
	g_printf ("Proximity sensor measurement: %s\n", near ? "NEAR" : "FAR");
	fflush (stdout);
}

static void
gyroscope_measurement (SSCSensorGyroscope *sensor, gfloat x, gfloat y,
		       gfloat z, gpointer user_data)
{
	SSCCli *cli = user_data;
	(void) sensor;
	if (!may_print_measurement (cli))
		return;
	g_printf ("Gyroscope sensor measurement: X=%f Y=%f Z=%f (raw angular velocity; unit unqualified)\n", x, y, z);
	fflush (stdout);
}

static void
stream_error (SSCSensor *sensor, GError *error, gpointer user_data)
{
	SSCCli *cli = user_data;
	(void) sensor;
	/* error is callback-borrowed. Print it before any reentrant shutdown;
	 * never retain or free the controller's emission-owned error. */
	g_printerr ("%s stream failed: %s\n", cli->sensor_name,
		error ? error->message : "UNKNOWN");
	cli->exit_status = EXIT_FAILURE;
	request_stop (cli);
}

static void
close_ready (GObject *source, GAsyncResult *result, gpointer user_data)
{
	SSCCli *cli = user_data;
	g_autoptr (GError) error = NULL;
	if (!validate_subject_result (cli, SSC_CLI_INVOCATION_CLOSE, source, result))
		return;
	if (!ssc_sensor_close_finish (cli->sensor, result, &error)) {
		g_printerr ("Unable to close %s sensor: %s; remote DSP state is UNKNOWN\n",
			cli->sensor_name, error ? error->message : "UNKNOWN");
		cli->exit_status = EXIT_FAILURE;
	} else {
		g_debug ("Disable request acknowledged; physical quiescence is not established");
	}
	finish_invocation (cli);
	cli->state = SSC_CLI_CLOSING;
	begin_retire (cli);
}

static void
begin_close (SSCCli *cli)
{
	g_assert (g_main_context_is_owner (cli->context));
	if (cli->close_started || cli->retire_started || cli->state == SSC_CLI_DONE ||
	    cli->invocation != SSC_CLI_INVOCATION_NONE)
		return;
	if (!cli->sensor) {
		begin_retire (cli);
		return;
	}
	cli->stop_requested = TRUE;
	cli->close_started = TRUE;
	cli->state = SSC_CLI_CLOSING;
	clear_source (&cli->timeout_source);
	/* Never pass the cancelled INIT/OPEN token into the resynchronizing CLOSE.
	 * Its base operation deadline (30s) governs, with no enable or retry here. */
	cli->invocation = SSC_CLI_INVOCATION_CLOSE;
	/* Original task tag is the actual known base method, not the wrapper. */
	cli->invocation_tag = SSC_SENSOR_GET_CLASS (cli->sensor)->close;
	g_main_context_push_thread_default (cli->context);
	ssc_sensor_close (cli->sensor, NULL, close_ready, cli);
	g_main_context_pop_thread_default (cli->context);
}

static void
request_stop (SSCCli *cli)
{
	if (cli->state == SSC_CLI_DONE)
		return;
	if (cli->discover) {
		/* Explicit CLI policy: any requested stop before DONE is failure,
		 * including SIGINT/SIGTERM during uncancellable retirement. */
		cli->discovery_interrupted = TRUE;
		cli->exit_status = EXIT_FAILURE;
	}
	cli->stop_requested = TRUE;
	if (cli->invocation == SSC_CLI_INVOCATION_INIT ||
	    cli->invocation == SSC_CLI_INVOCATION_OPEN ||
	    cli->invocation == SSC_CLI_INVOCATION_DISCOVER) {
		g_autoptr (GCancellable) pending = cli->pending ? g_object_ref (cli->pending) : NULL;
		if (pending)
			g_cancellable_cancel (pending);
		/* Await its actual logical callback before CLOSE: PENDING is not a
		 * successful close, and returning here must not finish the process. */
		return;
	}
	if (cli->state == SSC_CLI_OPEN)
		begin_close (cli);
	/* CLOSING/RETIRING/ERROR_WAIT stop requests never cancel cleanup, duplicate
	 * an invocation or abandon the retained owner dispatcher. */
}

static gboolean
timeout_ready (gpointer user_data)
{
	request_stop (user_data);
	return G_SOURCE_REMOVE;
}

static gboolean
unix_stop_ready (gpointer user_data)
{
	request_stop (user_data);
	return G_SOURCE_CONTINUE;
}

static void
open_ready (GObject *source, GAsyncResult *result, gpointer user_data)
{
	SSCCli *cli = user_data;
	g_autoptr (GError) error = NULL;
	gboolean success;
	if (!validate_subject_result (cli, SSC_CLI_INVOCATION_OPEN, source, result))
		return;
	success = ssc_sensor_open_finish (cli->sensor, result, &error);
	finish_invocation (cli);
	cli->state = SSC_CLI_OPENING;
	if (!success) {
		if (!cli->stop_requested || !g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
			g_printerr ("Unable to open %s sensor: %s\n", cli->sensor_name,
				error ? error->message : "UNKNOWN");
			cli->exit_status = EXIT_FAILURE;
		}
		cli->stop_requested = TRUE;
	}
	if (cli->stop_requested) {
		/* OPEN finish has been consumed. Even a failed/cancelled OPEN may
		 * have submitted enable, so make one explicit CLOSE resync attempt. */
		begin_close (cli);
		return;
	}
	cli->state = SSC_CLI_OPEN;
	g_debug ("%s sensor logically open", cli->sensor_name);
}

static SSCSensor *
finish_constructor (SSCCli *cli, GAsyncResult *result, GError **error)
{
	gpointer sensor = NULL;
	switch (cli->kind) {
	case SSC_CLI_PROXIMITY:
		sensor = ssc_sensor_proximity_new_finish (result, error); break;
	case SSC_CLI_LIGHT:
		sensor = ssc_sensor_light_new_finish (result, error); break;
	case SSC_CLI_ACCELEROMETER:
		sensor = ssc_sensor_accelerometer_new_finish (result, error); break;
	case SSC_CLI_MAGNETOMETER:
		sensor = ssc_sensor_magnetometer_new_finish (result, error); break;
	case SSC_CLI_COMPASS:
		sensor = ssc_sensor_compass_new_finish (result, error); break;
	case SSC_CLI_GYROSCOPE:
		sensor = ssc_sensor_gyroscope_new_finish (result, error); break;
	default:
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Unsupported CLI sensor kind"); break;
	}
	return sensor ? SSC_SENSOR (sensor) : NULL;
}

static void
connect_measurement (SSCCli *cli)
{
	if (cli->sample_metadata)
		cli->measurement_id = g_signal_connect (cli->sensor, "sample",
			G_CALLBACK (sample_measurement), cli);
	else switch (cli->kind) {
	case SSC_CLI_PROXIMITY:
		cli->measurement_id = g_signal_connect (cli->sensor, "measurement",
			G_CALLBACK (proximity_measurement), cli); break;
	case SSC_CLI_LIGHT:
		cli->measurement_id = g_signal_connect (cli->sensor, "measurement",
			G_CALLBACK (light_measurement), cli); break;
	case SSC_CLI_ACCELEROMETER:
		cli->measurement_id = g_signal_connect (cli->sensor, "measurement",
			G_CALLBACK (accelerometer_measurement), cli); break;
	case SSC_CLI_MAGNETOMETER:
		cli->measurement_id = g_signal_connect (cli->sensor, "measurement",
			G_CALLBACK (magnetometer_measurement), cli); break;
	case SSC_CLI_COMPASS:
		cli->measurement_id = g_signal_connect (cli->sensor, "measurement",
			G_CALLBACK (compass_measurement), cli); break;
	case SSC_CLI_GYROSCOPE:
		cli->measurement_id = g_signal_connect (cli->sensor, "measurement",
			G_CALLBACK (gyroscope_measurement), cli); break;
	}
	cli->stream_error_id = g_signal_connect (cli->sensor, "stream-error",
		G_CALLBACK (stream_error), cli);
}

static void
init_ready (GObject *source, GAsyncResult *result, gpointer user_data)
{
	SSCCli *cli = user_data;
	g_autoptr (GError) error = NULL;
	SSCSensor *subject = validate_constructor_result (cli, source, result);
	if (!subject)
		return;
	cli->retirement_subject = subject;
	cli->sensor = finish_constructor (cli, result, &error);
	finish_invocation (cli);
	cli->state = SSC_CLI_INITIALIZING;
	if (cli->sensor && cli->sensor != cli->retirement_subject) {
		error_wait (cli, result, "constructor returned a different sensor object");
		return;
	}
	if (!cli->sensor) {
		if (!cli->stop_requested || !g_error_matches (error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
			g_printerr ("Unable to initialize %s sensor: %s\n", cli->sensor_name,
				error ? error->message : "UNKNOWN");
			cli->exit_status = EXIT_FAILURE;
		}
		/* No successful INIT means no fabricated CLOSE. The genuine source's
		 * early scope still owns any late failed-INIT backend work. */
		begin_retire (cli);
		return;
	}
	if (cli->inspect) {
		if (!cli->stop_requested && !prepare_inspection (cli))
			cli->exit_status = EXIT_FAILURE;
		begin_retire (cli);
		return;
	}
	connect_measurement (cli);
	if (cli->stop_requested) {
		begin_close (cli);
		return;
	}
	cli->state = SSC_CLI_OPENING;
	cli->pending = g_cancellable_new ();
	cli->invocation = SSC_CLI_INVOCATION_OPEN;
	cli->invocation_tag = SSC_SENSOR_GET_CLASS (cli->sensor)->open;
	g_main_context_push_thread_default (cli->context);
	cli->stream_requested = TRUE;
	ssc_sensor_open (cli->sensor, cli->pending, open_ready, cli);
	g_main_context_pop_thread_default (cli->context);
}

static void
start_constructor (SSCCli *cli)
{
	cli->state = SSC_CLI_INITIALIZING;
	cli->pending = g_cancellable_new ();
	cli->invocation = SSC_CLI_INVOCATION_INIT;
	cli->expected_type = expected_sensor_type (cli->kind);
	g_main_context_push_thread_default (cli->context);
	if (cli->selection_enabled) {
		/* Public GAsyncInitable construction preserves the original typed INIT
		 * result/tag and existing finish/retirement ownership path. */
		g_async_initable_new_async (cli->expected_type, G_PRIORITY_DEFAULT,
			cli->pending, init_ready, cli,
			SSC_SENSOR_DATA_TYPE, selected_data_type (cli->kind),
			SSC_SENSOR_SELECTION_ENABLED, TRUE,
			SSC_SENSOR_UID_HIGH, cli->uid_high,
			SSC_SENSOR_UID_LOW, cli->uid_low, NULL);
		g_main_context_pop_thread_default (cli->context);
		return;
	}
	switch (cli->kind) {
	case SSC_CLI_PROXIMITY:
		ssc_sensor_proximity_new (cli->pending, init_ready, cli); break;
	case SSC_CLI_LIGHT:
		ssc_sensor_light_new (cli->pending, init_ready, cli); break;
	case SSC_CLI_ACCELEROMETER:
		ssc_sensor_accelerometer_new (cli->pending, init_ready, cli); break;
	case SSC_CLI_MAGNETOMETER:
		ssc_sensor_magnetometer_new (cli->pending, init_ready, cli); break;
	case SSC_CLI_COMPASS:
		ssc_sensor_compass_new (cli->pending, init_ready, cli); break;
	case SSC_CLI_GYROSCOPE:
		ssc_sensor_gyroscope_new (cli->pending, init_ready, cli); break;
	}
	g_main_context_pop_thread_default (cli->context);
}


static void
start_discovery (SSCCli *cli)
{
	cli->state = SSC_CLI_DISCOVERING;
	g_main_context_push_thread_default (cli->context);
	/* Bare exact base construction captures this owner, but never INITs a
	 * client. Own the trusted subject before submitting DISCOVER. */
	cli->retirement_subject = g_object_new (SSC_TYPE_SENSOR,
		SSC_SENSOR_DATA_TYPE, cli->discovery_type, NULL);
	cli->pending = g_cancellable_new ();
	cli->invocation = SSC_CLI_INVOCATION_DISCOVER;
	cli->invocation_tag = ssc_sensor_discover_async;
	ssc_sensor_discover_async (cli->retirement_subject, cli->pending, discover_ready, cli);
	g_main_context_pop_thread_default (cli->context);
}

static gboolean
select_sensor (const gchar *name, SSCCliSensorKind *kind)
{
	static const struct { const gchar *name; SSCCliSensorKind kind; } choices[] = {
		{"proximity", SSC_CLI_PROXIMITY}, {"light", SSC_CLI_LIGHT},
		{"accelerometer", SSC_CLI_ACCELEROMETER}, {"magnetometer", SSC_CLI_MAGNETOMETER},
		{"compass", SSC_CLI_COMPASS}, {"gyroscope", SSC_CLI_GYROSCOPE}
	};
	for (guint i = 0; i < G_N_ELEMENTS (choices); i++) {
		if (g_strcmp0 (name, choices[i].name) == 0) {
			*kind = choices[i].kind;
			return TRUE;
		}
	}
	return FALSE;
}

static void
cleanup (SSCCli *cli)
{
	clear_source (&cli->timeout_source);
	clear_source (&cli->sigint_source);
	clear_source (&cli->sigterm_source);
	/* Object cleanup already ran in complete() while the owner was held. */
	g_assert (cli->state == SSC_CLI_DONE && !cli->sensor && !cli->retirement_subject &&
		!cli->pending && !cli->diagnostic_result && !cli->measurement_id &&
		!cli->stream_error_id && cli->invocation == SSC_CLI_INVOCATION_NONE &&
		!cli->invocation_tag);
	g_clear_pointer (&cli->loop, g_main_loop_unref);
	g_clear_pointer (&cli->context, g_main_context_unref);
}

int
main (int argc, char *argv[])
{
	g_autoptr (GOptionContext) options_context = NULL;
	g_autoptr (GError) error = NULL;
	g_autofree gchar *sensor_name = NULL;
	g_autofree gchar *discovery_type = NULL;
	g_autofree gchar *uid_high_text = NULL, *uid_low_text = NULL;
	gboolean version = FALSE, debug = FALSE, inspect = FALSE, sample_metadata = FALSE;
	gint64 timeout = DEFAULT_ENABLE_SECONDS;
	SSCCli cli = {0};
	const GOptionEntry options[] = {
		{"version", 0, 0, G_OPTION_ARG_NONE, &version, "Print version information and exit.", NULL},
		{"debug", 'v', 0, G_OPTION_ARG_NONE, &debug, "Enable GLib debug logs; not QMI payload traces.", NULL},
		{"sensor", 0, 0, G_OPTION_ARG_STRING, &sensor_name, "Sensor: proximity, light, accelerometer, magnetometer, compass or gyroscope.", NULL},
		{"inspect", 0, 0, G_OPTION_ARG_NONE, &inspect, "Initialize selected sensor, retire locally, then print metadata without requesting a stream.", NULL},
		{"sample-metadata", 0, 0, G_OPTION_ARG_NONE, &sample_metadata, "Print typed semantic samples with local sequence, raw ticks and unqualified quality/clock metadata; streaming only.", NULL},
		{"discover", 0, 0, G_OPTION_ARG_STRING, &discovery_type, "List UIDs for one data-type report, then retire locally; no sensor INIT or stream requested.", "DATA_TYPE"},
		{"uid-high", 0, 0, G_OPTION_ARG_STRING, &uid_high_text, "Select this exact high64 UID half with --uid-low and --sensor; unsigned ASCII decimal.", "UINT64"},
		{"uid-low", 0, 0, G_OPTION_ARG_STRING, &uid_low_text, "Select this exact low64 UID half with --uid-high and --sensor; unsigned ASCII decimal.", "UINT64"},
		{"timeout", 0, 0, G_OPTION_ARG_INT64, &timeout, "Seconds before requesting shutdown, including INIT/OPEN/discovery (default 10); local cleanup waits for actual backend callbacks.", NULL},
		{NULL, 0, 0, G_OPTION_ARG_NONE, NULL, NULL, NULL}
	};

	options_context = g_option_context_new ("- CLI tool for Qualcomm Sensor Core sensors");
	g_option_context_add_main_entries (options_context, options, NULL);
	if (!g_option_context_parse (options_context, &argc, &argv, &error)) {
		g_printerr ("Parsing CLI options failed: %s\n", error->message);
		return EXIT_FAILURE;
	}
	if (version) {
		g_printf ("libssc version %d.%d.%d\n", LIBSSC_MAJOR_VERSION, LIBSSC_MINOR_VERSION, LIBSSC_PATCH_VERSION);
		return EXIT_SUCCESS;
	}
	if (sample_metadata) {
		if (inspect || discovery_type != NULL) {
			g_printerr ("--sample-metadata is streaming-only and cannot be combined with --inspect or --discover\n");
			return EXIT_FAILURE;
		}
		if (argc != 1) {
			g_printerr ("--sample-metadata does not accept positional arguments\n");
			return EXIT_FAILURE;
		}
	}
	cli.selection_enabled = uid_high_text != NULL || uid_low_text != NULL;
	if (cli.selection_enabled) {
		if (uid_high_text == NULL || uid_low_text == NULL) {
			g_printerr ("--uid-high and --uid-low must be supplied together\n");
			return EXIT_FAILURE;
		}
		if (discovery_type != NULL) {
			g_printerr ("UID selection cannot be combined with --discover\n");
			return EXIT_FAILURE;
		}
		if (!parse_uid (uid_high_text, &cli.uid_high) || !parse_uid (uid_low_text, &cli.uid_low)) {
			g_printerr ("--uid-high and --uid-low require unsigned ASCII decimal values between 0 and 18446744073709551615\n");
			return EXIT_FAILURE;
		}
		if (argc != 1) {
			g_printerr ("UID selection does not accept positional arguments\n");
			return EXIT_FAILURE;
		}
	}
	if (discovery_type != NULL) {
		if (!*discovery_type || !g_utf8_validate (discovery_type, -1, NULL)) {
			g_printerr ("--discover requires a nonempty UTF-8 data-type\n");
			return EXIT_FAILURE;
		}
		if (sensor_name != NULL || inspect) {
			g_printerr ("--discover cannot be combined with --sensor or --inspect\n");
			return EXIT_FAILURE;
		}
		if (argc != 1) {
			g_printerr ("--discover does not accept positional arguments\n");
			return EXIT_FAILURE;
		}
	} else if (!select_sensor (sensor_name, &cli.kind)) {
		g_printerr ("Specify a supported sensor: proximity, light, accelerometer, magnetometer, compass or gyroscope\n");
		return EXIT_FAILURE;
	}
	if (timeout < 1 || timeout > G_MAXUINT) {
		g_printerr ("--timeout must be between 1 and %u seconds\n", G_MAXUINT);
		return EXIT_FAILURE;
	}
	if (debug && !g_setenv ("G_MESSAGES_DEBUG", "all", TRUE)) {
		g_printerr ("Failed to enable GLib debug logs\n");
		return EXIT_FAILURE;
	}
	/* Shared diagnostics never receive the raw requested discovery type. */
	cli.sensor_name = discovery_type ? "discovery" : sensor_name;
	cli.inspect = inspect;
	cli.sample_metadata = sample_metadata;
	cli.discover = discovery_type != NULL;
	cli.discovery_type = discovery_type;
	cli.context = g_main_context_ref_thread_default ();
	cli.loop = g_main_loop_new (cli.context, FALSE);
	cli.timeout_source = g_timeout_source_new_seconds ((guint) timeout);
	g_source_set_callback (cli.timeout_source, timeout_ready, &cli, NULL);
	g_source_attach (cli.timeout_source, cli.context);
	cli.sigint_source = g_unix_signal_source_new (SIGINT);
	g_source_set_callback (cli.sigint_source, unix_stop_ready, &cli, NULL);
	g_source_attach (cli.sigint_source, cli.context);
	cli.sigterm_source = g_unix_signal_source_new (SIGTERM);
	g_source_set_callback (cli.sigterm_source, unix_stop_ready, &cli, NULL);
	g_source_attach (cli.sigterm_source, cli.context);
	/* Sources, captured owner and loop exist before any async construction. */
	if (cli.discover)
		start_discovery (&cli);
	else
		start_constructor (&cli);
	if (cli.state != SSC_CLI_DONE)
		g_main_loop_run (cli.loop);
	cleanup (&cli);
	if (cli.inspect) {
		/* The genuine terminal receipt and owner cleanup already completed.
		 * Only owned text is accessed here, never the retired sensor. */
		if (cli.exit_status == EXIT_SUCCESS && cli.inspection_ready && cli.inspection_text &&
		    (fputs (cli.inspection_text, stdout) == EOF || fflush (stdout) == EOF || ferror (stdout))) {
			g_printerr ("Unable to write %s metadata inspection\n", cli.sensor_name);
			cli.exit_status = EXIT_FAILURE;
		}
		g_clear_pointer (&cli.inspection_text, g_free);
	}
	if (cli.discover) {
		if (!cli.discovery_succeeded || cli.discovery_interrupted || !cli.discovered_uids)
			cli.exit_status = EXIT_FAILURE;
		else if (cli.exit_status == EXIT_SUCCESS && !print_discovery (&cli))
			cli.exit_status = EXIT_FAILURE;
		/* The immutable list is independent of the now-retired sensor. This
		 * also frees successful results suppressed by stop/cleanup errors. */
		g_clear_pointer (&cli.discovered_uids, ssc_sensor_uid_list_free);
	}
	return cli.exit_status;
}
