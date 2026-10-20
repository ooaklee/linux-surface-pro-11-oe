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

#include "libssc-client-private.h"

enum {
	SIGNAL_REPORT,
	SIGNAL_REPORT_FAILED,
	SIGNAL_SENSOR_INITIALIZED,
	SIGNAL_REPORT_FRAME,
	N_SIGNALS
};
static guint signals[N_SIGNALS];

typedef struct _ClientBundle ClientBundle;
typedef struct _ClientTicket ClientTicket;
typedef struct _ReportSlot ReportSlot;

typedef enum {
	REPORT_SLOT_FREE,
	REPORT_SLOT_COPYING,
	REPORT_SLOT_READY,
	REPORT_SLOT_ACTIVE,
	REPORT_SLOT_RETIRING
} ReportSlotState;

typedef enum {
	REPORT_DRAIN_IDLE,
	REPORT_DRAIN_ATTACHING,
	REPORT_DRAIN_SCHEDULED,
	REPORT_DRAIN_RUNNING
} ReportDrainState;

/* Alignment covers the fundamental types used by protobuf-c's generated
 * structs. Header bytes are charged too, bounding allocation count. */
typedef union {
	gsize charged;
	long double alignment;
	gpointer pointer_alignment;
} ReportAllocation;

struct _ReportSlot {
	SscLifetimeNode *node;
	ReportSlotState state;
	ReportSlot *next;
	guint64 sequence;
	gsize charged;
	ClientBundle *bundle;
	GBytes *bytes;
	SscClientResponse *message;
	gsize next_body;
	ProtobufCAllocator allocator;
	gsize decoded_bytes;
	gboolean decode_budget_failed;
};

typedef enum {
	BUNDLE_LIVE,
	BUNDLE_DRAINING,
	BUNDLE_RELEASING,
	BUNDLE_CLOSING,
	BUNDLE_CLOSED
} BundleState;

/* Resource fields, pending counts and send list are owner-context-only. */
struct _ClientBundle {
	gint refs;
	SscLifetimeNode *node;
	GMainContext *owner;
	QmiDevice *device;
	QmiClientSsc *client;
#if QMI_QRTR_SUPPORTED
	QrtrBus *bus;
#endif
	gulong report_small_id;
	gulong report_large_id;
	guint acquisitions;
	GList *sends; /* borrowed tickets, each held by its backend callback */
	BundleState state;
};

typedef enum {
	TICKET_INIT,
	TICKET_SEND
} TicketKind;

struct _ClientTicket {
	gint refs;
	SscLifetimeNode *node;
	gboolean admitted;
	TicketKind kind;
	GMainContext *owner;
	GTask *task;
	SSCClient *self; /* borrowed from task until the terminal decision */
	ClientBundle *bundle;
	GCancellable *caller;
	gulong cancel_id;
	GCancellable *backend;
	gboolean done;
	gboolean queued_send;
	GBytes *payload;
	gboolean has_payload;
	guint64 uid_high;
	guint64 uid_low;
	guint32 message_id;
	gint priority;
};

typedef struct _SSCClientPrivate {
	/* Only this short publication/handoff is shared with foreign dispose. */
	GMutex mutex;
	GMainContext *owner;
	ClientBundle *resources;
	ClientTicket *initialization;
	SscLifetime *scope;
	SscLifetimeNode *generation;
	gboolean ready;
	gboolean disposed;
	gboolean retired;
	/* Fixed slots and all credit/scheduler publication live under mutex. The
	 * ACTIVE decoder/body cursor is touched only by the sole owner drainer. */
	ReportSlot report_slots[SSC_CLIENT_REPORT_MAX_COUNT];
	ReportSlot *report_head;
	ReportSlot *report_tail;
	ReportDrainState report_drain;
	guint64 report_sequence;
	SSCClientReportStats report_stats;
	gboolean report_failure_claimed;
	ClientBundle *report_failure_bundle;
} SSCClientPrivate;

struct _SSCClient {
	GObject parent;
	SSCClientPrivate *priv;
};

static void async_initable_iface_init (GAsyncInitableIface *iface);

G_DEFINE_TYPE_WITH_CODE (SSCClient, ssc_client, G_TYPE_OBJECT,
	G_ADD_PRIVATE (SSCClient)
	G_IMPLEMENT_INTERFACE (G_TYPE_ASYNC_INITABLE, async_initable_iface_init));

GQuark
ssc_client_error_quark (void)
{
	return g_quark_from_static_string ("ssc-client");
}

static GError *
report_error_for_reason (SSCClientReportFailure reason)
{
	const gchar *message;
	gint code = SSC_CLIENT_ERROR_REPORT_OVERFLOW;
	switch (reason) {
	case SSC_CLIENT_REPORT_FAILURE_NONE:
		return NULL;
	case SSC_CLIENT_REPORT_FAILURE_COUNT:
		message = "SSC report count budget exhausted";
		break;
	case SSC_CLIENT_REPORT_FAILURE_BYTES:
		message = "SSC report byte budget exhausted";
		break;
	case SSC_CLIENT_REPORT_FAILURE_WIRE:
		message = "SSC report exceeds the encoded envelope limit";
		break;
	case SSC_CLIENT_REPORT_FAILURE_SEQUENCE:
		message = "SSC report reservation sequence exhausted";
		break;
	case SSC_CLIENT_REPORT_FAILURE_DECODE_BUDGET:
		message = "SSC report decoded allocation budget exhausted";
		break;
	case SSC_CLIENT_REPORT_FAILURE_DATA:
		code = SSC_CLIENT_ERROR_REPORT_INVALID;
		message = "Cannot extract valid SSC report data";
		break;
	case SSC_CLIENT_REPORT_FAILURE_DECODE:
		code = SSC_CLIENT_ERROR_REPORT_INVALID;
		message = "Failed to unpack SSC report envelope";
		break;
	default:
		g_assert_not_reached ();
	}
	return g_error_new_literal (ssc_client_error_quark (), code, message);
}

GError *
ssc_client_dup_report_error (SSCClient *self)
{
	SSCClientReportFailure reason;
	g_return_val_if_fail (SSC_IS_CLIENT (self), NULL);
	g_mutex_lock (&self->priv->mutex);
	reason = self->priv->report_stats.failure_reason;
	g_mutex_unlock (&self->priv->mutex);
	return report_error_for_reason (reason);
}

void
ssc_client_get_report_stats (SSCClient *self, SSCClientReportStats *stats)
{
	g_return_if_fail (SSC_IS_CLIENT (self));
	g_return_if_fail (stats != NULL);
	g_mutex_lock (&self->priv->mutex);
	*stats = self->priv->report_stats;
	g_mutex_unlock (&self->priv->mutex);
}

static void bundle_maybe_cleanup (ClientBundle *bundle);
static void bundle_begin_cleanup (ClientBundle *bundle);
static void ticket_complete (ClientTicket *ticket, GError *error);

/* Always defer, even if the caller currently owns the context. */
typedef struct {
	SscLifetimeNode *node;
	GSourceFunc callback;
	gpointer data;
	GDestroyNotify destroy;
} ClientOwnerWork;

static gboolean
owner_work_dispatch (gpointer data)
{
	ClientOwnerWork *work = data;
	SscLifetimeNode *node = ssc_lifetime_node_ref (work->node);
	gboolean again = work->callback (work->data);
	ssc_lifetime_node_unref (node);
	return again;
}

static void
owner_work_free (gpointer data)
{
	ClientOwnerWork *work = data;
	SscLifetimeNode *node = work->node;
	/* The real destructor can register detached cleanup children. */
	if (work->destroy)
		work->destroy (work->data);
	g_free (work);
	ssc_lifetime_node_unref (node);
}

