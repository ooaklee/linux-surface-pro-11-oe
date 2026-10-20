/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Fixed proxy context. Exact retained sensors own state across native calls
 * and deferred work. No device dereference after external callbacks. Logical
 * CLOSE is not a terminal-retirement or hardware-quiescence receipt. */
#include "drivers.h"
#include "drv-ssc-polling.h"

typedef struct {
	SensorDevice *owner; /* identity only after callbacks; NULL on detach */
	gulong handler;
	gulong error_handler;
	gboolean in_flight;
	gboolean notifying;
	gboolean needs_close;
	gboolean stop_requested;
	gboolean active;
	gboolean recovery_pending;
	gboolean fault_reported;
	GError *fault;
	GMainContext *context;
	GSource *recovery;
	SscPollingOperation close;
} SscPollingState;

static GQuark
polling_quark (void)
{
	return g_quark_from_static_string ("iio-sensor-proxy-ssc-polling-v1");
}

static void schedule_recovery (SSCSensor *sensor, SscPollingState *state);

static void
cancel_recovery (SscPollingState *state)
{
	GSource *source = g_steal_pointer (&state->recovery);
	if (!source)
		return;
	g_source_destroy (source);
	g_source_unref (source);
}

static void
state_free (gpointer value)
{
	SscPollingState *state = value;
	/* Queued sources retain the sensor. Detach/completion must break that
	 * ownership before qdata is finalized. */
	g_assert (state->recovery == NULL);
	g_clear_error (&state->fault);
	g_main_context_unref (state->context);
	g_free (state);
}

static void
disconnect_measurement (SSCSensor *sensor, SscPollingState *state)
{
	if (state->handler && g_signal_handler_is_connected (sensor, state->handler))
		g_signal_handler_disconnect (sensor, state->handler);
	state->handler = 0;
	state->active = FALSE;
}

static void
disconnect_error (SSCSensor *sensor, SscPollingState *state)
{
	if (state->error_handler && g_signal_handler_is_connected (sensor, state->error_handler))
		g_signal_handler_disconnect (sensor, state->error_handler);
	state->error_handler = 0;
}

void
ssc_driver_polling_detach (SSCSensor *sensor)
{
	SscPollingState *state = g_object_get_qdata (G_OBJECT (sensor), polling_quark ());
	if (!state)
		return;
	state->owner = NULL;
	state->stop_requested = TRUE;
	state->recovery_pending = FALSE;
	cancel_recovery (state);
	disconnect_measurement (sensor, state);
	disconnect_error (sensor, state);
}

static void
notify_state (SscPollingState *state, const GError *error)
{
	SensorDevice *owner = state->owner;
	SensorStateUpdateFunc callback;
	gpointer user_data;
	g_autoptr(GError) copy = error ? g_error_copy (error) : NULL;
	if (!owner)
		return;
	callback = owner->state_callback;
	user_data = owner->user_data;
	if (!callback)
		return;
	state->notifying = TRUE;
	callback (owner, copy, user_data);
	state->notifying = FALSE;
	/* owner may now be detached/freed. Never dereference it here. */
	/* Initial fault recovery is scheduled only after this returns. CLOSE
	 * notifications consume/cancel that recovery before entering here. */
}

static gboolean
perform (SscPollingOperation operation, SSCSensor *sensor, GError **error)
{
	gboolean success = operation (sensor, error);
	if (!success && !*error)
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "unknown error");
	return success && !*error;
}

static gboolean
return_error (GError **destination, GError *error)
{
	g_propagate_error (destination, error);
	return FALSE;
}

static gboolean
cancelled (GError **error)
{
	g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_CANCELLED,
		             "SSC start was cancelled before completion");
	return FALSE;
}

static void
append_recovery_error (GError **primary, const GError *cleanup)
{
	GError *combined = g_error_new ((*primary)->domain, (*primary)->code,
		"%s; SSC recovery CLOSE failed [%s:%d]: %s", (*primary)->message,
		g_quark_to_string (cleanup->domain), cleanup->code, cleanup->message);
	g_clear_error (primary);
	*primary = combined;
}

/* Consume one required CLOSE attempt. Its failure signal is disconnected:
 * the actual return error is observed, not a trigger for recursive retries. */
