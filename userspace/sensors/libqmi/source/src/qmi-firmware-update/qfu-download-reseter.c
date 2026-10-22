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

#include <config.h>
#include <string.h>

#include <gio/gio.h>

#include <libqmi-glib.h>

#include "qfu-device-selection.h"
#include "qfu-download-reseter.h"
#include "qfu-helpers.h"
#include "qfu-image.h"
#include "qfu-qdl-device.h"
#include "qfu-sahara-device.h"


G_DEFINE_TYPE (QfuDownloadReseter, qfu_download_reseter, G_TYPE_OBJECT)

struct _QfuDownloadReseterPrivate {
    QfuDeviceSelection *device_selection;
};

/******************************************************************************/
/* Run */

typedef struct {
    GFile           *serial_file;
    QfuSaharaDevice *sahara_device;
    QfuQdlDevice    *qdl_device;
} RunContext;

static void
run_context_free (RunContext *ctx)
{
    if (ctx->serial_file)
        g_object_unref (ctx->serial_file);
    if (ctx->sahara_device)
        g_object_unref (ctx->sahara_device);
    if (ctx->qdl_device)
        g_object_unref (ctx->qdl_device);

    g_slice_free (RunContext, ctx);
}

static void
wait_for_cdc_wdm_ready (QfuDeviceSelection *device_selection,
                        GAsyncResult       *res,
                        GTask              *task)
{
    GError *error = NULL;
    GFile  *cdc_wdm_file;
    gchar  *path;

    cdc_wdm_file = qfu_device_selection_wait_for_cdc_wdm_finish (device_selection, res, &error);
    if (!cdc_wdm_file) {
        g_prefix_error (&error, "error waiting for cdc-wdm: ");
        g_task_return_error (task, error);
        g_object_unref (task);
        return;
    }

    path = g_file_get_path (cdc_wdm_file);
    g_debug ("[qfu-download-reseter] cdc-wdm device found: %s", path);
    g_free (path);
    g_object_unref (cdc_wdm_file);

    g_print ("normal mode detected\n");
    g_task_return_boolean (task, TRUE);
    g_object_unref (task);
}

gboolean
qfu_download_reseter_run_finish (QfuDownloadReseter  *self,
                                 GAsyncResult        *res,
                                 GError             **error)
{
    return g_task_propagate_boolean (G_TASK (res), error);
}

void
qfu_download_reseter_run (QfuDownloadReseter  *self,
                          GCancellable        *cancellable,
                          GAsyncReadyCallback  callback,
                          gpointer             user_data)
{
    RunContext *ctx;
    GTask      *task;
    GError     *error = NULL;

    ctx = g_slice_new0 (RunContext);

    task = g_task_new (self, cancellable, callback, user_data);
    g_task_set_task_data (task, ctx, (GDestroyNotify) run_context_free);

    ctx->serial_file = qfu_device_selection_get_single_tty (self->priv->device_selection, QFU_HELPERS_DEVICE_MODE_DOWNLOAD);
    if (!ctx->serial_file) {
        g_task_return_new_error (task, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                                    "No serial device in download mode found to run QDL reset operation");
        g_object_unref (task);
        return;
    }

    /* Check if we can setup a Sahara device. Always check this first, because
     * the sahara stack is very sensitive to any kind of data sent to the port. */
    ctx->sahara_device = qfu_sahara_device_new (ctx->serial_file, g_task_get_cancellable (task), &error);
    if (!ctx->sahara_device) {
        g_debug ("[qfu-download-reseter] sahara device creation failed: %s", error->message);
        g_clear_error (&error);

        /* Check if we can setup a QDL device */
        ctx->qdl_device = qfu_qdl_device_new (ctx->serial_file, g_task_get_cancellable (task), &error);
        if (!ctx->qdl_device) {
            g_debug ("[qfu-download-reseter] qdl device creation failed: %s", error->message);
            g_clear_error (&error);
        }
    }

    if (!ctx->qdl_device && !ctx->sahara_device) {
        g_task_return_new_error (task, G_IO_ERROR, G_IO_ERROR_FAILED, "unsupported download protocol");
        g_object_unref (task);
        return;
    }

    if (ctx->qdl_device) {
        g_debug ("[qfu-download-reseter] QDL reset");
        qfu_qdl_device_reset (ctx->qdl_device, g_task_get_cancellable (task), NULL);
        g_clear_object (&ctx->qdl_device);
    } else if (ctx->sahara_device) {
        g_debug ("[qfu-download-reseter] firehose reset");
        qfu_sahara_device_firehose_reset (ctx->sahara_device, g_task_get_cancellable (task), NULL);
        g_clear_object (&ctx->sahara_device);
    } else
        g_assert_not_reached ();

    g_clear_object (&ctx->serial_file);

    g_print ("rebooting in normal mode...\n");
    g_debug ("[qfu-download-reseter] now waiting for cdc-wdm device...");

    qfu_device_selection_wait_for_cdc_wdm (self->priv->device_selection,
                                           g_task_get_cancellable (task),
                                           (GAsyncReadyCallback) wait_for_cdc_wdm_ready,
                                           task);
}

/******************************************************************************/

QfuDownloadReseter *
qfu_download_reseter_new (QfuDeviceSelection *device_selection)
{
    QfuDownloadReseter *self;

    self = g_object_new (QFU_TYPE_DOWNLOAD_RESETER, NULL);
    self->priv->device_selection = g_object_ref (device_selection);

    return self;
}

static void
qfu_download_reseter_init (QfuDownloadReseter *self)
{
    self->priv = G_TYPE_INSTANCE_GET_PRIVATE (self, QFU_TYPE_DOWNLOAD_RESETER, QfuDownloadReseterPrivate);
}

static void
dispose (GObject *object)
{
    QfuDownloadReseter *self = QFU_DOWNLOAD_RESETER (object);

    g_clear_object (&self->priv->device_selection);

    G_OBJECT_CLASS (qfu_download_reseter_parent_class)->dispose (object);
}

static void
qfu_download_reseter_class_init (QfuDownloadReseterClass *klass)
{
    GObjectClass *object_class = G_OBJECT_CLASS (klass);

    g_type_class_add_private (object_class, sizeof (QfuDownloadReseterPrivate));

    object_class->dispose = dispose;
}
