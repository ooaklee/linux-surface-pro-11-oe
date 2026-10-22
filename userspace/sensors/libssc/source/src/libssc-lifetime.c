/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Local libssc work retirement, independent of persistent GObject lifetimes. */
#include "libssc-lifetime-private.h"

#define SSC_CLEANUP_MESSAGE_MAX_BYTES 512

struct _SSCSensorRetirementReceipt {
	GError *release_error;
	GError *close_error;
};

G_DEFINE_BOXED_TYPE (SSCSensorRetirementReceipt, ssc_sensor_retirement_receipt,
	ssc_sensor_retirement_receipt_copy, ssc_sensor_retirement_receipt_free)

SSCSensorRetirementReceipt *
ssc_sensor_retirement_receipt_copy (const SSCSensorRetirementReceipt *receipt)
{
	SSCSensorRetirementReceipt *copy;
	g_return_val_if_fail (receipt != NULL, NULL);
	copy = g_new0 (SSCSensorRetirementReceipt, 1);
	if (receipt->release_error)
		copy->release_error = g_error_copy (receipt->release_error);
	if (receipt->close_error)
		copy->close_error = g_error_copy (receipt->close_error);
	return copy;
}

void
ssc_sensor_retirement_receipt_free (SSCSensorRetirementReceipt *receipt)
{
	if (!receipt)
		return;
	g_clear_error (&receipt->release_error);
	g_clear_error (&receipt->close_error);
	g_free (receipt);
}

gboolean
ssc_sensor_retirement_receipt_get_local_complete (
	const SSCSensorRetirementReceipt *receipt)
{
	g_return_val_if_fail (receipt != NULL, FALSE);
	return TRUE;
}

GError *
ssc_sensor_retirement_receipt_dup_release_error (
	const SSCSensorRetirementReceipt *receipt)
{
	g_return_val_if_fail (receipt != NULL, NULL);
	return receipt->release_error ? g_error_copy (receipt->release_error) : NULL;
}

GError *
ssc_sensor_retirement_receipt_dup_close_error (
	const SSCSensorRetirementReceipt *receipt)
{
	g_return_val_if_fail (receipt != NULL, NULL);
	return receipt->close_error ? g_error_copy (receipt->close_error) : NULL;
}

typedef struct _RetirementCoordinator RetirementCoordinator;

struct _SscLifetime {
	gint refs;
	GMutex mutex;
	GMainContext *owner;
	SscLifetimeNode *nodes; /* borrowed, protected through final node epilogue */
	gboolean sealed, terminal;
	RetirementCoordinator *coordinator; /* guarded borrow, never an owning task */
	SSCSensorRetirementReceipt *receipt;
	GError *release_error, *close_error;
};

struct _SscLifetimeNode {
	gint refs;
	SscLifetime *scope;
	SscLifetimeNode *next;
	const gchar *kind;
	gboolean finishing, target_invoked;
	GWeakRef target;
	SscLifetimeTargetFunc retire;
};

struct _RetirementCoordinator {
	GSource source;
	SscLifetime *scope;
	GTask *task;
	SscLifetimeBeginFunc begin;
	gboolean started;
};

SscLifetime *
ssc_lifetime_new (GMainContext *owner)
{
	SscLifetime *scope;
	g_return_val_if_fail (owner != NULL, NULL);
	scope = g_new0 (SscLifetime, 1);
	scope->refs = 1;
	g_mutex_init (&scope->mutex);
	scope->owner = g_main_context_ref (owner);
	return scope;
}

SscLifetime *
ssc_lifetime_ref (SscLifetime *scope)
{
	if (scope)
		g_atomic_int_inc (&scope->refs);
	return scope;
}

void
ssc_lifetime_unref (SscLifetime *scope)
{
	if (!scope || !g_atomic_int_dec_and_test (&scope->refs))
		return;
	g_assert (!scope->nodes && !scope->coordinator);
	g_clear_pointer (&scope->receipt, ssc_sensor_retirement_receipt_free);
	g_clear_error (&scope->release_error);
	g_clear_error (&scope->close_error);
	g_main_context_unref (scope->owner);
	g_mutex_clear (&scope->mutex);
	g_free (scope);
}

