/* -*- Mode: C; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- */
/*
 * qmi-firmware-update -- Command line tool to update firmware in QMI devices
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Copyright (C) 2016 Zodiac Inflight Innovations
 * Copyright (C) 2016-2017 Aleksander Morgado <aleksander@aleksander.es>
 */

#ifndef QFU_DOWNLOAD_RESETER_H
#define QFU_DOWNLOAD_RESETER_H

#include <glib-object.h>
#include <gio/gio.h>
#include <libqmi-glib.h>

#include "qfu-device-selection.h"

G_BEGIN_DECLS

#define QFU_TYPE_DOWNLOAD_RESETER            (qfu_download_reseter_get_type ())
#define QFU_DOWNLOAD_RESETER(obj)            (G_TYPE_CHECK_INSTANCE_CAST ((obj), QFU_TYPE_DOWNLOAD_RESETER, QfuDownloadReseter))
#define QFU_DOWNLOAD_RESETER_CLASS(klass)    (G_TYPE_CHECK_CLASS_CAST ((klass),  QFU_TYPE_DOWNLOAD_RESETER, QfuDownloadReseterClass))
#define QFU_IS_DOWNLOAD_RESETER(obj)         (G_TYPE_CHECK_INSTANCE_TYPE ((obj), QFU_TYPE_DOWNLOAD_RESETER))
#define QFU_IS_DOWNLOAD_RESETER_CLASS(klass) (G_TYPE_CHECK_CLASS_TYPE ((klass),  QFU_TYPE_DOWNLOAD_RESETER))
#define QFU_DOWNLOAD_RESETER_GET_CLASS(obj)  (G_TYPE_INSTANCE_GET_CLASS ((obj),  QFU_TYPE_DOWNLOAD_RESETER, QfuDownloadReseterClass))

typedef struct _QfuDownloadReseter QfuDownloadReseter;
typedef struct _QfuDownloadReseterClass QfuDownloadReseterClass;
typedef struct _QfuDownloadReseterPrivate QfuDownloadReseterPrivate;

struct _QfuDownloadReseter {
    GObject                   parent;
    QfuDownloadReseterPrivate *priv;
};

struct _QfuDownloadReseterClass {
    GObjectClass parent;
};

GType qfu_download_reseter_get_type (void);
G_DEFINE_AUTOPTR_CLEANUP_FUNC (QfuDownloadReseter, g_object_unref);

QfuDownloadReseter  *qfu_download_reseter_new        (QfuDeviceSelection   *device_selection);
void                 qfu_download_reseter_run        (QfuDownloadReseter   *self,
                                                      GCancellable         *cancellable,
                                                      GAsyncReadyCallback   callback,
                                                      gpointer              user_data);
gboolean             qfu_download_reseter_run_finish (QfuDownloadReseter   *self,
                                                      GAsyncResult         *res,
                                                      GError              **error);

G_END_DECLS

#endif /* QFU_DOWNLOAD_RESETER_H */
