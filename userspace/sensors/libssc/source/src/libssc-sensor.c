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
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

#include "libssc-client-private.h"
#include "libssc-common-private.h"
#include "ssc-common.pb-c.h"
#include "ssc-sensor-suid.pb-c.h"
#include "libssc-sensor.h"
#include "libssc-sensor-private.h"
#include "libssc-lifetime-private.h"
#include "libssc-sensor-accelerometer.h"
#include "libssc-sensor-compass.h"
#include "libssc-sensor-gyroscope.h"
#include "libssc-sensor-light.h"
#include "libssc-sensor-magnetometer.h"
#include "libssc-sensor-proximity.h"
#include <math.h>

#define SENSOR_OPERATION_TIMEOUT_MS 30000
#define SENSOR_REGISTRY_RETRY_MS 1000
#define SENSOR_MAX_REGISTRY_ATTEMPTS 100
#define SENSOR_REPORT_MAILBOX_COUNT 8
#define SENSOR_REPORT_MAX_BYTES ((gsize) G_MAXUINT16)
#define SENSOR_DECODE_MAX_BYTES ((gsize) 4 * 1024 * 1024)
#define SENSOR_SUID_MAX_WIRE_PAIRS 256
#define SENSOR_ATTRIBUTE_MAX_DEPTH 32
#define SENSOR_ATTRIBUTE_MAX_FIELDS 8192
#define SENSOR_STREAM_FRAME_COUNT 64
#define SENSOR_STREAM_FRAME_QUANTUM 16

enum {
	PROP_NAME = 1, PROP_UID_LOW, PROP_UID_HIGH, PROP_VENDOR, PROP_DATA_TYPE,
	PROP_STREAM_TYPE, PROP_AVAILABLE, PROP_SAMPLE_RATE, PROP_CLIENT, PROP_FILE,
	PROP_MOUNT_MATRIX, PROP_SELECTION_ENABLED, N_PROPERTIES
};
static GParamSpec *properties[N_PROPERTIES];
enum { SIGNAL_STREAM_ERROR, SIGNAL_SAMPLE, N_SIGNALS };
static guint sensor_signals[N_SIGNALS];

typedef struct _SensorOperation SensorOperation;
typedef struct _SensorReportTicket SensorReportTicket;
typedef struct _SensorReportSlot SensorReportSlot;
typedef struct _SensorStreamCtl SensorStreamCtl;
typedef struct _SensorStreamTicket SensorStreamTicket;

typedef enum {
	SENSOR_STREAM_UNINITIALIZED, SENSOR_STREAM_CLOSED, SENSOR_STREAM_OPENING,
	SENSOR_STREAM_OPEN, SENSOR_STREAM_CLOSING, SENSOR_STREAM_FAULTED,
	SENSOR_STREAM_RETIRED
} SensorStreamState;

typedef enum { SENSOR_OP_INIT, SENSOR_OP_OPEN, SENSOR_OP_CLOSE, SENSOR_OP_DISCOVER } SensorOperationKind;
typedef enum {
	SENSOR_PHASE_CLIENT, SENSOR_PHASE_REGISTRY, SENSOR_PHASE_SUID,
	SENSOR_PHASE_ATTRIBUTES, SENSOR_PHASE_RETRY, SENSOR_PHASE_OPEN,
	SENSOR_PHASE_CLOSE, SENSOR_PHASE_TERMINAL
} SensorPhase;

typedef struct {
	guint64 uid_high, uid_low;
	gchar *name, *vendor;
	guint stream_type;
	gboolean available;
	gfloat sample_rate;
	gfloat mount_matrix[3][3];
	gboolean have_name, have_vendor, have_stream, have_available, have_rate, have_matrix;
} SensorMetadata;

typedef struct {
	guint64 high, low;
} SensorUid;

struct _SSCSensorUidList {
	gsize length;
	SensorUid *uids;
};

G_DEFINE_BOXED_TYPE (SSCSensorUidList, ssc_sensor_uid_list,
	ssc_sensor_uid_list_copy, ssc_sensor_uid_list_free)

SSCSensorUidList *
ssc_sensor_uid_list_copy (const SSCSensorUidList *list)
{
	SSCSensorUidList *copy;
	g_return_val_if_fail (list != NULL, NULL);
	copy = g_new0 (SSCSensorUidList, 1);
	copy->length = list->length;
	if (copy->length) {
		copy->uids = g_new (SensorUid, copy->length);
		memcpy (copy->uids, list->uids, copy->length * sizeof (SensorUid));
	}
	return copy;
}

void
ssc_sensor_uid_list_free (SSCSensorUidList *list)
{
	if (!list)
		return;
	g_free (list->uids);
	g_free (list);
}

gsize
ssc_sensor_uid_list_get_length (const SSCSensorUidList *list)
{
	g_return_val_if_fail (list != NULL, 0);
	return list->length;
}

gboolean
ssc_sensor_uid_list_get_uid (const SSCSensorUidList *list, gsize index,
			     guint64 *high, guint64 *low)
{
	g_return_val_if_fail (list != NULL, FALSE);
	if (index >= list->length)
		return FALSE;
	if (high)
		*high = list->uids[index].high;
	if (low)
		*low = list->uids[index].low;
	return TRUE;
}

static gint
sensor_uid_compare (gconstpointer first, gconstpointer second, gpointer data)
{
	const SensorUid *a = first, *b = second;
	(void) data;
	if (a->high != b->high)
		return a->high < b->high ? -1 : 1;
	return a->low < b->low ? -1 : a->low > b->low ? 1 : 0;
}

/* Copy only owned fixed64 values while the decoded response is alive. The
 * wire count is checked before deduplication: duplicates do not evade the cap. */
static SSCSensorUidList *
sensor_uid_list_from_response (const SscSuidResponse *response, GError **error)
{
	SSCSensorUidList *list;
	gsize unique = 0;
	if (response->n_uid > SENSOR_SUID_MAX_WIRE_PAIRS ||
	    response->n_uid > G_MAXSIZE / sizeof (SensorUid) ||
	    response->n_uid * sizeof (SensorUid) > SENSOR_REPORT_MAX_BYTES) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NO_SPACE,
			"Sensor SUID inventory exceeds the 256 wire-pair limit");
		return NULL;
	}
	list = g_new0 (SSCSensorUidList, 1);
	if (response->n_uid) {
		list->uids = g_new (SensorUid, response->n_uid);
		for (gsize i = 0; i < response->n_uid; i++) {
			if (!response->uid || !response->uid[i]) {
				g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
					"Sensor SUID inventory contains a missing pair");
				ssc_sensor_uid_list_free (list);
				return NULL;
			}
			list->uids[i].high = response->uid[i]->high;
			list->uids[i].low = response->uid[i]->low;
		}
		g_qsort_with_data (list->uids, (gint) response->n_uid,
			sizeof (SensorUid), sensor_uid_compare, NULL);
		for (gsize i = 0; i < response->n_uid; i++)
			if (!unique || sensor_uid_compare (&list->uids[i],
							   &list->uids[unique - 1], NULL))
				list->uids[unique++] = list->uids[i];
	}
	list->length = unique;
	return list;
}

static gboolean
sensor_uid_list_contains (const SSCSensorUidList *list, guint64 high, guint64 low)
{
	for (gsize i = 0; i < list->length; i++)
		if (list->uids[i].high == high && list->uids[i].low == low)
			return TRUE;
	return FALSE;
}

struct _SensorReportTicket {
	gint refs;
	SensorOperation *operation;
	SensorPhase phase;
	guint epoch;
	guint64 uid_high, uid_low;
};

struct _SensorReportSlot {
	SensorReportSlot *next;
	gboolean reserved, copying;
	SensorReportTicket *ticket;
	guint32 message_id;
	GBytes *bytes;
};

struct _SensorOperation {
	gint refs;
	SscLifetimeNode *lifetime;
	GMainContext *owner;
	GTask *task;
	SSCSensor *self; /* borrowed from task until terminal decision */
	SensorOperationKind kind;
	SensorPhase phase;
	guint epoch;
	gint done; /* atomic read from cancellation/foreign report callbacks */
	gint published_epoch; /* mailbox admission snapshot, not wire correlation */
	SSCClient *client;
	GCancellable *caller, *transport;
	gulong cancel_id, report_id, failure_id;
	SensorReportTicket *report_ticket; /* owner ref; broken on phase/terminal cleanup */
	gint cancel_queued, foreign_fault_queued;
	GSource *deadline_source, *retry_source, *progress_source;
	gboolean progress_again;
	gint64 deadline_usec;
	gboolean ack_seen, report_seen, registry_present;
	guint registry_attempts;
	gchar *data_type;
	SensorMetadata metadata;
	gboolean selection_enabled;
	guint64 requested_uid_high, requested_uid_low;
	SSCSensorUidList *discovered_uids;
	/* Foreign report ingress never reads mutable sensor/private state. */
	GMutex mail_mutex;
	SensorReportSlot mail_slots[SENSOR_REPORT_MAILBOX_COUNT];
	SensorReportSlot *mail_head, *mail_tail;
	guint mail_used;
	gboolean mail_scheduled, mail_failed, mail_failure_claimed;
	gint mail_error_code;
	SensorStreamCtl *stream;
	guint64 stream_epoch;
	guint stream_phase_epoch;
	gboolean stream_started, stream_repeat_open, may_have_submitted;
};

/* Persistent ownership stops at weak sensor/client links. Signal closures and
 * transient dispatch/retire tickets own controller refs, never the sensor.
 * mutex serializes publication identity and foreign fault ingress; queue,
 * handler/source management and all decoder work remain fixed-owner-only. */
struct _SensorStreamCtl {
	gint refs, retired, retire_queued;
	SscLifetime *lifetime;
	GMainContext *owner;
	GWeakRef sensor, client;
	const SscSensorDecoder *decoder;
	GMutex mutex;
	SensorStreamState state;
	guint64 epoch, sequence;
	SensorStreamTicket *current; /* borrowed from signal closure(s) */
	GError *pending_error, *error;
	gboolean fault_queued, fault_notified;
	gulong frame_id, failure_id;
	GSource *drain_source; /* attached source owns itself; no owning backedge */
	gboolean drain_active, drain_deferred; /* owner-only, across source replacement */
	SscMeasurementSnapshot snapshot;
	SscMeasurementFrame frames[SENSOR_STREAM_FRAME_COUNT];
	guint head, count;
	gboolean proximity_seen, proximity_near;
};

struct _SensorStreamTicket {
	gint refs;
	SscLifetimeNode *lifetime;
	SensorStreamCtl *stream;
	SensorOperation *operation; /* owning, NULL for steady delivery */
	guint phase_epoch;
	guint64 stream_epoch;
	SensorStreamState state;
};

typedef struct {
	GMainContext *owner;
	GThread *construction_thread;
	SscLifetime *lifetime;
	SensorOperation *active;
	gboolean disposed, initialized, metadata_valid, ever_external_client;
	gboolean selection_enabled;
	guint64 uid_low, uid_high;
	gchar *name, *vendor, *data_type;
	guint stream_type;
	gboolean available;
	gfloat sample_rate;
	gfloat mount_matrix[3][3];
	SSCClient *client;
	SensorStreamCtl *stream;
} SSCSensorPrivate;

static void async_initable_iface_init (GAsyncInitableIface *iface);
G_DEFINE_TYPE_WITH_CODE (SSCSensor, ssc_sensor, G_TYPE_OBJECT,
	G_ADD_PRIVATE (SSCSensor)
	G_IMPLEMENT_INTERFACE (G_TYPE_ASYNC_INITABLE, async_initable_iface_init))

static SensorOperation *operation_ref (SensorOperation *operation);
static void operation_unref (SensorOperation *operation);
static void operation_terminal (SensorOperation *operation, GError *error);
static gboolean operation_guard (SensorOperation *operation);
static void operation_progress (SensorOperation *operation);
static void operation_schedule_progress (SensorOperation *operation);
static void operation_begin_phase (SensorOperation *operation, SensorPhase phase);
static void clear_report_observer (SensorOperation *operation);
static void operation_report (SensorReportTicket *ticket, guint32 message_id,
			      const guint8 *bytes, gsize length);
static SensorStreamCtl *stream_ref (SensorStreamCtl *stream);
static void stream_unref (SensorStreamCtl *stream);
static gboolean stream_ticket_current_locked (SensorStreamTicket *ticket);
static gboolean stream_begin_operation (SensorOperation *operation);
static gboolean stream_terminal_lock (SensorOperation *operation, GError **error);
static void stream_terminal_state_locked (SensorOperation *operation, GError *error,
					 GError **notice, gboolean *arm);
static void stream_after_terminal (SensorOperation *operation, GError *notice, gboolean arm);
static void stream_clear_observers (SensorStreamCtl *stream, SSCClient *client);
static void stream_cancel_drain (SensorStreamCtl *stream);
static void stream_schedule_drain (SensorStreamCtl *stream);
static void stream_retire (SensorStreamCtl *stream, SSCClient *client);
static void stream_metadata_commit (SensorStreamCtl *stream, SSCSensorPrivate *priv);
static void stream_queue_fault (SensorStreamTicket *ticket, const GError *error);

GQuark
ssc_sensor_error_quark (void)
{
	return g_quark_from_static_string ("ssc-sensor");
}

static void
metadata_identity (SensorMetadata *metadata)
{
	memset (metadata, 0, sizeof (*metadata));
	metadata->mount_matrix[0][0] = 1.0f;
	metadata->mount_matrix[1][1] = 1.0f;
	metadata->mount_matrix[2][2] = 1.0f;
}

static void
metadata_clear (SensorMetadata *metadata)
{
	g_clear_pointer (&metadata->name, g_free);
	g_clear_pointer (&metadata->vendor, g_free);
}

static void
queue_owner (GMainContext *owner, gint priority, GSourceFunc callback,
	     gpointer data, GDestroyNotify destroy)
{
	GSource *source = g_idle_source_new ();
	g_source_set_priority (source, priority);
	g_source_set_can_recurse (source, FALSE);
	g_source_set_callback (source, callback, data, destroy);
	g_source_attach (source, owner);
	g_source_unref (source);
}

static SensorOperation *
operation_ref (SensorOperation *operation)
{
	g_atomic_int_inc (&operation->refs);
	return operation;
}

static void
operation_unref (SensorOperation *operation)
{
	SscLifetimeNode *lifetime;
	if (!g_atomic_int_dec_and_test (&operation->refs))
		return;
	g_assert (g_atomic_int_get (&operation->done));
	g_assert (!operation->task && !operation->self && !operation->client);
	g_assert (!operation->report_id && !operation->failure_id && !operation->cancel_id);
	g_assert (!operation->report_ticket);
	g_assert (!operation->deadline_source && !operation->retry_source &&
		  !operation->progress_source);
	g_assert (!operation->mail_used && !operation->mail_head && !operation->mail_scheduled);
	g_clear_object (&operation->caller);
	g_clear_object (&operation->transport);
	g_clear_pointer (&operation->stream, stream_unref);
	metadata_clear (&operation->metadata);
	g_clear_pointer (&operation->discovered_uids, ssc_sensor_uid_list_free);
	g_free (operation->data_type);
	g_mutex_clear (&operation->mail_mutex);
	g_main_context_unref (operation->owner);
	lifetime = operation->lifetime;
	g_free (operation);
	/* The operation node includes late private callback/source/closure tails,
	 * not merely its already-published public logical GTask result. */
	ssc_lifetime_node_unref (lifetime);
}