gboolean
ssc_lifetime_is_sealed (SscLifetime *scope)
{
	gboolean sealed;
	if (!scope)
		return FALSE;
	g_mutex_lock (&scope->mutex);
	sealed = scope->sealed;
	g_mutex_unlock (&scope->mutex);
	return sealed;
}

SscLifetimeNode *
ssc_lifetime_node_new (SscLifetime *scope, SscLifetimeNode *parent,
	const gchar *kind)
{
	SscLifetimeNode *node;
	if (!scope)
		return NULL;
	g_return_val_if_fail (kind != NULL, NULL);
	node = g_new0 (SscLifetimeNode, 1);
	node->refs = 1;
	node->scope = ssc_lifetime_ref (scope);
	node->kind = kind;
	g_weak_ref_init (&node->target, NULL);
	g_mutex_lock (&scope->mutex);
	if (parent) {
		/* Caller owns a real parent reference. Membership is not inferred
		 * from an operation's current pointer or a diagnostic counter. */
		g_assert (parent->scope == scope && !parent->finishing);
		g_assert (g_atomic_int_get (&parent->refs) > 0);
		g_assert (!scope->terminal);
	} else if (scope->sealed) {
		g_mutex_unlock (&scope->mutex);
		g_weak_ref_clear (&node->target);
		ssc_lifetime_unref (node->scope);
		g_free (node);
		return NULL;
	}
	node->next = scope->nodes;
	scope->nodes = node;
	g_mutex_unlock (&scope->mutex);
	return node;
}

SscLifetimeNode *
ssc_lifetime_node_ref (SscLifetimeNode *node)
{
	if (node) {
		/* Promotions from the scope's borrowed list also hold scope->mutex;
		 * ordinary callers already own a reference to the containing work. */
		g_assert (g_atomic_int_get (&node->refs) > 0);
		g_atomic_int_inc (&node->refs);
	}
	return node;
}

void
ssc_lifetime_node_unref (SscLifetimeNode *node)
{
	SscLifetime *scope;
	SscLifetimeNode **link;
	if (!node)
		return;
	scope = node->scope;
	/* Serialize the last decrement with weak-target snapshot promotion. */
	g_mutex_lock (&scope->mutex);
	if (!g_atomic_int_dec_and_test (&node->refs)) {
		g_mutex_unlock (&scope->mutex);
		return;
	}
	node->finishing = TRUE;
	g_mutex_unlock (&scope->mutex);
	/* No strong target reference or user destructor is hidden in this node.
	 * Keep it a member until its weak registration has really been released. */
	g_weak_ref_clear (&node->target);
	g_mutex_lock (&scope->mutex);
	for (link = &scope->nodes; *link && *link != node; link = &(*link)->next)
		;
	g_assert (*link == node);
	*link = node->next;
	g_mutex_unlock (&scope->mutex);
	g_free (node);
	/* Wake outside the scope mutex: source prepare/check acquire it from
	 * the main context. No scope->context/context->scope lock inversion. */
	g_main_context_wakeup (scope->owner);
	ssc_lifetime_unref (scope);
}

SscLifetime *
ssc_lifetime_node_get_scope (SscLifetimeNode *node)
{
	return node ? node->scope : NULL;
}

void
ssc_lifetime_node_set_target (SscLifetimeNode *node, GObject *object,
	SscLifetimeTargetFunc retire)
{
	SscLifetime *scope;
	if (!node)
		return;
	g_return_if_fail (G_IS_OBJECT (object) && retire != NULL);
	scope = node->scope;
	/* The caller holds the node throughout publication. Prior to publication
	 * it already blocks terminal eligibility, including after the seal. */
	g_weak_ref_set (&node->target, object);
	g_mutex_lock (&scope->mutex);
	g_assert (!node->finishing && !node->retire);
	node->retire = retire;
	g_mutex_unlock (&scope->mutex);
	g_main_context_wakeup (scope->owner);
}

