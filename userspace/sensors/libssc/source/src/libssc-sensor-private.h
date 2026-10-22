/* SPDX-License-Identifier: GPL-3.0-or-later */
/*
 * libssc private measurement contract. Not an installed/public ABI.
 * Copyright (C) 2022-2026 Dylan Van Assche
 *
 * This program is free software; you may redistribute and modify it under
 * the GNU General Public License, version 3 or (at your option) any later
 * version. It is provided without any warranty. See the accompanying LICENSE.
 */
#ifndef _LIBSSC_SENSOR_PRIVATE_H_
#define _LIBSSC_SENSOR_PRIVATE_H_

#include "libssc-sensor.h"
#include "libssc-sensor-sample.h"
#include <protobuf-c/protobuf-c.h>

G_BEGIN_DECLS

typedef enum {
	SSC_MEASUREMENT_ACCELEROMETER,
	SSC_MEASUREMENT_COMPASS,
	SSC_MEASUREMENT_GYROSCOPE,
	SSC_MEASUREMENT_LIGHT,
	SSC_MEASUREMENT_MAGNETOMETER,
	SSC_MEASUREMENT_PROXIMITY
} SscMeasurementKind;

typedef enum {
	SSC_FRAME_VALID_PAYLOAD = 1u << 0,
	SSC_FRAME_ACCURACY_KNOWN = 1u << 1,
	SSC_FRAME_CLOCK_UNQUALIFIED = 1u << 2
} SscMeasurementFlags;

/* No SP11 profile currently qualifies the alternative proximity dialect.
 * A future positive profile qualification is required before setting this. */
#define SSC_SENSOR_FORMAT_PROXIMITY_DAVINCI (1u << 0)

typedef struct {
	guint64 uid_high, uid_low;
	gfloat mount_matrix[3][3];
	guint stream_type;
	gfloat sample_rate;
	guint qualified_format_flags;
} SscMeasurementSnapshot;

typedef struct {
	SscMeasurementKind kind;
	guint64 epoch, sequence, raw_timestamp;
	gint32 accuracy;
	guint validity_flags;
	union {
		struct { gfloat x, y, z; } vector;
		gfloat scalar;
		gboolean near;
	} value;
} SscMeasurementFrame;

G_STATIC_ASSERT (sizeof (SscMeasurementFrame) <= 128);

/* Hidden constructor for an already authorized semantic frame. NULL frames or
 * unknown private kinds return NULL. All values are independently owned;
 * no input pointer, sensor or stream reference is retained. */
SSCSensorSample *ssc_sensor_sample_new (guint64 uid_high, guint64 uid_low,
				       const SscMeasurementFrame *frame);

/* Immutable, static-lifetime descriptor installed during subclass init.
 * decode is called only by the fixed owner, after exact ticket/epoch/state,
 * full UID and declared message-ID filtering. The supplied allocator is
 * bounded; all unpacked objects MUST be freed with that same allocator before
 * returning, on both success and failure. Snapshot, input bytes, allocator and
 * output frame cannot be retained. decode must not emit or mutate lifecycle.
 *
 * On success decode sets kind, raw accuracy and semantic value; the controller
 * sets epoch/sequence/raw_timestamp and clock/quality validity bits. Accuracy
 * outside 0..3 is retained as unknown quality, not a decoder assertion.
 * emit_legacy borrows a validated immutable frame for one owner callback;
 * reentrant public calls are permitted, so the controller reauthorizes after it.
 */
typedef struct {
	SscMeasurementKind kind;
	const gchar *data_type;
	const guint32 *message_ids;
	guint n_message_ids;
	gboolean (*decode) (const SscMeasurementSnapshot *snapshot,
		guint32 message_id, const guint8 *bytes, gsize length,
		ProtobufCAllocator *allocator, SscMeasurementFrame *frame,
		GError **error);
	void (*emit_legacy) (SSCSensor *self, const SscMeasurementFrame *frame);
} SscSensorDecoder;

/* Construction-only, once; descriptor storage must have static lifetime.
 * Complete construct properties are checked at INIT admission, not in init(). */
void ssc_sensor_install_decoder (SSCSensor *self, const SscSensorDecoder *decoder);

/* Reject wrong concrete sensor type before consuming the actual GAsyncInitable
 * result. The base finish still validates the original operation tag/source.
 * No outer wrapper task, alternate finish identity or public API is introduced. */
SSCSensor *ssc_sensor_new_typed_finish (GAsyncResult *result, GType expected_type,
				      GError **error);

G_END_DECLS

#endif