static SensorReportTicket *
report_ticket_ref (SensorReportTicket *ticket)
{
	g_atomic_int_inc (&ticket->refs);
	return ticket;
}

static void
report_ticket_unref (SensorReportTicket *ticket)
{
	if (!g_atomic_int_dec_and_test (&ticket->refs))
		return;
	operation_unref (ticket->operation);
	g_free (ticket);
}

static void
report_ticket_destroy (gpointer data, GClosure *closure)
{
	(void) closure;
	report_ticket_unref (data);
}

static void
operation_closure_destroy (gpointer data, GClosure *closure)
{
	(void) closure;
	operation_unref (data);
}

static void
destroy_source (GSource **field)
{
	GSource *source = g_steal_pointer (field);
	if (source) {
		g_source_destroy (source);
		g_source_unref (source);
	}
}

static gboolean
operation_cancelled (SensorOperation *operation)
{
	return operation->caller && g_cancellable_is_cancelled (operation->caller);
}

static GError *
operation_cancel_error (void)
{
	return g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CANCELLED, "Sensor operation cancelled");
}

static GError *
operation_timeout_error (void)
{
	return g_error_new_literal (G_IO_ERROR, G_IO_ERROR_TIMED_OUT, "Sensor operation timed out");
}

/* Committed fields change without any user callback between individual writes.
 * Owner serialization is required; the borrowed matrix is not an atomic API. */
static SSCClient *
metadata_commit (SensorOperation *operation)
{
	SSCSensorPrivate *priv = ssc_sensor_get_instance_private (operation->self);
	SSCClient *old = priv->client;
	g_free (priv->name);
	g_free (priv->vendor);
	priv->name = g_steal_pointer (&operation->metadata.name);
	priv->vendor = g_steal_pointer (&operation->metadata.vendor);
	priv->uid_high = operation->metadata.uid_high;
	priv->uid_low = operation->metadata.uid_low;
	priv->stream_type = operation->metadata.stream_type;
	priv->available = operation->metadata.available;
	priv->sample_rate = operation->metadata.sample_rate;
	memcpy (priv->mount_matrix, operation->metadata.mount_matrix, sizeof (priv->mount_matrix));
	priv->client = g_object_ref (operation->client);
	priv->metadata_valid = TRUE;
	priv->initialized = TRUE;
	stream_metadata_commit (priv->stream, priv);
	return old; /* release only after terminal publication/cleanup */
}

static void
operation_terminal (SensorOperation *operation, GError *error)
{
	SSCSensorPrivate *priv;
	GTask *task;
	SSCClient *old_client = NULL, *client;
	gboolean drop_active = FALSE;
	gboolean stream_locked, arm_stream = FALSE;
	GError *stream_notice = NULL;
	if (g_atomic_int_get (&operation->done)) {
		g_clear_error (&error);
		return;
	}
	operation_ref (operation);
	g_assert (g_main_context_is_owner (operation->owner));
	priv = ssc_sensor_get_instance_private (operation->self);
	if (!error && operation_cancelled (operation))
		error = operation_cancel_error ();
	if (!error && operation->deadline_usec &&
	    g_get_monotonic_time () >= operation->deadline_usec)
		error = operation_timeout_error ();
	if (!error && priv->disposed)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED, "Sensor disposed");
	if (!error && ssc_lifetime_is_sealed (priv->lifetime))
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED, "Sensor retired");
	if (!error && operation->client)
		error = ssc_client_dup_report_error (operation->client);
	if (!error && operation->kind == SENSOR_OP_DISCOVER && !operation->discovered_uids)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED,
			"Sensor discovery completed without an inventory");
	/* Linearize mailbox closure with foreign reservation: a known handoff
	 * failure cannot race a successful result merely because its idle is late. */
	g_mutex_lock (&operation->mail_mutex);
	if (!error && operation->mail_failed)
		error = g_error_new_literal (G_IO_ERROR, operation->mail_error_code,
			"Sensor report handoff failed");
	stream_locked = stream_terminal_lock (operation, &error);
	/* This is the immutable logical result. Later caller cancellation cannot
	 * replace it at GTask finish; late tickets see done before touching self. */
	g_atomic_int_set (&operation->done, TRUE);
	operation->phase = SENSOR_PHASE_TERMINAL;
	operation->epoch++;
	g_atomic_int_set (&operation->published_epoch, operation->epoch);
	if (stream_locked) {
		stream_terminal_state_locked (operation, error, &stream_notice, &arm_stream);
		g_mutex_unlock (&operation->stream->mutex);
	}
	g_mutex_unlock (&operation->mail_mutex);
	if (stream_locked && !arm_stream &&
	    operation->stream->state != SENSOR_STREAM_OPEN) {
		stream_cancel_drain (operation->stream);
		stream_clear_observers (operation->stream, operation->client);
	}
	if (priv->active == operation) {
		priv->active = NULL;
		drop_active = TRUE;
	}
	if (!error && operation->kind == SENSOR_OP_INIT && !priv->initialized)
		old_client = metadata_commit (operation);
	clear_report_observer (operation);
	if (operation->failure_id) {
		operation->failure_id = 0;
		/* Failure observer data is this exact live operation, never another
		 * sensor/operation on a shared client. Already removed is an empty set. */
		g_signal_handlers_disconnect_matched (operation->client,
			G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, operation);
	}
	destroy_source (&operation->deadline_source);
	destroy_source (&operation->retry_source);
	destroy_source (&operation->progress_source);
	if (operation->cancel_id) {
		g_cancellable_disconnect (operation->caller, operation->cancel_id);
		operation->cancel_id = 0;
	}
	g_clear_object (&operation->caller);
	if (error && operation->transport)
		g_cancellable_cancel (operation->transport);
	task = g_steal_pointer (&operation->task);
	client = g_steal_pointer (&operation->client);
	operation->self = NULL;
	if (error) {
		g_clear_pointer (&operation->discovered_uids, ssc_sensor_uid_list_free);
		g_task_return_error (task, error);
	} else if (operation->kind == SENSOR_OP_DISCOVER)
		g_task_return_pointer (task, g_steal_pointer (&operation->discovered_uids),
			(GDestroyNotify) ssc_sensor_uid_list_free);
	else
		g_task_return_boolean (task, TRUE);
	/* Logical task publication precedes pending sample/error delivery. Callback
	 * execution on a different caller context has no total ordering promise. */
	stream_after_terminal (operation, stream_notice, arm_stream);
	g_object_unref (task);
	g_clear_object (&client);
	g_clear_object (&old_client);
	if (drop_active)
		operation_unref (operation);
	operation_unref (operation);
}

static gboolean
operation_guard (SensorOperation *operation)
{
	SSCSensorPrivate *priv;
	GError *error = NULL;
	if (g_atomic_int_get (&operation->done))
		return FALSE;
	g_assert (g_main_context_is_owner (operation->owner));
	priv = ssc_sensor_get_instance_private (operation->self);
	if (priv->disposed || ssc_lifetime_is_sealed (priv->lifetime) ||
	    priv->active != operation)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED, "Sensor operation is no longer current");
	else if (operation_cancelled (operation))
		error = operation_cancel_error ();
	else if (g_get_monotonic_time () >= operation->deadline_usec)
		error = operation_timeout_error ();
	else if (operation->client)
		error = ssc_client_dup_report_error (operation->client);
	if (!error && operation->stream &&
	    (operation->stream_started || operation->stream_repeat_open)) {
		SensorStreamCtl *stream = operation->stream;
		g_mutex_lock (&stream->mutex);
		if (g_atomic_int_get (&stream->retired) || stream->epoch != operation->stream_epoch)
			error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED, "Sensor stream is no longer current");
		else if (stream->pending_error)
			error = g_error_copy (stream->pending_error);
		else if (operation->stream_started && (!stream->current ||
			 stream->current->operation != operation ||
			 stream->current->phase_epoch != operation->stream_phase_epoch))
			error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED, "Sensor stream observer is no longer current");
		g_mutex_unlock (&stream->mutex);
	}
	if (!error) {
		g_mutex_lock (&operation->mail_mutex);
		if (operation->mail_failed)
			error = g_error_new_literal (G_IO_ERROR, operation->mail_error_code,
				"Sensor report handoff failed");
		g_mutex_unlock (&operation->mail_mutex);
	}
	if (!error)
		return TRUE;
	operation_terminal (operation, error);
	return FALSE;
}

static gboolean
cancel_on_owner (gpointer data)
{
	SensorOperation *operation = data;
	if (!g_atomic_int_get (&operation->done))
		operation_terminal (operation, operation_cancel_error ());
	return G_SOURCE_REMOVE;
}

static void
caller_cancelled (GCancellable *caller, gpointer data)
{
	SensorOperation *operation = data;
	(void) caller;
	if (g_atomic_int_compare_and_exchange (&operation->cancel_queued, 0, 1))
		queue_owner (operation->owner, G_PRIORITY_DEFAULT, cancel_on_owner,
			operation_ref (operation), (GDestroyNotify) operation_unref);
}

static gboolean
deadline_on_owner (gpointer data)
{
	SensorOperation *operation = operation_ref (data);
	if (!g_atomic_int_get (&operation->done))
		operation_terminal (operation, operation_timeout_error ());
	operation_unref (operation);
	return G_SOURCE_REMOVE;
}

static gboolean
progress_on_owner (gpointer data)
{
	SensorOperation *operation = operation_ref (data);
	GSource *current = g_main_current_source ();
	gboolean again;
	operation->progress_again = FALSE;
	if (!g_atomic_int_get (&operation->done))
		operation_progress (operation);
	again = operation->progress_again && !g_atomic_int_get (&operation->done);
	if (operation->progress_source == current) {
		operation->progress_source = NULL;
		g_source_unref (current);
	}
	if (again)
		operation_schedule_progress (operation);
	operation_unref (operation);
	return G_SOURCE_REMOVE;
}

static void
operation_schedule_progress (SensorOperation *operation)
{
	if (g_atomic_int_get (&operation->done))
		return;
	if (operation->progress_source) {
		operation->progress_again = TRUE;
		return;
	}
	operation->progress_source = g_idle_source_new ();
	g_source_set_priority (operation->progress_source, G_PRIORITY_DEFAULT);
	g_source_set_can_recurse (operation->progress_source, FALSE);
	g_source_set_callback (operation->progress_source, progress_on_owner,
		operation_ref (operation), (GDestroyNotify) operation_unref);
	g_source_attach (operation->progress_source, operation->owner);
}

/* Real generated codecs use this bounded allocator during one owner callback.
 * The result is parsed/copied and freed before the stack allocator goes away. */
typedef union {
	gsize charged;
	long double alignment;
	gpointer pointer_alignment;
} SensorAllocation;

typedef struct {
	ProtobufCAllocator allocator;
	gsize live;
	gboolean exceeded;
} SensorDecode;

static void *
sensor_decode_alloc (void *data, size_t size)
{
	SensorDecode *decode = data;
	SensorAllocation *allocation;
	gsize charged;
	if (size > SENSOR_DECODE_MAX_BYTES - sizeof (SensorAllocation)) {
		decode->exceeded = TRUE;
		return NULL;
	}
	charged = size + sizeof (SensorAllocation);
	if (decode->live > SENSOR_DECODE_MAX_BYTES - charged) {
		decode->exceeded = TRUE;
		return NULL;
	}
	allocation = g_malloc (charged);
	allocation->charged = charged;
	decode->live += charged;
	return allocation + 1;
}

static void
sensor_decode_free (void *data, void *pointer)
{
	SensorDecode *decode = data;
	SensorAllocation *allocation;
	if (!pointer)
		return;
	allocation = ((SensorAllocation *) pointer) - 1;
	g_assert (decode->live >= allocation->charged);
	decode->live -= allocation->charged;
	g_free (allocation);
}

static void
sensor_decode_init (SensorDecode *decode)
{
	memset (decode, 0, sizeof (*decode));
	decode->allocator.alloc = sensor_decode_alloc;
	decode->allocator.free = sensor_decode_free;
	decode->allocator.allocator_data = decode;
}

static GError *
sensor_decode_error (SensorDecode *decode)
{
	return g_error_new_literal (G_IO_ERROR,
		decode->exceeded ? G_IO_ERROR_NO_SPACE : G_IO_ERROR_INVALID_DATA,
		decode->exceeded ? "Sensor report decoded allocation budget exhausted" :
		"Cannot decode sensor report");
}

static SensorStreamCtl *
stream_ref (SensorStreamCtl *stream)
{
	g_atomic_int_inc (&stream->refs);
	return stream;
}

static void
stream_unref (SensorStreamCtl *stream)
{
	if (!g_atomic_int_dec_and_test (&stream->refs))
		return;
	g_assert (!stream->frame_id && !stream->failure_id && !stream->drain_source);
	g_weak_ref_clear (&stream->sensor);
	g_weak_ref_clear (&stream->client);
	g_clear_error (&stream->pending_error);
	g_clear_error (&stream->error);
	g_mutex_clear (&stream->mutex);
	g_main_context_unref (stream->owner);
	ssc_lifetime_unref (stream->lifetime);
	g_free (stream);
}

static SensorStreamTicket *
stream_ticket_ref (SensorStreamTicket *ticket)
{
	g_atomic_int_inc (&ticket->refs);
	return ticket;
}

static void
stream_ticket_unref (SensorStreamTicket *ticket)
{
	SensorStreamCtl *stream = ticket->stream;
	SscLifetimeNode *lifetime;
	/* Current-pointer promotion and the final decrement share this mutex.
	 * A foreign closure destroy cannot expose a still-published refs==0 ticket. */
	g_mutex_lock (&stream->mutex);
	if (!g_atomic_int_dec_and_test (&ticket->refs)) {
		g_mutex_unlock (&stream->mutex);
		return;
	}
	/* Unexpected client disposal can invalidate its closures before the owner
	 * fault ticket runs. Never leave a non-owning current pointer dangling. */
	if (stream->current == ticket)
		stream->current = NULL;
	g_mutex_unlock (&stream->mutex);
	if (ticket->operation)
		operation_unref (ticket->operation);
	stream_unref (stream);
	lifetime = ticket->lifetime;
	g_free (ticket);
	ssc_lifetime_node_unref (lifetime);
}

static void
stream_ticket_destroy (gpointer data, GClosure *closure)
{
	SensorStreamTicket *ticket = data;
	GError *error;
	(void) closure;
	/* Planned replacements/retirement publish a different/NULL ticket before
	 * disconnect. Unexpected destruction of a CURRENT handler is visible loss. */
	error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED,
		"Sensor stream observer disconnected");
	stream_queue_fault (ticket, error);
	g_error_free (error);
	stream_ticket_unref (ticket);
}

/* Caller holds stream mutex. This check is valid on foreign threads: it reads
 * only mutex-protected publication and immutable ticket fields, never priv.
 * Operation phase/current-self checks additionally run on owner before use. */