static void
queue_owner (GMainContext *owner, SscLifetimeNode *parent, gint priority, GSourceFunc callback,
	     gpointer data, GDestroyNotify destroy)
{
	ClientOwnerWork *work = g_new0 (ClientOwnerWork, 1);
	GSource *source = g_idle_source_new ();
	work->node = ssc_lifetime_node_new (ssc_lifetime_node_get_scope (parent),
		parent, "client-owner-source");
	work->callback = callback;
	work->data = data;
	work->destroy = destroy;
	g_source_set_priority (source, priority);
	g_source_set_can_recurse (source, FALSE);
	g_source_set_callback (source, owner_work_dispatch, work, owner_work_free);
	g_source_attach (source, owner);
	g_source_unref (source);
}

static ClientBundle *
bundle_ref (ClientBundle *bundle)
{
	g_atomic_int_inc (&bundle->refs);
	return bundle;
}

static void
bundle_unref (ClientBundle *bundle)
{
	SscLifetimeNode *node;
	if (!bundle || !g_atomic_int_dec_and_test (&bundle->refs))
		return;
	g_assert (bundle->state == BUNDLE_CLOSED);
	g_assert (!bundle->device && !bundle->client && !bundle->sends && !bundle->acquisitions);
#if QMI_QRTR_SUPPORTED
	g_assert (!bundle->bus);
#endif
	node = bundle->node;
	g_main_context_unref (bundle->owner);
	g_free (bundle);
	ssc_lifetime_node_unref (node);
}

static ClientBundle *
bundle_new (GMainContext *owner, SscLifetimeNode *parent)
{
	ClientBundle *bundle = g_new0 (ClientBundle, 1);
	bundle->refs = 1;
	bundle->owner = g_main_context_ref (owner);
	bundle->node = ssc_lifetime_node_new (ssc_lifetime_node_get_scope (parent),
		parent, "client-bundle");
	return bundle;
}

static ClientTicket *
ticket_ref (ClientTicket *ticket)
{
	g_atomic_int_inc (&ticket->refs);
	return ticket;
}

static void
ticket_unref (ClientTicket *ticket)
{
	SscLifetimeNode *node;
	if (!g_atomic_int_dec_and_test (&ticket->refs))
		return;
	g_assert (ticket->done && !ticket->task && !ticket->self && !ticket->cancel_id);
	g_assert (!ticket->queued_send);
	node = ticket->node;
	bundle_unref (ticket->bundle);
	g_clear_object (&ticket->caller);
	g_clear_object (&ticket->backend);
	g_clear_pointer (&ticket->payload, g_bytes_unref);
	g_main_context_unref (ticket->owner);
	g_free (ticket);
	ssc_lifetime_node_unref (node);
}

static ClientTicket *
ticket_new (SSCClient *self, TicketKind kind, GCancellable *cancellable,
	    GAsyncReadyCallback callback, gpointer user_data)
{
	ClientTicket *ticket = g_new0 (ClientTicket, 1);
	ticket->refs = 1;
	ticket->kind = kind;
	/* SEND is a new public/private API root. A generation-owned INIT is a
	 * descendant already registered before its factory returned. */
	g_mutex_lock (&self->priv->mutex);
	ticket->node = ssc_lifetime_node_new (self->priv->scope,
		kind == TICKET_INIT ? self->priv->generation : NULL, "client-ticket");
	ticket->admitted = !self->priv->scope || ticket->node != NULL;
	if (self->priv->retired || self->priv->disposed)
		ticket->admitted = FALSE;
	g_mutex_unlock (&self->priv->mutex);
	ticket->owner = g_main_context_ref (self->priv->owner);
	ticket->task = g_task_new (self, cancellable, callback, user_data);
	/* Result choice belongs to owner dispatch, not later finish-time masking. */
	g_task_set_check_cancellable (ticket->task, FALSE);
	ticket->self = self;
	if (cancellable)
		ticket->caller = g_object_ref (cancellable);
	ticket->priority = G_PRIORITY_DEFAULT;
	return ticket;
}

static gboolean
client_disposed (SSCClient *self)
{
	gboolean disposed;
	g_mutex_lock (&self->priv->mutex);
	disposed = self->priv->disposed || self->priv->retired ||
		ssc_lifetime_is_sealed (self->priv->scope);
	g_mutex_unlock (&self->priv->mutex);
	return disposed;
}

static gboolean
ticket_cancelled (ClientTicket *ticket)
{
	return ticket->caller && g_cancellable_is_cancelled (ticket->caller);
}

static GError *
cancelled_error (void)
{
	return g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CANCELLED, "SSC operation cancelled");
}

static GError *
closed_error (void)
{
	return g_error_new_literal (G_IO_ERROR, G_IO_ERROR_CLOSED, "SSC client disposed");
}

/* A rejected root has no owner/backend work. Keep its real caller GTask and
 * tag, but do not run owner-only ticket completion on the rejecting thread. */
static void
ticket_reject (ClientTicket *ticket)
{
	GTask *task = g_steal_pointer (&ticket->task);
	ticket->done = TRUE;
	ticket->self = NULL;
	g_task_return_error (task, closed_error ());
	g_object_unref (task);
}

static gboolean
cancel_on_owner (gpointer data)
{
	ClientTicket *ticket = data;
	if (!ticket->done)
		ticket_complete (ticket, cancelled_error ());
	return G_SOURCE_REMOVE;
}

static void
caller_cancelled (GCancellable *cancellable, gpointer data)
{
	ClientTicket *ticket = data;
	/* No private state, transport cancellation or disconnect on this thread. */
	queue_owner (ticket->owner, ticket->node, ticket->priority, cancel_on_owner,
		     ticket_ref (ticket), (GDestroyNotify) ticket_unref);
}

static gboolean
ticket_observe_cancellation (ClientTicket *ticket)
{
	if (ticket->caller)
		ticket->cancel_id = g_cancellable_connect (ticket->caller,
			G_CALLBACK (caller_cancelled), ticket_ref (ticket),
			(GDestroyNotify) ticket_unref);
	if (ticket_cancelled (ticket)) {
		ticket_complete (ticket, cancelled_error ());
		return FALSE;
	}
	return TRUE;
}

static void
bundle_finished (ClientBundle *bundle)
{
	g_clear_object (&bundle->client);
	g_clear_object (&bundle->device);
#if QMI_QRTR_SUPPORTED
	g_clear_object (&bundle->bus);
#endif
	bundle->state = BUNDLE_CLOSED;
	/* Drop the one cleanup-lifetime ref acquired by begin_cleanup. */
	bundle_unref (bundle);
}

static void
close_ready (QmiDevice *device, GAsyncResult *result, gpointer data)
{
	ClientBundle *bundle = data;
	GError *error = NULL;
	if (!qmi_device_close_finish (device, result, &error)) {
		if (!error)
			error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED,
				"SSC QMI device close failed without an error");
		ssc_lifetime_record_error (ssc_lifetime_node_get_scope (bundle->node),
			SSC_LIFETIME_ERROR_CLOSE, error);
		g_warning ("Could not close SSC QMI device: %s", error ? error->message : "unknown failure");
		g_clear_error (&error);
	}
	bundle_finished (bundle);
	bundle_unref (bundle); /* callback */
}

static void
bundle_close (ClientBundle *bundle)
{
	bundle->state = BUNDLE_CLOSING;
	if (!bundle->device) {
		bundle_finished (bundle);
		return;
	}
	/* Close is also required after a failed/partial open, and is idempotent. */
	g_main_context_push_thread_default (bundle->owner);
	qmi_device_close_async (bundle->device, 10, NULL,
		(GAsyncReadyCallback) close_ready, bundle_ref (bundle));
	g_main_context_pop_thread_default (bundle->owner);
}