static gboolean
close_required (SSCSensor *sensor, SscPollingState *state, GError **error)
{
	gboolean reported = state->fault_reported;
	disconnect_measurement (sensor, state);
	disconnect_error (sensor, state);
	cancel_recovery (state);
	state->recovery_pending = FALSE;
	if (!perform (state->close, sensor, error))
		return FALSE;
	state->needs_close = FALSE;
	g_clear_error (&state->fault);
	state->fault_reported = FALSE;
	if (reported)
		notify_state (state, NULL);
	return TRUE;
}

static gboolean
recover_on_owner (gpointer value)
{
	SSCSensor *sensor = value; /* source retains this exact object */
	SscPollingState *state = g_object_get_qdata (G_OBJECT (sensor), polling_quark ());
	GSource *source = g_steal_pointer (&state->recovery);
	g_autoptr(GError) error = NULL;
	if (source)
		g_source_unref (source);
	if (!state->owner || !state->needs_close)
		return G_SOURCE_REMOVE;
	if (state->in_flight || state->notifying) {
		/* Sync waits dispatch this context. Resume at the outer epilogue,
		 * not by repeatedly scheduling another idle inside that wait. */
		state->recovery_pending = TRUE;
		return G_SOURCE_REMOVE;
	}
	state->in_flight = TRUE;
	if (!close_required (sensor, state, &error)) {
		if (state->fault)
			append_recovery_error (&state->fault, error);
		notify_state (state, state->fault ? state->fault : error);
	}
	state->in_flight = FALSE;
	return G_SOURCE_REMOVE;
}

static void
schedule_recovery (SSCSensor *sensor, SscPollingState *state)
{
	if (!state->owner || !state->recovery_pending || !state->needs_close ||
	    state->in_flight || state->notifying || state->recovery)
		return;
	state->recovery = g_idle_source_new ();
	g_source_set_callback (state->recovery, recover_on_owner,
	                       g_object_ref (sensor), g_object_unref);
	g_source_attach (state->recovery, state->context);
}

static void
stream_error (SSCSensor *sensor, const GError *error, gpointer unused)
{
	g_autoptr(SSCSensor) retained = g_object_ref (sensor);
	SscPollingState *state = g_object_get_qdata (G_OBJECT (sensor), polling_quark ());
	(void) unused;
	if (!state || !state->owner || state->fault)
		return;
	state->fault = error ? g_error_copy (error) :
		g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "SSC stream failed without an error");
	state->needs_close = TRUE;
	state->recovery_pending = TRUE;
	disconnect_measurement (sensor, state);
	state->fault_reported = TRUE;
	notify_state (state, state->fault);
	schedule_recovery (sensor, state);
}

void
ssc_driver_startup_failed (SensorDevice *device, SSCSensor *sensor, const GError *error)
{
	g_autoptr(SSCSensor) retained = g_object_ref (sensor);
	SscPollingState *state = g_object_get_qdata (G_OBJECT (sensor), polling_quark ());

	g_return_if_fail (error != NULL);
	/* Only a successfully opened, still-owned stream can expire here. The
	 * deadline is armed after OPEN returns, never within its nested wait. */
	if (!state || state->owner != device || !state->active || state->fault ||
	    state->in_flight || state->notifying)
		return;
	state->fault = g_error_copy (error);
	state->needs_close = TRUE;
	state->recovery_pending = TRUE;
	disconnect_measurement (sensor, state);
	state->fault_reported = TRUE;
	/* This private local notification fails pending Claims promptly. A slow
	 * native CLOSE must not hold their reply hostage. No fake provider signal. */
	notify_state (state, state->fault);
	schedule_recovery (sensor, state);
}

static gboolean
connect_error (SSCSensor *sensor, SscPollingState *state, GError **error)
{
	GSignalQuery query = { 0 };
	guint id = g_signal_lookup ("stream-error", G_OBJECT_TYPE (sensor));
	if (id)
		g_signal_query (id, &query);
	if (!id || query.return_type != G_TYPE_NONE || query.n_params != 1 ||
	    (query.param_types[0] & ~G_SIGNAL_TYPE_STATIC_SCOPE) != G_TYPE_ERROR) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
		                     "SSC provider lacks the required stream-error signal");
		return FALSE;
	}
	state->error_handler = g_signal_connect (sensor, "stream-error", G_CALLBACK (stream_error), NULL);
	if (state->error_handler)
		return TRUE;
	g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED, "Could not observe SSC stream errors");
	return FALSE;
}

