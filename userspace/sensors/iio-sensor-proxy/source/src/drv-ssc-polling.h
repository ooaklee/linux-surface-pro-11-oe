/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef IIO_SENSOR_PROXY_SSC_POLLING_H
#define IIO_SENSOR_PROXY_SSC_POLLING_H

#include <libssc-sensor.h>

/* This is a private adapter, not a libssc API. */
struct SensorDevice;
typedef gboolean (*SscPollingOperation) (SSCSensor *sensor, GError **error);

gboolean ssc_driver_set_polling_full (struct SensorDevice *device,
				     SSCSensor *sensor,
				     GCallback measurement,
				     SscPollingOperation open,
				     SscPollingOperation close,
				     gboolean state,
				     GError **error);

/* Call before freeing SensorDevice/its private data. This only invalidates
 * local handler ownership; it is not a transport-quiescence receipt. */
void ssc_driver_polling_detach (SSCSensor *sensor);

/* A local first-reading deadline, never emitted as a native stream-error.
 * Retains the exact sensor across notification and schedules required CLOSE. */
void ssc_driver_startup_failed (struct SensorDevice *device,
			       SSCSensor *sensor, const GError *error);

#endif