static void
release_ready (QmiDevice *device, GAsyncResult *result, gpointer data)
{
	ClientBundle *bundle = data;
	GError *error = NULL;
	if (!qmi_device_release_client_finish (device, result, &error)) {
		if (!error)
			error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED,
				"SSC QMI client release failed without an error");
		ssc_lifetime_record_error (ssc_lifetime_node_get_scope (bundle->node),
			SSC_LIFETIME_ERROR_RELEASE, error);
		g_warning ("Could not release SSC QMI client: %s", error ? error->message : "unknown failure");
		g_clear_error (&error);
	}
	/* libqmi considers it released even if its asynchronous release failed. */
	g_clear_object (&bundle->client);
	bundle_close (bundle);
	bundle_unref (bundle); /* callback */
}

static void
bundle_maybe_cleanup (ClientBundle *bundle)
{
	if (bundle->state != BUNDLE_DRAINING || bundle->acquisitions || bundle->sends)
		return;
	if (!bundle->client) {
		bundle_close (bundle);
		return;
	}
	g_assert (bundle->device);
	bundle->state = BUNDLE_RELEASING;
	g_main_context_push_thread_default (bundle->owner);
	qmi_device_release_client (bundle->device, QMI_CLIENT (bundle->client),
		QMI_DEVICE_RELEASE_CLIENT_FLAGS_RELEASE_CID, 10, NULL,
		(GAsyncReadyCallback) release_ready, bundle_ref (bundle));
	g_main_context_pop_thread_default (bundle->owner);
}

static void
bundle_begin_cleanup (ClientBundle *bundle)
{
	GPtrArray *cancellables;
	if (bundle->state != BUNDLE_LIVE)
		return;
	bundle_ref (bundle); /* survives drain, release and close independently */
	bundle->state = BUNDLE_DRAINING;
	if (bundle->report_small_id) {
		g_signal_handler_disconnect (bundle->client, bundle->report_small_id);
		bundle->report_small_id = 0;
	}
	if (bundle->report_large_id) {
		g_signal_handler_disconnect (bundle->client, bundle->report_large_id);
		bundle->report_large_id = 0;
	}
	/* Snapshot before cancel: a completion may mutate the pending-send list. */
	cancellables = g_ptr_array_new_with_free_func (g_object_unref);
	for (GList *l = bundle->sends; l; l = l->next) {
		ClientTicket *ticket = l->data;
		g_ptr_array_add (cancellables, g_object_ref (ticket->backend));
	}
	for (guint i = 0; i < cancellables->len; i++)
		g_cancellable_cancel (g_ptr_array_index (cancellables, i));
	g_ptr_array_unref (cancellables);
	bundle_maybe_cleanup (bundle);
}

#if QMI_QRTR_SUPPORTED
/* QMI output owns borrowed report bytes only until its signal returns. */
typedef struct {
	GWeakRef client;
	SscLifetimeNode *node;
} ReportLink;

typedef struct {
	SSCClient *self;
	SscLifetimeNode *node;
} ClientReportDrain;

static gboolean report_drain (gpointer data);

static void
report_count_inc (guint64 *value)
{
	if (*value != G_MAXUINT64)
		(*value)++;
}

static gboolean
report_current_locked (SSCClientPrivate *priv, ClientBundle *bundle)
{
	return !priv->disposed && !priv->retired && !ssc_lifetime_is_sealed (priv->scope) &&
		!priv->report_stats.failed &&
		priv->ready && priv->resources == bundle;
}

static gboolean
report_schedule_locked (SSCClientPrivate *priv)
{
	if (priv->report_drain != REPORT_DRAIN_IDLE)
		return FALSE;
	if ((!priv->report_stats.failed || priv->report_failure_claimed) &&
	    (!priv->report_head || priv->report_head->state != REPORT_SLOT_READY))
		return FALSE;
	priv->report_drain = REPORT_DRAIN_ATTACHING;
	return TRUE;
}

/* Unique ATTACHING owner holds self while creating and attaching the source.
 * No caller creates a second source until this one returns to IDLE. */
static void
report_source_free (gpointer data)
{
	ClientReportDrain *work = data;
	SscLifetimeNode *node = work->node;
	g_object_unref (work->self);
	g_free (work);
	ssc_lifetime_node_unref (node);
}

static void
report_attach (SSCClient *self, SscLifetimeNode *parent)
{
	GSource *source = g_idle_source_new ();
	ClientReportDrain *work = g_new0 (ClientReportDrain, 1);
	guint source_id;
	work->self = g_object_ref (self);
	work->node = ssc_lifetime_node_new (ssc_lifetime_node_get_scope (parent),
		parent, "client-report-source");
	g_source_set_priority (source, G_PRIORITY_DEFAULT);
	g_source_set_can_recurse (source, FALSE);
	g_source_set_callback (source, report_drain, work, report_source_free);
	g_mutex_lock (&self->priv->mutex);
	g_assert (self->priv->report_drain == REPORT_DRAIN_ATTACHING);
	self->priv->report_drain = REPORT_DRAIN_SCHEDULED;
	g_mutex_unlock (&self->priv->mutex);
	source_id = g_source_attach (source, self->priv->owner);
	g_assert (source_id != 0);
	g_source_unref (source);
}

/* Only compact immutable first-failure data is latched under the mutex. */
static void
report_fail_locked (SSCClientPrivate *priv, ClientBundle *bundle,
		    SSCClientReportFailure reason, gsize length)
{
	if (!report_current_locked (priv, bundle))
		return;
	priv->report_stats.failed = TRUE;
	priv->report_stats.failure_reason = reason;
	priv->report_stats.first_failure_length = length;
	priv->report_stats.first_failure_reports = priv->report_stats.used_reports;
	priv->report_stats.first_failure_raw_bytes = priv->report_stats.used_raw_bytes;
	priv->report_failure_bundle = bundle_ref (bundle);
	priv->ready = FALSE;
}

static void
report_fail (SSCClient *self, ClientBundle *bundle,
	     SSCClientReportFailure reason, gsize length)
{
	gboolean attach;
	g_mutex_lock (&self->priv->mutex);
	report_fail_locked (self->priv, bundle, reason, length);
	attach = report_schedule_locked (self->priv);
	g_mutex_unlock (&self->priv->mutex);
	if (attach)
		report_attach (self, bundle->node);
}

/* Real generated finishes still own every backend debt after logical failure.
 * Snapshot tickets before cancellation can reenter and mutate bundle->sends. */
static void
report_publish_failure (SSCClient *self)
{
	ClientBundle *bundle = NULL;
	SSCClientReportFailure reason = SSC_CLIENT_REPORT_FAILURE_NONE;
	GPtrArray *pending;
	GError *error;
	gboolean emit;
	g_mutex_lock (&self->priv->mutex);
	if (self->priv->report_stats.failed && !self->priv->report_failure_claimed) {
		self->priv->report_failure_claimed = TRUE;
		reason = self->priv->report_stats.failure_reason;
		bundle = g_steal_pointer (&self->priv->report_failure_bundle);
	}
	g_mutex_unlock (&self->priv->mutex);
	if (!bundle)
		return;
	error = report_error_for_reason (reason);
	pending = g_ptr_array_new_with_free_func ((GDestroyNotify) ticket_unref);
	for (GList *l = bundle->sends; l; l = l->next)
		g_ptr_array_add (pending, ticket_ref (l->data));
	for (guint i = 0; i < pending->len; i++)
		ticket_complete (g_ptr_array_index (pending, i), g_error_copy (error));
	g_ptr_array_unref (pending);
	bundle_begin_cleanup (bundle);
	g_warning ("SSC report delivery failed: %s", error->message);
	/* Do not run GObject dispose: observers and the sticky query are retained. */
	g_mutex_lock (&self->priv->mutex);
	emit = !self->priv->scope || (!self->priv->retired && !self->priv->disposed &&
		!ssc_lifetime_is_sealed (self->priv->scope));
	if (emit)
		report_count_inc (&self->priv->report_stats.failure_notifications);
	g_mutex_unlock (&self->priv->mutex);
	/* A pre-seal authorization may unwind, but cleanup is never conditional
	 * on authorization of a new report-failed emission. */
	if (emit)
		g_signal_emit (self, signals[SIGNAL_REPORT_FAILED], 0, error);
	g_error_free (error);
	bundle_unref (bundle);
}