static gboolean
stream_ticket_current_locked (SensorStreamTicket *ticket)
{
	SensorStreamCtl *stream = ticket->stream;
	return !g_atomic_int_get (&stream->retired) &&
		!ssc_lifetime_is_sealed (stream->lifetime) && stream->current == ticket &&
		stream->epoch == ticket->stream_epoch && stream->state == ticket->state;
}

static gboolean
stream_ticket_current (SensorStreamTicket *ticket)
{
	SensorStreamCtl *stream = ticket->stream;
	gboolean current;
	g_mutex_lock (&stream->mutex);
	current = stream_ticket_current_locked (ticket);
	g_mutex_unlock (&stream->mutex);
	if (current && ticket->operation) {
		SensorOperation *operation = ticket->operation;
		SSCSensorPrivate *priv;
		if (g_atomic_int_get (&operation->done) ||
		    operation->epoch != ticket->phase_epoch ||
		    operation->stream_epoch != ticket->stream_epoch || !operation->self)
			return FALSE;
		priv = ssc_sensor_get_instance_private (operation->self);
		current = priv->active == operation && !priv->disposed;
	}
	return current;
}

/* Fixed-owner frame authorization, including a fault already queued by a
 * callback or foreign ingress. No mutex spans an application callback. A
 * later foreign fault may still arrive after this check; it is handled by the
 * existing owner fault path, not by an invented atomic delivery guarantee. */
static gboolean
stream_frame_current (SensorStreamTicket *ticket, const SscMeasurementFrame *frame)
{
	SensorStreamCtl *stream = ticket->stream;
	gboolean current;
	if (!stream_ticket_current (ticket))
		return FALSE;
	g_mutex_lock (&stream->mutex);
	current = stream_ticket_current_locked (ticket) && !stream->pending_error &&
		stream->count && stream->frames[stream->head].epoch == frame->epoch &&
		stream->frames[stream->head].sequence == frame->sequence;
	g_mutex_unlock (&stream->mutex);
	return current;
}

static void
stream_cancel_drain (SensorStreamCtl *stream)
{
	GSource *source = g_steal_pointer (&stream->drain_source);
	if (source)
		g_source_destroy (source); /* controller holds no owning source ref */
}

static void
stream_clear_observers (SensorStreamCtl *stream, SSCClient *client)
{
	SensorStreamTicket *old_ticket;
	g_mutex_lock (&stream->mutex);
	old_ticket = stream->current ? stream_ticket_ref (stream->current) : NULL;
	stream->current = NULL;
	g_mutex_unlock (&stream->mutex);
	stream->frame_id = stream->failure_id = 0;
	if (old_ticket) {
		/* Exact DATA matching is one GLib-serialized operation and accepts an
		 * empty set. Numeric IDs may already have been removed/reused. Never
		 * hold stream mutex across closure destroy notifications. */
		if (client)
			g_signal_handlers_disconnect_matched (client, G_SIGNAL_MATCH_DATA,
				0, 0, NULL, NULL, old_ticket);
		stream_ticket_unref (old_ticket);
	}
}

static void
stream_emit_notice (SensorStreamCtl *stream, GError *notice)
{
	SSCSensor *self;
	if (!notice)
		return;
	self = g_weak_ref_get (&stream->sensor);
	if (self && !g_atomic_int_get (&stream->retired) &&
	    !ssc_lifetime_is_sealed (stream->lifetime))
		g_signal_emit (self, sensor_signals[SIGNAL_STREAM_ERROR], 0, notice);
	g_clear_object (&self);
	g_error_free (notice); /* separate immutable emission copy, borrowed by handlers */
}

static void
stream_fail_current (SensorStreamTicket *ticket, GError *error)
{
	SensorStreamCtl *stream = ticket->stream;
	SSCClient *client;
	GError *notice = NULL;
	g_assert (g_main_context_is_owner (stream->owner));
	if (!stream_ticket_current (ticket)) {
		g_clear_error (&error);
		return;
	}
	if (ticket->operation) {
		/* terminal owns a distinct error and commits its task before notification */
		operation_terminal (ticket->operation, error);
		return;
	}
	g_mutex_lock (&stream->mutex);
	if (!stream_ticket_current_locked (ticket)) {
		g_mutex_unlock (&stream->mutex);
		g_clear_error (&error);
		return;
	}
	if (!stream->error)
		stream->error = g_error_copy (error);
	stream->state = SENSOR_STREAM_FAULTED;
	stream->head = stream->count = 0;
	g_clear_error (&stream->pending_error);
	stream->fault_queued = FALSE;
	if (!stream->fault_notified) {
		stream->fault_notified = TRUE;
		notice = g_error_copy (stream->error);
	}
	g_mutex_unlock (&stream->mutex);
	stream_cancel_drain (stream);
	client = g_weak_ref_get (&stream->client);
	stream_clear_observers (stream, client);
	g_clear_object (&client);
	g_error_free (error);
	stream_emit_notice (stream, notice);
}

static gboolean
stream_fault_on_owner (gpointer data)
{
	SensorStreamTicket *ticket = stream_ticket_ref (data);
	SensorStreamCtl *stream = ticket->stream;
	GError *error = NULL;
	g_mutex_lock (&stream->mutex);
	if (stream_ticket_current_locked (ticket) && stream->pending_error)
		error = g_error_copy (stream->pending_error);
	g_mutex_unlock (&stream->mutex);
	if (error)
		stream_fail_current (ticket, error);
	stream_ticket_unref (ticket);
	return G_SOURCE_REMOVE;
}

/* A wrong owner is a detectable programming-contract failure, not caller
 * authentication. Old/retired tickets DROP without faulting a newer session.
 * At most one bounded event is published per epoch; no payload is inspected. */
static void
stream_queue_fault (SensorStreamTicket *ticket, const GError *error)
{
	SensorStreamCtl *stream = ticket->stream;
	gboolean attach = FALSE;
	g_mutex_lock (&stream->mutex);
	if (stream_ticket_current_locked (ticket) && !stream->fault_queued) {
		stream->pending_error = error ? g_error_copy (error) :
			g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED,
				"Sensor stream callback violated its fixed owner context");
		stream->fault_queued = TRUE;
		attach = TRUE;
	}
	g_mutex_unlock (&stream->mutex);
	if (attach)
		queue_owner (stream->owner, G_PRIORITY_DEFAULT, stream_fault_on_owner,
			stream_ticket_ref (ticket), (GDestroyNotify) stream_ticket_unref);
}

static void
stream_client_failed (SSCClient *client, GError *error, gpointer data)
{
	SensorStreamTicket *ticket = stream_ticket_ref (data);
	SensorStreamCtl *stream = ticket->stream;
	(void) client;
	if (!g_main_context_is_owner (stream->owner))
		stream_queue_fault (ticket, error);
	else if (stream_ticket_current (ticket))
		stream_fail_current (ticket, error ? g_error_copy (error) :
			g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "Sensor client report failed"));
	stream_ticket_unref (ticket);
}

typedef struct {
	SensorStreamCtl *stream;
	SscLifetimeNode *lifetime;
} SensorStreamDrain;

static void
stream_drain_free (SensorStreamDrain *drain)
{
	SscLifetimeNode *lifetime = drain->lifetime;
	stream_unref (drain->stream);
	g_free (drain);
	ssc_lifetime_node_unref (lifetime);
}

static gboolean
stream_drain (gpointer data)
{
	SensorStreamDrain *drain = data;
	SensorStreamCtl *stream = stream_ref (drain->stream);
	SscLifetimeNode *lifetime = ssc_lifetime_node_ref (drain->lifetime);
	GSource *source = g_main_current_source ();
	guint work = 0;
	gboolean again = FALSE;
	gboolean keep_source, deferred;
	if (stream->drain_source != source) {
		stream_unref (stream);
		ssc_lifetime_node_unref (lifetime);
		return G_SOURCE_REMOVE;
	}
	if (stream->drain_active) {
		stream->drain_deferred = TRUE;
		if (stream->drain_source == source)
			stream->drain_source = NULL;
		stream_unref (stream);
		ssc_lifetime_node_unref (lifetime);
		return G_SOURCE_REMOVE;
	}
	stream->drain_active = TRUE;
	stream->drain_deferred = FALSE;
	while (work < SENSOR_STREAM_FRAME_QUANTUM) {
		SscMeasurementFrame frame;
		SSCSensorSample *sample;
		guint64 uid_high = 0, uid_low = 0;
		SensorStreamTicket *ticket = NULL;
		GError *error = NULL;
		SSCSensor *self;
		g_mutex_lock (&stream->mutex);
		if (!g_atomic_int_get (&stream->retired) &&
		    !ssc_lifetime_is_sealed (stream->lifetime) && stream->state == SENSOR_STREAM_OPEN &&
		    stream->current) {
			ticket = stream_ticket_ref (stream->current);
			uid_high = stream->snapshot.uid_high;
			uid_low = stream->snapshot.uid_low;
			if (stream->pending_error)
				error = g_error_copy (stream->pending_error);
		}
		g_mutex_unlock (&stream->mutex);
		if (!ticket)
			break;
		if (error) {
			stream_fail_current (ticket, error);
			stream_ticket_unref (ticket);
			break;
		}
		if (!stream_ticket_current (ticket) || !stream->count) {
			stream_ticket_unref (ticket);
			break;
		}
		/* Keep the active frame charged through both callbacks. Reentrant
		 * close/dispose may reset the FIFO; never pop its successor session. */
		frame = stream->frames[stream->head];
		self = g_weak_ref_get (&stream->sensor);
		if (!self) {
			stream_ticket_unref (ticket);
			break;
		}
		/* Freeze value/identity before user code; the box owns no backend or
		 * sensor reference and may safely outlive this stream. */
		sample = ssc_sensor_sample_new (uid_high, uid_low, &frame);
		if (!sample) {
			/* Admission already checks the decoder kind. Fail visibly if a
			 * future internal producer violates that invariant; never emit a
			 * NULL public value or silently drop its companion metadata. */
			stream_fail_current (ticket, g_error_new_literal (G_IO_ERROR,
				G_IO_ERROR_INVALID_DATA, "Invalid semantic sample kind"));
			g_object_unref (self);
			stream_ticket_unref (ticket);
			break;
		}
		stream->decoder->emit_legacy (self, &frame);
		g_object_unref (self);
		/* Preserve legacy last-user-unref/disposal timing. Reacquire, rather
		 * than retaining self across both notification windows. */
		if (!stream_frame_current (ticket, &frame)) {
			ssc_sensor_sample_free (sample);
			stream_ticket_unref (ticket);
			break;
		}
		self = g_weak_ref_get (&stream->sensor);
		if (!self || !stream_frame_current (ticket, &frame)) {
			g_clear_object (&self);
			ssc_sensor_sample_free (sample);
			stream_ticket_unref (ticket);
			break;
		}
		g_signal_emit (self, sensor_signals[SIGNAL_SAMPLE], 0, sample);
		g_object_unref (self);
		ssc_sensor_sample_free (sample);
		if (!stream_frame_current (ticket, &frame)) {
			stream_ticket_unref (ticket);
			break;
		}
		stream->head = (stream->head + 1) % SENSOR_STREAM_FRAME_COUNT;
		stream->count--;
		stream_ticket_unref (ticket);
		work++;
	}
	g_mutex_lock (&stream->mutex);
	again = !g_atomic_int_get (&stream->retired) &&
		!ssc_lifetime_is_sealed (stream->lifetime) && stream->state == SENSOR_STREAM_OPEN &&
		stream->count > 0 && stream->current != NULL;
	g_mutex_unlock (&stream->mutex);
	/* A reentrant CLOSE->OPEN can destroy this source and stage a successor.
	 * Only its callback-unwound epilogue may create the next source; the old
	 * source is compared by identity, never dereferenced or unrefed here. */
	keep_source = again && stream->drain_source == source;
	if (!keep_source && stream->drain_source == source)
		stream->drain_source = NULL;
	deferred = stream->drain_deferred;
	stream->drain_active = stream->drain_deferred = FALSE;
	if (!keep_source && (again || deferred))
		stream_schedule_drain (stream);
	stream_unref (stream);
	/* A destroyed source may already have run its destroy notify during a
	 * reentrant callback. Keep its node live through this actual epilogue. */
	ssc_lifetime_node_unref (lifetime);
	return keep_source ? G_SOURCE_CONTINUE : G_SOURCE_REMOVE;
}

static void
stream_schedule_drain (SensorStreamCtl *stream)
{
	GSource *source;
	SensorStreamTicket *parent;
	SensorStreamDrain *drain;
	if (stream->drain_active) {
		stream->drain_deferred = TRUE;
		return;
	}
	if (stream->drain_source || !stream->count ||
	    stream->state != SENSOR_STREAM_OPEN || g_atomic_int_get (&stream->retired) ||
	    ssc_lifetime_is_sealed (stream->lifetime))
		return;
	g_mutex_lock (&stream->mutex);
	parent = stream->current ? stream_ticket_ref (stream->current) : NULL;
	g_mutex_unlock (&stream->mutex);
	if (!parent)
		return;
	drain = g_new0 (SensorStreamDrain, 1);
	drain->stream = stream_ref (stream);
	drain->lifetime = ssc_lifetime_node_new (stream->lifetime, parent->lifetime,
		"sensor-stream-drain");
	stream_ticket_unref (parent);
	g_assert (drain->lifetime);
	source = g_idle_source_new ();
	g_source_set_priority (source, G_PRIORITY_DEFAULT);
	g_source_set_can_recurse (source, FALSE);
	g_source_set_callback (source, stream_drain, drain,
		(GDestroyNotify) stream_drain_free);
	stream->drain_source = source;
	g_source_attach (source, stream->owner);
	g_source_unref (source);
}

