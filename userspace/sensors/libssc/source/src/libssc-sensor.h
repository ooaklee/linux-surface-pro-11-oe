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

#ifndef _LIBSSC_SENSOR_H_
#define _LIBSSC_SENSOR_H_

#include <glib.h>
#include <gio/gio.h>
#include "libssc-sensor-retirement.h"
#include "libssc-sensor-sample.h"

G_BEGIN_DECLS

typedef struct _SSCSensor SSCSensor;
typedef struct _SSCClient SSCClient;

#define SSC_TYPE_SENSOR (ssc_sensor_get_type())

G_DECLARE_DERIVABLE_TYPE (SSCSensor, ssc_sensor, SSC, SENSOR, GObject);

typedef enum {
	SSC_SENSOR_ERROR_UNAVAILABLE,
	SSC_SENSOR_ERROR_SAMPLE_RATE_UNAVAILABLE,
	SSC_SENSOR_ERROR_NO_SERVICE,
} SSCSensorError;

GQuark ssc_sensor_error_quark(void);

#define SSC_SENSOR_UID_LOW "uid-low"
#define SSC_SENSOR_UID_HIGH "uid-high"
/* Construct-only, FALSE by default. When TRUE, INIT verifies the supplied
 * full-width UID pair belongs to data-type, rather than selecting its default.
 * Neither a UID value nor list ordering identifies a physical board position.
 * Since: 0.4.6
 */
#define SSC_SENSOR_SELECTION_ENABLED "selection-enabled"
#define SSC_SENSOR_NAME "name"
#define SSC_SENSOR_VENDOR "vendor"
#define SSC_SENSOR_DATA_TYPE "data-type"
#define SSC_SENSOR_STREAM_TYPE "stream-type"
#define SSC_SENSOR_AVAILABLE "available"
#define SSC_SENSOR_SAMPLE_RATE "sample-rate"
#define SSC_SENSOR_CLIENT "client"
#define SSC_SENSOR_MOUNT_MATRIX "mount-matrix"

void		 ssc_sensor_new (gchar *data_type, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data);
SSCSensor 	*ssc_sensor_new_finish (GAsyncResult *result, GError **error);
void		 ssc_sensor_open (SSCSensor *self, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data);
gboolean	 ssc_sensor_open_finish (SSCSensor *self, GAsyncResult *result, GError **error);
void		 ssc_sensor_close (SSCSensor *self, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data);
gboolean	 ssc_sensor_close_finish (SSCSensor *self, GAsyncResult *result, GError **error);

/* Since 0.4.7 the inherited "sample" signal provides a borrowed immutable
 * SSCSensorSample after the existing typed "measurement" signal. Retaining
 * consumers copy it. Legacy callbacks that invalidate the current stream or
 * queue a fault can suppress its companion sample. This is a semantic stream:
 * proximity repeats are deduplicated, acceleration is mount-transformed and
 * compass values are derived headings. Epoch/sequence are local bookkeeping,
 * not DSP correlation; raw ticks remain clock-unqualified. No class slot was
 * added and existing signal signatures and class layout remain unchanged. */

/**
 * SSCSensorUidList:
 *
 * Immutable owned sensor UID pairs from one matching data-type report. Values
 * are sorted by unsigned high, then unsigned low, with duplicates removed.
 * This inventory does not identify board roles or establish sensor readiness.
 *
 * Since: 0.4.6
 */
typedef struct _SSCSensorUidList SSCSensorUidList;

#define SSC_TYPE_SENSOR_UID_LIST (ssc_sensor_uid_list_get_type ())
GType ssc_sensor_uid_list_get_type (void) G_GNUC_CONST;

/**
 * ssc_sensor_uid_list_copy:
 * @list: an immutable UID list
 *
 * Returns: (transfer full): an independent immutable copy
 * Since: 0.4.6
 */
SSCSensorUidList *ssc_sensor_uid_list_copy (const SSCSensorUidList *list);

/**
 * ssc_sensor_uid_list_free:
 * @list: (nullable) (transfer full): a list to release
 *
 * Since: 0.4.6
 */
void ssc_sensor_uid_list_free (SSCSensorUidList *list);

/**
 * ssc_sensor_uid_list_get_length:
 * @list: an immutable UID list
 *
 * Returns: the number of unique UID pairs, including zero for an empty list
 * Since: 0.4.6
 */
gsize ssc_sensor_uid_list_get_length (const SSCSensorUidList *list);

/**
 * ssc_sensor_uid_list_get_uid:
 * @list: an immutable UID list
 * @index: zero-based index
 * @high: (out) (optional): location for the high 64 bits
 * @low: (out) (optional): location for the low 64 bits
 *
 * Copy one pair by value. Out-of-range indices leave outputs unchanged. All
 * unsigned 64-bit values, including zero, are represented without conversion.
 *
 * Returns: %TRUE if the index exists, otherwise %FALSE
 * Since: 0.4.6
 */