static void *
report_decode_alloc (void *data, size_t size)
{
	ReportSlot *slot = data;
	ReportAllocation *allocation;
	gsize charged;
	if (size > SSC_CLIENT_REPORT_DECODE_MAX_BYTES - sizeof (ReportAllocation)) {
		slot->decode_budget_failed = TRUE;
		return NULL;
	}
	charged = sizeof (ReportAllocation) + size;
	if (slot->decoded_bytes > SSC_CLIENT_REPORT_DECODE_MAX_BYTES - charged) {
		slot->decode_budget_failed = TRUE;
		return NULL;
	}
	/* GLib's fatal allocation convention is not advertised as recoverable OOM. */
	allocation = g_malloc (charged);
	allocation->charged = charged;
	slot->decoded_bytes += charged;
	return allocation + 1;
}

static void
report_decode_free (void *data, void *pointer)
{
	ReportSlot *slot = data;
	ReportAllocation *allocation;
	if (!pointer)
		return;
	allocation = ((ReportAllocation *) pointer) - 1;
	g_assert (slot->decoded_bytes >= allocation->charged);
	slot->decoded_bytes -= allocation->charged;
	g_free (allocation);
}

/* The slot is still charged while protobuf/raw storage and bundle ownership
 * are actually released outside mutex. A COPYING slot cannot arrive here. */
static void
report_retire (SSCClient *self, ReportSlot *slot, gboolean invalidated)
{
	ClientBundle *bundle;
	SscLifetimeNode *node;
	gsize charged;
	g_mutex_lock (&self->priv->mutex);
	g_assert (slot == self->priv->report_head && slot->state == REPORT_SLOT_ACTIVE);
	self->priv->report_head = slot->next;
	if (!self->priv->report_head)
		self->priv->report_tail = NULL;
	slot->state = REPORT_SLOT_RETIRING;
	bundle = slot->bundle;
	node = slot->node;
	charged = slot->charged;
	g_mutex_unlock (&self->priv->mutex);
	if (slot->message)
		ssc_client_response__free_unpacked (slot->message, &slot->allocator);
	g_assert (slot->decoded_bytes == 0);
	g_clear_pointer (&slot->bytes, g_bytes_unref);
	bundle_unref (bundle);
	g_mutex_lock (&self->priv->mutex);
	g_assert (self->priv->report_stats.used_reports > 0);
	g_assert (self->priv->report_stats.used_raw_bytes >= charged);
	self->priv->report_stats.used_reports--;
	self->priv->report_stats.used_raw_bytes -= charged;
	report_count_inc (&self->priv->report_stats.reports_retired);
	if (invalidated)
		report_count_inc (&self->priv->report_stats.reports_invalidated);
	memset (slot, 0, sizeof (*slot));
	g_mutex_unlock (&self->priv->mutex);
	ssc_lifetime_node_unref (node);
}

static gboolean
report_body_authorized (SSCClient *self, ReportSlot *slot)
{
	gboolean current;
	g_mutex_lock (&self->priv->mutex);
	current = report_current_locked (self->priv, slot->bundle);
	g_mutex_unlock (&self->priv->mutex);
	return current;
}

static gboolean
report_drain (gpointer data)
{
	ClientReportDrain *work_item = data;
	SSCClient *self = g_object_ref (work_item->self);
	SscLifetimeNode *node = ssc_lifetime_node_ref (work_item->node);
	guint work = 0;
	g_mutex_lock (&self->priv->mutex);
	g_assert (self->priv->report_drain == REPORT_DRAIN_SCHEDULED);
	self->priv->report_drain = REPORT_DRAIN_RUNNING;
	g_mutex_unlock (&self->priv->mutex);
	while (work < SSC_CLIENT_REPORT_BODY_QUANTUM) {
		ReportSlot *slot;
		gboolean current;
		gsize length;
		const guint8 *bytes;
		SscClientResponseBody *body;
		GArray *buffer;
		report_publish_failure (self);
		g_mutex_lock (&self->priv->mutex);
		/* A foreign failure that arrived after the publication check must not
		 * lose its one notification at an empty/COPYING-head transition. */
		if (self->priv->report_stats.failed && !self->priv->report_failure_claimed) {
			g_mutex_unlock (&self->priv->mutex);
			continue;
		}
		slot = self->priv->report_head;
		if (!slot || slot->state == REPORT_SLOT_COPYING) {
			self->priv->report_drain = REPORT_DRAIN_IDLE;
			g_mutex_unlock (&self->priv->mutex);
			g_object_unref (self);
			ssc_lifetime_node_unref (node);
			return G_SOURCE_REMOVE;
		}
		g_assert (slot->state == REPORT_SLOT_READY || slot->state == REPORT_SLOT_ACTIVE);
		slot->state = REPORT_SLOT_ACTIVE;
		current = report_current_locked (self->priv, slot->bundle);
		g_mutex_unlock (&self->priv->mutex);
		if (!current) {
			report_retire (self, slot, TRUE);
			work++;
			continue;
		}
		if (!slot->message) {
			bytes = g_bytes_get_data (slot->bytes, &length);
			slot->allocator.alloc = report_decode_alloc;
			slot->allocator.free = report_decode_free;
			slot->allocator.allocator_data = slot;
			slot->message = ssc_client_response__unpack (&slot->allocator, length, bytes);
			if (!slot->message) {
				g_assert (slot->decoded_bytes == 0);
				report_fail (self, slot->bundle,
					slot->decode_budget_failed ? SSC_CLIENT_REPORT_FAILURE_DECODE_BUDGET :
					SSC_CLIENT_REPORT_FAILURE_DECODE, length);
				report_retire (self, slot, TRUE);
				work++;
				continue;
			}
		}
		if (slot->next_body == slot->message->n_response) {
			report_retire (self, slot, FALSE);
			work++;
			continue;
		}
		/* One signal invocation may unwind after authorization. Recheck between
		 * private and legacy publication, and before authorizing another body. */
		if (!report_body_authorized (self, slot)) {
			report_retire (self, slot, TRUE);
			work++;
			continue;
		}
		body = slot->message->response[slot->next_body];
		buffer = g_array_sized_new (FALSE, FALSE, 1, body->msg.len);
		g_array_set_size (buffer, body->msg.len);
		if (body->msg.len)
			memcpy (buffer->data, body->msg.data, body->msg.len);
		/* Preserve raw sensor ticks, not a guessed clock/unit conversion. Both
		 * channels borrow this same read-only payload; no second copy is needed.
		 * A private observer can dispose/fault the actual client reentrantly. */
		g_signal_emit (self, signals[SIGNAL_REPORT_FRAME], 0, body->msg_id,
			slot->message->uid->high, slot->message->uid->low,
			body->timestamp, buffer);
		if (report_body_authorized (self, slot))
			g_signal_emit (self, signals[SIGNAL_REPORT], 0, body->msg_id,
				slot->message->uid->high, slot->message->uid->low, buffer);
		g_array_unref (buffer);
		slot->next_body++;
		g_mutex_lock (&self->priv->mutex);
		/* Count one logical body even if legacy fanout was suppressed. Preserve
		 * the existing post-callback accounting timing, not a consumer receipt. */
		report_count_inc (&self->priv->report_stats.bodies_published);
		g_mutex_unlock (&self->priv->mutex);
		work++;
		if (slot->next_body == slot->message->n_response)
			report_retire (self, slot, FALSE);
	}
	g_mutex_lock (&self->priv->mutex);
	/* Keep the sole source across yield, including any ACTIVE partial message.
	 * Producers never attach while this source is scheduled or running. */
	self->priv->report_drain = REPORT_DRAIN_SCHEDULED;
	g_mutex_unlock (&self->priv->mutex);
	g_object_unref (self);
	ssc_lifetime_node_unref (node);
	return G_SOURCE_CONTINUE;
}

