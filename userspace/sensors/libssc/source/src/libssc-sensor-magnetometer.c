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
#include "ssc-sensor-magnetometer.pb-c.h"
#include "libssc-sensor-magnetometer.h"

enum {
	SIGNAL_MEASUREMENT,
	N_SIGNALS
};
static guint signals[N_SIGNALS];

G_DEFINE_TYPE (SSCSensorMagnetometer, ssc_sensor_magnetometer, SSC_TYPE_SENSOR)

static gboolean
decode_measurement (const SscMeasurementSnapshot *snapshot, guint32 message_id,
		    const guint8 *bytes, gsize length, ProtobufCAllocator *allocator,
		    SscMeasurementFrame *frame, GError **error)
{
	SscMagnetometerResponse *msg;
	gboolean valid = FALSE;
	gfloat x, y, z;

	(void) snapshot;
	if (message_id != SSC_MSG_REPORT_MEASUREMENT) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Unexpected magnetometer measurement message");
		return FALSE;
	}
	msg = ssc_magnetometer_response__unpack (allocator, length, bytes);
	if (!msg) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Failed to unpack magnetometer measurement");
		return FALSE;
	}
	if (msg->n_magnetic_field < 3 || !msg->magnetic_field ||
	    !isfinite (msg->magnetic_field[0]) || !isfinite (msg->magnetic_field[1]) ||
	    !isfinite (msg->magnetic_field[2])) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Invalid magnetometer vector components");
		goto out;
	}
	x = msg->magnetic_field[0];
	y = msg->magnetic_field[1];
	z = msg->magnetic_field[2];
	/* Preserve the existing raw axis convention; no unit/calibration guess. */
	frame->kind = SSC_MEASUREMENT_MAGNETOMETER;
	frame->accuracy = msg->accuracy;
	frame->value.vector.x = x;
	frame->value.vector.y = y;
	frame->value.vector.z = z;
	valid = TRUE;
out:
	ssc_magnetometer_response__free_unpacked (msg, allocator);
	return valid;
}

static void
emit_measurement (SSCSensor *self, const SscMeasurementFrame *frame)
{
	g_signal_emit (self, signals[SIGNAL_MEASUREMENT], 0, frame->value.vector.x, frame->value.vector.y, frame->value.vector.z);
}

static const guint32 measurement_ids[] = { SSC_MSG_REPORT_MEASUREMENT };

static const SscSensorDecoder decoder = {
	.kind = SSC_MEASUREMENT_MAGNETOMETER,
	.data_type = "mag",
	.message_ids = measurement_ids,
	.n_message_ids = G_N_ELEMENTS (measurement_ids),
	.decode = decode_measurement,
	.emit_legacy = emit_measurement,
};

gboolean
ssc_sensor_magnetometer_close_finish (SSCSensorMagnetometer *self, GAsyncResult *result, GError **error)
{
	if (!SSC_IS_SENSOR_MAGNETOMETER (self)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Expected a magnetometer sensor");
		return FALSE;
	}
	return ssc_sensor_close_finish (SSC_SENSOR (self), result, error);
}

void
ssc_sensor_magnetometer_close (SSCSensorMagnetometer *self, GCancellable *cancellable,
			GAsyncReadyCallback callback, gpointer user_data)
{
	g_return_if_fail (SSC_IS_SENSOR_MAGNETOMETER (self));
	ssc_sensor_close (SSC_SENSOR (self), cancellable, callback, user_data);
}

gboolean
ssc_sensor_magnetometer_close_sync (SSCSensorMagnetometer *self, GCancellable *cancellable, GError **error)
{
	gboolean success = FALSE;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_magnetometer_close (self, cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	success = ssc_sensor_magnetometer_close_finish (self, ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return success;
}

gboolean
ssc_sensor_magnetometer_open_finish (SSCSensorMagnetometer *self, GAsyncResult *result, GError **error)
{
	if (!SSC_IS_SENSOR_MAGNETOMETER (self)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Expected a magnetometer sensor");
		return FALSE;
	}
	return ssc_sensor_open_finish (SSC_SENSOR (self), result, error);
}

void
ssc_sensor_magnetometer_open (SSCSensorMagnetometer *self, GCancellable *cancellable,
			GAsyncReadyCallback callback, gpointer user_data)
{
	g_return_if_fail (SSC_IS_SENSOR_MAGNETOMETER (self));
	ssc_sensor_open (SSC_SENSOR (self), cancellable, callback, user_data);
}

gboolean
ssc_sensor_magnetometer_open_sync (SSCSensorMagnetometer *self, GCancellable *cancellable, GError **error)
{
	gboolean success = FALSE;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_magnetometer_open (self, cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	success = ssc_sensor_magnetometer_open_finish (self, ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return success;
}

static void
ssc_sensor_magnetometer_class_init (SSCSensorMagnetometerClass *klass)
{
	signals[SIGNAL_MEASUREMENT] = g_signal_new ("measurement",
		G_TYPE_FROM_CLASS (klass),
		G_SIGNAL_RUN_FIRST,
		0, NULL, NULL, NULL,
		G_TYPE_NONE,
		3, G_TYPE_FLOAT, G_TYPE_FLOAT, G_TYPE_FLOAT);
}

static void
ssc_sensor_magnetometer_init (SSCSensorMagnetometer *self)
{
	ssc_sensor_install_decoder (SSC_SENSOR (self), &decoder);
}

SSCSensorMagnetometer *
ssc_sensor_magnetometer_new_finish (GAsyncResult *result, GError **error)
{
	SSCSensor *sensor = ssc_sensor_new_typed_finish (result, SSC_TYPE_SENSOR_MAGNETOMETER, error);
	return sensor ? SSC_SENSOR_MAGNETOMETER (sensor) : NULL;
}

void
ssc_sensor_magnetometer_new (GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data)
{
	g_async_initable_new_async (
			SSC_TYPE_SENSOR_MAGNETOMETER,
			G_PRIORITY_DEFAULT,
			cancellable,
			callback,
			user_data,
			SSC_SENSOR_DATA_TYPE, "mag",
			NULL);
}

SSCSensorMagnetometer *
ssc_sensor_magnetometer_new_sync (GCancellable *cancellable, GError **error)
{
	SSCSensorMagnetometer *self = NULL;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_magnetometer_new (cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	self = ssc_sensor_magnetometer_new_finish (ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return self;
}
