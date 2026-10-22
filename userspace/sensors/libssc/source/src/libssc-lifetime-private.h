/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Private ownership graph; not an installed ABI. */
#ifndef _LIBSSC_LIFETIME_PRIVATE_H_
#define _LIBSSC_LIFETIME_PRIVATE_H_

#include <gio/gio.h>
#include "libssc-sensor-retirement.h"

G_BEGIN_DECLS

typedef struct _SscLifetime SscLifetime;
typedef struct _SscLifetimeNode SscLifetimeNode;
typedef void (*SscLifetimeTargetFunc) (GObject *object);
typedef void (*SscLifetimeBeginFunc) (GObject *subject);

typedef enum {
	SSC_LIFETIME_ERROR_RELEASE,
	SSC_LIFETIME_ERROR_CLOSE
} SscLifetimeErrorStage;

SscLifetime *ssc_lifetime_new (GMainContext *owner);
SscLifetime *ssc_lifetime_ref (SscLifetime *scope);
void ssc_lifetime_unref (SscLifetime *scope);
gboolean ssc_lifetime_is_sealed (SscLifetime *scope);

/* NULL scope is the legacy untracked client mode. For a non-NULL scope,
 * parent==NULL atomically tries a new root and returns NULL after sealing.
 * A child requires an actually held live parent from this same scope. Register
 * before submission/attachment, and keep the parent until registration ends.
 * kind is an immutable static diagnostic string. No node owns a GObject.
 */
SscLifetimeNode *ssc_lifetime_node_new (SscLifetime *scope,
	SscLifetimeNode *parent, const gchar *kind);
SscLifetimeNode *ssc_lifetime_node_ref (SscLifetimeNode *node);
void ssc_lifetime_node_unref (SscLifetimeNode *node);
/* Borrowed only while caller holds node; NULL node returns NULL for legacy
 * mode. Do not retain this pointer after releasing that node. */
SscLifetime *ssc_lifetime_node_get_scope (SscLifetimeNode *node);

/* A privately created client's generation is live work until explicit retire
 * or dispose has handed its resources to registered children. This target is
 * weak; the owner coordinator promotes it safely outside the scope mutex.
 * Each target is called once on owner, including targets registered by a live
 * pre-seal parent after retirement was requested. Retire must be idempotent.
 * The object owner retains node until its actual handoff epilogue is complete.
 */
void ssc_lifetime_node_set_target (SscLifetimeNode *node, GObject *object,
	SscLifetimeTargetFunc retire);

/* First actual error per stage, bounded/copied. Never holds source objects.
 * Recording does not complete a node or turn a failed finish into success.
 */
void ssc_lifetime_record_error (SscLifetime *scope,
	SscLifetimeErrorStage stage, const GError *error);

/* Consumes task in every case. Caller created it with original subject/tag
 * and caller thread-default context. First request seals root admission before
 * attaching an independently rooted owner coordinator. begin runs once on
 * owner before weak targets are retired. The coordinator sleeps (no polling)
 * until actual work changes, then publishes a receipt on a later owner turn.
 * Scope borrows its guarded identity; it owns no waiter GTask backedge.
 * Duplicate pending requests get PENDING; terminal requests get cached copies.
 * No cancellation or timeout can synthesize a receipt.
 */
void ssc_lifetime_retire (SscLifetime *scope, GTask *task,
	SscLifetimeBeginFunc begin);

G_END_DECLS
#endif