static GError *
copy_bounded_error (const GError *error)
{
	gchar *message = g_strndup (error->message, SSC_CLEANUP_MESSAGE_MAX_BYTES);
	const gchar *invalid;
	GError *copy;
	/* A truncated UTF-8 sequence must not become an invalid binding string.
	 * Keep the valid bounded prefix, retaining the original domain/code. */
	if (!g_utf8_validate (message, -1, &invalid))
		message[invalid - message] = '\0';
	copy = g_error_new_literal (error->domain, error->code,
		*message ? message : "Backend cleanup failed (diagnostic unavailable)");
	g_free (message);
	return copy;
}

void
ssc_lifetime_record_error (SscLifetime *scope, SscLifetimeErrorStage stage,
	const GError *error)
{
	GError *copy, **slot;
	if (!scope || !error)
		return;
	g_return_if_fail (stage == SSC_LIFETIME_ERROR_RELEASE ||
		stage == SSC_LIFETIME_ERROR_CLOSE);
	copy = copy_bounded_error (error);
	g_mutex_lock (&scope->mutex);
	g_assert (!scope->terminal);
	slot = stage == SSC_LIFETIME_ERROR_RELEASE ?
		&scope->release_error : &scope->close_error;
	if (!*slot)
		*slot = g_steal_pointer (&copy);
	g_mutex_unlock (&scope->mutex);
	g_clear_error (&copy);
}

static gboolean
coordinator_ready_locked (RetirementCoordinator *coordinator)
{
	SscLifetime *scope = coordinator->scope;
	if (!coordinator->started || !scope->nodes)
		return TRUE;
	for (SscLifetimeNode *node = scope->nodes; node; node = node->next)
		if (!node->finishing && node->retire && !node->target_invoked)
			return TRUE;
	return FALSE;
}

static gboolean
coordinator_prepare (GSource *source, gint *timeout)
{
	RetirementCoordinator *coordinator = (RetirementCoordinator *) source;
	gboolean ready;
	*timeout = -1;
	g_mutex_lock (&coordinator->scope->mutex);
	ready = coordinator_ready_locked (coordinator);
	g_mutex_unlock (&coordinator->scope->mutex);
	return ready;
}

static gboolean
coordinator_check (GSource *source)
{
	gint timeout;
	return coordinator_prepare (source, &timeout);
}

static GPtrArray *
coordinator_targets (RetirementCoordinator *coordinator)
{
	SscLifetime *scope = coordinator->scope;
	GPtrArray *targets = g_ptr_array_new_with_free_func (
		(GDestroyNotify) ssc_lifetime_node_unref);
	g_mutex_lock (&scope->mutex);
	for (SscLifetimeNode *node = scope->nodes; node; node = node->next) {
		if (!node->finishing && node->retire && !node->target_invoked) {
			node->target_invoked = TRUE;
			g_ptr_array_add (targets, ssc_lifetime_node_ref (node));
		}
	}
	g_mutex_unlock (&scope->mutex);
	return targets;
}

