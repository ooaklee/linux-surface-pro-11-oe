/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Owned public values, separate from the private stream-frame layout. */
#include "libssc-sensor-private.h"

struct _SSCSensorSample {
	SSCSensorSampleKind kind;
	guint64 uid_high, uid_low;
	guint64 epoch, sequence, raw_timestamp;
	gint32 accuracy;
	guint flags;
	union {
		struct { gfloat x, y, z; } vector;
		gfloat scalar;
		gboolean near;
	} value;
};

G_DEFINE_BOXED_TYPE (SSCSensorSample, ssc_sensor_sample,
	ssc_sensor_sample_copy, ssc_sensor_sample_free)

static gboolean
sample_kind_from_private (SscMeasurementKind kind, SSCSensorSampleKind *public_kind)
{
	switch (kind) {
	case SSC_MEASUREMENT_ACCELEROMETER:
		*public_kind = SSC_SENSOR_SAMPLE_KIND_ACCELEROMETER;
		return TRUE;
	case SSC_MEASUREMENT_COMPASS:
		*public_kind = SSC_SENSOR_SAMPLE_KIND_COMPASS;
		return TRUE;
	case SSC_MEASUREMENT_GYROSCOPE:
		*public_kind = SSC_SENSOR_SAMPLE_KIND_GYROSCOPE;
		return TRUE;
	case SSC_MEASUREMENT_LIGHT:
		*public_kind = SSC_SENSOR_SAMPLE_KIND_LIGHT;
		return TRUE;
	case SSC_MEASUREMENT_MAGNETOMETER:
		*public_kind = SSC_SENSOR_SAMPLE_KIND_MAGNETOMETER;
		return TRUE;
	case SSC_MEASUREMENT_PROXIMITY:
		*public_kind = SSC_SENSOR_SAMPLE_KIND_PROXIMITY;
		return TRUE;
	default:
		return FALSE;
	}
}

SSCSensorSample *
ssc_sensor_sample_new (guint64 uid_high, guint64 uid_low,
		       const SscMeasurementFrame *frame)
{
	SSCSensorSample value = {0};
	SSCSensorSample *sample;

	if (!frame || !sample_kind_from_private (frame->kind, &value.kind))
		return NULL;
	value.uid_high = uid_high;
	value.uid_low = uid_low;
	value.epoch = frame->epoch;
	value.sequence = frame->sequence;
	value.raw_timestamp = frame->raw_timestamp;
	value.accuracy = frame->accuracy;
	/* The current public contract never qualifies a physical sensor clock. */
	value.flags = SSC_SENSOR_SAMPLE_CLOCK_UNQUALIFIED;
	if (frame->validity_flags & SSC_FRAME_VALID_PAYLOAD)
		value.flags |= SSC_SENSOR_SAMPLE_VALID_PAYLOAD;
	if ((frame->validity_flags & SSC_FRAME_ACCURACY_KNOWN) &&
	    frame->accuracy >= 0 && frame->accuracy <= 3)
		value.flags |= SSC_SENSOR_SAMPLE_ACCURACY_KNOWN;
	switch (value.kind) {
	case SSC_SENSOR_SAMPLE_KIND_ACCELEROMETER:
	case SSC_SENSOR_SAMPLE_KIND_GYROSCOPE:
	case SSC_SENSOR_SAMPLE_KIND_MAGNETOMETER:
		value.value.vector.x = frame->value.vector.x;
		value.value.vector.y = frame->value.vector.y;
		value.value.vector.z = frame->value.vector.z;
		break;
	case SSC_SENSOR_SAMPLE_KIND_COMPASS:
	case SSC_SENSOR_SAMPLE_KIND_LIGHT:
		value.value.scalar = frame->value.scalar;
		break;
	case SSC_SENSOR_SAMPLE_KIND_PROXIMITY:
		value.value.near = frame->value.near;
		break;
	}
	sample = g_new (SSCSensorSample, 1);
	*sample = value;
	return sample;
}

SSCSensorSample *
ssc_sensor_sample_copy (const SSCSensorSample *sample)
{
	SSCSensorSample *copy;

	g_return_val_if_fail (sample != NULL, NULL);
	copy = g_new (SSCSensorSample, 1);
	*copy = *sample;
	return copy;
}

void
ssc_sensor_sample_free (SSCSensorSample *sample)
{
	g_free (sample);
}

SSCSensorSampleKind
ssc_sensor_sample_get_kind (const SSCSensorSample *sample)
{
	g_return_val_if_fail (sample != NULL, SSC_SENSOR_SAMPLE_KIND_ACCELEROMETER);
	return sample->kind;
}

guint64
ssc_sensor_sample_get_uid_high (const SSCSensorSample *sample)
{
	g_return_val_if_fail (sample != NULL, 0);
	return sample->uid_high;
}

guint64
ssc_sensor_sample_get_uid_low (const SSCSensorSample *sample)
{
	g_return_val_if_fail (sample != NULL, 0);
	return sample->uid_low;
}

guint64
ssc_sensor_sample_get_epoch (const SSCSensorSample *sample)
{
	g_return_val_if_fail (sample != NULL, 0);
	return sample->epoch;
}

guint64
ssc_sensor_sample_get_sequence (const SSCSensorSample *sample)
{
	g_return_val_if_fail (sample != NULL, 0);
	return sample->sequence;
}

guint64
ssc_sensor_sample_get_raw_timestamp (const SSCSensorSample *sample)
{
	g_return_val_if_fail (sample != NULL, 0);
	return sample->raw_timestamp;
}

gint32
ssc_sensor_sample_get_accuracy (const SSCSensorSample *sample)
{
	g_return_val_if_fail (sample != NULL, 0);
	return sample->accuracy;
}

guint
ssc_sensor_sample_get_flags (const SSCSensorSample *sample)
{
	g_return_val_if_fail (sample != NULL, 0);
	return sample->flags;
}

gboolean
ssc_sensor_sample_get_vector (const SSCSensorSample *sample,
			      gfloat *x, gfloat *y, gfloat *z)
{
	g_return_val_if_fail (sample != NULL, FALSE);
	if (sample->kind != SSC_SENSOR_SAMPLE_KIND_ACCELEROMETER &&
	    sample->kind != SSC_SENSOR_SAMPLE_KIND_GYROSCOPE &&
	    sample->kind != SSC_SENSOR_SAMPLE_KIND_MAGNETOMETER)
		return FALSE;
	if (x)
		*x = sample->value.vector.x;
	if (y)
		*y = sample->value.vector.y;
	if (z)
		*z = sample->value.vector.z;
	return TRUE;
}

gboolean
ssc_sensor_sample_get_scalar (const SSCSensorSample *sample, gfloat *value)
{
	g_return_val_if_fail (sample != NULL, FALSE);
	if (sample->kind != SSC_SENSOR_SAMPLE_KIND_COMPASS &&
	    sample->kind != SSC_SENSOR_SAMPLE_KIND_LIGHT)
		return FALSE;
	if (value)
		*value = sample->value.scalar;
	return TRUE;
}

gboolean
ssc_sensor_sample_get_near (const SSCSensorSample *sample, gboolean *near)
{
	g_return_val_if_fail (sample != NULL, FALSE);
	if (sample->kind != SSC_SENSOR_SAMPLE_KIND_PROXIMITY)
		return FALSE;
	if (near)
		*near = sample->value.near;
	return TRUE;
}