static void
finish_call (SSCSensor *sensor, SscPollingState *state)
{
	state->in_flight = FALSE;
	schedule_recovery (sensor, state);
}

gboolean
ssc_driver_set_polling_full (SensorDevice *device, SSCSensor *sensor,
			     GCallback measurement, SscPollingOperation open,
			     SscPollingOperation close, gboolean enabled, GError **error)
{
	g_autoptr(SSCSensor) retained = NULL;
	g_autoptr(GError) native_error = NULL;
	SscPollingState *state;
	gulong handler;
	gboolean success;

	g_return_val_if_fail (error == NULL || *error == NULL, FALSE);
	if (!device || !SSC_IS_SENSOR (sensor) || !measurement || !open || !close) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			             "Invalid SSC polling operation");
		return FALSE;
	}
	retained = g_object_ref (sensor);
	state = g_object_get_qdata (G_OBJECT (sensor), polling_quark ());
	if (!state) {
		state = g_new0 (SscPollingState, 1);
		state->owner = device;
		state->close = close;
		state->context = g_main_context_ref_thread_default ();
		g_object_set_qdata_full (G_OBJECT (sensor), polling_quark (), state, state_free);
	}
	if (state->owner != device || state->close != close) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_CLOSED,
			             "SSC adapter has been detached or replaced");
		return FALSE;
	}
	if (!enabled) {
		state->stop_requested = TRUE;
		disconnect_measurement (sensor, state);
	}
	if (state->in_flight || state->notifying) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PENDING,
			             "An SSC polling operation is still pending");
		return FALSE;
	}
	cancel_recovery (state);
	if (!enabled) {
		if (!state->needs_close)
			return TRUE;
		state->in_flight = TRUE;
		success = close_required (sensor, state, &native_error);
		finish_call (sensor, state);
		return success ? TRUE : return_error (error, g_steal_pointer (&native_error));
	}
	if (state->active)
		return TRUE;
	state->in_flight = TRUE;
	state->stop_requested = FALSE;
	if (state->needs_close) {
		success = close_required (sensor, state, &native_error);
		if (!success) {
			finish_call (sensor, state);
			return return_error (error, g_steal_pointer (&native_error));
		}
		if (!state->owner || state->stop_requested) {
			finish_call (sensor, state);
			return cancelled (error);
		}
	}
	if (!connect_error (sensor, state, &native_error)) {
		finish_call (sensor, state);
		return return_error (error, g_steal_pointer (&native_error));
	}
	handler = g_signal_connect (sensor, "measurement", measurement, device);
	if (!handler) {
		disconnect_error (sensor, state);
		finish_call (sensor, state);
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_FAILED,
			             "Could not connect SSC measurement delivery");
		return FALSE;
	}
	state->handler = handler;
	state->needs_close = TRUE;
	success = open (sensor, &native_error);
	if (!success && !native_error)
		native_error = state->fault ? g_error_copy (state->fault) :
			g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "unknown error");
	if (!success || native_error || state->fault || !state->owner ||
	    state->stop_requested || state->handler != handler) {
		g_autoptr(GError) cleanup_error = NULL;
		disconnect_measurement (sensor, state);
		disconnect_error (sensor, state);
		if (!native_error && state->fault)
			native_error = g_error_copy (state->fault);
		if (!native_error)
			cancelled (&native_error);
		if (g_error_matches (native_error, G_IO_ERROR, G_IO_ERROR_PENDING)) {
			/* Rejected admission cannot close another active native call.
			 * A separately observed fault still owes later recovery. */
			if (!state->fault)
				state->needs_close = FALSE;
		} else if (!close_required (sensor, state, &cleanup_error)) {
			append_recovery_error (&native_error, cleanup_error);
			if (state->fault && state->fault_reported) {
				/* The initial fault may have cancelled the proxy's OPEN
				 * attempt already. Preserve and report cleanup failure
				 * independently of that now-stale attempt's return. */
				append_recovery_error (&state->fault, cleanup_error);
				notify_state (state, state->fault);
			}
		}
		finish_call (sensor, state);
		return return_error (error, g_steal_pointer (&native_error));
	}
	state->active = TRUE;
	finish_call (sensor, state);
	return TRUE;
}
