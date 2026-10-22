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
#include "ssc-sensor-light.pb-c.h"
#include "libssc-sensor-light.h"

enum {
	SIGNAL_MEASUREMENT,
	N_SIGNALS
};
static guint signals[N_SIGNALS];

G_DEFINE_TYPE (SSCSensorLight, ssc_sensor_light, SSC_TYPE_SENSOR)

static gboolean
decode_measurement (const SscMeasurementSnapshot *snapshot, guint32 message_id,
		    const guint8 *bytes, gsize length, ProtobufCAllocator *allocator,
		    SscMeasurementFrame *frame, GError **error)
{
	SscLightResponse *msg;
	gboolean valid = FALSE;

	(void) snapshot;
	if (message_id != SSC_MSG_REPORT_MEASUREMENT) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Unexpected light measurement message");
		return FALSE;
	}
	msg = ssc_light_response__unpack (allocator, length, bytes);
	if (!msg) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Failed to unpack light measurement");
		return FALSE;
	}
	/* Consume the first intensity only, preserving the existing convention. */
	if (msg->n_intensity < 1 || !msg->intensity ||
	    !isfinite (msg->intensity[0]) || msg->intensity[0] < 0.0f) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Invalid nonnegative finite light intensity");
		goto out;
	}
	frame->kind = SSC_MEASUREMENT_LIGHT;
	frame->accuracy = msg->accuracy;
	frame->value.scalar = msg->intensity[0];
	valid = TRUE;
out:
	ssc_light_response__free_unpacked (msg, allocator);
	return valid;
}

static void
emit_measurement (SSCSensor *self, const SscMeasurementFrame *frame)
{
	g_signal_emit (self, signals[SIGNAL_MEASUREMENT], 0, frame->value.scalar);
}

static const guint32 measurement_ids[] = { SSC_MSG_REPORT_MEASUREMENT };

static const SscSensorDecoder decoder = {
	.kind = SSC_MEASUREMENT_LIGHT,
	.data_type = "ambient_light",
	.message_ids = measurement_ids,
	.n_message_ids = G_N_ELEMENTS (measurement_ids),
	.decode = decode_measurement,
	.emit_legacy = emit_measurement,
};

gboolean
ssc_sensor_light_close_finish (SSCSensorLight *self, GAsyncResult *result, GError **error)
{
	if (!SSC_IS_SENSOR_LIGHT (self)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Expected a light sensor");
		return FALSE;
	}
	return ssc_sensor_close_finish (SSC_SENSOR (self), result, error);
}

void
ssc_sensor_light_close (SSCSensorLight *self, GCancellable *cancellable,
			GAsyncReadyCallback callback, gpointer user_data)
{
	g_return_if_fail (SSC_IS_SENSOR_LIGHT (self));
	ssc_sensor_close (SSC_SENSOR (self), cancellable, callback, user_data);
}

gboolean
ssc_sensor_light_close_sync (SSCSensorLight *self, GCancellable *cancellable, GError **error)
{
	gboolean success = FALSE;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_light_close (self, cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	success = ssc_sensor_light_close_finish (self, ctx.result, error);
	ssc_common_clear_sync_context (&ctx);


	return success;
}

gboolean
ssc_sensor_light_open_finish (SSCSensorLight *self, GAsyncResult *result, GError **error)
{
	if (!SSC_IS_SENSOR_LIGHT (self)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Expected a light sensor");
		return FALSE;
	}
	return ssc_sensor_open_finish (SSC_SENSOR (self), result, error);
}

void
ssc_sensor_light_open (SSCSensorLight *self, GCancellable *cancellable,
			GAsyncReadyCallback callback, gpointer user_data)
{
	g_return_if_fail (SSC_IS_SENSOR_LIGHT (self));
	ssc_sensor_open (SSC_SENSOR (self), cancellable, callback, user_data);
}

gboolean
ssc_sensor_light_open_sync (SSCSensorLight *self, GCancellable *cancellable, GError **error)
{
	gboolean success = FALSE;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_light_open (self, cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	success = ssc_sensor_light_open_finish (self, ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return success;
}

static void
ssc_sensor_light_class_init (SSCSensorLightClass *klass)
{
	signals[SIGNAL_MEASUREMENT] = g_signal_new ("measurement",
		G_TYPE_FROM_CLASS (klass),
		G_SIGNAL_RUN_FIRST,
		0, NULL, NULL, NULL,
		G_TYPE_NONE,
		1, G_TYPE_FLOAT);
}

static void
ssc_sensor_light_init (SSCSensorLight *self)
{
	ssc_sensor_install_decoder (SSC_SENSOR (self), &decoder);
}

SSCSensorLight *
ssc_sensor_light_new_finish (GAsyncResult *result, GError **error)
{
	SSCSensor *sensor = ssc_sensor_new_typed_finish (result, SSC_TYPE_SENSOR_LIGHT, error);
	return sensor ? SSC_SENSOR_LIGHT (sensor) : NULL;
}

void
ssc_sensor_light_new (GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data)
{
	g_async_initable_new_async (
			SSC_TYPE_SENSOR_LIGHT,
			G_PRIORITY_DEFAULT,
			cancellable,
			callback,
			user_data,
			SSC_SENSOR_DATA_TYPE, "ambient_light",
			NULL);
}

SSCSensorLight *
ssc_sensor_light_new_sync (GCancellable *cancellable, GError **error)
{
	SSCSensorLight *self = NULL;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_light_new (cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	self = ssc_sensor_light_new_finish (ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return self;
}