static void
stream_frame_received (SSCClient *client, guint32 message_id, guint64 uid_high,
		       guint64 uid_low, guint64 raw_timestamp, GArray *buffer, gpointer data)
{
	SensorStreamTicket *ticket = stream_ticket_ref (data);
	SensorStreamCtl *stream = ticket->stream;
	SscMeasurementFrame frame = {0};
	SensorDecode decode;
	GError *error = NULL;
	gboolean recognized = FALSE, decoded;
	(void) client;
	if (!g_main_context_is_owner (stream->owner)) {
		stream_queue_fault (ticket, NULL);
		goto out;
	}
	if (!stream_ticket_current (ticket) ||
	    (ticket->state != SENSOR_STREAM_OPENING && ticket->state != SENSOR_STREAM_OPEN) ||
	    uid_high != stream->snapshot.uid_high || uid_low != stream->snapshot.uid_low)
		goto out;
	for (guint i = 0; i < stream->decoder->n_message_ids; i++)
		if (message_id == stream->decoder->message_ids[i]) {
			recognized = TRUE;
			break;
		}
	if (!recognized)
		goto out;
	g_mutex_lock (&stream->mutex);
	if (stream->pending_error)
		error = g_error_copy (stream->pending_error);
	g_mutex_unlock (&stream->mutex);
	if (error)
		goto fail;
	if (!buffer || (buffer->len && !buffer->data))
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Invalid sensor measurement payload");
	else if (buffer->len > SENSOR_REPORT_MAX_BYTES)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_NO_SPACE, "Sensor measurement exceeds raw payload limit");
	if (error)
		goto fail;
	sensor_decode_init (&decode);
	decoded = stream->decoder->decode (&stream->snapshot, message_id,
		(const guint8 *) buffer->data, buffer->len, &decode.allocator, &frame, &error);
	/* Descriptor owns every generated unpack/free within its callback. */
	g_assert (decode.live == 0);
	if (decode.exceeded) {
		g_clear_error (&error);
		error = sensor_decode_error (&decode);
	} else if (!decoded && !error)
		error = sensor_decode_error (&decode);
	else if (decoded && !error && frame.kind != stream->decoder->kind)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_INVALID_DATA, "Sensor decoder returned the wrong measurement kind");
	if (error)
		goto fail;
	if (!stream_ticket_current (ticket))
		goto out;
	if (frame.kind == SSC_MEASUREMENT_PROXIMITY && stream->proximity_seen &&
	    stream->proximity_near == !!frame.value.near)
		goto evidence;
	if (stream->count == SENSOR_STREAM_FRAME_COUNT || stream->sequence == G_MAXUINT64) {
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_NO_SPACE,
			stream->count == SENSOR_STREAM_FRAME_COUNT ? "Sensor semantic frame FIFO exhausted" :
			"Sensor semantic frame sequence exhausted");
		goto fail;
	}
	frame.epoch = ticket->stream_epoch;
	frame.sequence = ++stream->sequence;
	frame.raw_timestamp = raw_timestamp; /* opaque sensor ticks, not nanoseconds */
	frame.validity_flags |= SSC_FRAME_VALID_PAYLOAD | SSC_FRAME_CLOCK_UNQUALIFIED;
	if (frame.accuracy >= 0 && frame.accuracy <= 3)
		frame.validity_flags |= SSC_FRAME_ACCURACY_KNOWN;
	else
		frame.validity_flags &= ~SSC_FRAME_ACCURACY_KNOWN;
	stream->frames[(stream->head + stream->count) % SENSOR_STREAM_FRAME_COUNT] = frame;
	stream->count++;
	if (frame.kind == SSC_MEASUREMENT_PROXIMITY) {
		stream->proximity_seen = TRUE;
		stream->proximity_near = !!frame.value.near;
	}
evidence:
	if (ticket->operation && operation_guard (ticket->operation)) {
		ticket->operation->report_seen = TRUE;
		operation_schedule_progress (ticket->operation);
	} else if (!ticket->operation)
		stream_schedule_drain (stream);
	goto out;
fail:
	stream_fail_current (ticket, g_steal_pointer (&error));
out:
	g_clear_error (&error);
	stream_ticket_unref (ticket);
}

/* Subscribe new, publish exact ticket, query sticky loss, retire old. A local
 * stream epoch is not a wire correlation cookie for a delayed DSP report. */
static gboolean
stream_replace_ticket (SensorStreamCtl *stream, SSCClient *client,
		       SensorOperation *operation, SensorStreamState state,
		       SscLifetimeNode *parent)
{
	SensorStreamTicket *ticket = g_new0 (SensorStreamTicket, 1);
	SensorStreamTicket *old_ticket;
	GError *error;
	gboolean success;
	ticket->refs = 1;
	ticket->lifetime = ssc_lifetime_node_new (stream->lifetime, parent,
		"sensor-stream-ticket");
	g_assert (ticket->lifetime);
	ticket->stream = stream_ref (stream);
	ticket->operation = operation ? operation_ref (operation) : NULL;
	ticket->phase_epoch = operation ? operation->stream_phase_epoch : 0;
	ticket->stream_epoch = stream->epoch;
	ticket->state = state;
	stream->frame_id = state == SENSOR_STREAM_CLOSING ? 0 :
		g_signal_connect_data (client, "report-frame", G_CALLBACK (stream_frame_received),
			stream_ticket_ref (ticket), stream_ticket_destroy, 0);
	stream->failure_id = g_signal_connect_data (client, "report-failed",
		G_CALLBACK (stream_client_failed), stream_ticket_ref (ticket), stream_ticket_destroy, 0);
	g_mutex_lock (&stream->mutex);
	old_ticket = stream->current ? stream_ticket_ref (stream->current) : NULL;
	stream->current = ticket;
	stream->state = state;
	g_mutex_unlock (&stream->mutex);
	error = ssc_client_dup_report_error (client);
	if (!error && ((!stream->failure_id ||
	     !g_signal_handler_is_connected (client, stream->failure_id)) ||
	    (state != SENSOR_STREAM_CLOSING && (!stream->frame_id ||
	     !g_signal_handler_is_connected (client, stream->frame_id)))))
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED,
			"Sensor stream client lost its newly installed observers");
	if (old_ticket) {
		g_signal_handlers_disconnect_matched (client, G_SIGNAL_MATCH_DATA,
			0, 0, NULL, NULL, old_ticket);
		stream_ticket_unref (old_ticket);
	}
	success = error == NULL;
	if (error)
		stream_fail_current (ticket, error);
	stream_ticket_unref (ticket);
	return success;
}

static gboolean
stream_begin_operation (SensorOperation *operation)
{
	SensorStreamCtl *stream = operation->stream;
	g_assert (g_main_context_is_owner (stream->owner));
	g_mutex_lock (&stream->mutex);
	if (g_atomic_int_get (&stream->retired) || stream->epoch == G_MAXUINT64) {
		gboolean retired = g_atomic_int_get (&stream->retired);
		g_mutex_unlock (&stream->mutex);
		operation_terminal (operation, g_error_new_literal (G_IO_ERROR,
			retired ? G_IO_ERROR_CLOSED : G_IO_ERROR_NO_SPACE,
			retired ? "Sensor stream retired" : "Sensor stream epoch exhausted"));
		return FALSE;
	}
	stream->epoch++;
	operation->stream_epoch = stream->epoch;
	operation->stream_phase_epoch = operation->epoch;
	operation->stream_started = TRUE;
	stream->state = operation->kind == SENSOR_OP_OPEN ? SENSOR_STREAM_OPENING : SENSOR_STREAM_CLOSING;
	stream->head = stream->count = 0;
	g_clear_error (&stream->pending_error);
	g_clear_error (&stream->error);
	stream->fault_queued = stream->fault_notified = FALSE;
	if (operation->kind == SENSOR_OP_OPEN) {
		stream->sequence = 0;
		stream->proximity_seen = FALSE;
	}
	g_mutex_unlock (&stream->mutex);
	stream_cancel_drain (stream);
	return stream_replace_ticket (stream, operation->client, operation, stream->state,
		operation->lifetime);
}

/* On TRUE the caller owns stream->mutex through immutable task decision.
 * A stale operation cannot clear observers or modify a successor session. */
static gboolean
stream_terminal_lock (SensorOperation *operation, GError **error)
{
	SensorStreamCtl *stream = operation->stream;
	if (!stream || (!operation->stream_started && !operation->stream_repeat_open))
		return FALSE;
	g_mutex_lock (&stream->mutex);
	if (g_atomic_int_get (&stream->retired) || stream->epoch != operation->stream_epoch ||
	    (operation->stream_started && (!stream->current ||
	     stream->current->operation != operation ||
	     stream->current->phase_epoch != operation->stream_phase_epoch ||
	     operation->epoch != operation->stream_phase_epoch)) ||
	    (operation->stream_repeat_open &&
	     (stream->state != SENSOR_STREAM_OPEN || !stream->current))) {
		if (!*error)
			*error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED, "Sensor stream operation is no longer current");
		g_mutex_unlock (&stream->mutex);
		return FALSE;
	}
	if (!*error && stream->pending_error)
		*error = g_error_copy (stream->pending_error);
	return TRUE;
}

static void
stream_terminal_state_locked (SensorOperation *operation, GError *error,
			      GError **notice, gboolean *arm)
{
	SensorStreamCtl *stream = operation->stream;
	if (operation->stream_repeat_open && !stream->pending_error)
		return; /* no reset, observer replacement or FIFO/dedupe mutation */
	if (!error && operation->kind == SENSOR_OP_OPEN) {
		stream->state = SENSOR_STREAM_OPEN;
		*arm = TRUE;
		return;
	}
	stream->head = stream->count = 0;
	if (!error)
		stream->state = SENSOR_STREAM_CLOSED;
	else if (operation->kind == SENSOR_OP_OPEN && !operation->may_have_submitted &&
		 !stream->pending_error)
		stream->state = SENSOR_STREAM_CLOSED;
	else {
		/* Failed accepted CLOSE is muted/FAULTED, remote state UNKNOWN. */
		stream->state = SENSOR_STREAM_FAULTED;
		if (!stream->error)
			stream->error = g_error_copy (stream->pending_error ? stream->pending_error : error);
		if (!stream->fault_notified) {
			stream->fault_notified = TRUE;
			*notice = g_error_copy (stream->error);
		}
	}
	g_clear_error (&stream->pending_error);
	stream->fault_queued = FALSE;
}

static void
stream_after_terminal (SensorOperation *operation, GError *notice, gboolean arm)
{
	SensorStreamCtl *stream = operation->stream;
	SSCClient *client;
	gboolean current;
	if (!stream) {
		g_clear_error (&notice);
		return;
	}
	g_mutex_lock (&stream->mutex);
	current = !g_atomic_int_get (&stream->retired) &&
		!ssc_lifetime_is_sealed (stream->lifetime) &&
		stream->epoch == operation->stream_epoch && stream->state == SENSOR_STREAM_OPEN &&
		stream->current && stream->current->operation == operation &&
		stream->current->phase_epoch == operation->stream_phase_epoch;
	g_mutex_unlock (&stream->mutex);
	if (arm && current) {
		client = g_weak_ref_get (&stream->client);
		if (client) {
			if (stream_replace_ticket (stream, client, NULL, SENSOR_STREAM_OPEN,
				operation->lifetime))
				stream_schedule_drain (stream);
			g_object_unref (client);
		} else {
			/* Client disposal after immutable OPEN success is a new runtime
			 * loss, not permission to rewrite the completed task as failure. */
			SensorStreamTicket *ticket = g_new0 (SensorStreamTicket, 1);
			ticket->refs = 1;
			ticket->lifetime = ssc_lifetime_node_new (stream->lifetime,
				operation->lifetime, "sensor-stream-ticket");
			g_assert (ticket->lifetime);
			ticket->stream = stream_ref (stream);
			ticket->stream_epoch = operation->stream_epoch;
			ticket->state = SENSOR_STREAM_OPEN;
			g_mutex_lock (&stream->mutex);
			stream->current = ticket;
			g_mutex_unlock (&stream->mutex);
			stream_fail_current (ticket, g_error_new_literal (G_IO_ERROR,
				G_IO_ERROR_CLOSED, "Sensor client disappeared after OPEN commit"));
			stream_ticket_unref (ticket);
		}
	}
	stream_emit_notice (stream, notice);
}

static void
stream_metadata_commit (SensorStreamCtl *stream, SSCSensorPrivate *priv)
{
	g_weak_ref_set (&stream->client, priv->client);
	stream->snapshot.uid_high = priv->uid_high;
	stream->snapshot.uid_low = priv->uid_low;
	stream->snapshot.stream_type = priv->stream_type;
	stream->snapshot.sample_rate = priv->sample_rate;
	memcpy (stream->snapshot.mount_matrix, priv->mount_matrix, sizeof (priv->mount_matrix));
	/* No unverified device/dialect qualification is inferred from data_type. */
	stream->snapshot.qualified_format_flags = 0;
	g_mutex_lock (&stream->mutex);
	stream->state = SENSOR_STREAM_CLOSED;
	g_mutex_unlock (&stream->mutex);
}

typedef struct {
	SensorStreamCtl *stream;
	SSCClient *client;
	GMainContext *owner;
	SscLifetimeNode *lifetime;
} SensorStreamRetire;

static gboolean
stream_retire_on_owner (gpointer data)
{
	SensorStreamRetire *ticket = data;
	SensorStreamCtl *stream = ticket->stream;
	g_mutex_lock (&stream->mutex);
	stream->state = SENSOR_STREAM_RETIRED;
	g_mutex_unlock (&stream->mutex);
	stream_cancel_drain (stream);
	stream_clear_observers (stream, ticket->client);
	stream->head = stream->count = 0;
	g_mutex_lock (&stream->mutex);
	g_clear_error (&stream->pending_error);
	g_mutex_unlock (&stream->mutex);
	g_weak_ref_set (&stream->client, NULL);
	g_clear_object (&ticket->client);
	return G_SOURCE_REMOVE;
}

static void
stream_retire_free (SensorStreamRetire *ticket)
{
	SscLifetimeNode *lifetime = ticket->lifetime;
	g_clear_object (&ticket->client);
	stream_unref (ticket->stream);
	g_main_context_unref (ticket->owner);
	g_free (ticket);
	if (lifetime)
		ssc_lifetime_node_unref (lifetime);
}

static void
stream_retire (SensorStreamCtl *stream, SSCClient *client)
{
	SensorStreamRetire *ticket;
	g_atomic_int_set (&stream->retired, TRUE);
	if (!g_atomic_int_compare_and_exchange (&stream->retire_queued, 0, 1)) {
		g_clear_object (&client);
		return;
	}
	ticket = g_new0 (SensorStreamRetire, 1);
	ticket->stream = stream_ref (stream);
	ticket->client = client; /* stolen final sensor client ref, never sensor */
	ticket->owner = g_main_context_ref (stream->owner);
	/* An unsealed dispose registers before the actual handoff. The sealed
	 * coordinator invokes this synchronously on owner and cannot publish until
	 * it returns; that inline begin sequence is deliberately not self-debt. */
	ticket->lifetime = ssc_lifetime_node_new (stream->lifetime, NULL,
		"sensor-stream-retire");
	if (g_main_context_is_owner (stream->owner)) {
		stream_retire_on_owner (ticket);
		stream_retire_free (ticket);
	} else {
		g_assert (ticket->lifetime);
		queue_owner (stream->owner, G_PRIORITY_DEFAULT, stream_retire_on_owner,
			ticket, (GDestroyNotify) stream_retire_free);
	}
	/* A stopped owner retains this bounded handoff; application shutdown MUST
	 * dispatch until retire and actual client/backend finish debts are drained.
	 * Destroy notify is not a magic escape from a retained stopped context. */
}

void
ssc_sensor_install_decoder (SSCSensor *self, const SscSensorDecoder *decoder)
{
	SSCSensorPrivate *priv;
	g_return_if_fail (SSC_IS_SENSOR (self));
	priv = ssc_sensor_get_instance_private (self);
	g_return_if_fail (g_thread_self () == priv->construction_thread &&
		!priv->active && !priv->initialized && !priv->disposed && !priv->stream->decoder);
	g_return_if_fail (decoder && decoder->data_type && *decoder->data_type &&
		decoder->message_ids && decoder->n_message_ids && decoder->decode && decoder->emit_legacy);
	priv->stream->decoder = decoder; /* immutable static-lifetime subclass descriptor */
}