static void
queue_report (QmiClientSsc *emitter, GArray *protobuf, ReportLink *link,
	      SscLifetimeNode *parent)
{
	SSCClient *self = g_weak_ref_get (&link->client);
	SSCClientPrivate *priv;
	ClientBundle *bundle;
	ReportSlot *slot = NULL;
	gboolean attach;
	gsize length = protobuf ? protobuf->len : 0;
	if (!self)
		return;
	priv = self->priv;
	g_mutex_lock (&priv->mutex);
	bundle = priv->resources;
	/* Fail/close ready publication before inspecting owner-only client: fault
	 * cleanup may already be clearing that resource outside this mutex. */
	if (!bundle || !report_current_locked (priv, bundle) || bundle->client != emitter) {
		if (priv->report_stats.failed)
			report_count_inc (&priv->report_stats.rejected_reports);
		else
			report_count_inc (&priv->report_stats.stale_reports);
		g_mutex_unlock (&priv->mutex);
		g_object_unref (self);
		return;
	}
	if (!protobuf || (length && !protobuf->data))
		report_fail_locked (priv, bundle, SSC_CLIENT_REPORT_FAILURE_DATA, length);
	else if (length > SSC_CLIENT_REPORT_MAX_WIRE_BYTES)
		report_fail_locked (priv, bundle, SSC_CLIENT_REPORT_FAILURE_WIRE, length);
	else if (priv->report_stats.used_reports == SSC_CLIENT_REPORT_MAX_COUNT)
		report_fail_locked (priv, bundle, SSC_CLIENT_REPORT_FAILURE_COUNT, length);
	else if (length > SSC_CLIENT_REPORT_MAX_BYTES - priv->report_stats.used_raw_bytes)
		report_fail_locked (priv, bundle, SSC_CLIENT_REPORT_FAILURE_BYTES, length);
	else if (priv->report_sequence == G_MAXUINT64)
		report_fail_locked (priv, bundle, SSC_CLIENT_REPORT_FAILURE_SEQUENCE, length);
	else {
		for (guint i = 0; i < SSC_CLIENT_REPORT_MAX_COUNT; i++)
			if (priv->report_slots[i].state == REPORT_SLOT_FREE) {
				slot = &priv->report_slots[i];
				break;
			}
		g_assert (slot);
		slot->state = REPORT_SLOT_COPYING;
		slot->sequence = ++priv->report_sequence;
		slot->charged = length;
		slot->bundle = bundle_ref (bundle);
		slot->node = ssc_lifetime_node_new (ssc_lifetime_node_get_scope (parent),
			parent, "client-report-slot");
		if (priv->report_tail)
			priv->report_tail->next = slot;
		else
			priv->report_head = slot;
		priv->report_tail = slot;
		priv->report_stats.used_reports++;
		priv->report_stats.used_raw_bytes += length;
		priv->report_stats.high_water_reports =
			MAX (priv->report_stats.high_water_reports, priv->report_stats.used_reports);
		priv->report_stats.high_water_raw_bytes =
			MAX (priv->report_stats.high_water_raw_bytes, priv->report_stats.used_raw_bytes);
		report_count_inc (&priv->report_stats.reports_admitted);
	}
	if (!slot)
		report_count_inc (&priv->report_stats.rejected_reports);
	attach = report_schedule_locked (priv);
	g_mutex_unlock (&priv->mutex);
	if (attach)
		report_attach (self, parent);
	if (slot) {
		/* Reservation stays COPYING and charged until this sole producer
		 * acknowledges its synchronous copy, even after fault/disposal. */
		GBytes *bytes = g_bytes_new (protobuf->data, length);
		g_mutex_lock (&priv->mutex);
		g_assert (slot->state == REPORT_SLOT_COPYING);
		slot->bytes = bytes;
		slot->state = REPORT_SLOT_READY;
		attach = report_schedule_locked (priv);
		g_mutex_unlock (&priv->mutex);
		if (attach)
			report_attach (self, parent);
	}
	g_object_unref (self);
}

static void
report_extraction_failed (QmiClientSsc *emitter, ReportLink *link,
			  SscLifetimeNode *parent)
{
	SSCClient *self = g_weak_ref_get (&link->client);
	gboolean attach;
	if (!self)
		return;
	g_mutex_lock (&self->priv->mutex);
	if (self->priv->resources &&
	    report_current_locked (self->priv, self->priv->resources) &&
	    self->priv->resources->client == emitter) {
		report_fail_locked (self->priv, self->priv->resources,
			SSC_CLIENT_REPORT_FAILURE_DATA, 0);
		report_count_inc (&self->priv->report_stats.rejected_reports);
	} else if (self->priv->report_stats.failed)
		report_count_inc (&self->priv->report_stats.rejected_reports);
	else
		report_count_inc (&self->priv->report_stats.stale_reports);
	attach = report_schedule_locked (self->priv);
	g_mutex_unlock (&self->priv->mutex);
	if (attach)
		report_attach (self, parent);
	g_object_unref (self);
}

static void
report_small_received (QmiClientSsc *emitter, QmiIndicationSscReportSmallOutput *output, gpointer data)
{
	ReportLink *link = data;
	SscLifetimeNode *node = ssc_lifetime_node_new (
		ssc_lifetime_node_get_scope (link->node), link->node, "client-report-callback");
	GError *error = NULL;
	GArray *protobuf = NULL;
	if (qmi_indication_ssc_report_small_output_get_data (output, &protobuf, &error))
		queue_report (emitter, protobuf, link, node);
	else {
		report_extraction_failed (emitter, link, node);
		g_clear_error (&error);
	}
	ssc_lifetime_node_unref (node);
}

static void
report_large_received (QmiClientSsc *emitter, QmiIndicationSscReportLargeOutput *output, gpointer data)
{
	ReportLink *link = data;
	SscLifetimeNode *node = ssc_lifetime_node_new (
		ssc_lifetime_node_get_scope (link->node), link->node, "client-report-callback");
	GError *error = NULL;
	GArray *protobuf = NULL;
	if (qmi_indication_ssc_report_large_output_get_data (output, &protobuf, &error))
		queue_report (emitter, protobuf, link, node);
	else {
		report_extraction_failed (emitter, link, node);
		g_clear_error (&error);
	}
	ssc_lifetime_node_unref (node);
}

static void
report_link_free (gpointer data, GClosure *closure)
{
	ReportLink *link = data;
	SscLifetimeNode *node = link->node;
	g_weak_ref_clear (&link->client);
	g_free (link);
	ssc_lifetime_node_unref (node);
}