gboolean ssc_sensor_uid_list_get_uid (const SSCSensorUidList *list, gsize index,
				     guint64 *high, guint64 *low);

G_DEFINE_AUTOPTR_CLEANUP_FUNC (SSCSensorUidList, ssc_sensor_uid_list_free)

/**
 * ssc_sensor_discover_async:
 * @self: an exact base SSCSensor constructed without asynchronous INIT
 * @cancellable: (nullable): optional operation cancellation
 * @callback: (scope async) (nullable): completion callback
 * @user_data: (closure callback): data for @callback
 *
 * Discover all UIDs for the nonempty data-type construction property. Initially
 * supports only a bare, uninitialized exact base sensor which has never had an
 * external client and has no installed decoder. Concurrent operations receive
 * PENDING; unsupported subjects receive NOT_SUPPORTED without starting a client.
 *
 * Uses a fresh native client, the unchanged registry readiness phase and an
 * all-instance SUID request with updates disabled. No attributes, INIT commit,
 * OPEN, stream or CLOSE are fabricated. More than 256 wire UID pairs, counted
 * before deduplication, fails with G_IO_ERROR_NO_SPACE rather than truncating.
 * An empty matching report succeeds with an empty list. The old constructors
 * remain default-only; explicit selected INIT uses selection-enabled together
 * with uid-high and uid-low and fails NOT_FOUND if that pair is absent.
 *
 * The callback runs on this call's thread-default context; work stays on the
 * fixed construction owner. A logical result is not backend quiescence. Keep
 * the owner dispatching through genuine ssc_sensor_retire_async() completion to
 * join accepted local work and preserve actual release/device-close errors.
 * No physical DSP shutdown, calibration or board-role guarantee is made.
 *
 * Since: 0.4.6
 */
void ssc_sensor_discover_async (SSCSensor *self, GCancellable *cancellable,
			       GAsyncReadyCallback callback, gpointer user_data);

/**
 * ssc_sensor_discover_finish:
 * @self: the original discovery subject
 * @result: the original discovery result
 * @error: return location for an operation or invalid-result error
 *
 * Wrong source/tag validation does not consume a genuine result. Empty success
 * is a non-NULL list of length zero, not NULL. This finish does not replace the
 * separate terminal local retirement receipt.
 *
 * Returns: (transfer full) (nullable): the immutable UID list, or NULL on error
 * Since: 0.4.6
 */
SSCSensorUidList *ssc_sensor_discover_finish (SSCSensor *self,
	GAsyncResult *result, GError **error);

/**
 * ssc_sensor_retire_async:
 * @self: a supported sensor with exclusively owned native libssc clients
 * @callback: (scope async) (nullable): completion callback
 * @user_data: (closure callback): data for @callback
 *
 * Terminally seal and retire this sensor's accepted local backend work. This
 * is not reusable CLOSE and does not implicitly enable or retry a disable.
 * Keep the fixed construction owner dispatching through the receipt; the
 * callback runs on this call's thread-default context. Coordinate earlier
 * application-owned logical callbacks separately before stopping their
 * contexts. There is no cancellation or time-based completion guarantee.
 *
 * Initially supports only the exact base and six in-tree sensor types that
 * never received a non-NULL external client property. Unsupported instances
 * are rejected without a receipt or cleanup side effects; rejection does not
 * retire their already accepted work. Concurrent repeats receive PENDING;
 * terminal repeats receive independent cached receipts. A NULL callback still
 * permits background local retirement; a later call can obtain its receipt.
 * Admission errors use G_IO_ERROR: NOT_SUPPORTED for excluded instances and
 * PENDING for a concurrent request. Neither error certifies local retirement.
 *
 * Since: 0.4.5
 */
void ssc_sensor_retire_async (SSCSensor *self, GAsyncReadyCallback callback,
			      gpointer user_data);

/**
 * ssc_sensor_retire_finish:
 * @self: the original sensor
 * @result: the original retirement result
 * @error: return location for an admission or invalid-result error
 *
 * Release/close failures are copied values inside a terminal receipt, not
 * errors on this result channel. NULL plus error is NOT permission to stop
 * dispatching. Wrong source/tag validation does not consume a genuine result.
 * A receipt joins libssc-owned work and consumed provider finishes, not all
 * provider internals, arbitrary user callbacks or physical DSP activity.
 *
 * Returns: (transfer full) (nullable): terminal local receipt, or NULL on rejection
 * Since: 0.4.5
 */
SSCSensorRetirementReceipt *ssc_sensor_retire_finish (SSCSensor *self,
	GAsyncResult *result, GError **error);

struct _SSCSensorClass {
	GObjectClass parent_class;

	void (*open) (SSCSensor *self, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data);
	gboolean (*open_finish) (SSCSensor *self, GAsyncResult *result, GError **error);
	void (*close) (SSCSensor *self, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data);
	gboolean (*close_finish) (SSCSensor *self, GAsyncResult *result, GError **error);
};

G_END_DECLS

#endif /* _LIBSSC_SENSOR_H_ */