/* This is a structural/string screen, not a replacement protobuf decoder.
 * Unknown length-delimited fields are opaque; only declared message positions
 * recurse. Known strings must fit the C string representation without embedded
 * NUL and contain valid length-aware UTF-8. Actual generated unpack still checks
 * schema/required fields. The SUID shape has no recursive walk or field cap. */
typedef enum {
	ATTR_WIRE_RESPONSE, ATTR_WIRE_ATTRIBUTE, ATTR_WIRE_VALUES,
	ATTR_WIRE_VALUE, ATTR_WIRE_NESTED_VALUES, ATTR_WIRE_SUID
} AttributeWireShape;

static gboolean
wire_varint (const guint8 **cursor, const guint8 *end, guint64 *value)
{
	guint64 result = 0;
	for (guint i = 0; i < 10; i++) {
		guint8 byte;
		if (*cursor == end)
			return FALSE;
		byte = *(*cursor)++;
		if (i == 9 && (byte & 0xfe))
			return FALSE;
		result |= ((guint64) (byte & 0x7f)) << (7 * i);
		if (!(byte & 0x80)) {
			*value = result;
			return TRUE;
		}
	}
	return FALSE;
}

static gboolean
attribute_wire_screen (const guint8 *cursor, const guint8 *end,
		       AttributeWireShape shape, guint depth, guint *fields, gboolean *exceeded)
{
	if (depth > SENSOR_ATTRIBUTE_MAX_DEPTH) {
		*exceeded = TRUE;
		return FALSE;
	}
	while (cursor < end) {
		guint64 tag, value;
		guint field, wire;
		AttributeWireShape child = ATTR_WIRE_RESPONSE;
		gboolean nested = FALSE;
		if (shape != ATTR_WIRE_SUID && *fields == SENSOR_ATTRIBUTE_MAX_FIELDS) {
			*exceeded = TRUE;
			return FALSE;
		}
		if (!wire_varint (&cursor, end, &tag) ||
		    (tag >> 3) == 0 || (tag >> 3) > G_MAXUINT32)
			return FALSE;
		(*fields)++;
		field = (guint) (tag >> 3);
		wire = tag & 7;
		switch (wire) {
		case 0:
			if (!wire_varint (&cursor, end, &value))
				return FALSE;
			break;
		case 1:
			if ((gsize) (end - cursor) < 8)
				return FALSE;
			cursor += 8;
			break;
		case 2:
			if (!wire_varint (&cursor, end, &value) || value > (guint64) (end - cursor))
				return FALSE;
			if (((shape == ATTR_WIRE_SUID && field == 1) ||
			     (shape == ATTR_WIRE_VALUE && field == 2)) &&
			    (memchr (cursor, 0, (gsize) value) ||
			     !g_utf8_validate ((const gchar *) cursor, (gssize) value, NULL)))
				return FALSE;
			if (shape == ATTR_WIRE_RESPONSE && field == 1) {
				child = ATTR_WIRE_ATTRIBUTE; nested = TRUE;
			} else if (shape == ATTR_WIRE_ATTRIBUTE && field == 2) {
				child = ATTR_WIRE_VALUES; nested = TRUE;
			} else if ((shape == ATTR_WIRE_VALUES || shape == ATTR_WIRE_NESTED_VALUES) && field == 1) {
				child = ATTR_WIRE_VALUE; nested = TRUE;
			} else if (shape == ATTR_WIRE_VALUE && field == 1) {
				child = ATTR_WIRE_NESTED_VALUES; nested = TRUE;
			}
			if (nested && !attribute_wire_screen (cursor, cursor + (gsize) value,
							     child, depth + 1, fields, exceeded))
				return FALSE;
			cursor += (gsize) value;
			break;
		case 5:
			if ((gsize) (end - cursor) < 4)
				return FALSE;
			cursor += 4;
			break;
		default:
			/* No selected schema field uses protobuf groups. */
			return FALSE;
		}
	}
	return cursor == end;
}

static gboolean
metadata_invalid (GError **error, const gchar *message)
{
	g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA, message);
	return FALSE;
}

static gboolean
attribute_scalar (SscAttrValue *value, gchar kind)
{
	if (!value)
		return FALSE;
	/* Optional fields are not a oneof: expected presence/type matters, not
	 * rejection of other valid optional fields in the same value. */
	return (kind == 's' && value->s) || (kind == 'f' && value->has_f) ||
		(kind == 'i' && value->has_i) || (kind == 'b' && value->has_b);
}

static gboolean
metadata_parse (SscAttrResponse *response, SensorMetadata *metadata, GError **error)
{
	for (gsize i = 0; i < response->n_attr; i++) {
		SscAttr *attribute = response->attr[i];
		SscAttrArrayValue *array = attribute->value_array;
		SscAttrValue *single = array->n_v == 1 ? array->v[0] : NULL;
		switch (attribute->id) {
		case SSC_ATTRIBUTE_NAME:
		case SSC_ATTRIBUTE_VENDOR: {
			gboolean *present = attribute->id == SSC_ATTRIBUTE_NAME ?
				&metadata->have_name : &metadata->have_vendor;
			gchar **text = attribute->id == SSC_ATTRIBUTE_NAME ?
				&metadata->name : &metadata->vendor;
			if (!attribute_scalar (single, 's') || !g_utf8_validate (single->s, -1, NULL))
				return metadata_invalid (error, "Invalid sensor name/vendor attribute");
			if (*present && g_strcmp0 (*text, single->s) != 0)
				return metadata_invalid (error, "Conflicting sensor name/vendor attribute");
			if (!*present)
				*text = g_strdup (single->s);
			*present = TRUE;
			break;
		}
		case SSC_ATTRIBUTE_AVAILABLE:
			if (!attribute_scalar (single, 'b'))
				return metadata_invalid (error, "Invalid sensor availability attribute");
			if (metadata->have_available && metadata->available != !!single->b)
				return metadata_invalid (error, "Conflicting sensor availability attribute");
			metadata->available = !!single->b;
			metadata->have_available = TRUE;
			break;
		case SSC_ATTRIBUTE_STREAM_TYPE:
			if (!attribute_scalar (single, 'i'))
				return metadata_invalid (error, "Invalid sensor stream attribute");
			/* The selected schema is unsigned fixed64. Compare at its full
			 * width before narrowing to the finite supported stream enum. */
			if (single->i != SSC_STREAM_TYPE_CONTINUOUS && single->i != SSC_STREAM_TYPE_ON_CHANGE) {
				g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
					"Unsupported sensor stream type");
				return FALSE;
			}
			if (metadata->have_stream && metadata->stream_type != single->i)
				return metadata_invalid (error, "Conflicting sensor stream attribute");
			metadata->stream_type = single->i == SSC_STREAM_TYPE_CONTINUOUS ?
				SSC_STREAM_TYPE_CONTINUOUS : SSC_STREAM_TYPE_ON_CHANGE;
			metadata->have_stream = TRUE;
			break;
		case SSC_ATTRIBUTE_SAMPLE_RATE: {
			gfloat selected = 0;
			if (!array->n_v)
				return metadata_invalid (error, "Empty sensor sample-rate attribute");
			for (gsize j = 0; j < array->n_v; j++) {
				if (!attribute_scalar (array->v[j], 'f') || !isfinite (array->v[j]->f))
					return metadata_invalid (error, "Invalid sensor sample-rate attribute");
				if (selected == 0 && array->v[j]->f > 0)
					selected = array->v[j]->f;
			}
			if (metadata->have_rate && metadata->sample_rate != selected)
				return metadata_invalid (error, "Conflicting sensor sample-rate attribute");
			metadata->sample_rate = selected;
			metadata->have_rate = TRUE;
			break;
		}
		case SSC_ATTRIBUTE_MOUNT_MATRIX: {
			gfloat matrix[3][3] = {{0}};
			gboolean all_zero = TRUE;
			if (array->n_v < 9)
				return metadata_invalid (error, "Incomplete sensor mount matrix");
			for (guint j = 0; j < 9; j++) {
				if (!attribute_scalar (array->v[j], 'f') || !isfinite (array->v[j]->f))
					return metadata_invalid (error, "Invalid sensor mount matrix");
				matrix[j/3][j%3] = array->v[j]->f;
				if (array->v[j]->f != 0)
					all_zero = FALSE;
			}
			if (all_zero) {
				matrix[0][0] = 1; matrix[1][1] = 1; matrix[2][2] = 1;
			}
			for (guint j = 0; metadata->have_matrix && j < 9; j++)
				if (metadata->mount_matrix[j/3][j%3] != matrix[j/3][j%3])
					return metadata_invalid (error, "Conflicting sensor mount matrix");
			memcpy (metadata->mount_matrix, matrix, sizeof (matrix));
			metadata->have_matrix = TRUE;
			break;
		}
		default:
			break;
		}
	}
	if (!metadata->have_stream || !metadata->have_available)
		return metadata_invalid (error, "Required sensor metadata is missing");
	if (metadata->available && metadata->stream_type == SSC_STREAM_TYPE_CONTINUOUS &&
	    (!metadata->have_rate || metadata->sample_rate <= 0 || !isfinite (metadata->sample_rate)))
		return metadata_invalid (error, "Continuous sensor has no finite positive sample rate");
	return TRUE;
}

static gboolean report_mail_drain (gpointer data);

static gboolean
report_mail_schedule_locked (SensorOperation *operation)
{
	if (operation->mail_scheduled)
		return FALSE;
	if ((!operation->mail_failed || operation->mail_failure_claimed) &&
	    (!operation->mail_head || operation->mail_head->copying))
		return FALSE;
	operation->mail_scheduled = TRUE;
	return TRUE;
}

static void
report_mail_attach (SensorOperation *operation)
{
	queue_owner (operation->owner, G_PRIORITY_DEFAULT, report_mail_drain,
		operation_ref (operation), (GDestroyNotify) operation_unref);
}

static gboolean
report_mail_drain (gpointer data)
{
	SensorOperation *operation = operation_ref (data);
	guint work = 0;
	while (work < SENSOR_REPORT_MAILBOX_COUNT) {
		SensorReportSlot *slot;
		gboolean fail = FALSE;
		g_mutex_lock (&operation->mail_mutex);
		if (operation->mail_failed && !operation->mail_failure_claimed) {
			operation->mail_failure_claimed = TRUE;
			fail = TRUE;
		}
		slot = operation->mail_head;
		g_mutex_unlock (&operation->mail_mutex);
		if (fail)
			operation_terminal (operation, g_error_new_literal (G_IO_ERROR,
				operation->mail_error_code, "Sensor report handoff failed"));
		g_mutex_lock (&operation->mail_mutex);
		/* Failure arriving after the prior snapshot must not lose its wake. */
		if (operation->mail_failed && !operation->mail_failure_claimed) {
			g_mutex_unlock (&operation->mail_mutex);
			continue;
		}
		slot = operation->mail_head;
		if (!slot || slot->copying) {
			operation->mail_scheduled = FALSE;
			g_mutex_unlock (&operation->mail_mutex);
			operation_unref (operation);
			return G_SOURCE_REMOVE;
		}
		operation->mail_head = slot->next;
		if (!operation->mail_head)
			operation->mail_tail = NULL;
		g_mutex_unlock (&operation->mail_mutex);
		if (!g_atomic_int_get (&operation->done)) {
			gsize length;
			const guint8 *bytes = g_bytes_get_data (slot->bytes, &length);
			operation_report (slot->ticket, slot->message_id, bytes, length);
		}
		/* Keep reservation through actual storage/ticket release. */
		g_clear_pointer (&slot->bytes, g_bytes_unref);
		report_ticket_unref (slot->ticket);
		g_mutex_lock (&operation->mail_mutex);
		g_assert (operation->mail_used > 0 && slot->reserved);
		operation->mail_used--;
		memset (slot, 0, sizeof (*slot));
		g_mutex_unlock (&operation->mail_mutex);
		work++;
	}
	operation_unref (operation);
	return G_SOURCE_CONTINUE;
}

static void
report_mail_enqueue (SensorReportTicket *ticket, guint32 message_id, GArray *buffer)
{
	SensorOperation *operation = ticket->operation;
	SensorReportSlot *slot = NULL;
	gboolean attach;
	GBytes *bytes;
	g_mutex_lock (&operation->mail_mutex);
	if (g_atomic_int_get (&operation->done) ||
	    ssc_lifetime_is_sealed (ssc_lifetime_node_get_scope (operation->lifetime)) ||
	    g_atomic_int_get (&operation->published_epoch) != (gint) ticket->epoch) {
		g_mutex_unlock (&operation->mail_mutex);
		return;
	}
	if (operation->mail_failed) {
		attach = report_mail_schedule_locked (operation);
		g_mutex_unlock (&operation->mail_mutex);
		if (attach)
			report_mail_attach (operation);
		return;
	}
	if (!buffer || (buffer->len && !buffer->data) ||
	    buffer->len > SENSOR_REPORT_MAX_BYTES ||
	    operation->mail_used == SENSOR_REPORT_MAILBOX_COUNT) {
		if (!operation->mail_failed)
			operation->mail_error_code = !buffer || (buffer->len && !buffer->data) ?
				G_IO_ERROR_INVALID_DATA : G_IO_ERROR_NO_SPACE;
		operation->mail_failed = TRUE;
	} else {
		for (guint i = 0; i < SENSOR_REPORT_MAILBOX_COUNT; i++)
			if (!operation->mail_slots[i].reserved) {
				slot = &operation->mail_slots[i];
				break;
			}
		g_assert (slot);
		slot->reserved = TRUE;
		slot->copying = TRUE;
		slot->ticket = report_ticket_ref (ticket);
		slot->message_id = message_id;
		if (operation->mail_tail)
			operation->mail_tail->next = slot;
		else
			operation->mail_head = slot;
		operation->mail_tail = slot;
		operation->mail_used++;
	}
	attach = report_mail_schedule_locked (operation);
	g_mutex_unlock (&operation->mail_mutex);
	if (attach)
		report_mail_attach (operation);
	if (!slot)
		return;
	/* Borrowed signal bytes cannot escape before this synchronous copy. */
	bytes = g_bytes_new (buffer->data, buffer->len);
	g_mutex_lock (&operation->mail_mutex);
	slot->bytes = bytes;
	slot->copying = FALSE;
	attach = report_mail_schedule_locked (operation);
	g_mutex_unlock (&operation->mail_mutex);
	if (attach)
		report_mail_attach (operation);
}

static gboolean
report_matches (SensorReportTicket *ticket, guint32 message_id,
		guint64 uid_high, guint64 uid_low)
{
	if (uid_high != ticket->uid_high || uid_low != ticket->uid_low)
		return FALSE;
	switch (ticket->phase) {
	case SENSOR_PHASE_REGISTRY:
	case SENSOR_PHASE_SUID:
		return message_id == SSC_MSG_RESPONSE_SUID;
	case SENSOR_PHASE_ATTRIBUTES:
		return message_id == SSC_MSG_RESPONSE_GET_ATTRIBUTES;
	case SENSOR_PHASE_OPEN:
		return message_id == SSC_MSG_RESPONSE_ENABLE_REPORT ||
			/* Descriptor measurement evidence comes ONLY from private decode. */
			((!ticket->operation->stream || !ticket->operation->stream->decoder) &&
			 (message_id == SSC_MSG_REPORT_MEASUREMENT ||
			  message_id == SSC_MSG_REPORT_MEASUREMENT_PROXIMITY));
	default:
		return FALSE;
	}
}