static void
connect_reports (ClientBundle *bundle, SSCClient *self)
{
	ReportLink *small = g_new0 (ReportLink, 1);
	ReportLink *large = g_new0 (ReportLink, 1);
	g_weak_ref_init (&small->client, self);
	g_weak_ref_init (&large->client, self);
	small->node = ssc_lifetime_node_new (ssc_lifetime_node_get_scope (bundle->node),
		bundle->node, "client-report-link");
	large->node = ssc_lifetime_node_new (ssc_lifetime_node_get_scope (bundle->node),
		bundle->node, "client-report-link");
	bundle->report_small_id = g_signal_connect_data (bundle->client, "report-small",
		G_CALLBACK (report_small_received), small, report_link_free, 0);
	bundle->report_large_id = g_signal_connect_data (bundle->client, "report-large",
		G_CALLBACK (report_large_received), large, report_link_free, 0);
}
#endif
/* Consume error, choose exactly one result, then remove self/task ownership. */
static void
ticket_complete (ClientTicket *ticket, GError *error)
{
	GTask *task;
	gboolean drop_initialization = FALSE;
	SSCClientReportFailure report_failure = SSC_CLIENT_REPORT_FAILURE_NONE;
	SSCClient *self;
	if (ticket->done) {
		g_clear_error (&error);
		return;
	}
	ticket_ref (ticket);
	self = ticket->self;
	if (!error && ticket_cancelled (ticket))
		error = cancelled_error ();
	g_mutex_lock (&self->priv->mutex);
	if (!error && (self->priv->disposed || self->priv->retired ||
		ssc_lifetime_is_sealed (self->priv->scope)))
		error = closed_error ();
	if (!error && self->priv->report_stats.failed)
		report_failure = self->priv->report_stats.failure_reason;
	if (ticket->kind == TICKET_INIT && ticket->bundle) {
		if (self->priv->initialization == ticket) {
			self->priv->initialization = NULL;
			drop_initialization = TRUE;
			if (!error && report_failure == SSC_CLIENT_REPORT_FAILURE_NONE) {
				g_assert (!self->priv->resources);
				self->priv->resources = bundle_ref (ticket->bundle);
				self->priv->ready = TRUE;
			}
		} else if (!error)
			error = closed_error ();
	}
	ticket->done = TRUE;
	g_mutex_unlock (&self->priv->mutex);
	if (!error && report_failure != SSC_CLIENT_REPORT_FAILURE_NONE)
		error = report_error_for_reason (report_failure);
	if (ticket->cancel_id) {
		g_cancellable_disconnect (ticket->caller, ticket->cancel_id);
		ticket->cancel_id = 0;
	}
	g_clear_object (&ticket->caller);
	if (error && ticket->backend)
		g_cancellable_cancel (ticket->backend);
	if (error && ticket->kind == TICKET_INIT && ticket->bundle)
		bundle_begin_cleanup (ticket->bundle);
	task = g_steal_pointer (&ticket->task);
	ticket->self = NULL;
	if (error)
		g_task_return_error (task, error);
	else
		g_task_return_boolean (task, TRUE);
	g_object_unref (task);
	if (drop_initialization)
		ticket_unref (ticket);
	ticket_unref (ticket);
}

static void
request_ready (QmiClientSsc *client, GAsyncResult *result, gpointer data)
{
	ClientTicket *ticket = data;
	ClientBundle *bundle = ticket->bundle;
	QmiMessageSscControlOutput *output;
	GError *error = NULL;
	/* Finish on the original source, never a later private client generation. */
	output = qmi_client_ssc_control_finish (bundle->client, result, &error);
	if (output) {
		if (!qmi_message_ssc_control_output_get_result (output, &error) && !error)
			error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "SSC QMI request failed");
		qmi_message_ssc_control_output_unref (output);
	} else if (!error)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "SSC QMI request returned no result");
	g_assert (ticket->queued_send);
	bundle->sends = g_list_remove (bundle->sends, ticket);
	ticket->queued_send = FALSE;
	ticket_complete (ticket, error);
	bundle_maybe_cleanup (bundle);
	ticket_unref (ticket); /* backend callback */
}

static gboolean
send_on_owner (gpointer data)
{
	ClientTicket *ticket = data;
	SSCClient *self = ticket->self;
	GError *error = NULL;
	QmiMessageSscControlInput *input;
	GArray *buffer;
	SscClientRequestBody body;
	SscClientConfig config;
	SscClientRequest request;
	SscUid uid;
	gsize size;
	SSCClientReportFailure report_failure = SSC_CLIENT_REPORT_FAILURE_NONE;
	if (!ticket_observe_cancellation (ticket))
		return G_SOURCE_REMOVE;
	g_mutex_lock (&self->priv->mutex);
	if (self->priv->disposed || self->priv->retired ||
	    ssc_lifetime_is_sealed (self->priv->scope))
		error = closed_error ();
	else if (self->priv->report_stats.failed)
		report_failure = self->priv->report_stats.failure_reason;
	else if (!self->priv->ready || !self->priv->resources)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_NOT_INITIALIZED, "SSC client not ready");
	else
		ticket->bundle = bundle_ref (self->priv->resources);
	g_mutex_unlock (&self->priv->mutex);
	if (report_failure != SSC_CLIENT_REPORT_FAILURE_NONE)
		error = report_error_for_reason (report_failure);
	if (error) {
		ticket_complete (ticket, error);
		return G_SOURCE_REMOVE;
	}
	ssc_client_config__init (&config);
	config.processor = SSC_PROCESSOR_APSS;
	config.suspend_mode = SSC_SUSPEND_MODE_WAKEUP;
	ssc_client_request_body__init (&body);
	if (ticket->has_payload) {
		body.has_msg = true;
		body.msg.data = (guint8 *) g_bytes_get_data (ticket->payload, &body.msg.len);
	}
	ssc_uid__init (&uid);
	uid.high = ticket->uid_high;
	uid.low = ticket->uid_low;
	ssc_client_request__init (&request);
	request.uid = &uid;
	request.msg_id = ticket->message_id;
	request.config = &config;
	request.request = &body;
	size = ssc_client_request__get_packed_size (&request);
	if (size > G_MAXUINT) {
		ticket_complete (ticket, g_error_new_literal (G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT, "SSC request too large"));
		return G_SOURCE_REMOVE;
	}
	buffer = g_array_sized_new (FALSE, FALSE, 1, size);
	g_array_set_size (buffer, size);
	ssc_client_request__pack (&request, (guint8 *) buffer->data);
	input = qmi_message_ssc_control_input_new ();
	if (!qmi_message_ssc_control_input_set_report_type (input, QMI_SSC_REPORT_TYPE_LARGE, &error) ||
	    !qmi_message_ssc_control_input_set_data (input, buffer, &error)) {
		if (!error)
			error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "Cannot build SSC control input");
	} else if (ticket_cancelled (ticket))
		error = cancelled_error ();
	else if (client_disposed (self))
		error = closed_error ();
	else
		error = ssc_client_dup_report_error (self);
	if (error) {
		qmi_message_ssc_control_input_unref (input);
		g_array_unref (buffer);
		ticket_complete (ticket, error);
		return G_SOURCE_REMOVE;
	}
	ticket->backend = g_cancellable_new ();
	ticket->queued_send = TRUE;
	ticket->bundle->sends = g_list_prepend (ticket->bundle->sends, ticket);
	g_main_context_push_thread_default (ticket->owner);
	qmi_client_ssc_control (ticket->bundle->client, input, 10, ticket->backend,
		(GAsyncReadyCallback) request_ready, ticket_ref (ticket));
	g_main_context_pop_thread_default (ticket->owner);
	qmi_message_ssc_control_input_unref (input);
	g_array_unref (buffer);
	return G_SOURCE_REMOVE;
}

gboolean
ssc_client_send_finish (SSCClient *self, GAsyncResult *result, GError **error)
{
	g_return_val_if_fail (g_task_is_valid (result, self), FALSE);
	g_return_val_if_fail (g_task_get_source_tag (G_TASK (result)) == ssc_client_send, FALSE);
	return g_task_propagate_boolean (G_TASK (result), error);
}

