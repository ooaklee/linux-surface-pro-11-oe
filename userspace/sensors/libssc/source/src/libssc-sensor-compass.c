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
#include "ssc-sensor-rotationvector.pb-c.h"
#include "libssc-sensor-compass.h"

enum {
	SIGNAL_MEASUREMENT,
	N_SIGNALS
};
static guint signals[N_SIGNALS];

G_DEFINE_TYPE (SSCSensorCompass, ssc_sensor_compass, SSC_TYPE_SENSOR)

static gboolean
decode_measurement (const SscMeasurementSnapshot *snapshot, guint32 message_id,
		    const guint8 *bytes, gsize length, ProtobufCAllocator *allocator,
		    SscMeasurementFrame *frame, GError **error)
{
	SscRotationvectorResponse *msg;
	gboolean valid = FALSE;
	gdouble q0, q1, q2, q3, norm, r1, r4, azimuth;
	gfloat heading;

	(void) snapshot;
	if (message_id != SSC_MSG_REPORT_MEASUREMENT) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Unexpected compass measurement message");
		return FALSE;
	}
	msg = ssc_rotationvector_response__unpack (allocator, length, bytes);
	if (!msg) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Failed to unpack compass measurement");
		return FALSE;
	}
	if (msg->n_rotation < 4 || !msg->rotation ||
	    !isfinite (msg->rotation[0]) || !isfinite (msg->rotation[1]) ||
	    !isfinite (msg->rotation[2]) || !isfinite (msg->rotation[3])) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Invalid compass quaternion components");
		goto out;
	}
	/* Double intermediates cover every finite float magnitude. Normalize
	 * before the existing x/y/z/w azimuth formula, without a unit epsilon. */
	q0 = msg->rotation[3];
	q1 = msg->rotation[0];
	q2 = msg->rotation[1];
	q3 = msg->rotation[2];
	norm = sqrt (q0 * q0 + q1 * q1 + q2 * q2 + q3 * q3);
	if (!isfinite (norm) || norm <= 0.0) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Compass quaternion has no finite positive norm");
		goto out;
	}
	q0 /= norm; q1 /= norm; q2 /= norm; q3 /= norm;
	r1 = 2.0 * q1 * q2 - 2.0 * q3 * q0;
	r4 = 1.0 - 2.0 * q1 * q1 - 2.0 * q3 * q3;
	azimuth = atan2 (r1, r4) * 180.0 / G_PI;
	if (azimuth < 0.0)
		azimuth += 360.0;
	heading = (gfloat) azimuth;
	if (!isfinite (azimuth) || !isfinite (heading)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_DATA,
			"Non-finite compass heading");
		goto out;
	}
	frame->kind = SSC_MEASUREMENT_COMPASS;
	frame->accuracy = msg->accuracy;
	frame->value.scalar = heading;
	valid = TRUE;
out:
	ssc_rotationvector_response__free_unpacked (msg, allocator);
	return valid;
}

static void
emit_measurement (SSCSensor *self, const SscMeasurementFrame *frame)
{
	g_signal_emit (self, signals[SIGNAL_MEASUREMENT], 0, frame->value.scalar);
}

static const guint32 measurement_ids[] = { SSC_MSG_REPORT_MEASUREMENT };

static const SscSensorDecoder decoder = {
	.kind = SSC_MEASUREMENT_COMPASS,
	.data_type = "rotv",
	.message_ids = measurement_ids,
	.n_message_ids = G_N_ELEMENTS (measurement_ids),
	.decode = decode_measurement,
	.emit_legacy = emit_measurement,
};

gboolean
ssc_sensor_compass_close_finish (SSCSensorCompass *self, GAsyncResult *result, GError **error)
{
	if (!SSC_IS_SENSOR_COMPASS (self)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Expected a compass sensor");
		return FALSE;
	}
	return ssc_sensor_close_finish (SSC_SENSOR (self), result, error);
}

void
ssc_sensor_compass_close (SSCSensorCompass *self, GCancellable *cancellable,
			GAsyncReadyCallback callback, gpointer user_data)
{
	g_return_if_fail (SSC_IS_SENSOR_COMPASS (self));
	ssc_sensor_close (SSC_SENSOR (self), cancellable, callback, user_data);
}

gboolean
ssc_sensor_compass_close_sync (SSCSensorCompass *self, GCancellable *cancellable, GError **error)
{
	gboolean success = FALSE;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_compass_close (self, cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	success = ssc_sensor_compass_close_finish (self, ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return success;
}

gboolean
ssc_sensor_compass_open_finish (SSCSensorCompass *self, GAsyncResult *result, GError **error)
{
	if (!SSC_IS_SENSOR_COMPASS (self)) {
		g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
			"Expected a compass sensor");
		return FALSE;
	}
	return ssc_sensor_open_finish (SSC_SENSOR (self), result, error);
}

void
ssc_sensor_compass_open (SSCSensorCompass *self, GCancellable *cancellable,
			GAsyncReadyCallback callback, gpointer user_data)
{
	g_return_if_fail (SSC_IS_SENSOR_COMPASS (self));
	ssc_sensor_open (SSC_SENSOR (self), cancellable, callback, user_data);
}

gboolean
ssc_sensor_compass_open_sync (SSCSensorCompass *self, GCancellable *cancellable, GError **error)
{
	gboolean success = FALSE;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_compass_open (self, cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	success = ssc_sensor_compass_open_finish (self, ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return success;
}

static void
ssc_sensor_compass_class_init (SSCSensorCompassClass *klass)
{
	signals[SIGNAL_MEASUREMENT] = g_signal_new ("measurement",
		G_TYPE_FROM_CLASS (klass),
		G_SIGNAL_RUN_FIRST,
		0, NULL, NULL, NULL,
		G_TYPE_NONE,
		1, G_TYPE_FLOAT);
}

static void
ssc_sensor_compass_init (SSCSensorCompass *self)
{
	ssc_sensor_install_decoder (SSC_SENSOR (self), &decoder);
}

SSCSensorCompass *
ssc_sensor_compass_new_finish (GAsyncResult *result, GError **error)
{
	SSCSensor *sensor = ssc_sensor_new_typed_finish (result, SSC_TYPE_SENSOR_COMPASS, error);
	return sensor ? SSC_SENSOR_COMPASS (sensor) : NULL;
}

void
ssc_sensor_compass_new (GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data)
{
	g_async_initable_new_async (
			SSC_TYPE_SENSOR_COMPASS,
			G_PRIORITY_DEFAULT,
			cancellable,
			callback,
			user_data,
			SSC_SENSOR_DATA_TYPE, "rotv",
			NULL);
}

SSCSensorCompass *
ssc_sensor_compass_new_sync (GCancellable *cancellable, GError **error)
{
	SSCSensorCompass *self = NULL;
	SyncContext ctx;

	ssc_common_init_sync_context (&ctx);
	ssc_sensor_compass_new (cancellable, ssc_common_callback_sync_context, &ctx);
	ssc_common_wait_sync_context (&ctx);
	self = ssc_sensor_compass_new_finish (ctx.result, error);
	ssc_common_clear_sync_context (&ctx);

	return self;
}