static void
report_received (SSCClient *client, guint32 message_id, guint64 uid_high,
		 guint64 uid_low, GArray *buffer, gpointer data)
{
	SensorReportTicket *ticket = report_ticket_ref (data);
	SensorOperation *operation = ticket->operation;
	(void) client;
	if (!g_atomic_int_get (&operation->done) &&
	    !ssc_lifetime_is_sealed (ssc_lifetime_node_get_scope (operation->lifetime)) &&
	    report_matches (ticket, message_id, uid_high, uid_low)) {
		if (g_main_context_is_owner (operation->owner)) {
			/* An in-flight old closure may survive its disconnect. Reject its
			 * epoch before even malformed-payload failure can affect a successor. */
			if (operation->phase != ticket->phase || operation->epoch != ticket->epoch) {
				report_ticket_unref (ticket);
				return;
			}
			if (!buffer || (buffer->len && !buffer->data))
				operation_terminal (operation, g_error_new_literal (G_IO_ERROR,
					G_IO_ERROR_INVALID_DATA, "Invalid sensor report payload"));
			else if (buffer->len > SENSOR_REPORT_MAX_BYTES)
				operation_terminal (operation, g_error_new_literal (G_IO_ERROR,
					G_IO_ERROR_NO_SPACE, "Sensor report exceeds the raw payload limit"));
			else
				operation_report (ticket, message_id,
					(const guint8 *) buffer->data, buffer->len);
		} else
			report_mail_enqueue (ticket, message_id, buffer);
	}
	report_ticket_unref (ticket);
}

typedef struct {
	SensorOperation *operation;
	GError *error;
} SensorFaultEvent;

static void
fault_event_free (SensorFaultEvent *event)
{
	g_clear_error (&event->error);
	operation_unref (event->operation);
	g_free (event);
}

static gboolean
fault_on_owner (gpointer data)
{
	SensorFaultEvent *event = data;
	operation_terminal (event->operation, g_steal_pointer (&event->error));
	return G_SOURCE_REMOVE;
}

static void
client_report_failed (SSCClient *client, GError *error, gpointer data)
{
	SensorOperation *operation = operation_ref (data);
	(void) client;
	if (!g_atomic_int_get (&operation->done)) {
		if (g_main_context_is_owner (operation->owner))
			operation_terminal (operation, error ? g_error_copy (error) :
				g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "Sensor client report failed"));
		else if (g_atomic_int_compare_and_exchange (&operation->foreign_fault_queued, 0, 1)) {
			SensorFaultEvent *event = g_new0 (SensorFaultEvent, 1);
			event->operation = operation_ref (operation);
			event->error = error ? g_error_copy (error) :
				g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "Sensor client report failed");
			queue_owner (operation->owner, G_PRIORITY_DEFAULT, fault_on_owner,
				event, (GDestroyNotify) fault_event_free);
		}
	}
	operation_unref (operation);
}

static gboolean
observe_client_failure (SensorOperation *operation)
{
	GError *error;
	operation->failure_id = g_signal_connect_data (operation->client, "report-failed",
		G_CALLBACK (client_report_failed), operation_ref (operation),
		operation_closure_destroy, 0);
	/* Subscribe first, then query: late subscribers cannot miss sticky loss. */
	error = ssc_client_dup_report_error (operation->client);
	if (!error)
		return TRUE;
	operation_terminal (operation, error);
	return FALSE;
}

static void
operation_report (SensorReportTicket *ticket, guint32 message_id,
		  const guint8 *bytes, gsize length)
{
	SensorOperation *operation = ticket->operation;
	SensorDecode decode;
	GError *error = NULL;
	if (g_atomic_int_get (&operation->done) || operation->phase != ticket->phase ||
	    operation->epoch != ticket->epoch || !operation_guard (operation))
		return;
	/* Requests disable updates. First semantically valid matching report is
	 * immutable phase evidence; duplicate later reports do not replace it. */
	if (operation->report_seen)
		return;
	sensor_decode_init (&decode);
	if (operation->phase == SENSOR_PHASE_REGISTRY || operation->phase == SENSOR_PHASE_SUID) {
		SscSuidResponse *response = NULL;
		guint fields = 0;
		gboolean exceeded = FALSE;
		const gchar *expected = operation->phase == SENSOR_PHASE_REGISTRY ?
			"registry" : operation->data_type;
		/* The generated C codec exposes string pointers without wire lengths.
		 * Screen declared data_type bytes before comparison can lose a suffix. */
		if (!length || !attribute_wire_screen (bytes, bytes + length,
			ATTR_WIRE_SUID, 0, &fields, &exceeded))
			error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
				"Invalid sensor SUID wire structure or string");
		else
			response = ssc_suid_response__unpack (&decode.allocator, length, bytes);
		if (!response && !error)
			error = sensor_decode_error (&decode);
		if (response) {
			if (g_strcmp0 (response->data_type, expected) == 0) {
				operation->registry_present = response->n_uid > 0;
				if (operation->phase == SENSOR_PHASE_SUID) {
					if (operation->kind == SENSOR_OP_DISCOVER || operation->selection_enabled) {
						SSCSensorUidList *list = sensor_uid_list_from_response (response, &error);
						if (list && operation->kind == SENSOR_OP_DISCOVER)
							operation->discovered_uids = g_steal_pointer (&list);
						else if (list && sensor_uid_list_contains (list,
							 operation->requested_uid_high, operation->requested_uid_low)) {
							operation->metadata.uid_high = operation->requested_uid_high;
							operation->metadata.uid_low = operation->requested_uid_low;
						} else if (list)
							error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
								"Requested sensor UID does not match the data type");
						ssc_sensor_uid_list_free (list);
					} else if (!response->n_uid)
						error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
							"No sensor matches the requested data type");
					else {
						operation->metadata.uid_high = response->uid[0]->high;
						operation->metadata.uid_low = response->uid[0]->low;
					}
				}
				if (!error)
					operation->report_seen = TRUE;
			}
			ssc_suid_response__free_unpacked (response, &decode.allocator);
		}
	} else if (operation->phase == SENSOR_PHASE_ATTRIBUTES) {
		SscAttrResponse *response = NULL;
		SensorMetadata staged;
		guint fields = 0;
		gboolean exceeded = FALSE;
		metadata_identity (&staged);
		staged.uid_high = operation->metadata.uid_high;
		staged.uid_low = operation->metadata.uid_low;
		if (!length || !attribute_wire_screen (bytes, bytes + length,
			ATTR_WIRE_RESPONSE, 0, &fields, &exceeded))
			error = g_error_new_literal (G_IO_ERROR,
				exceeded ? G_IO_ERROR_NO_SPACE : G_IO_ERROR_INVALID_DATA,
				exceeded ? "Sensor attribute wire budget exhausted" :
				"Invalid sensor attribute wire structure");
		else {
			response = ssc_attr_response__unpack (&decode.allocator, length, bytes);
			if (!response)
				error = sensor_decode_error (&decode);
			else if (metadata_parse (response, &staged, &error)) {
				metadata_clear (&operation->metadata);
				operation->metadata = staged;
				memset (&staged, 0, sizeof (staged));
				operation->report_seen = TRUE;
			}
		}
		if (response)
			ssc_attr_response__free_unpacked (response, &decode.allocator);
		metadata_clear (&staged);
	} else if (operation->phase == SENSOR_PHASE_OPEN) {
		if (message_id == SSC_MSG_RESPONSE_ENABLE_REPORT) {
			SscConfigResponse *response = ssc_config_response__unpack (&decode.allocator, length, bytes);
			if (!response)
				error = sensor_decode_error (&decode);
			else {
				if (response->has_sample_rate && !isfinite (response->sample_rate))
					error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
						"Sensor configuration has nonfinite sample rate");
				else
					operation->report_seen = TRUE;
				ssc_config_response__free_unpacked (response, &decode.allocator);
			}
		} else if (!operation->stream || !operation->stream->decoder) {
			/* Preserved weaker measurement-ID receipt fallback, not decoded
			 * subclass measurement or physical hardware-state validation. */
			operation->report_seen = TRUE;
		}
	}
	g_assert (decode.live == 0);
	if (error)
		operation_terminal (operation, error);
	else if (operation->report_seen)
		operation_schedule_progress (operation);
}

typedef struct {
	SensorOperation *operation;
	SSCClient *client;
	SensorPhase phase;
	guint epoch;
} SensorSendTicket;

static void
send_ready (GObject *source, GAsyncResult *result, gpointer data)
{
	SensorSendTicket *ticket = data;
	SensorOperation *operation = ticket->operation;
	GError *error = NULL;
	gboolean success;
	(void) source;
	/* Always finish on the owned original client, including tombstone tickets. */
	success = ssc_client_send_finish (ticket->client, result, &error);
	if (!success && !error)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "Sensor request failed without an error");
	g_assert (g_main_context_is_owner (operation->owner));
	if (!g_atomic_int_get (&operation->done) && operation->phase == ticket->phase &&
	    operation->epoch == ticket->epoch) {
		if (error)
			operation_terminal (operation, g_steal_pointer (&error));
		else if (operation_guard (operation)) {
			operation->ack_seen = TRUE;
			operation_schedule_progress (operation);
		}
	}
	g_clear_error (&error);
	g_object_unref (ticket->client);
	operation_unref (operation);
	g_free (ticket);
}

static GArray *
pack_request (SensorOperation *operation, const ProtobufCMessage *message)
{
	gsize size = protobuf_c_message_get_packed_size (message);
	GArray *buffer;
	if (size > G_MAXUINT) {
		operation_terminal (operation, g_error_new_literal (G_IO_ERROR,
			G_IO_ERROR_INVALID_ARGUMENT, "Sensor request is too large"));
		return NULL;
	}
	buffer = g_array_sized_new (FALSE, FALSE, 1, size);
	g_array_set_size (buffer, size);
	protobuf_c_message_pack (message, (guint8 *) buffer->data);
	return buffer;
}

static void
send_request (SensorOperation *operation, guint64 uid_high, guint64 uid_low,
	      guint32 message_id, GArray *buffer)
{
	SensorSendTicket *ticket;
	if (!operation_guard (operation))
		return;
	ticket = g_new0 (SensorSendTicket, 1);
	ticket->operation = operation_ref (operation);
	ticket->client = g_object_ref (operation->client);
	ticket->phase = operation->phase;
	ticket->epoch = operation->epoch;
	g_main_context_push_thread_default (operation->owner);
	/* Conservative may-have-submitted boundary: local encoding and current
	 * guard succeeded, but the client may still reject before actual transport. */
	if (operation->stream_started && operation->kind == SENSOR_OP_OPEN)
		operation->may_have_submitted = TRUE;
	ssc_client_send (ticket->client, uid_high, uid_low, message_id, buffer,
		operation->transport, send_ready, ticket);
	g_main_context_pop_thread_default (operation->owner);
}

/* Caller holds an operation reference through this synchronous cleanup.
 * Terminal pins one explicitly; phase/retry callers retain their dispatch ref.
 * Removing closures and releasing the owner ticket can drop operation refs. */
static void
clear_report_observer (SensorOperation *operation)
{
	SensorReportTicket *ticket = g_steal_pointer (&operation->report_ticket);
	operation->report_id = 0;
	if (ticket) {
		/* The operation-owned ref keeps DATA identity alive even if its
		 * signal closure disappeared on another thread. Break the bounded
		 * operation->ticket->operation cycle before disconnect/unref. */
		g_signal_handlers_disconnect_matched (operation->client,
			G_SIGNAL_MATCH_DATA, 0, 0, NULL, NULL, ticket);
		report_ticket_unref (ticket);
	}
}

static void
operation_begin_phase (SensorOperation *operation, SensorPhase phase)
{
	guint64 uid_high = operation->metadata.uid_high, uid_low = operation->metadata.uid_low;
	guint32 message_id = 0;
	GArray *buffer = NULL;
	if (!operation_guard (operation))
		return;
	clear_report_observer (operation);
	destroy_source (&operation->retry_source);
	operation->epoch++;
	g_mutex_lock (&operation->mail_mutex);
	g_atomic_int_set (&operation->published_epoch, operation->epoch);
	g_mutex_unlock (&operation->mail_mutex);
	operation->phase = phase;
	operation->ack_seen = FALSE;
	operation->report_seen = FALSE;
	operation->registry_present = FALSE;
	if (phase == SENSOR_PHASE_REGISTRY || phase == SENSOR_PHASE_SUID) {
		SscSuidRequest request = SSC_SUID_REQUEST__INIT;
		if (phase == SENSOR_PHASE_REGISTRY) {
			if (operation->registry_attempts == SENSOR_MAX_REGISTRY_ATTEMPTS) {
				operation_terminal (operation, g_error_new_literal (ssc_sensor_error_quark (),
					SSC_SENSOR_ERROR_NO_SERVICE, "Sensor registry retry limit reached"));
				return;
			}
			operation->registry_attempts++;
		}
		request.data_type = phase == SENSOR_PHASE_REGISTRY ? "registry" : operation->data_type;
		request.has_enable_updates = TRUE;
		request.enable_updates = FALSE;
		request.has_only_default_values = TRUE;
		request.only_default_values = phase == SENSOR_PHASE_REGISTRY ||
			(operation->kind != SENSOR_OP_DISCOVER && !operation->selection_enabled);
		buffer = pack_request (operation, &request.base);
		uid_high = SSC_SENSOR_UID_SUID_HIGH;
		uid_low = SSC_SENSOR_UID_SUID_LOW;
		message_id = SSC_MSG_REQUEST_SUID;
	} else if (phase == SENSOR_PHASE_ATTRIBUTES) {
		SscAttrRequest request = SSC_ATTR_REQUEST__INIT;
		request.has_enable_updates = TRUE;
		request.enable_updates = FALSE;
		buffer = pack_request (operation, &request.base);
		message_id = SSC_MSG_REQUEST_GET_ATTRIBUTES;
	} else if (phase == SENSOR_PHASE_OPEN) {
		if (operation->metadata.stream_type == SSC_STREAM_TYPE_CONTINUOUS) {
			SscEnableConfigRequest request = SSC_ENABLE_CONFIG_REQUEST__INIT;
			request.sample_rate = operation->metadata.sample_rate;
			buffer = pack_request (operation, &request.base);
			message_id = SSC_MSG_REQUEST_ENABLE_REPORT_CONTINUOUS;
		} else
			message_id = SSC_MSG_REQUEST_ENABLE_REPORT_ON_CHANGE;
	} else if (phase == SENSOR_PHASE_CLOSE)
		message_id = SSC_MSG_REQUEST_DISABLE_REPORT;
	else
		g_assert_not_reached ();
	if (g_atomic_int_get (&operation->done)) {
		g_clear_pointer (&buffer, g_array_unref);
		return;
	}
	if (operation->stream && operation->stream->decoder &&
	    (phase == SENSOR_PHASE_OPEN || phase == SENSOR_PHASE_CLOSE) &&
	    !stream_begin_operation (operation)) {
		g_clear_pointer (&buffer, g_array_unref);
		return;
	}
	if (phase != SENSOR_PHASE_CLOSE) {
		SensorReportTicket *ticket = g_new0 (SensorReportTicket, 1);
		ticket->refs = 1;
		ticket->operation = operation_ref (operation);
		ticket->phase = phase;
		ticket->epoch = operation->epoch;
		ticket->uid_high = uid_high;
		ticket->uid_low = uid_low;
		operation->report_ticket = ticket;
		operation->report_id = g_signal_connect_data (operation->client, "report",
			G_CALLBACK (report_received), report_ticket_ref (ticket), report_ticket_destroy, 0);
	}
	/* The observer is installed before request admission, preserving first
	 * measurement evidence. The real client snapshots buffer before return. */
	send_request (operation, uid_high, uid_low, message_id, buffer);
	g_clear_pointer (&buffer, g_array_unref);
}

