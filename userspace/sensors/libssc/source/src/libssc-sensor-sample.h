/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Immutable, owned semantic samples delivered by libssc sensors. */
#ifndef _LIBSSC_SENSOR_SAMPLE_H_
#define _LIBSSC_SENSOR_SAMPLE_H_

#include <glib-object.h>

G_BEGIN_DECLS

/**
 * SSCSensorSampleKind:
 * @SSC_SENSOR_SAMPLE_KIND_ACCELEROMETER: an accelerometer vector
 * @SSC_SENSOR_SAMPLE_KIND_COMPASS: a derived compass heading
 * @SSC_SENSOR_SAMPLE_KIND_GYROSCOPE: a gyroscope vector
 * @SSC_SENSOR_SAMPLE_KIND_LIGHT: a light scalar
 * @SSC_SENSOR_SAMPLE_KIND_MAGNETOMETER: a magnetometer vector
 * @SSC_SENSOR_SAMPLE_KIND_PROXIMITY: a proximity near/far value
 *
 * The semantic value kind. Values retain the corresponding existing sensor
 * measurement signal's convention, not an unmounted/raw-wire representation.
 *
 * Since: 0.4.7
 */
typedef enum {
	SSC_SENSOR_SAMPLE_KIND_ACCELEROMETER = 0,
	SSC_SENSOR_SAMPLE_KIND_COMPASS = 1,
	SSC_SENSOR_SAMPLE_KIND_GYROSCOPE = 2,
	SSC_SENSOR_SAMPLE_KIND_LIGHT = 3,
	SSC_SENSOR_SAMPLE_KIND_MAGNETOMETER = 4,
	SSC_SENSOR_SAMPLE_KIND_PROXIMITY = 5
} SSCSensorSampleKind;

/**
 * SSCSensorSampleFlags:
 * @SSC_SENSOR_SAMPLE_VALID_PAYLOAD: the semantic payload passed the decoder
 * @SSC_SENSOR_SAMPLE_ACCURACY_KNOWN: the raw accuracy is in the supported 0..3 range
 * @SSC_SENSOR_SAMPLE_CLOCK_UNQUALIFIED: raw timestamp ticks have no qualified clock mapping
 *
 * These flags do not establish physical calibration, board orientation or
 * timestamp frequency. CLOCK_UNQUALIFIED is set for every current sample.
 * Other flag bits are reserved; callers must not infer meanings for them.
 *
 * Since: 0.4.7
 */
typedef enum {
	SSC_SENSOR_SAMPLE_VALID_PAYLOAD = 1u << 0,
	SSC_SENSOR_SAMPLE_ACCURACY_KNOWN = 1u << 1,
	SSC_SENSOR_SAMPLE_CLOCK_UNQUALIFIED = 1u << 2
} SSCSensorSampleFlags;

/**
 * SSCSensorSample:
 *
 * An immutable owned value snapshot of one delivered semantic measurement.
 * Copy a signal's borrowed sample to retain it after that callback. Copies
 * may use g_autoptr; the borrowed callback pointer itself must not be freed.
 * remain valid independently of subsequent samples and sensor disposal; they
 * retain no sensor, client, stream or local-retirement reference.
 *
 * This is not every wire event or a raw protobuf capture. Existing semantic
 * transformations and proximity deduplication remain in effect. The UID is
 * the validated stream UID, not a physical board-role assignment. Local
 * epoch/sequence values are neither DSP correlation cookies nor cross-device
 * ordering. Raw timestamps and raw accuracy do not qualify calibration or a
 * physical clock. There is no public sample constructor or writable storage.
 *
 * Since: 0.4.7
 */
typedef struct _SSCSensorSample SSCSensorSample;

#define SSC_TYPE_SENSOR_SAMPLE (ssc_sensor_sample_get_type ())
GType ssc_sensor_sample_get_type (void) G_GNUC_CONST;

/**
 * ssc_sensor_sample_copy:
 * @sample: an immutable sample
 *
 * Returns: (transfer full): an independent immutable value copy
 * Since: 0.4.7
 */
SSCSensorSample *ssc_sensor_sample_copy (const SSCSensorSample *sample);

/**
 * ssc_sensor_sample_free:
 * @sample: (nullable) (transfer full): a sample to release
 *
 * Since: 0.4.7
 */
void ssc_sensor_sample_free (SSCSensorSample *sample);

