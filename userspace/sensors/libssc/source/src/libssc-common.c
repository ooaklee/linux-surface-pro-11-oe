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

#include "libssc-common-private.h"

void
ssc_common_dump_protobuf (GArray *protobuf)
{
	GString *str = NULL;
	g_autofree gchar *data = NULL;

	if (protobuf == NULL) {
		g_warning ("Invalid ProtoBuf data!");
		return;
	}

	g_debug ("ProtoBuf data:");
	str = g_string_new ("");
	for (gsize i = 0; i < protobuf->len; i++) {
		guint8 value = g_array_index (protobuf, guint8, i);
		g_string_append_printf (str, "\\x%02x", value); 
	}

	data = g_string_free (str, FALSE);
	g_debug ("%s", data);
}

void
ssc_common_init_sync_context (SyncContext *ctx) {
	g_mutex_init (&ctx->mutex);
	g_cond_init (&ctx->condition);
	ctx->finished = FALSE;
	ctx->result = NULL;
	ctx->object = NULL;
	ctx->context = g_main_context_ref_thread_default ();
}

void
ssc_common_wait_sync_context (SyncContext *ctx) {
	g_mutex_lock (&ctx->mutex);
	while (!ctx->finished) {
		g_mutex_unlock (&ctx->mutex);
		g_main_context_iteration (ctx->context, TRUE);
		g_mutex_lock (&ctx->mutex);
	}
	g_mutex_unlock (&ctx->mutex);
}

void
ssc_common_callback_sync_context (GObject *source, GAsyncResult *result, gpointer user_data)
{
	SyncContext *ctx = user_data;
	(void) source;

	g_mutex_lock (&ctx->mutex);
	ctx->result = g_object_ref (result);
	ctx->finished = TRUE;
	g_cond_signal (&ctx->condition);
	/* Wake before unlocking: the waiter may clear this stack context as
	 * soon as it observes finished. No ctx access is valid after unlock. */
	g_main_context_wakeup (ctx->context);
	g_mutex_unlock (&ctx->mutex);
}

void
ssc_common_clear_sync_context (SyncContext *ctx) {
	g_mutex_clear (&ctx->mutex);
	g_cond_clear (&ctx->condition);
	g_clear_object (&ctx->result);
	g_clear_pointer (&ctx->context, g_main_context_unref);
}