static gboolean
retry_on_owner (gpointer data)
{
	SensorOperation *operation = operation_ref (data);
	GSource *current = g_main_current_source ();
	if (operation->retry_source == current) {
		operation->retry_source = NULL;
		g_source_unref (current);
	}
	if (operation_guard (operation))
		operation_begin_phase (operation, SENSOR_PHASE_REGISTRY);
	operation_unref (operation);
	return G_SOURCE_REMOVE;
}

static void
operation_progress (SensorOperation *operation)
{
	if (!operation_guard (operation))
		return;
	if (operation->phase == SENSOR_PHASE_CLOSE) {
		if (operation->ack_seen)
			operation_terminal (operation, NULL);
		return;
	}
	if (!operation->ack_seen || !operation->report_seen)
		return;
	switch (operation->phase) {
	case SENSOR_PHASE_REGISTRY:
		if (operation->registry_present)
			operation_begin_phase (operation, SENSOR_PHASE_SUID);
		else {
			gint64 next = MIN (g_get_monotonic_time () +
				((gint64) SENSOR_REGISTRY_RETRY_MS) * 1000, operation->deadline_usec);
			clear_report_observer (operation);
			operation->epoch++;
			g_mutex_lock (&operation->mail_mutex);
			g_atomic_int_set (&operation->published_epoch, operation->epoch);
			g_mutex_unlock (&operation->mail_mutex);
			operation->phase = SENSOR_PHASE_RETRY;
			operation->ack_seen = FALSE;
			operation->report_seen = FALSE;
			operation->retry_source = g_timeout_source_new (SENSOR_REGISTRY_RETRY_MS);
			g_source_set_ready_time (operation->retry_source, next);
			g_source_set_callback (operation->retry_source, retry_on_owner,
				operation_ref (operation), (GDestroyNotify) operation_unref);
			g_source_attach (operation->retry_source, operation->owner);
		}
		break;
	case SENSOR_PHASE_SUID:
		if (operation->kind == SENSOR_OP_DISCOVER)
			operation_terminal (operation, NULL);
		else
			operation_begin_phase (operation, SENSOR_PHASE_ATTRIBUTES);
		break;
	case SENSOR_PHASE_ATTRIBUTES:
	case SENSOR_PHASE_OPEN:
		operation_terminal (operation, NULL);
		break;
	default:
		break;
	}
}

static void
client_ready (GObject *source, GAsyncResult *result, gpointer data)
{
	SensorOperation *operation = data;
	GError *error = NULL;
	SSCClient *client = ssc_client_new_finish (result, &error);
	(void) source;
	g_assert (g_main_context_is_owner (operation->owner));
	if (!client && !error)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "Sensor client creation returned no client");
	if (!g_atomic_int_get (&operation->done) && operation->phase == SENSOR_PHASE_CLIENT) {
		if (error)
			operation_terminal (operation, g_steal_pointer (&error));
		else if (operation_guard (operation)) {
			operation->client = g_steal_pointer (&client);
			if (observe_client_failure (operation))
				operation_begin_phase (operation, SENSOR_PHASE_REGISTRY);
		}
	}
	g_clear_object (&client);
	g_clear_error (&error);
	operation_unref (operation);
}

static void sensor_open (SSCSensor *, GCancellable *, GAsyncReadyCallback, gpointer);
static void sensor_close (SSCSensor *, GCancellable *, GAsyncReadyCallback, gpointer);
static void initable_init_async (GAsyncInitable *, int, GCancellable *, GAsyncReadyCallback, gpointer);

static gboolean
entry_on_owner (gpointer data)
{
	SensorOperation *operation = data;
	SSCSensorPrivate *priv = ssc_sensor_get_instance_private (operation->self);
	GError *error = NULL;
	g_assert (g_main_context_is_owner (operation->owner));
	/* Overlap admission precedes method prerequisites and never touches the
	 * previous operation's task, observer, deadline or cancellation token. */
	if (priv->disposed)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED, "Sensor disposed");
	else if (ssc_lifetime_is_sealed (priv->lifetime))
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED, "Sensor retired");
	else if (priv->active)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_PENDING, "Another sensor operation is pending");
	else if (operation->kind == SENSOR_OP_DISCOVER &&
		 (G_OBJECT_TYPE (operation->self) != SSC_TYPE_SENSOR || priv->initialized ||
		  priv->metadata_valid || priv->ever_external_client || priv->client ||
		  priv->stream->decoder))
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
			"Sensor discovery requires a bare uninitialized base sensor");
	else if ((operation->kind == SENSOR_OP_INIT || operation->kind == SENSOR_OP_DISCOVER) &&
		 (!priv->data_type || !*priv->data_type || !g_utf8_validate (priv->data_type, -1, NULL)))
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "Sensor data type is required");
	else if (operation->kind == SENSOR_OP_INIT && priv->stream->decoder &&
		 g_strcmp0 (priv->data_type, priv->stream->decoder->data_type) != 0)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Sensor data type does not match its installed decoder");
	else if ((operation->kind == SENSOR_OP_OPEN || operation->kind == SENSOR_OP_CLOSE) &&
		 (!priv->initialized || !priv->metadata_valid || !priv->client))
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_NOT_INITIALIZED, "Sensor is not initialized");
	else if (operation->kind == SENSOR_OP_OPEN && !priv->available)
		error = g_error_new_literal (ssc_sensor_error_quark (), SSC_SENSOR_ERROR_UNAVAILABLE, "Cannot open unavailable sensor");
	else if (operation->kind == SENSOR_OP_OPEN &&
		 priv->stream_type != SSC_STREAM_TYPE_CONTINUOUS && priv->stream_type != SSC_STREAM_TYPE_ON_CHANGE)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "Unsupported sensor stream type");
	else if (operation->kind == SENSOR_OP_OPEN && priv->stream_type == SSC_STREAM_TYPE_CONTINUOUS &&
		 (!isfinite (priv->sample_rate) || priv->sample_rate <= 0))
		error = g_error_new_literal (ssc_sensor_error_quark (),
			SSC_SENSOR_ERROR_SAMPLE_RATE_UNAVAILABLE, "Sensor sample rate is unavailable");
	else if (operation->kind == SENSOR_OP_OPEN && priv->stream->decoder &&
		 priv->stream->state == SENSOR_STREAM_FAULTED)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED,
			"Faulted sensor stream requires explicit successful CLOSE or recreation");
	if (error) {
		operation_terminal (operation, error);
		return G_SOURCE_REMOVE;
	}
	priv->active = operation_ref (operation);
	operation->transport = g_cancellable_new ();
	operation->deadline_usec = g_get_monotonic_time () +
		((gint64) SENSOR_OPERATION_TIMEOUT_MS) * 1000;
	operation->deadline_source = g_timeout_source_new (SENSOR_OPERATION_TIMEOUT_MS);
	g_source_set_ready_time (operation->deadline_source, operation->deadline_usec);
	g_source_set_callback (operation->deadline_source, deadline_on_owner,
		operation_ref (operation), (GDestroyNotify) operation_unref);
	g_source_attach (operation->deadline_source, operation->owner);
	if (operation->caller)
		operation->cancel_id = g_cancellable_connect (operation->caller,
			G_CALLBACK (caller_cancelled), operation_ref (operation),
			(GDestroyNotify) operation_unref);
	if (!operation_guard (operation))
		return G_SOURCE_REMOVE;
	if (operation->kind == SENSOR_OP_INIT && priv->initialized) {
		operation->client = g_object_ref (priv->client);
		operation_terminal (operation, NULL);
	} else if (operation->kind == SENSOR_OP_INIT || operation->kind == SENSOR_OP_DISCOVER) {
		operation->data_type = g_strdup (priv->data_type);
		operation->selection_enabled = operation->kind == SENSOR_OP_INIT && priv->selection_enabled;
		operation->requested_uid_high = priv->uid_high;
		operation->requested_uid_low = priv->uid_low;
		operation->phase = SENSOR_PHASE_CLIENT;
		g_main_context_push_thread_default (operation->owner);
		ssc_client_new_scoped (priv->lifetime, operation->lifetime,
			operation->transport, client_ready, operation_ref (operation));
		g_main_context_pop_thread_default (operation->owner);
	} else {
		operation->client = g_object_ref (priv->client);
		operation->metadata.uid_high = priv->uid_high;
		operation->metadata.uid_low = priv->uid_low;
		operation->metadata.stream_type = priv->stream_type;
		operation->metadata.sample_rate = priv->sample_rate;
		if (priv->stream->decoder) {
			operation->stream = stream_ref (priv->stream);
			g_mutex_lock (&priv->stream->mutex);
			if (operation->kind == SENSOR_OP_OPEN && priv->stream->state == SENSOR_STREAM_OPEN) {
				operation->stream_repeat_open = TRUE;
				operation->stream_epoch = priv->stream->epoch;
			}
			g_mutex_unlock (&priv->stream->mutex);
			if (operation_guard (operation)) {
				if (operation->stream_repeat_open)
					operation_terminal (operation, NULL);
				else
					operation_begin_phase (operation, operation->kind == SENSOR_OP_OPEN ?
						SENSOR_PHASE_OPEN : SENSOR_PHASE_CLOSE);
			}
		} else if (observe_client_failure (operation))
			operation_begin_phase (operation, operation->kind == SENSOR_OP_OPEN ?
				SENSOR_PHASE_OPEN : SENSOR_PHASE_CLOSE);
	}
	return G_SOURCE_REMOVE;
}

static void
begin_operation (SSCSensor *self, SensorOperationKind kind, GCancellable *cancellable,
		 GAsyncReadyCallback callback, gpointer data, gpointer source_tag, gint priority)
{
	SSCSensorPrivate *priv = ssc_sensor_get_instance_private (self);
	SensorOperation *operation;
	SscLifetimeNode *lifetime;
	GTask *task;
	/* Atomically join a new root before an owner source can exist. Sealed
	 * rejection still uses the original source/tag and caller context, without
	 * attaching owner work or changing another operation's immutable result. */
	task = g_task_new (self, cancellable, callback, data);
	g_task_set_check_cancellable (task, FALSE);
	g_task_set_source_tag (task, source_tag);
	g_task_set_priority (task, priority);
	lifetime = ssc_lifetime_node_new (priv->lifetime, NULL, "sensor-operation");
	if (!lifetime) {
		g_task_return_new_error (task, G_IO_ERROR, G_IO_ERROR_CLOSED, "Sensor retired");
		g_object_unref (task);
		return;
	}
	operation = g_new0 (SensorOperation, 1);
	operation->refs = 1;
	operation->lifetime = lifetime;
	operation->kind = kind;
	operation->owner = g_main_context_ref (priv->owner);
	/* Construct on caller before source attachment: callback affinity is not
	 * replaced by owner dispatch or the context of a later open operation. */
	operation->task = task;
	operation->self = self;
	if (cancellable)
		operation->caller = g_object_ref (cancellable);
	metadata_identity (&operation->metadata);
	g_mutex_init (&operation->mail_mutex);
	queue_owner (operation->owner, priority, entry_on_owner, operation,
		(GDestroyNotify) operation_unref);
}

static gboolean
finish_operation (SSCSensor *self, GAsyncResult *result, gpointer tag, GError **error)
{
	if (!G_IS_TASK (result) || !g_task_is_valid (result, self) ||
	    g_task_get_source_tag (G_TASK (result)) != tag) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Invalid sensor operation result");
		return FALSE;
	}
	return g_task_propagate_boolean (G_TASK (result), error);
}

void
ssc_sensor_discover_async (SSCSensor *self, GCancellable *cancellable,
			   GAsyncReadyCallback callback, gpointer user_data)
{
	g_return_if_fail (SSC_IS_SENSOR (self));
	begin_operation (self, SENSOR_OP_DISCOVER, cancellable, callback, user_data,
		ssc_sensor_discover_async, G_PRIORITY_DEFAULT);
}

SSCSensorUidList *
ssc_sensor_discover_finish (SSCSensor *self, GAsyncResult *result, GError **error)
{
	if (!SSC_IS_SENSOR (self) || !G_IS_TASK (result) ||
	    !g_task_is_valid (result, self) ||
	    g_task_get_source_tag (G_TASK (result)) != ssc_sensor_discover_async) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Invalid sensor discovery result");
		return NULL;
	}
	return g_task_propagate_pointer (G_TASK (result), error);
}

static gboolean
sensor_open_finish (SSCSensor *self, GAsyncResult *result, GError **error)
{
	return finish_operation (self, result, sensor_open, error);
}

static gboolean
sensor_close_finish (SSCSensor *self, GAsyncResult *result, GError **error)
{
	return finish_operation (self, result, sensor_close, error);
}

static void
sensor_open (SSCSensor *self, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer data)
{
	begin_operation (self, SENSOR_OP_OPEN, cancellable, callback, data, sensor_open, G_PRIORITY_DEFAULT);
}

static void
sensor_close (SSCSensor *self, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer data)
{
	begin_operation (self, SENSOR_OP_CLOSE, cancellable, callback, data, sensor_close, G_PRIORITY_DEFAULT);
}

void
ssc_sensor_open (SSCSensor *self, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer data)
{
	g_return_if_fail (SSC_IS_SENSOR (self));
	g_return_if_fail (SSC_SENSOR_GET_CLASS (self)->open && SSC_SENSOR_GET_CLASS (self)->open_finish);
	SSC_SENSOR_GET_CLASS (self)->open (self, cancellable, callback, data);
}

gboolean
ssc_sensor_open_finish (SSCSensor *self, GAsyncResult *result, GError **error)
{
	g_return_val_if_fail (SSC_IS_SENSOR (self), FALSE);
	return SSC_SENSOR_GET_CLASS (self)->open_finish (self, result, error);
}

void
ssc_sensor_close (SSCSensor *self, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer data)
{
	g_return_if_fail (SSC_IS_SENSOR (self));
	g_return_if_fail (SSC_SENSOR_GET_CLASS (self)->close && SSC_SENSOR_GET_CLASS (self)->close_finish);
	SSC_SENSOR_GET_CLASS (self)->close (self, cancellable, callback, data);
}

