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

#ifndef _LIBSSC_CLIENT_H_
#define _LIBSSC_CLIENT_H_

#include <glib.h>
#include <glib/gstdio.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <gio/gio.h>
#include <libqmi-glib.h>
#include <stdbool.h>
#include "libssc-common-private.h"
#include "libssc-sensor.h"
#include "libssc-lifetime-private.h"
#include "ssc-common.pb-c.h"

G_BEGIN_DECLS

typedef struct _SSCClient SSCClient;
typedef struct _SSCSensor SSCSensor;

#define SSC_TYPE_CLIENT (ssc_client_get_type())

G_DECLARE_FINAL_TYPE (SSCClient, ssc_client, SSC, CLIENT, GObject);

typedef enum {
	SSC_CLIENT_ERROR_PROTOBUF,
	SSC_CLIENT_ERROR_LOOKUP,
	SSC_CLIENT_ERROR_REPORT_OVERFLOW,
	SSC_CLIENT_ERROR_REPORT_INVALID,
} SSCClientError;

/* Finite software resource policy; these are not hardware burst limits. */
#define SSC_CLIENT_REPORT_MAX_COUNT 64
#define SSC_CLIENT_REPORT_MAX_BYTES ((gsize) 1024 * 1024)
#define SSC_CLIENT_REPORT_MAX_WIRE_BYTES ((gsize) G_MAXUINT16)
#define SSC_CLIENT_REPORT_BODY_QUANTUM 16
#define SSC_CLIENT_REPORT_DECODE_MAX_BYTES ((gsize) 4 * 1024 * 1024)

typedef enum {
	SSC_CLIENT_REPORT_FAILURE_NONE,
	SSC_CLIENT_REPORT_FAILURE_COUNT,
	SSC_CLIENT_REPORT_FAILURE_BYTES,
	SSC_CLIENT_REPORT_FAILURE_WIRE,
	SSC_CLIENT_REPORT_FAILURE_DATA,
	SSC_CLIENT_REPORT_FAILURE_DECODE,
	SSC_CLIENT_REPORT_FAILURE_DECODE_BUDGET,
	SSC_CLIENT_REPORT_FAILURE_SEQUENCE,
} SSCClientReportFailure;

typedef struct {
	guint used_reports;
	gsize used_raw_bytes;
	guint high_water_reports;
	gsize high_water_raw_bytes;
	guint64 reports_admitted;
	guint64 reports_retired;
	guint64 reports_invalidated;
	guint64 bodies_published;
	guint64 rejected_reports;
	guint64 stale_reports;
	guint64 failure_notifications;
	gboolean failed;
	SSCClientReportFailure failure_reason;
	gsize first_failure_length;
	guint first_failure_reports;
	gsize first_failure_raw_bytes;
} SSCClientReportStats;

#define SSC_PROCESSOR_APSS		1
#define SSC_SUSPEND_MODE_WAKEUP		0
#define SSC_SENSOR_TYPE_SUID		"suid"
#define SSC_SENSOR_UID_SUID_LOW		0xABABABABABABABABUL
#define SSC_SENSOR_UID_SUID_HIGH	0xABABABABABABABABUL
#define SSC_MSG_REQUEST_SUID		512
#define SSC_MSG_RESPONSE_SUID		768

/*
 * Private async client contract: the construction thread-default main context
 * owns backend acquisition, control, indication dispatch and cleanup. Entries
 * enqueue there, while each result GTask preserves its caller's context.
 * The publication mutex permits dispose/final-unref to detach resources on a
 * different thread; detached cleanup never resurrects or needs SSCClient.
 * Caller cancellation only queues an owner event. All owning contexts must
 * continue to dispatch until their outstanding backend callbacks are consumed.
 * Logical cancellation is not physical transport/DSP quiescence. No synchronous
 * common helper or installed sensor class layout is changed by this contract.
 */

void
ssc_client_new (GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data);

/* Bind the sensor's actual lifetime before any client INIT source is attached.
 * parent remains held through this call. NULL scope is legacy standalone mode.
 * The returned async result remains the genuine GAsyncInitable client task.
 */
void
ssc_client_new_scoped (SscLifetime *scope, SscLifetimeNode *parent,
	GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data);

/* Fixed-owner-only, idempotent: actively hand owned resources to real cleanup
 * while caller/task references remain. This is not GObject run_dispose.
 */
void ssc_client_retire (SSCClient *self);

SSCClient *
ssc_client_new_finish (GAsyncResult *res, GError **error);

void
ssc_client_send (SSCClient *self, guint64 uid_high, guint64 uid_low, guint32 message_id, GArray *protobuf, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data); 

gboolean
ssc_client_send_finish (SSCClient *self, GAsyncResult *res, GError **error);

/* First terminal report error, copied under the publication lock. NULL before
 * failure. The owner emits report-failed(GError*) once; its argument is borrowed.
 * Subscribe then query before starting a report-dependent transaction. */
GError *
ssc_client_dup_report_error (SSCClient *self);

void
ssc_client_get_report_stats (SSCClient *self, SSCClientReportStats *stats);

/* Private report-frame(uint32 message_id, uint64 uid_high, uint64 uid_low,
 * uint64 raw_timestamp, GArray *payload) is emitted first for each authorized
 * body on the fixed owner context. Timestamp units/clock remain unqualified.
 * The unchanged report signal follows only if the actual client is still
 * authorized after private callbacks. One signal invocation already authorized
 * may unwind; this is not atomic delivery across channels or their handlers.
 * Both channels borrow the same read-only array. Retaining consumers must ref
 * it and keep it immutable, or copy it. One body quantum/counter increment is
 * charged after fanout unwinds, including private-only publication; counters
 * do not prove that a consumer received or accepted a physical measurement.
 * Observers must filter full UID/message identity before decoding. This is a
 * private userspace contract, not a stable external ABI or caller authentication.
 */

SSCSensor *
ssc_client_get_sensor_by_data_type (SSCClient *self, gchar *data_type);

G_END_DECLS

#endif /* _LIBSSC_CLIENT_H_ */
