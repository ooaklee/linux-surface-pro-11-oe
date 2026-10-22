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

#ifndef _LIBSSC_CLI_H_
#define _LIBSSC_CLI_H_

#include <stdio.h>
#include <glib.h>
#include <glib/gstdio.h>
#include <gio/gio.h>
#include "libssc-version-private.h"
#include "libssc-sensor.h"
#include "libssc-sensor-sample.h"
#include "libssc-sensor-proximity.h"
#include "libssc-sensor-light.h"
#include "libssc-sensor-accelerometer.h"
#include "libssc-sensor-magnetometer.h"
#include "libssc-sensor-compass.h"
#include "libssc-sensor-gyroscope.h"

typedef enum {
	SSC_CLI_INITIALIZING,
	SSC_CLI_OPENING,
	SSC_CLI_OPEN,
	SSC_CLI_CLOSING,
	SSC_CLI_RETIRING,
	SSC_CLI_ERROR_WAIT,
	SSC_CLI_DONE,
	SSC_CLI_DISCOVERING
} SSCCliState;

typedef enum {
	SSC_CLI_INVOCATION_NONE,
	SSC_CLI_INVOCATION_INIT,
	SSC_CLI_INVOCATION_OPEN,
	SSC_CLI_INVOCATION_CLOSE,
	SSC_CLI_INVOCATION_RETIRE,
	SSC_CLI_INVOCATION_DISCOVER
} SSCCliInvocation;

typedef enum {
	SSC_CLI_PROXIMITY,
	SSC_CLI_LIGHT,
	SSC_CLI_ACCELEROMETER,
	SSC_CLI_MAGNETOMETER,
	SSC_CLI_COMPASS,
	SSC_CLI_GYROSCOPE
} SSCCliSensorKind;

/* Main retains owner dispatch through the actual terminal retirement receipt,
 * after consuming its own logical callback obligations. sensor and
 * retirement_subject own independent refs, even when their pointers match.
 * Failed INIT may have only a subject. One invocation and one diagnostic
 * result are retained; malformed results never replace the genuine operation. */
typedef struct {
	GMainLoop *loop;
	GMainContext *context;
	SSCSensor *sensor;
	SSCSensor *retirement_subject;
	GCancellable *pending;
	GAsyncResult *diagnostic_result;
	GSource *timeout_source, *sigint_source, *sigterm_source;
	gulong measurement_id, stream_error_id;
	SSCCliState state;
	SSCCliInvocation invocation;
	GType expected_type;
	gpointer invocation_tag;
	SSCCliSensorKind kind;
	const gchar *sensor_name;
	const gchar *discovery_type;
	/* Owned immutable result survives sensor cleanup for post-retirement I/O. */
	SSCSensorUidList *discovered_uids;
	/* Owned metadata snapshot, emitted only after actual terminal cleanup. */
	gchar *inspection_text;
	guint64 uid_high, uid_low;
	gboolean selection_enabled;
	gboolean stop_requested, close_started, retire_started;
	gboolean inspect, inspection_ready, stream_requested;
	gboolean sample_metadata;
	gboolean discover, discovery_succeeded, discovery_interrupted;
	gint exit_status;
} SSCCli;

#endif /* _LIBSSC_CLI_H_ */