static gboolean
coordinator_dispatch (GSource *source, GSourceFunc callback, gpointer data)
{
	RetirementCoordinator *coordinator = (RetirementCoordinator *) source;
	SscLifetime *scope = coordinator->scope;
	GPtrArray *targets;
	gboolean first;
	GTask *task;
	SSCSensorRetirementReceipt *receipt;
	(void) callback;
	(void) data;
	g_assert (g_main_context_is_owner (scope->owner));
	g_mutex_lock (&scope->mutex);
	g_assert (scope->coordinator == coordinator && scope->sealed && !scope->terminal);
	first = !coordinator->started;
	coordinator->started = TRUE;
	g_mutex_unlock (&scope->mutex);
	if (first)
		coordinator->begin (g_task_get_source_object (coordinator->task));
	targets = coordinator_targets (coordinator);
	for (guint i = 0; i < targets->len; i++) {
		SscLifetimeNode *node = g_ptr_array_index (targets, i);
		GObject *object = g_weak_ref_get (&node->target);
		if (object) {
			node->retire (object);
			g_object_unref (object);
		}
		/* No object means its dispose handoff already owns registered work;
		 * it is not permission to erase any ticket or bundle member. */
	}
	if (first || targets->len) {
		g_ptr_array_unref (targets);
		/* Even an empty start completes only on a later owner dispatch,
		 * after start/target calls and all their current epilogues return. */
		return G_SOURCE_CONTINUE;
	}
	g_ptr_array_unref (targets);
	g_mutex_lock (&scope->mutex);
	if (scope->nodes) {
		g_mutex_unlock (&scope->mutex);
		return G_SOURCE_CONTINUE;
	}
	scope->receipt = g_new0 (SSCSensorRetirementReceipt, 1);
	if (scope->release_error)
		scope->receipt->release_error = g_error_copy (scope->release_error);
	if (scope->close_error)
		scope->receipt->close_error = g_error_copy (scope->close_error);
	scope->terminal = TRUE;
	scope->coordinator = NULL;
	receipt = ssc_sensor_retirement_receipt_copy (scope->receipt);
	task = g_steal_pointer (&coordinator->task);
	g_mutex_unlock (&scope->mutex);
	/* Clear the guarded borrow before task return/callback/final source unref.
	 * No scope lock spans user callbacks or object destruction. */
	g_task_return_pointer (task, receipt,
		(GDestroyNotify) ssc_sensor_retirement_receipt_free);
	g_object_unref (task);
	return G_SOURCE_REMOVE;
}

static void
coordinator_finalize (GSource *source)
{
	RetirementCoordinator *coordinator = (RetirementCoordinator *) source;
	g_assert (!coordinator->task);
	ssc_lifetime_unref (coordinator->scope);
}

static GSourceFuncs coordinator_funcs = {
	.prepare = coordinator_prepare,
	.check = coordinator_check,
	.dispatch = coordinator_dispatch,
	.finalize = coordinator_finalize
};

void
ssc_lifetime_retire (SscLifetime *scope, GTask *task, SscLifetimeBeginFunc begin)
{
	RetirementCoordinator *coordinator;
	SSCSensorRetirementReceipt *cached = NULL;
	gboolean pending;
	g_return_if_fail (scope != NULL && G_IS_TASK (task) && begin != NULL);
	/* Never let a later cancellation replace the selected terminal value. */
	g_task_set_check_cancellable (task, FALSE);
	g_mutex_lock (&scope->mutex);
	pending = scope->sealed && !scope->terminal;
	if (scope->terminal)
		cached = ssc_sensor_retirement_receipt_copy (scope->receipt);
	if (pending || cached) {
		g_mutex_unlock (&scope->mutex);
		if (cached)
			g_task_return_pointer (task, cached,
				(GDestroyNotify) ssc_sensor_retirement_receipt_free);
		else
			g_task_return_new_error (task, G_IO_ERROR, G_IO_ERROR_PENDING,
				"Sensor retirement is already pending; no receipt for this request");
		g_object_unref (task);
		return;
	}
	coordinator = (RetirementCoordinator *) g_source_new (&coordinator_funcs,
		sizeof (RetirementCoordinator));
	coordinator->scope = ssc_lifetime_ref (scope);
	coordinator->task = task; /* consumed, independently rooted by owner source */
	coordinator->begin = begin;
	scope->sealed = TRUE;
	scope->coordinator = coordinator;
	g_mutex_unlock (&scope->mutex);
	g_source_set_priority ((GSource *) coordinator, G_PRIORITY_DEFAULT);
	g_source_set_can_recurse ((GSource *) coordinator, FALSE);
	/* Custom prepare/check return FALSE while pending work has no new target.
	 * There is no always-ready idle or grace timer. Actual node transitions
	 * wake owner, so dormant completion cannot spin or lose a last-node wake. */
	g_source_attach ((GSource *) coordinator, scope->owner);
	g_source_unref ((GSource *) coordinator);
}