void
ssc_client_send (SSCClient *self, guint64 uid_high, guint64 uid_low, guint32 message_id,
		 GArray *protobuf, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data)
{
	ClientTicket *ticket;
	g_return_if_fail (SSC_IS_CLIENT (self));
	ticket = ticket_new (self, TICKET_SEND, cancellable, callback, user_data);
	g_task_set_source_tag (ticket->task, ssc_client_send);
	if (!ticket->admitted) {
		ticket_reject (ticket);
		ticket_unref (ticket);
		return;
	}
	ticket->uid_high = uid_high;
	ticket->uid_low = uid_low;
	ticket->message_id = message_id;
	if (protobuf) {
		ticket->has_payload = TRUE;
		ticket->payload = g_bytes_new (protobuf->data, protobuf->len);
	}
	queue_owner (ticket->owner, ticket->node, ticket->priority, send_on_owner,
		ticket_ref (ticket), (GDestroyNotify) ticket_unref);
	ticket_unref (ticket);
}

#if QMI_QRTR_SUPPORTED
/* Resource-returning calls deliberately receive NULL cancellation: a cancelled
 * libqmi GTask finish can otherwise hide a registered, acquired client. Logical
 * cancellation completes our task, while this callback still owns late data.
 */
static gboolean
init_continue (ClientTicket *ticket, GError *error)
{
	if (ticket->done) {
		g_clear_error (&error);
		bundle_maybe_cleanup (ticket->bundle);
		return FALSE;
	}
	if (!error && ticket_cancelled (ticket))
		error = cancelled_error ();
	if (!error && client_disposed (ticket->self))
		error = closed_error ();
	if (error) {
		ticket_complete (ticket, error);
		return FALSE;
	}
	return TRUE;
}

static void
allocate_client_ready (QmiDevice *device, GAsyncResult *result, gpointer data)
{
	ClientTicket *ticket = data;
	GError *error = NULL;
	ticket->bundle->client = QMI_CLIENT_SSC (qmi_device_allocate_client_finish (ticket->bundle->device, result, &error));
	ticket->bundle->acquisitions--;
	if (!ticket->bundle->client && !error)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "SSC client allocation returned no client");
	if (init_continue (ticket, error)) {
		connect_reports (ticket->bundle, ticket->self);
		ticket_complete (ticket, NULL);
	}
	ticket_unref (ticket);
}

static void
device_open_ready (QmiDevice *device, GAsyncResult *result, gpointer data)
{
	ClientTicket *ticket = data;
	GError *error = NULL;
	gboolean opened = qmi_device_open_finish (ticket->bundle->device, result, &error);
	ticket->bundle->acquisitions--;
	if (!opened && !error)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "SSC device open failed");
	if (init_continue (ticket, error)) {
		ticket->bundle->acquisitions++;
		g_main_context_push_thread_default (ticket->owner);
		qmi_device_allocate_client (ticket->bundle->device, QMI_SERVICE_SSC, QMI_CID_NONE,
			10, NULL, (GAsyncReadyCallback) allocate_client_ready, ticket_ref (ticket));
		g_main_context_pop_thread_default (ticket->owner);
	}
	ticket_unref (ticket);
}

static void
device_new_ready (GObject *source, GAsyncResult *result, gpointer data)
{
	ClientTicket *ticket = data;
	GError *error = NULL;
	ticket->bundle->device = qmi_device_new_from_node_finish (result, &error);
	ticket->bundle->acquisitions--;
	if (!ticket->bundle->device && !error)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "SSC device creation returned no device");
	if (init_continue (ticket, error)) {
		ticket->bundle->acquisitions++;
		g_main_context_push_thread_default (ticket->owner);
		qmi_device_open (ticket->bundle->device,
			QMI_DEVICE_OPEN_FLAGS_AUTO | QMI_DEVICE_OPEN_FLAGS_EXPECT_INDICATIONS,
			15, NULL, (GAsyncReadyCallback) device_open_ready, ticket_ref (ticket));
		g_main_context_pop_thread_default (ticket->owner);
	}
	ticket_unref (ticket);
}

static void
bus_new_ready (GObject *source, GAsyncResult *result, gpointer data)
{
	ClientTicket *ticket = data;
	GError *error = NULL;
	QrtrNode *node = NULL;
	ticket->bundle->bus = qrtr_bus_new_finish (result, &error);
	ticket->bundle->acquisitions--;
	if (!ticket->bundle->bus && !error)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_FAILED, "QRTR bus creation returned no bus");
	if (init_continue (ticket, error)) {
		for (GList *l = qrtr_bus_peek_nodes (ticket->bundle->bus); l; l = l->next) {
			if (l->data && qrtr_node_lookup_port (l->data, QMI_SERVICE_SSC) >= 0) {
				node = l->data;
				break;
			}
		}
		if (!node)
			ticket_complete (ticket, g_error_new_literal (ssc_client_error_quark (),
				SSC_CLIENT_ERROR_LOOKUP, "SSC QMI Service not found"));
		else {
			ticket->bundle->acquisitions++;
			g_main_context_push_thread_default (ticket->owner);
			qmi_device_new_from_node (node, NULL, device_new_ready, ticket_ref (ticket));
			g_main_context_pop_thread_default (ticket->owner);
		}
	}
	ticket_unref (ticket);
}
#endif

static gboolean
init_on_owner (gpointer data)
{
	ClientTicket *ticket = data;
	SSCClient *self = ticket->self;
	GError *error = NULL;
	gboolean ready;
	SSCClientReportFailure report_failure = SSC_CLIENT_REPORT_FAILURE_NONE;
	if (!ticket_observe_cancellation (ticket))
		return G_SOURCE_REMOVE;
	g_mutex_lock (&self->priv->mutex);
	ready = self->priv->ready;
	if (self->priv->disposed || self->priv->retired ||
	    ssc_lifetime_is_sealed (self->priv->scope))
		error = closed_error ();
	else if (self->priv->report_stats.failed)
		report_failure = self->priv->report_stats.failure_reason;
	else if (self->priv->initialization)
		error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_PENDING, "SSC initialization already pending");
	else if (!ready)
		self->priv->initialization = ticket_ref (ticket);
	g_mutex_unlock (&self->priv->mutex);
	if (report_failure != SSC_CLIENT_REPORT_FAILURE_NONE)
		error = report_error_for_reason (report_failure);
	if (error || ready) {
		ticket_complete (ticket, error);
		return G_SOURCE_REMOVE;
	}
	ticket->bundle = bundle_new (ticket->owner, ticket->node);
#if QMI_QRTR_SUPPORTED
	ticket->bundle->acquisitions++;
	g_main_context_push_thread_default (ticket->owner);
	qrtr_bus_new (1000, NULL, bus_new_ready, ticket_ref (ticket));
	g_main_context_pop_thread_default (ticket->owner);
#else
	ticket_complete (ticket, g_error_new_literal (G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
		"SSC requires libqmi QRTR support"));
#endif
	return G_SOURCE_REMOVE;
}

static gboolean
dispose_init_on_owner (gpointer data)
{
	ClientTicket *ticket = data;
	if (!ticket->done)
		ticket_complete (ticket, closed_error ());
	return G_SOURCE_REMOVE;
}

static gboolean
dispose_bundle_on_owner (gpointer data)
{
	bundle_begin_cleanup (data);
	return G_SOURCE_REMOVE;
}

static void
ssc_client_init (SSCClient *self)
{
	self->priv = ssc_client_get_instance_private (self);
	g_mutex_init (&self->priv->mutex);
	self->priv->owner = g_main_context_ref_thread_default ();
}

