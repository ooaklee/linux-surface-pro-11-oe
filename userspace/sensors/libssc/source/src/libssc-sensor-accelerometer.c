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
#include "ssc-sensor-accelerometer.pb-c.h"
#include "libssc-sensor-accelerometer.h"

enum {
	SIGNAL_MEASUREMENT,
	N_SIGNALS
};
static guint signals[N_SIGNALS];

G_DEFINE_TYPE (SSCSensorAccelerometer, ssc_sensor_accelerometer, SSC_TYPE_SENSOR)

static gboolean
decode_measurement (const SscMeasurementSnapshot *snapshot, guint32 message_id,
		    const guint8 *bytes, gsize length, ProtobufCAllocator *allocator,
		    SscMeasurementFrame *frame, GError **error)
{
	SscAccelerometerResponse *msg;
	gboolean valid = FALSE;
	gfloat x, y, z;
	gfloat transformed_x, transformed_y, transformed_z;

	if (message_id != SSC_MSG_REPORT_MEASUREMENT) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Unexpected accelerometer measurement message");
		return FALSE;
	}
	msg = ssc_accelerometer_response__unpack (allocator, length, bytes);
	if (!msg) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Failed to unpack accelerometer measurement");
		return FALSE;
	}
	if (msg->n_acceleration < 3 || !msg->acceleration ||
	    !isfinite (msg->acceleration[0]) || !isfinite (msg->acceleration[1]) ||
	    !isfinite (msg->acceleration[2])) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Invalid accelerometer vector components");
		goto out;
	}
	x = msg->acceleration[0];
	y = msg->acceleration[1];
	z = msg->acceleration[2];
	for (guint row = 0; row < 3; row++) {
		for (guint column = 0; column < 3; column++) {
			if (!isfinite (snapshot->mount_matrix[row][column])) {
				g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
					"Invalid accelerometer mount matrix");
				goto out;
			}
		}
	}
	/* Preserve the existing committed mount-matrix convention. */
	transformed_x = snapshot->mount_matrix[0][0] * x +
		snapshot->mount_matrix[0][1] * y + snapshot->mount_matrix[0][2] * z;
	transformed_y = snapshot->mount_matrix[1][0] * x +
		snapshot->mount_matrix[1][1] * y + snapshot->mount_matrix[1][2] * z;
	transformed_z = snapshot->mount_matrix[2][0] * x +
		snapshot->mount_matrix[2][1] * y + snapshot->mount_matrix[2][2] * z;
	if (!isfinite (transformed_x) || !isfinite (transformed_y) || !isfinite (transformed_z)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Non-finite transformed accelerometer vector");
		goto out;
	}
	x = transformed_x;
	y = transformed_y;
	z = transformed_z;
	frame->kind = SSC_MEASUREMENT_ACCELEROMETER;
	frame->accuracy = msg->accuracy;
	frame->value.vector.x = x;
	frame->value.vector.y = y;
	frame->value.vector.z = z;
	valid = TRUE;
out:
	ssc_accelerometer_response__free_unpacked (msg, allocator);
	return valid;
}

static void
emit_measurement (SSCSensor *self, const SscMeasurementFrame *frame)
{
	g_signal_emit (self, signals[SIGNAL_MEASUREMENT], 0, frame->value.vector.x, frame->value.vector.y, frame->value.vector.z);
}

static const guint32 measurement_ids[] = { SSC_MSG_REPORT_MEASUREMENT };

static const SscSensorDecoder decoder = {
	.kind = SSC_MEASUREMENT_ACCELEROMETER,
	.data_type = "accel",
	.message_ids = measurement_ids,
	.n_message_ids = G_N_ELEMENTS (measurement_ids),
	.decode = decode_measurement,
	.emit_legacy = emit_measurement,
};

gboolean
ssc_sensor_accelerometer_close_finish (SSCSensorAccelerometer *self, GAsyncResult *result, GError **error)
{
	if (!SSC_IS_SENSOR_ACCELEROMETER (self)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Expected an accelerometer sensor");
		return FALSE;
	}
	return ssc_sensor_close_finish (SSC_SENSOR (self), result, error);
}

void
ssc_sensor_accelerometer_close (SSCSensorAccelerometer *self, GCancellable *cancellable,
			GAsyncReadyCallback callback, gpointer user_data)
{
	g_return_if_fail (SSC_IS_SENSOR_ACCELEROMETER (self));
	ssc_sensor_close (SSC_SENSOR (self), cancellable, callback, user_data);
}

gboolean
ssc_sensor_accelerometer_close_sync (SSCSensorAccelerometer *self, GCancellable *cancellable, GError **error)
{
	gboolean success = FALSE;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_accelerometer_close (self, cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	success = ssc_sensor_accelerometer_close_finish (self, ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return success;
}

gboolean
ssc_sensor_accelerometer_open_finish (SSCSensorAccelerometer *self, GAsyncResult *result, GError **error)
{
	if (!SSC_IS_SENSOR_ACCELEROMETER (self)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Expected an accelerometer sensor");
		return FALSE;
	}
	return ssc_sensor_open_finish (SSC_SENSOR (self), result, error);
}

void
ssc_sensor_accelerometer_open (SSCSensorAccelerometer *self, GCancellable *cancellable,
			GAsyncReadyCallback callback, gpointer user_data)
{
	g_return_if_fail (SSC_IS_SENSOR_ACCELEROMETER (self));
	ssc_sensor_open (SSC_SENSOR (self), cancellable, callback, user_data);
}

gboolean
ssc_sensor_accelerometer_open_sync (SSCSensorAccelerometer *self, GCancellable *cancellable, GError **error)
{
	gboolean success = FALSE;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_accelerometer_open (self, cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	success = ssc_sensor_accelerometer_open_finish (self, ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return success;
}

static void
ssc_sensor_accelerometer_class_init (SSCSensorAccelerometerClass *klass)
{
	signals[SIGNAL_MEASUREMENT] = g_signal_new ("measurement",
		G_TYPE_FROM_CLASS (klass),
		G_SIGNAL_RUN_FIRST,
		0, NULL, NULL, NULL,
		G_TYPE_NONE,
		3, G_TYPE_FLOAT, G_TYPE_FLOAT, G_TYPE_FLOAT);
}

static void
ssc_sensor_accelerometer_init (SSCSensorAccelerometer *self)
{
	ssc_sensor_install_decoder (SSC_SENSOR (self), &decoder);
}

SSCSensorAccelerometer *
ssc_sensor_accelerometer_new_finish (GAsyncResult *result, GError **error)
{
	SSCSensor *sensor = ssc_sensor_new_typed_finish (result, SSC_TYPE_SENSOR_ACCELEROMETER, error);
	return sensor ? SSC_SENSOR_ACCELEROMETER (sensor) : NULL;
}

void
ssc_sensor_accelerometer_new (GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data)
{
	g_async_initable_new_async (
			SSC_TYPE_SENSOR_ACCELEROMETER,
			G_PRIORITY_DEFAULT,
			cancellable,
			callback,
			user_data,
			SSC_SENSOR_DATA_TYPE, "accel",
			NULL);
}

SSCSensorAccelerometer *
ssc_sensor_accelerometer_new_sync (GCancellable *cancellable, GError **error)
{
	SSCSensorAccelerometer *self = NULL;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_accelerometer_new (cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	self = ssc_sensor_accelerometer_new_finish (ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return self;
}
