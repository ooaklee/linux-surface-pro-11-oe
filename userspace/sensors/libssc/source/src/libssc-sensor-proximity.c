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

#include <math.h>
#include "libssc-common-private.h"
#include "libssc-sensor-private.h"
#include "ssc-sensor-proximity.pb-c.h"
#include "libssc-sensor-proximity.h"

enum {
	SIGNAL_MEASUREMENT,
	N_SIGNALS
};
static guint signals[N_SIGNALS];

G_DEFINE_TYPE (SSCSensorProximity, ssc_sensor_proximity, SSC_TYPE_SENSOR)

static gboolean
decode_measurement (const SscMeasurementSnapshot *snapshot, guint32 message_id,
		    const guint8 *bytes, gsize length, ProtobufCAllocator *allocator,
		    SscMeasurementFrame *frame, GError **error)
{
	SscProximityResponse *msg;
	gboolean valid = FALSE;

	(void) snapshot;
	/* Matching 1025 is recognized, but no current profile qualifies its
	 * alternate format. Never guess a native struct or Xiaomi dialect. */
	if (message_id == SSC_MSG_REPORT_MEASUREMENT) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED,
			"The alternate proximity measurement format is not qualified");
		return FALSE;
	}
	if (message_id != SSC_MSG_REPORT_MEASUREMENT_PROXIMITY) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Unexpected proximity measurement message");
		return FALSE;
	}
	msg = ssc_proximity_response__unpack (allocator, length, bytes);
	if (!msg) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Failed to unpack proximity measurement");
		return FALSE;
	}
	if (msg->near != 0 && msg->near != 1) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Proximity near value must be zero or one");
		goto out;
	}
	frame->kind = SSC_MEASUREMENT_PROXIMITY;
	frame->accuracy = msg->accuracy;
	frame->value.near = msg->near == 1;
	valid = TRUE;
out:
	ssc_proximity_response__free_unpacked (msg, allocator);
	return valid;
}

static void
emit_measurement (SSCSensor *self, const SscMeasurementFrame *frame)
{
	g_signal_emit (self, signals[SIGNAL_MEASUREMENT], 0, frame->value.near);
}

static const guint32 measurement_ids[] = {
	SSC_MSG_REPORT_MEASUREMENT_PROXIMITY, SSC_MSG_REPORT_MEASUREMENT
};

static const SscSensorDecoder decoder = {
	.kind = SSC_MEASUREMENT_PROXIMITY,
	.data_type = "proximity",
	.message_ids = measurement_ids,
	.n_message_ids = G_N_ELEMENTS (measurement_ids),
	.decode = decode_measurement,
	.emit_legacy = emit_measurement,
};

gboolean
ssc_sensor_proximity_close_finish (SSCSensorProximity *self, GAsyncResult *result, GError **error)
{
	if (!SSC_IS_SENSOR_PROXIMITY (self)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Expected a proximity sensor");
		return FALSE;
	}
	return ssc_sensor_close_finish (SSC_SENSOR (self), result, error);
}

void
ssc_sensor_proximity_close (SSCSensorProximity *self, GCancellable *cancellable,
			GAsyncReadyCallback callback, gpointer user_data)
{
	g_return_if_fail (SSC_IS_SENSOR_PROXIMITY (self));
	ssc_sensor_close (SSC_SENSOR (self), cancellable, callback, user_data);
}

gboolean
ssc_sensor_proximity_close_sync (SSCSensorProximity *self, GCancellable *cancellable, GError **error)
{
	gboolean success = FALSE;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_proximity_close (self, cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	success = ssc_sensor_proximity_close_finish (self, ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return success;
}

gboolean
ssc_sensor_proximity_open_finish (SSCSensorProximity *self, GAsyncResult *result, GError **error)
{
	if (!SSC_IS_SENSOR_PROXIMITY (self)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Expected a proximity sensor");
		return FALSE;
	}
	return ssc_sensor_open_finish (SSC_SENSOR (self), result, error);
}

void
ssc_sensor_proximity_open (SSCSensorProximity *self, GCancellable *cancellable,
			GAsyncReadyCallback callback, gpointer user_data)
{
	g_return_if_fail (SSC_IS_SENSOR_PROXIMITY (self));
	ssc_sensor_open (SSC_SENSOR (self), cancellable, callback, user_data);
}

gboolean
ssc_sensor_proximity_open_sync (SSCSensorProximity *self, GCancellable *cancellable, GError **error)
{
	gboolean success = FALSE;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_proximity_open (self, cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	success = ssc_sensor_proximity_open_finish (self, ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return success;
}

static void
ssc_sensor_proximity_class_init (SSCSensorProximityClass *klass)
{
	signals[SIGNAL_MEASUREMENT] = g_signal_new ("measurement",
		G_TYPE_FROM_CLASS (klass),
		G_SIGNAL_RUN_FIRST,
		0, NULL, NULL, NULL,
		G_TYPE_NONE,
		1, G_TYPE_BOOLEAN);
}

static void
ssc_sensor_proximity_init (SSCSensorProximity *self)
{
	ssc_sensor_install_decoder (SSC_SENSOR (self), &decoder);
}

SSCSensorProximity *
ssc_sensor_proximity_new_finish (GAsyncResult *result, GError **error)
{
	SSCSensor *sensor = ssc_sensor_new_typed_finish (result, SSC_TYPE_SENSOR_PROXIMITY, error);
	return sensor ? SSC_SENSOR_PROXIMITY (sensor) : NULL;
}

void
ssc_sensor_proximity_new (GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data)
{
	g_async_initable_new_async (
			SSC_TYPE_SENSOR_PROXIMITY,
			G_PRIORITY_DEFAULT,
			cancellable,
			callback,
			user_data,
			SSC_SENSOR_DATA_TYPE, "proximity",
			NULL);
}

SSCSensorProximity *
ssc_sensor_proximity_new_sync (GCancellable *cancellable, GError **error)
{
	SSCSensorProximity *self = NULL;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_proximity_new (cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	self = ssc_sensor_proximity_new_finish (ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return self;
}