gboolean
ssc_sensor_close_finish (SSCSensor *self, GAsyncResult *result, GError **error)
{
	g_return_val_if_fail (SSC_IS_SENSOR (self), FALSE);
	return SSC_SENSOR_GET_CLASS (self)->close_finish (self, result, error);
}

static gboolean
retirement_supported_type (SSCSensor *self)
{
	GType type = G_OBJECT_TYPE (self);
	return type == SSC_TYPE_SENSOR || type == SSC_TYPE_SENSOR_ACCELEROMETER ||
		type == SSC_TYPE_SENSOR_COMPASS || type == SSC_TYPE_SENSOR_GYROSCOPE ||
		type == SSC_TYPE_SENSOR_LIGHT || type == SSC_TYPE_SENSOR_MAGNETOMETER ||
		type == SSC_TYPE_SENSOR_PROXIMITY;
}

static void
sensor_retire_begin (GObject *subject)
{
	SSCSensorPrivate *priv = ssc_sensor_get_instance_private (SSC_SENSOR (subject));
	g_assert (g_main_context_is_owner (priv->owner));
	/* Logical completion may precede late backend callbacks; their operation
	 * node remains until their actual callback/source/closure epilogues retire.
	 * The coordinator separately visits every safely registered client origin,
	 * including failed/late INIT generations absent from priv->client. */
	if (priv->active)
		operation_terminal (priv->active, g_error_new_literal (G_IO_ERROR,
			G_IO_ERROR_CLOSED, "Sensor retired"));
	stream_retire (priv->stream, g_steal_pointer (&priv->client));
	priv->initialized = priv->metadata_valid = FALSE;
}

void
ssc_sensor_retire_async (SSCSensor *self, GAsyncReadyCallback callback, gpointer user_data)
{
	SSCSensorPrivate *priv;
	GTask *task;
	g_return_if_fail (SSC_IS_SENSOR (self));
	priv = ssc_sensor_get_instance_private (self);
	task = g_task_new (self, NULL, callback, user_data);
	g_task_set_source_tag (task, ssc_sensor_retire_async);
	/* Eligibility is a rejection only: do not seal, drop injected references,
	 * dispose subclasses or certify already accepted unsupported work. */
	if (!retirement_supported_type (self) || priv->ever_external_client) {
		g_task_return_new_error (task, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
			"Sensor ownership or concrete type does not support retirement");
		g_object_unref (task);
		return;
	}
	ssc_lifetime_retire (priv->lifetime, task, sensor_retire_begin);
}

SSCSensorRetirementReceipt *
ssc_sensor_retire_finish (SSCSensor *self, GAsyncResult *result, GError **error)
{
	if (!SSC_IS_SENSOR (self) || !G_IS_TASK (result) ||
	    !g_task_is_valid (result, self) ||
	    g_task_get_source_tag (G_TASK (result)) != ssc_sensor_retire_async) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Invalid sensor retirement result");
		return NULL;
	}
	return g_task_propagate_pointer (G_TASK (result), error);
}

static void
initable_init_async (GAsyncInitable *initable, int priority, GCancellable *cancellable,
		     GAsyncReadyCallback callback, gpointer data)
{
	begin_operation (SSC_SENSOR (initable), SENSOR_OP_INIT, cancellable,
		callback, data, initable_init_async, priority);
}

static gboolean
initable_init_finish (GAsyncInitable *initable, GAsyncResult *result, GError **error)
{
	return finish_operation (SSC_SENSOR (initable), result, initable_init_async, error);
}

static void
async_initable_iface_init (GAsyncInitableIface *iface)
{
	iface->init_async = initable_init_async;
	iface->init_finish = initable_init_finish;
}

/* Properties are serialized by the application on owner/construction thread.
 * Active explicit run_dispose instead requires actual owner-context ownership.
 * The matrix pointer stays borrowed; callers must not read it concurrently
 * with init commit or finalization. */
static gboolean
property_affinity (SSCSensorPrivate *priv)
{
	return g_thread_self () == priv->construction_thread || g_main_context_is_owner (priv->owner);
}

static void
sensor_set_property (GObject *object, guint id, const GValue *value, GParamSpec *spec)
{
	SSCSensorPrivate *priv = ssc_sensor_get_instance_private (SSC_SENSOR (object));
	g_return_if_fail (property_affinity (priv));
	switch (id) {
	case PROP_UID_LOW:
		priv->uid_low = g_value_get_uint64 (value); break;
	case PROP_UID_HIGH:
		priv->uid_high = g_value_get_uint64 (value); break;
	case PROP_SELECTION_ENABLED:
		priv->selection_enabled = g_value_get_boolean (value); break;
	case PROP_DATA_TYPE:
		g_free (priv->data_type); priv->data_type = g_value_dup_string (value); break;
	case PROP_CLIENT: {
		SSCClient *old = priv->client;
		priv->client = g_value_dup_object (value);
		if (priv->client)
			priv->ever_external_client = TRUE;
		g_clear_object (&old);
		break;
	}
	default:
		G_OBJECT_WARN_INVALID_PROPERTY_ID (object, id, spec); break;
	}
}

static void
sensor_get_property (GObject *object, guint id, GValue *value, GParamSpec *spec)
{
	SSCSensorPrivate *priv = ssc_sensor_get_instance_private (SSC_SENSOR (object));
	g_return_if_fail (property_affinity (priv));
	switch (id) {
	case PROP_UID_LOW: g_value_set_uint64 (value, priv->uid_low); break;
	case PROP_UID_HIGH: g_value_set_uint64 (value, priv->uid_high); break;
	case PROP_SELECTION_ENABLED: g_value_set_boolean (value, priv->selection_enabled); break;
	case PROP_NAME: g_value_set_string (value, priv->name); break;
	case PROP_VENDOR: g_value_set_string (value, priv->vendor); break;
	case PROP_DATA_TYPE: g_value_set_string (value, priv->data_type); break;
	case PROP_STREAM_TYPE: g_value_set_uint (value, priv->stream_type); break;
	case PROP_AVAILABLE: g_value_set_boolean (value, priv->available); break;
	case PROP_SAMPLE_RATE: g_value_set_float (value, priv->sample_rate); break;
	case PROP_MOUNT_MATRIX: g_value_set_pointer (value, priv->mount_matrix); break;
	case PROP_CLIENT: g_value_set_object (value, priv->client); break;
	default: G_OBJECT_WARN_INVALID_PROPERTY_ID (object, id, spec); break;
	}
}

static void
sensor_dispose (GObject *object)
{
	SSCSensorPrivate *priv = ssc_sensor_get_instance_private (SSC_SENSOR (object));
	/* Normal final unref can run elsewhere only after tasks/entries are gone.
	 * Active explicit dispose is owner-context-affine, not a concurrency API.
	 * The sealed coordinator holds self: before its once-only stream handoff,
	 * disposal can therefore only be explicit and also requires owner. After
	 * that handoff, later foreign final disposal must remain inert. */
	g_return_if_fail ((!priv->active &&
		(!ssc_lifetime_is_sealed (priv->lifetime) ||
		 g_atomic_int_get (&priv->stream->retire_queued))) ||
		g_main_context_is_owner (priv->owner));
	priv->disposed = TRUE;
	stream_retire (priv->stream, g_steal_pointer (&priv->client));
	if (priv->active)
		operation_terminal (priv->active, g_error_new_literal (G_IO_ERROR,
			G_IO_ERROR_CLOSED, "Sensor disposed"));
	g_clear_pointer (&priv->name, g_free);
	g_clear_pointer (&priv->vendor, g_free);
	g_clear_pointer (&priv->data_type, g_free);
	G_OBJECT_CLASS (ssc_sensor_parent_class)->dispose (object);
}

static void
sensor_finalize (GObject *object)
{
	SSCSensorPrivate *priv = ssc_sensor_get_instance_private (SSC_SENSOR (object));
	g_assert (!priv->active);
	stream_unref (priv->stream);
	ssc_lifetime_unref (priv->lifetime);
	g_main_context_unref (priv->owner);
	g_thread_unref (priv->construction_thread);
	G_OBJECT_CLASS (ssc_sensor_parent_class)->finalize (object);
}

static void
ssc_sensor_class_init (SSCSensorClass *klass)
{
	GObjectClass *object_class = G_OBJECT_CLASS (klass);
	object_class->get_property = sensor_get_property;
	object_class->set_property = sensor_set_property;
	object_class->dispose = sensor_dispose;
	object_class->finalize = sensor_finalize;
	klass->open = sensor_open;
	klass->open_finish = sensor_open_finish;
	klass->close = sensor_close;
	klass->close_finish = sensor_close_finish;
	/* Additive signal only: no public class layout or virtual slot changes.
	 * The GError is borrowed during emission; retaining consumers copy it. */
	sensor_signals[SIGNAL_STREAM_ERROR] = g_signal_new ("stream-error",
		G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
		G_TYPE_NONE, 1, G_TYPE_ERROR);
	/**
	 * SSCSensor::sample:
	 * @self: the sensor
	 * @sample: (transfer none): immutable delivered semantic sample
	 *
	 * Runs on the fixed construction owner after the existing typed
	 * measurement signal. Copy @sample to retain it beyond the callback.
	 * Use g_autoptr only with an owned ssc_sensor_sample_copy(), never with
	 * the borrowed callback pointer itself.
	 * A legacy handler that closes, retires or disposes the sensor, replaces
	 * the stream, or queues a fault can suppress this companion signal.
	 * Proximity repeats already deduplicated by the controller emit neither
	 * signal; this is not a raw wire heartbeat. Local epoch and admission
	 * sequence do not establish DSP freshness. Raw timestamps remain ticks
	 * from an unqualified clock; recognized accuracy is not calibration.
	 *
	 * Since: 0.4.7
	 */
	sensor_signals[SIGNAL_SAMPLE] = g_signal_new ("sample",
		G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
		G_TYPE_NONE, 1, SSC_TYPE_SENSOR_SAMPLE);
	properties[PROP_UID_LOW] = g_param_spec_uint64 (SSC_SENSOR_UID_LOW, "Sensor UID low",
		"Lower64bits of the sensor UID", 0, G_MAXUINT64, 0, G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY);
	properties[PROP_UID_HIGH] = g_param_spec_uint64 (SSC_SENSOR_UID_HIGH, "Sensor UID high",
		"Higher64bits of the sensor UID", 0, G_MAXUINT64, 0, G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY);
	properties[PROP_SELECTION_ENABLED] = g_param_spec_boolean (SSC_SENSOR_SELECTION_ENABLED,
		"Explicit sensor UID selection", "Verify the supplied UID belongs to the data type during INIT",
		FALSE, G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY);
	properties[PROP_NAME] = g_param_spec_string (SSC_SENSOR_NAME, "Sensor driver name",
		"Name of the sensor driver", NULL, G_PARAM_READABLE);
	properties[PROP_VENDOR] = g_param_spec_string (SSC_SENSOR_VENDOR, "Sensor vendor",
		"Name of the vendor of the sensor", NULL, G_PARAM_READABLE);
	properties[PROP_DATA_TYPE] = g_param_spec_string (SSC_SENSOR_DATA_TYPE, "Data type",
		"The data type supported by the sensor", NULL, G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY);
	properties[PROP_STREAM_TYPE] = g_param_spec_uint (SSC_SENSOR_STREAM_TYPE, "Stream type",
		"The stream type supported by the sensor", 0, SSC_STREAM_TYPE_ON_CHANGE, 0, G_PARAM_READABLE);
	properties[PROP_AVAILABLE] = g_param_spec_boolean (SSC_SENSOR_AVAILABLE, "Availability",
		"Whether sensor measurements are available", FALSE, G_PARAM_READABLE);
	properties[PROP_SAMPLE_RATE] = g_param_spec_float (SSC_SENSOR_SAMPLE_RATE, "Sample rate",
		"The sensor sample rate in Hz", 0, G_MAXFLOAT, 0, G_PARAM_READABLE);
	properties[PROP_MOUNT_MATRIX] = g_param_spec_pointer (SSC_SENSOR_MOUNT_MATRIX, "Mount matrix",
		"Borrowed mount matrix valid during sensor lifetime", G_PARAM_READABLE);
	properties[PROP_CLIENT] = g_param_spec_object (SSC_SENSOR_CLIENT, "SSC Client",
		"Reference to SSC Client", SSC_TYPE_CLIENT, G_PARAM_READWRITE | G_PARAM_CONSTRUCT_ONLY);
	for (guint id = 1; id < N_PROPERTIES; id++)
		if (properties[id])
			g_object_class_install_property (object_class, id, properties[id]);
}

static void
ssc_sensor_init (SSCSensor *self)
{
	SSCSensorPrivate *priv = ssc_sensor_get_instance_private (self);
	priv->owner = g_main_context_ref_thread_default ();
	priv->construction_thread = g_thread_ref (g_thread_self ());
	/* Scope exists before construct properties, async INIT or any owner source. */
	priv->lifetime = ssc_lifetime_new (priv->owner);
	priv->stream = g_new0 (SensorStreamCtl, 1);
	priv->stream->refs = 1;
	priv->stream->lifetime = ssc_lifetime_ref (priv->lifetime);
	priv->stream->owner = g_main_context_ref (priv->owner);
	priv->stream->state = SENSOR_STREAM_UNINITIALIZED;
	g_mutex_init (&priv->stream->mutex);
	g_weak_ref_init (&priv->stream->sensor, self);
	g_weak_ref_init (&priv->stream->client, NULL);
	memset (priv->mount_matrix, 0, sizeof (priv->mount_matrix));
	priv->mount_matrix[0][0] = 1;
	priv->mount_matrix[1][1] = 1;
	priv->mount_matrix[2][2] = 1;
}

SSCSensor *
ssc_sensor_new_finish (GAsyncResult *result, GError **error)
{
	GObject *source = g_async_result_get_source_object (result), *sensor;
	if (!source || !SSC_IS_SENSOR (source)) {
		g_clear_object (&source);
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "Invalid sensor construction result");
		return NULL;
	}
	sensor = g_async_initable_new_finish (G_ASYNC_INITABLE (source), result, error);
	g_object_unref (source);
	return sensor ? SSC_SENSOR (sensor) : NULL;
}

SSCSensor *
ssc_sensor_new_typed_finish (GAsyncResult *result, GType expected_type, GError **error)
{
	GObject *source;
	if (!G_IS_ASYNC_RESULT (result) || !g_type_is_a (expected_type, SSC_TYPE_SENSOR)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Invalid typed sensor construction result");
		return NULL;
	}
	source = g_async_result_get_source_object (result);
	if (!source || !G_TYPE_CHECK_INSTANCE_TYPE (source, expected_type)) {
		g_clear_object (&source);
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Sensor construction result has the wrong concrete type");
		return NULL;
	}
	g_object_unref (source);
	/* Actual base init_finish checks source/tag before consuming its result. */
	return ssc_sensor_new_finish (result, error);
}

void
ssc_sensor_new (gchar *data_type, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer data)
{
	g_async_initable_new_async (SSC_TYPE_SENSOR, G_PRIORITY_DEFAULT, cancellable,
		callback, data, SSC_SENSOR_DATA_TYPE, data_type, NULL);
}
