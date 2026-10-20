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

#ifndef _LIBSSC_SENSOR_PROXIMITY_H_
#define _LIBSSC_SENSOR_PROXIMITY_H_

#include <glib.h>
#include <gio/gio.h>
#include "libssc-sensor.h"

#define SSC_TYPE_SENSOR_PROXIMITY (ssc_sensor_proximity_get_type())

typedef struct _SSCSensorProximity {
	SSCSensor parent;
} SSCSensorProximity;

G_DECLARE_FINAL_TYPE (SSCSensorProximity, ssc_sensor_proximity, SSC, SENSOR_PROXIMITY, SSCSensor);

void		 	 ssc_sensor_proximity_new (GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data);
SSCSensorProximity 	*ssc_sensor_proximity_new_finish (GAsyncResult *result, GError **error);
SSCSensorProximity 	*ssc_sensor_proximity_new_sync (GCancellable *cancellable, GError **error);
void			 ssc_sensor_proximity_open (SSCSensorProximity *self, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data);
gboolean		 ssc_sensor_proximity_open_finish (SSCSensorProximity *self, GAsyncResult *result, GError **error);
gboolean		 ssc_sensor_proximity_open_sync (SSCSensorProximity *self, GCancellable *cancellable, GError **error);
void			 ssc_sensor_proximity_close (SSCSensorProximity *self, GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data);
gboolean		 ssc_sensor_proximity_close_finish (SSCSensorProximity *self, GAsyncResult *result, GError **error);
gboolean		 ssc_sensor_proximity_close_sync (SSCSensorProximity *self, GCancellable *cancellable, GError **error);

#endif /* _LIBSSC_SENSOR_PROXIMITY_H_ */