/**
 * ssc_sensor_sample_get_kind:
 * @sample: an immutable sample
 *
 * Returns: the semantic value kind
 * Since: 0.4.7
 */
SSCSensorSampleKind ssc_sensor_sample_get_kind (const SSCSensorSample *sample);

/**
 * ssc_sensor_sample_get_uid_high:
 * @sample: an immutable sample
 *
 * Returns: the exact high 64 bits of the validated stream UID
 * Since: 0.4.7
 */
guint64 ssc_sensor_sample_get_uid_high (const SSCSensorSample *sample);

/**
 * ssc_sensor_sample_get_uid_low:
 * @sample: an immutable sample
 *
 * Returns: the exact low 64 bits of the validated stream UID
 * Since: 0.4.7
 */
guint64 ssc_sensor_sample_get_uid_low (const SSCSensorSample *sample);

/**
 * ssc_sensor_sample_get_epoch:
 * @sample: an immutable sample
 *
 * Returns: the local stream epoch, not a wire correlation cookie
 * Since: 0.4.7
 */
guint64 ssc_sensor_sample_get_epoch (const SSCSensorSample *sample);

/**
 * ssc_sensor_sample_get_sequence:
 * @sample: an immutable sample
 *
 * Returns: local semantic admission order, not every wire event
 * Since: 0.4.7
 */
guint64 ssc_sensor_sample_get_sequence (const SSCSensorSample *sample);

/**
 * ssc_sensor_sample_get_raw_timestamp:
 * @sample: an immutable sample
 *
 * Returns: exact opaque sensor ticks, not nanoseconds or wall-clock time
 * Since: 0.4.7
 */
guint64 ssc_sensor_sample_get_raw_timestamp (const SSCSensorSample *sample);

/**
 * ssc_sensor_sample_get_accuracy:
 * @sample: an immutable sample
 *
 * Raw signed accuracy is retained even outside 0..3. Consult the
 * ACCURACY_KNOWN flag instead of assuming that an unknown value is calibrated.
 *
 * Returns: the unchanged raw accuracy value
 * Since: 0.4.7
 */
gint32 ssc_sensor_sample_get_accuracy (const SSCSensorSample *sample);

/**
 * ssc_sensor_sample_get_flags:
 * @sample: an immutable sample
 *
 * Returns: a bitset of #SSCSensorSampleFlags; reserved bits currently zero
 * Since: 0.4.7
 */
guint ssc_sensor_sample_get_flags (const SSCSensorSample *sample);

/**
 * ssc_sensor_sample_get_vector:
 * @sample: an immutable sample
 * @x: (out) (optional): location for the semantic X component
 * @y: (out) (optional): location for the semantic Y component
 * @z: (out) (optional): location for the semantic Z component
 *
 * Supports accelerometer, gyroscope and magnetometer samples. A wrong kind
 * returns FALSE without changing any output. NULL output pointers are allowed.
 *
 * Returns: TRUE if the sample contains a vector, otherwise FALSE
 * Since: 0.4.7
 */
gboolean ssc_sensor_sample_get_vector (const SSCSensorSample *sample,
	gfloat *x, gfloat *y, gfloat *z);

/**
 * ssc_sensor_sample_get_scalar:
 * @sample: an immutable sample
 * @value: (out) (optional): location for the semantic scalar
 *
 * Supports compass heading and light samples. A wrong kind returns FALSE
 * without changing the output. A NULL output pointer is allowed.
 *
 * Returns: TRUE if the sample contains a scalar, otherwise FALSE
 * Since: 0.4.7
 */
gboolean ssc_sensor_sample_get_scalar (const SSCSensorSample *sample, gfloat *value);

/**
 * ssc_sensor_sample_get_near:
 * @sample: an immutable sample
 * @near: (out) (optional): location for the proximity state
 *
 * Supports proximity samples only. A wrong kind returns FALSE without
 * changing the output. A NULL output pointer is allowed.
 *
 * Returns: TRUE if the sample contains a proximity state, otherwise FALSE
 * Since: 0.4.7
 */
gboolean ssc_sensor_sample_get_near (const SSCSensorSample *sample, gboolean *near);

G_DEFINE_AUTOPTR_CLEANUP_FUNC (SSCSensorSample, ssc_sensor_sample_free)

G_END_DECLS
#endif /* _LIBSSC_SENSOR_SAMPLE_H_ */