static void
client_detach (SSCClient *self, gboolean disposing)
{
	ClientBundle *bundle;
	ClientTicket *initialization;
	SscLifetimeNode *generation;
#if QMI_QRTR_SUPPORTED
	gboolean attach;
	SscLifetimeNode *report_parent = NULL;
#endif
	/* Safe handoff if a caller-context GTask releases the final self ref on a
	 * different thread. No transport call, user callback or self resurrection
	 * occurs under the mutex or from the detached cleanup operation.
	 */
	g_mutex_lock (&self->priv->mutex);
	if (disposing)
		self->priv->disposed = TRUE;
	self->priv->retired = TRUE;
	self->priv->ready = FALSE;
	bundle = g_steal_pointer (&self->priv->resources);
	initialization = g_steal_pointer (&self->priv->initialization);
	generation = g_steal_pointer (&self->priv->generation);
#if QMI_QRTR_SUPPORTED
	attach = report_schedule_locked (self->priv);
	if (attach) {
		/* A repeated detach may no longer own the generation, but existing
		 * queued work still supplies its own held ancestry. Never attach
		 * scoped drain work as an untracked post-seal root. */
		if (generation)
			report_parent = ssc_lifetime_node_ref (generation);
		else if (self->priv->report_head)
			report_parent = ssc_lifetime_node_ref (self->priv->report_head->node);
		else if (self->priv->report_failure_bundle)
			report_parent = ssc_lifetime_node_ref (self->priv->report_failure_bundle->node);
		g_assert (!self->priv->scope || report_parent);
	}
#endif
	g_mutex_unlock (&self->priv->mutex);
	if (bundle) {
		if (disposing)
			queue_owner (bundle->owner, bundle->node, G_PRIORITY_DEFAULT,
				dispose_bundle_on_owner, bundle, (GDestroyNotify) bundle_unref);
		else {
			bundle_begin_cleanup (bundle);
			bundle_unref (bundle);
		}
	}
	if (initialization) {
		if (disposing)
			queue_owner (initialization->owner, initialization->node, initialization->priority,
				dispose_init_on_owner, initialization, (GDestroyNotify) ticket_unref);
		else {
			dispose_init_on_owner (initialization);
			ticket_unref (initialization);
		}
	}
#if QMI_QRTR_SUPPORTED
	if (attach)
		report_attach (self, report_parent);
	ssc_lifetime_node_unref (report_parent);
#endif
	/* Descendant cleanup now owns its true work independently of self. */
	ssc_lifetime_node_unref (generation);
}

void
ssc_client_retire (SSCClient *self)
{
	g_return_if_fail (SSC_IS_CLIENT (self));
	g_return_if_fail (g_main_context_is_owner (self->priv->owner));
	client_detach (self, FALSE);
}

static void
ssc_client_dispose (GObject *object)
{
	client_detach (SSC_CLIENT (object), TRUE);
	G_OBJECT_CLASS (ssc_client_parent_class)->dispose (object);
}

static void
ssc_client_finalize (GObject *object)
{
	SSCClient *self = SSC_CLIENT (object);
	g_assert (self->priv->report_drain == REPORT_DRAIN_IDLE);
	g_assert (!self->priv->report_head && !self->priv->report_tail);
	g_assert (!self->priv->report_failure_bundle);
	g_assert (self->priv->report_stats.used_reports == 0);
	g_assert (self->priv->report_stats.used_raw_bytes == 0);
	g_assert (!self->priv->resources && !self->priv->initialization && !self->priv->generation);
	ssc_lifetime_unref (self->priv->scope);
	g_main_context_unref (self->priv->owner);
	g_mutex_clear (&self->priv->mutex);
	G_OBJECT_CLASS (ssc_client_parent_class)->finalize (object);
}

static void
initable_init_async (GAsyncInitable *initable, int io_priority, GCancellable *cancellable,
		     GAsyncReadyCallback callback, gpointer user_data)
{
	SSCClient *self = SSC_CLIENT (initable);
	ClientTicket *ticket = ticket_new (self, TICKET_INIT, cancellable, callback, user_data);
	ticket->priority = io_priority;
	g_task_set_source_tag (ticket->task, initable_init_async);
	g_task_set_priority (ticket->task, io_priority);
	if (!ticket->admitted || ssc_lifetime_is_sealed (self->priv->scope)) {
		ticket_reject (ticket);
		ticket_unref (ticket);
		return;
	}
	queue_owner (ticket->owner, ticket->node, io_priority, init_on_owner,
		ticket_ref (ticket), (GDestroyNotify) ticket_unref);
	ticket_unref (ticket);
}

static gboolean
initable_init_finish (GAsyncInitable *initable, GAsyncResult *result, GError **error)
{
	g_return_val_if_fail (g_task_is_valid (result, initable), FALSE);
	g_return_val_if_fail (g_task_get_source_tag (G_TASK (result)) == initable_init_async, FALSE);
	return g_task_propagate_boolean (G_TASK (result), error);
}

static void
async_initable_iface_init (GAsyncInitableIface *iface)
{
	iface->init_async = initable_init_async;
	iface->init_finish = initable_init_finish;
}

static void
ssc_client_class_init (SSCClientClass *klass)
{
	GObjectClass *object_class = G_OBJECT_CLASS (klass);
	object_class->dispose = ssc_client_dispose;
	object_class->finalize = ssc_client_finalize;
	signals[SIGNAL_REPORT] = g_signal_new ("report", G_TYPE_FROM_CLASS (klass),
		G_SIGNAL_RUN_FIRST, 0, NULL, NULL, NULL, G_TYPE_NONE,
		4, G_TYPE_UINT, G_TYPE_UINT64, G_TYPE_UINT64, G_TYPE_ARRAY);
	signals[SIGNAL_REPORT_FAILED] = g_signal_new ("report-failed", G_TYPE_FROM_CLASS (klass),
		G_SIGNAL_RUN_FIRST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, G_TYPE_ERROR);
	signals[SIGNAL_SENSOR_INITIALIZED] = g_signal_new ("sensor-initialized", G_TYPE_FROM_CLASS (klass),
		G_SIGNAL_RUN_FIRST, 0, NULL, NULL, NULL, G_TYPE_NONE, 1, SSC_TYPE_SENSOR);
	signals[SIGNAL_REPORT_FRAME] = g_signal_new ("report-frame", G_TYPE_FROM_CLASS (klass),
		G_SIGNAL_RUN_FIRST, 0, NULL, NULL, NULL, G_TYPE_NONE,
		5, G_TYPE_UINT, G_TYPE_UINT64, G_TYPE_UINT64, G_TYPE_UINT64, G_TYPE_ARRAY);
}

SSCClient *
ssc_client_new_finish (GAsyncResult *result, GError **error)
{
	GObject *source = g_async_result_get_source_object (result);
	GObject *client;
	if (!source || !SSC_IS_CLIENT (source)) {
		g_clear_object (&source);
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Invalid SSC construction result");
		return NULL;
	}
	client = g_async_initable_new_finish (G_ASYNC_INITABLE (source), result, error);
	g_object_unref (source);
	return client ? SSC_CLIENT (client) : NULL;
}

void
ssc_client_new (GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data)
{
	g_async_initable_new_async (SSC_TYPE_CLIENT, G_PRIORITY_DEFAULT,
		cancellable, callback, user_data, NULL);
}

static void
client_retire_target (GObject *object)
{
	ssc_client_retire (SSC_CLIENT (object));
}

void
ssc_client_new_scoped (SscLifetime *scope, SscLifetimeNode *parent,
		       GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data)
{
	SSCClient *self;
	if (!scope) {
		ssc_client_new (cancellable, callback, user_data);
		return;
	}
	self = g_object_new (SSC_TYPE_CLIENT, NULL);
	self->priv->scope = ssc_lifetime_ref (scope);
	self->priv->generation = ssc_lifetime_node_new (scope, parent, "client-generation");
	if (self->priv->generation)
		ssc_lifetime_node_set_target (self->priv->generation, G_OBJECT (self),
			client_retire_target);
	/* Same real GAsyncInitable task/source/tag as the legacy constructor;
	 * attach lifetime and weak target before init_async can queue work. */
	g_async_initable_init_async (G_ASYNC_INITABLE (self), G_PRIORITY_DEFAULT,
		cancellable, callback, user_data);
	g_object_unref (self);
}
