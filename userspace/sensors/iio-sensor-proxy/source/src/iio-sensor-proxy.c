/*
 * Copyright (c) 2014-2016 Bastien Nocera <hadess@hadess.net>
 *
 * This program is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 3 as published by
 * the Free Software Foundation.
 *
 */

#include "config.h"

#include <locale.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>

#include <glib-unix.h>
#include <gio/gio.h>
#include <gudev/gudev.h>
#include <polkit/polkit.h>
#include "drivers.h"
#include "orientation.h"

#include "iio-sensor-proxy-resources.h"

#define SENSOR_PROXY_DBUS_NAME          "net.hadess.SensorProxy"
#define SENSOR_PROXY_DBUS_PATH          "/net/hadess/SensorProxy"
#define SENSOR_PROXY_COMPASS_DBUS_PATH  "/net/hadess/SensorProxy/Compass"
#define SENSOR_PROXY_IFACE_NAME         SENSOR_PROXY_DBUS_NAME
#define SENSOR_PROXY_COMPASS_IFACE_NAME SENSOR_PROXY_DBUS_NAME ".Compass"

#define NUM_SENSOR_TYPES DRIVER_TYPE_PROXIMITY + 1

/* This is a first-valid-reading budget after successful SSC OPEN, not a
 * transport OPEN timeout. Only the noninstalled Claim fixture overrides it. */
#ifndef SSC_FIRST_READING_TIMEOUT_MSEC
#define SSC_FIRST_READING_TIMEOUT_MSEC 5000
#endif

typedef struct SensorData SensorData;

typedef struct {
	GDBusMethodInvocation *invocation;
	char *sender;
	guint watch_id;
} PendingClaim;

typedef struct {
	guint refs;
	SensorDevice *device; /* Identity only; never dereference after a driver call. */
	GHashTable *clients;
	GHashTable *members;
	GPtrArray *pending;
	gboolean open_started;
	gboolean open_done;
	gboolean open_ok;
	gboolean first_reading;
	gboolean announce;
	GSource *deadline;
	SensorData *data; /* Valid while the owned deadline remains attached. */
	DriverType type;
} SensorStartAttempt;

typedef struct SensorCandidate SensorCandidate;

struct SensorData {
	GMainLoop *loop;
	GUdevClient *client;
	GDBusNodeInfo *introspection_data;
	GDBusConnection *connection;
	guint name_id;
	int ret;

	PolkitAuthority *auth;

	SensorDriver      *drivers[NUM_SENSOR_TYPES];
	SensorDevice      *devices[NUM_SENSOR_TYPES];
	GUdevDevice       *udev_devices[NUM_SENSOR_TYPES];
	GHashTable        *clients[NUM_SENSOR_TYPES]; /* key = D-Bus name, value = watch ID */

	SensorStartAttempt *starts[NUM_SENSOR_TYPES];
	gboolean faulted[NUM_SENSOR_TYPES];
	gboolean shutting_down;
	GPtrArray *candidates; /* Ordered, owned current source revisions. */
	GHashTable *seed_events; /* Paths observed before enumeration completes. */
	gboolean selecting;
	gboolean selection_ready;
	gboolean selection_pending;
	guint selection_idle;
	GPtrArray *selection_starts; /* Borrowed queue owned by the admission pass. */
	guint event_depth;
	guint sigint_id;
	guint sigterm_id;

	/* Accelerometer */
	OrientationUp previous_orientation;
	Tilt          previous_tilt;

	/* Light */
	gdouble previous_level;
	gboolean uses_lux;

	/* Compass */
	gdouble previous_heading;

	/* Proximity */
	gboolean previous_prox_near;
};

static const SensorDriver * const drivers[] = {
	&iio_buffer_accel,
	&iio_poll_accel,
	&input_accel,
	&iio_buffer_light,
	&iio_poll_light,
	&hwmon_light,
	&fake_compass,
	&fake_light,
	&iio_buffer_compass,
	&iio_poll_proximity,
	&input_proximity,
#ifdef HAS_LIBSSC
	&ssc_proximity,
	&ssc_light,
	&ssc_accel,
	&ssc_compass,
#endif
};

struct SensorCandidate {
	guint refs;
	GUdevDevice *source;
	char *path;
	gboolean retired;
	gboolean probing;
	gboolean tried[G_N_ELEMENTS (drivers)];
};

static ReadingsUpdateFunc driver_type_to_callback_func (DriverType type);
static void sensor_state_changed_func (SensorDevice *device, const GError *error, gpointer user_data);
static void select_sensor_candidates (SensorData *data);
static void queue_sensor_selection (SensorData *data);

static const char *
driver_type_to_str (DriverType type)
{
	switch (type) {
	case DRIVER_TYPE_ACCEL:
		return "accelerometer";
	case DRIVER_TYPE_LIGHT:
		return "ambient light sensor";
	case DRIVER_TYPE_COMPASS:
		return "compass";
	case DRIVER_TYPE_PROXIMITY:
		return "proximity";
	default:
		g_assert_not_reached ();
	}
}

#define DRIVER_FOR_TYPE(driver_type) data->drivers[driver_type]
#define DEVICE_FOR_TYPE(driver_type) data->devices[driver_type]
#define UDEV_DEVICE_FOR_TYPE(driver_type) data->udev_devices[driver_type]

static void sensor_changes (GUdevClient *client,
			    gchar       *action,
			    GUdevDevice *device,
			    SensorData  *data);

static gboolean
driver_type_exists (SensorData *data,
		    DriverType  driver_type)
{
	return (DRIVER_FOR_TYPE(driver_type) != NULL);
}

static gboolean
sensor_type_available (SensorData *data, DriverType type)
{
	/* Discovery/lifetime still track the provider. A fault is not physical
	 * removal, but desktop clients must not treat it as a usable sensor. */
	return driver_type_exists (data, type) && !data->faulted[type];
}

static SensorCandidate *
sensor_candidate_ref (SensorCandidate *candidate)
{
	candidate->refs++;
	return candidate;
}

static void
sensor_candidate_unref (gpointer value)
{
	SensorCandidate *candidate = value;
	if (--candidate->refs != 0)
		return;
	g_object_unref (candidate->source);
	g_free (candidate->path);
	g_free (candidate);
}

static gint
sensor_candidate_index (SensorData *data, const char *path)
{
	for (guint i = 0; i < data->candidates->len; i++) {
		SensorCandidate *candidate = g_ptr_array_index (data->candidates, i);
		if (g_strcmp0 (candidate->path, path) == 0)
			return (gint) i;
	}
	return -1;
}

static gboolean
sensor_candidate_is_current (SensorData *data, SensorCandidate *candidate)
{
	gint index;
	if (candidate->retired || data->shutting_down)
		return FALSE;
	index = sensor_candidate_index (data, candidate->path);
	return index >= 0 && g_ptr_array_index (data->candidates, index) == candidate;
}

static void
register_sensor_candidate (SensorData *data, GUdevDevice *source,
			   gboolean carry_inflight_attempts)
{
	const char *path = g_udev_device_get_sysfs_path (source);
	SensorCandidate *candidate;
	gint index;
	if (!path || data->shutting_down)
		return;
	candidate = g_new0 (SensorCandidate, 1);
	candidate->refs = 1;
	candidate->source = g_object_ref (source);
	candidate->path = g_strdup (path);
	index = sensor_candidate_index (data, path);
	if (index >= 0) {
		SensorCandidate *old = g_ptr_array_index (data->candidates, index);
		/* A same-source change dispatched inside admission fences the old
		 * result, but must not create a fresh retry budget for the driver's
		 * own side effects. Carry every attempted pair, not just the last.
		 * A later event outside admission, or a new add, starts a fresh wave. */
		if (carry_inflight_attempts && old->probing) {
			memcpy (candidate->tried, old->tried, sizeof (candidate->tried));
			candidate->probing = TRUE;
		}
		old->retired = TRUE;
		g_ptr_array_index (data->candidates, index) = candidate;
		sensor_candidate_unref (old);
	} else {
		g_ptr_array_add (data->candidates, candidate);
	}
}

static gboolean
retire_sensor_candidate (SensorData *data, const char *path)
{
	gint index = sensor_candidate_index (data, path);
	if (index < 0)
		return FALSE;
	((SensorCandidate *) g_ptr_array_index (data->candidates, index))->retired = TRUE;
	g_ptr_array_remove_index (data->candidates, index);
	return TRUE;
}

static void
seed_sensor_candidates (GUdevClient *client, SensorData *data)
{
	GList *devices, *input, *platform, *l;

	devices = g_udev_client_query_by_subsystem (client, "iio");
	input = g_udev_client_query_by_subsystem (client, "input");
	platform = g_udev_client_query_by_subsystem (client, "platform");
	devices = g_list_concat (devices, input);
	devices = g_list_concat (devices, platform);
#ifdef HAS_LIBSSC
	GList *fastrpc;
	fastrpc = g_udev_client_query_by_subsystem (client, "misc");
	devices = g_list_concat (devices, fastrpc);
#endif

	/* Register the whole enumeration before any discover/open can dispatch
	 * events. Queued sources, not only the currently probed one, have an
	 * owned identity which a nested remove/change can retire. */
	for (l = devices; l != NULL; l = l->next) {
		GUdevDevice *dev = l->data;
		const char *path = g_udev_device_get_sysfs_path (dev);
		/* An observed remove must win over a retained enumeration result,
		 * even if the path had not yet been registered when it arrived. */
		if (path && sensor_candidate_index (data, path) < 0 &&
		    (!data->seed_events || !g_hash_table_contains (data->seed_events, path)))
			register_sensor_candidate (data, dev, FALSE);
	}

	g_list_free_full (devices, g_object_unref);
}

static void
free_client_watch (gpointer data)
{
	guint watch_id = GPOINTER_TO_UINT (data);

	if (watch_id == 0)
		return;
	g_bus_unwatch_name (watch_id);
}

static GHashTable *
create_clients_hash_table (void)
{
	return g_hash_table_new_full (g_str_hash, g_str_equal,
				      g_free, free_client_watch);
}

typedef enum {
	PROP_HAS_ACCELEROMETER		= 1 << 0,
	PROP_ACCELEROMETER_ORIENTATION  = 1 << 1,
	PROP_HAS_AMBIENT_LIGHT		= 1 << 2,
	PROP_LIGHT_LEVEL		= 1 << 3,
	PROP_HAS_COMPASS                = 1 << 4,
	PROP_COMPASS_HEADING            = 1 << 5,
	PROP_HAS_PROXIMITY              = 1 << 6,
	PROP_PROXIMITY_NEAR             = 1 << 7,
	PROP_ACCELEROMETER_TILT         = 1 << 8,
} PropertiesMask;

#define PROP_ALL (PROP_HAS_ACCELEROMETER | \
                  PROP_ACCELEROMETER_ORIENTATION | \
                  PROP_HAS_AMBIENT_LIGHT | \
                  PROP_LIGHT_LEVEL | \
                  PROP_HAS_PROXIMITY | \
		  PROP_PROXIMITY_NEAR | \
                  PROP_ACCELEROMETER_TILT)
#define PROP_ALL_COMPASS (PROP_HAS_COMPASS | \
			  PROP_COMPASS_HEADING)

static PropertiesMask
mask_for_sensor_type (DriverType sensor_type)
{
	switch (sensor_type) {
	case DRIVER_TYPE_ACCEL:
		return PROP_HAS_ACCELEROMETER |
			PROP_ACCELEROMETER_ORIENTATION |
			PROP_ACCELEROMETER_TILT;
	case DRIVER_TYPE_LIGHT:
		return PROP_HAS_AMBIENT_LIGHT |
			PROP_LIGHT_LEVEL;
	case DRIVER_TYPE_COMPASS:
		return PROP_HAS_COMPASS |
			PROP_COMPASS_HEADING;
	case DRIVER_TYPE_PROXIMITY:
		return PROP_HAS_PROXIMITY |
			PROP_PROXIMITY_NEAR;
	default:
		g_assert_not_reached ();
	}
}

static void
send_dbus_event_for_client (SensorData     *data,
			    const char     *destination_bus_name,
			    PropertiesMask  mask)
{
	GVariantBuilder props_builder;
	GVariant *props_changed = NULL;

	g_return_if_fail (destination_bus_name != NULL);

	g_variant_builder_init (&props_builder, G_VARIANT_TYPE ("a{sv}"));

	if (mask & PROP_HAS_ACCELEROMETER) {
		gboolean has_accel;

		has_accel = sensor_type_available (data, DRIVER_TYPE_ACCEL);
		g_variant_builder_add (&props_builder, "{sv}", "HasAccelerometer",
				       g_variant_new_boolean (has_accel));

		/* Send the orientation when the device appears */
		if (has_accel) {
			mask |= PROP_ACCELEROMETER_ORIENTATION;
			mask |= PROP_ACCELEROMETER_TILT;
                } else {
			data->previous_orientation = ORIENTATION_UNDEFINED;
			data->previous_tilt = TILT_UNDEFINED;
		}
	}

	if (mask & PROP_ACCELEROMETER_ORIENTATION) {
		g_variant_builder_add (&props_builder, "{sv}", "AccelerometerOrientation",
				       g_variant_new_string (orientation_to_string (data->previous_orientation)));
	}

	if (mask & PROP_ACCELEROMETER_TILT) {
		g_variant_builder_add (&props_builder, "{sv}", "AccelerometerTilt",
				       g_variant_new_string (tilt_to_string (data->previous_tilt)));
	}

	if (mask & PROP_HAS_AMBIENT_LIGHT) {
		gboolean has_als;

		has_als = sensor_type_available (data, DRIVER_TYPE_LIGHT);
		g_variant_builder_add (&props_builder, "{sv}", "HasAmbientLight",
				       g_variant_new_boolean (has_als));

		/* Send the light level when the device appears */
		if (has_als)
			mask |= PROP_LIGHT_LEVEL;
	}

	if (mask & PROP_LIGHT_LEVEL) {
		g_variant_builder_add (&props_builder, "{sv}", "LightLevelUnit",
				       g_variant_new_string (data->uses_lux ? "lux" : "vendor"));
		g_variant_builder_add (&props_builder, "{sv}", "LightLevel",
				       g_variant_new_double (data->previous_level));
	}

	if (mask & PROP_HAS_COMPASS) {
		gboolean has_compass;

		has_compass = sensor_type_available (data, DRIVER_TYPE_COMPASS);
		g_variant_builder_add (&props_builder, "{sv}", "HasCompass",
				       g_variant_new_boolean (has_compass));

		/* Send the heading when the device appears */
		if (has_compass)
			mask |= PROP_COMPASS_HEADING;
	}

	if (mask & PROP_COMPASS_HEADING) {
		g_variant_builder_add (&props_builder, "{sv}", "CompassHeading",
				       g_variant_new_double (data->previous_heading));
	}

	if (mask & PROP_HAS_PROXIMITY) {
		gboolean has_proximity;

		has_proximity = sensor_type_available (data, DRIVER_TYPE_PROXIMITY);
		g_variant_builder_add (&props_builder, "{sv}", "HasProximity",
				       g_variant_new_boolean (has_proximity));

		/* Send proximity information when the device appears */
		if (has_proximity)
			mask |= PROP_PROXIMITY_NEAR;
	}

	if (mask & PROP_PROXIMITY_NEAR) {
		g_variant_builder_add (&props_builder, "{sv}", "ProximityNear",
				       g_variant_new_boolean (data->previous_prox_near));
	}

	props_changed = g_variant_new ("(s@a{sv}@as)", (mask & PROP_ALL) ? SENSOR_PROXY_IFACE_NAME : SENSOR_PROXY_COMPASS_IFACE_NAME,
				       g_variant_builder_end (&props_builder),
				       g_variant_new_strv (NULL, 0));

	g_dbus_connection_emit_signal (data->connection,
				       destination_bus_name,
				       (mask & PROP_ALL) ? SENSOR_PROXY_DBUS_PATH : SENSOR_PROXY_COMPASS_DBUS_PATH,
				       "org.freedesktop.DBus.Properties",
				       "PropertiesChanged",
				       props_changed, NULL);
}

static void
send_dbus_event (SensorData     *data,
		 PropertiesMask  mask)
{
	GHashTable *ht;
	guint i;
	GHashTableIter iter;
	gpointer key, value;

	g_assert (mask != 0);
	g_assert (data->connection);
	g_assert ((mask & PROP_ALL) == 0 || (mask & PROP_ALL_COMPASS) == 0);

	/* Make a list of the events each client for each sensor
	 * is interested in */
	ht = g_hash_table_new (g_str_hash, g_str_equal);
	for (i = 0; i < NUM_SENSOR_TYPES; i++) {
		GList *clients, *l;

		clients = g_hash_table_get_keys (data->clients[i]);
		for (l = clients; l != NULL; l = l->next) {
			PropertiesMask m, new_mask;

			/* Already have a mask? */
			m = GPOINTER_TO_UINT (g_hash_table_lookup (ht, l->data));
			new_mask = mask & mask_for_sensor_type (i);
			m |= new_mask;
			g_hash_table_insert (ht, l->data, GUINT_TO_POINTER (m));
		}
		/* The keys remain owned by the client table; only this temporary
		 * list of borrowed pointers belongs to the enumeration caller. */
		g_list_free (clients);
	}

	g_hash_table_iter_init (&iter, ht);
	while (g_hash_table_iter_next (&iter, &key, &value))
		send_dbus_event_for_client (data, (const char *) key, GPOINTER_TO_UINT (value));
	g_hash_table_destroy (ht);
}

static void
send_driver_changed_dbus_event (SensorData   *data,
				DriverType    driver_type)
{
	const char *property;
	const char *interface;
	const char *path;
	PropertiesMask readings_mask;
	GVariantBuilder props_builder;
	gboolean available;

	switch (driver_type) {
	case DRIVER_TYPE_ACCEL:
		property = "HasAccelerometer";
		readings_mask = PROP_ACCELEROMETER_ORIENTATION | PROP_ACCELEROMETER_TILT;
		break;
	case DRIVER_TYPE_LIGHT:
		property = "HasAmbientLight";
		readings_mask = PROP_LIGHT_LEVEL;
		break;
	case DRIVER_TYPE_PROXIMITY:
		property = "HasProximity";
		readings_mask = PROP_PROXIMITY_NEAR;
		break;
	case DRIVER_TYPE_COMPASS:
		property = "HasCompass";
		readings_mask = PROP_COMPASS_HEADING;
		break;
	default:
		g_assert_not_reached ();
	}

	available = sensor_type_available (data, driver_type);
	if (!available && driver_type == DRIVER_TYPE_ACCEL) {
		data->previous_orientation = ORIENTATION_UNDEFINED;
		data->previous_tilt = TILT_UNDEFINED;
	}

	interface = driver_type == DRIVER_TYPE_COMPASS ? SENSOR_PROXY_COMPASS_IFACE_NAME : SENSOR_PROXY_IFACE_NAME;
	path = driver_type == DRIVER_TYPE_COMPASS ? SENSOR_PROXY_COMPASS_DBUS_PATH : SENSOR_PROXY_DBUS_PATH;

	/* Availability must reach observers which have not claimed the sensor yet,
	 * including after removal has discarded its client table. Never broadcast
	 * readings: those remain subject to the per-sensor claim below. */
	g_variant_builder_init (&props_builder, G_VARIANT_TYPE ("a{sv}"));
	g_variant_builder_add (&props_builder, "{sv}", property,
			       g_variant_new_boolean (available));
	g_dbus_connection_emit_signal (data->connection, NULL, path,
				       "org.freedesktop.DBus.Properties", "PropertiesChanged",
				       g_variant_new ("(s@a{sv}@as)", interface,
						      g_variant_builder_end (&props_builder),
						      g_variant_new_strv (NULL, 0)), NULL);

	/* Keep the initial reading refresh for existing claimants. The caller still
	 * delays hotplug notification until its first reading when already claimed. */
	if (available && (!data->starts[driver_type] || data->starts[driver_type]->first_reading))
		send_dbus_event (data, readings_mask);
}

static gboolean
any_sensors_left (SensorData *data)
{
	guint i;
	gboolean exists = FALSE;

	for (i = 0; i < NUM_SENSOR_TYPES; i++) {
		if (driver_type_exists (data, i)) {
			exists = TRUE;
			break;
		}
	}

	return exists;
}

static void
pending_claim_free (gpointer value)
{
	PendingClaim *claim = value;

	if (claim->invocation)
		g_dbus_method_invocation_return_error (claim->invocation, G_DBUS_ERROR,
			G_DBUS_ERROR_FAILED, "Sensor start was cancelled");
	g_free (claim->sender);
	g_free (claim);
}

static SensorStartAttempt *
start_attempt_ref (SensorStartAttempt *attempt)
{
	attempt->refs++;
	return attempt;
}

static void
start_attempt_unref (SensorStartAttempt *attempt)
{
	if (!attempt || --attempt->refs != 0)
		return;
	g_assert (attempt->deadline == NULL);
	g_ptr_array_unref (attempt->pending);
	g_hash_table_unref (attempt->members);
	g_hash_table_unref (attempt->clients);
	g_free (attempt);
}

static void
start_attempt_cancel_deadline (SensorStartAttempt *attempt)
{
	GSource *source = g_steal_pointer (&attempt->deadline);
	if (source) {
		g_source_destroy (source);
		g_source_unref (source);
	}
}

static gboolean
start_attempt_is_current (SensorData *data, DriverType type, SensorStartAttempt *attempt)
{
	return data->starts[type] == attempt && DEVICE_FOR_TYPE(type) == attempt->device &&
		data->clients[type] == attempt->clients;
}

static void
start_attempt_add_claim (SensorStartAttempt *attempt, const char *sender,
			guint watch_id, GDBusMethodInvocation *invocation)
{
	PendingClaim *claim = g_new0 (PendingClaim, 1);

	claim->invocation = invocation;
	claim->sender = g_strdup (sender);
	claim->watch_id = watch_id;
	g_hash_table_replace (attempt->members, g_strdup (sender), GUINT_TO_POINTER (watch_id));
	g_ptr_array_add (attempt->pending, claim);
}

static void
start_attempt_reply (SensorStartAttempt *attempt, const char *failure)
{
	guint i;

	for (i = 0; i < attempt->pending->len; i++) {
		PendingClaim *claim = g_ptr_array_index (attempt->pending, i);
		GDBusMethodInvocation *invocation = g_steal_pointer (&claim->invocation);

		if (!invocation)
			continue;
		if (failure)
			g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
				G_DBUS_ERROR_FAILED, "%s", failure);
		else
			g_dbus_method_invocation_return_value (invocation, NULL);
	}
}

static void
start_attempt_remove_members (SensorStartAttempt *attempt)
{
	GHashTableIter iter;
	gpointer key, value;

	g_hash_table_iter_init (&iter, attempt->members);
	while (g_hash_table_iter_next (&iter, &key, &value)) {
		if (g_hash_table_lookup (attempt->clients, key) == value)
			g_hash_table_remove (attempt->clients, key);
	}
}

static void
finish_start_attempt (SensorData *data, DriverType type,
		      SensorStartAttempt *attempt, const char *failure)
{
	if (!start_attempt_is_current (data, type, attempt))
		return;
	if (!failure && (!attempt->open_done || !attempt->open_ok || !attempt->first_reading))
		return;

	/* Detach before replies/cleanup. A returning older OPEN cannot consume
	 * claims belonging to a subsequent start, even at the same device address. */
	data->starts[type] = NULL;
	start_attempt_cancel_deadline (attempt);
	if (failure)
		start_attempt_remove_members (attempt);
	start_attempt_reply (attempt, failure);
	if (attempt->announce && !data->shutting_down)
		send_driver_changed_dbus_event (data, type);
	start_attempt_unref (attempt); /* data->starts ownership */
}

static void
cancel_start_attempt (SensorData *data, DriverType type, const char *failure)
{
	SensorStartAttempt *attempt = data->starts[type];

	if (attempt)
		finish_start_attempt (data, type, attempt, failure);
}

static void
sensor_state_changed_func (SensorDevice *device, const GError *error, gpointer user_data)
{
	SensorData *data = user_data;
	guint type;

	if (!device || data->shutting_down)
		return;
	/* Do not dereference a potentially detached identity. A notification may
	 * arrive while a synchronous operation dispatches removal/replacement. */
	for (type = 0; type < NUM_SENSOR_TYPES; type++) {
		if (DEVICE_FOR_TYPE(type) == device)
			break;
	}
	if (type == NUM_SENSOR_TYPES || !driver_type_exists (data, type))
		return;
	if (error) {
		g_warning ("Sensor stream failure for %s: %s", driver_type_to_str (type), error->message);
		if (data->faulted[type])
			return;
		data->faulted[type] = TRUE;
		if (data->starts[type])
			data->starts[type]->announce = FALSE;
		cancel_start_attempt (data, type, error->message);
		/* Never call client_release/STOP here. The adapter owns deferred
		 * exact-sensor CLOSE recovery, outside the native error callback. */
		g_hash_table_remove_all (data->clients[type]);
		send_driver_changed_dbus_event (data, type);
	} else if (data->faulted[type]) {
		/* NULL means required CLOSE succeeded, not that a stream is healthy.
		 * Only a new Claim may authorize another OPEN and fresh reading. */
		data->faulted[type] = FALSE;
		send_driver_changed_dbus_event (data, type);
	}
}

static gboolean
first_reading_deadline (gpointer value)
{
	SensorStartAttempt *attempt = value; /* Exact attempt retained by source. */
	SensorData *data = attempt->data;
	DriverType type = attempt->type;
	GSource *source = g_steal_pointer (&attempt->deadline);
	g_autoptr(GError) error = NULL;
	SensorDevice *device;

	if (source)
		g_source_unref (source);
	if (data->shutting_down || !start_attempt_is_current (data, type, attempt) ||
	    !attempt->open_done || !attempt->open_ok || attempt->first_reading)
		return G_SOURCE_REMOVE;
	device = DEVICE_FOR_TYPE(type);
	error = g_error_new_literal (G_IO_ERROR, G_IO_ERROR_TIMED_OUT,
		"SSC first valid reading deadline expired");
	/* The optional hook retains its exact native sensor, revokes delivery,
	 * notifies/fails Claims, then schedules CLOSE outside this callback. It
	 * may detach/free device or data; do not dereference either afterwards. */
	device->drv->startup_failed (device, error);
	return G_SOURCE_REMOVE;
}

static void
start_attempt_arm_deadline (SensorData *data, DriverType type, SensorStartAttempt *attempt)
{
	if (!start_attempt_is_current (data, type, attempt) || !attempt->open_ok ||
	    attempt->first_reading || !DEVICE_FOR_TYPE(type)->drv->startup_failed)
		return;
	attempt->data = data;
	attempt->type = type;
	attempt->deadline = g_timeout_source_new (SSC_FIRST_READING_TIMEOUT_MSEC);
	g_source_set_callback (attempt->deadline, first_reading_deadline,
		start_attempt_ref (attempt), (GDestroyNotify) start_attempt_unref);
	/* Same owner context as the SSC adapter; no dependency on the later
	 * main-loop assignment during startup. Dispatch is not a realtime bound. */
	g_source_attach (attempt->deadline, g_main_context_get_thread_default ());
}

static SensorStartAttempt *
prepare_start_attempt (SensorData *data, DriverType type, gboolean announce,
		       const char *sender, guint watch_id, GDBusMethodInvocation *invocation)
{
	SensorStartAttempt *attempt = g_new0 (SensorStartAttempt, 1);
	GHashTableIter iter;
	gpointer key, value;

	g_assert (data->starts[type] == NULL);
	attempt->refs = 1; /* local ownership survives a nested removal */
	attempt->data = data;
	attempt->type = type;
	attempt->device = DEVICE_FOR_TYPE(type);
	attempt->clients = g_hash_table_ref (data->clients[type]);
	attempt->members = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
	attempt->pending = g_ptr_array_new_with_free_func (pending_claim_free);
	attempt->announce = announce;
	g_hash_table_iter_init (&iter, attempt->clients);
	while (g_hash_table_iter_next (&iter, &key, &value))
		g_hash_table_insert (attempt->members, g_strdup (key), value);
	if (invocation)
		start_attempt_add_claim (attempt, sender, watch_id, invocation);
	data->starts[type] = start_attempt_ref (attempt);
	return attempt;
}

static void
execute_start_attempt (SensorData *data, SensorStartAttempt *attempt)
{
	DriverType type = attempt->type;
	g_autoptr(GError) error = NULL;
	gboolean success;

	/* A prepared token, not a device address, authorizes activation. A nested
	 * removal/Release may have canceled it before the admission pass ended. */
	if (data->shutting_down || !start_attempt_is_current (data, type, attempt) ||
	    attempt->open_started)
		return;
	g_assert (!data->selecting);
	attempt->open_started = TRUE;

	success = driver_set_polling_full (attempt->device, TRUE, &error);
	/* Only token identity authorizes post-call state access. The driver/device
	 * may have disappeared while its synchronous operation dispatched events. */
	if (start_attempt_is_current (data, type, attempt)) {
		attempt->open_done = TRUE;
		attempt->open_ok = success;
		finish_start_attempt (data, type, attempt,
			success ? NULL : error ? error->message : "Sensor could not be started");
		if (success)
			start_attempt_arm_deadline (data, type, attempt);
	}
}

static void
start_sensor (SensorData *data, DriverType type, gboolean announce,
	      const char *sender, guint watch_id, GDBusMethodInvocation *invocation)
{
	SensorStartAttempt *attempt = prepare_start_attempt (data, type, announce,
		sender, watch_id, invocation);

	if (data->selecting) {
		/* This includes Claims dispatched by another constructor's nested
		 * context. They join a current token immediately, but OPEN must not
		 * hold the admission barrier while waiting on the native provider. */
		g_assert (data->selection_starts != NULL);
		g_ptr_array_add (data->selection_starts, attempt);
		return;
	}
	execute_start_attempt (data, attempt);
	start_attempt_unref (attempt);
}

static gboolean
sensor_selection_idle (gpointer value)
{
	SensorData *data = value;
	data->selection_idle = 0;
	/* Consume a busy idle rather than spinning it inside a native nested
	 * main-context wait. The outer epilogue owns the next scheduling chance. */
	if (!data->selecting && data->event_depth == 0)
		select_sensor_candidates (data);
	return G_SOURCE_REMOVE;
}

static void
queue_sensor_selection (SensorData *data)
{
	if (data->shutting_down)
		return;
	data->selection_pending = TRUE;
	if (data->selection_ready && !data->selecting && data->event_depth == 0 &&
	    data->selection_idle == 0)
		data->selection_idle = g_idle_add (sensor_selection_idle, data);
}

static void
select_sensor_candidates (SensorData *data)
{
	g_autoptr(GPtrArray) snapshot = NULL;
	g_autoptr(GPtrArray) prepared = NULL;
	if (data->shutting_down || !data->selection_ready)
		return;
	if (data->selecting || data->event_depth != 0) {
		data->selection_pending = TRUE;
		return;
	}
	data->selecting = TRUE;
	data->selection_pending = FALSE;
	g_assert (data->selection_starts == NULL);
	prepared = g_ptr_array_new_with_free_func ((GDestroyNotify) start_attempt_unref);
	data->selection_starts = prepared;
	snapshot = g_ptr_array_new_with_free_func (sensor_candidate_unref);
	for (guint i = 0; i < data->candidates->len; i++)
		g_ptr_array_add (snapshot, sensor_candidate_ref (g_ptr_array_index (data->candidates, i)));
	for (guint n = 0; n < snapshot->len && !data->shutting_down; n++) {
		SensorCandidate *candidate = g_ptr_array_index (snapshot, n);
		if (!sensor_candidate_is_current (data, candidate))
			continue;
		candidate->probing = TRUE;
		for (guint i = 0; i < G_N_ELEMENTS (drivers); i++) {
			SensorDriver *driver = (SensorDriver *) drivers[i];
			SensorDevice *device;
			gboolean found;
			if (!sensor_candidate_is_current (data, candidate))
				break;
			/* Skipped alternates remain eligible if a winner is removed.
			 * A known faulted provider is still owned and keeps its explicit
			 * Claim/CLOSE recovery policy, not an automatic retry loop. */
			if (driver_type_exists (data, driver->type) || candidate->tried[i])
				continue;
			candidate->tried[i] = TRUE;
			found = driver_discover (driver, candidate->source);
			if (!sensor_candidate_is_current (data, candidate))
				break;
			if (!found || driver_type_exists (data, driver->type))
				continue;
			g_debug ("Trying device %s of type %s at %s", candidate->path,
				driver_type_to_str (driver->type), driver->driver_name);
			device = driver_open (driver, candidate->source,
				driver_type_to_callback_func (driver->type), data);
			if (!sensor_candidate_is_current (data, candidate) ||
			    driver_type_exists (data, driver->type)) {
				if (device)
					driver_close (device);
				continue;
			}
			if (!device)
				continue;
			/* No unopened reservation is observable. There is no callback
			 * between these assignments; admission publishes one complete slot. */
			device->state_callback = sensor_state_changed_func;
			UDEV_DEVICE_FOR_TYPE(driver->type) = g_object_ref (candidate->source);
			DEVICE_FOR_TYPE(driver->type) = device;
			DRIVER_FOR_TYPE(driver->type) = driver;
			data->faulted[driver->type] = FALSE;
			g_assert (data->starts[driver->type] == NULL);
			if (g_hash_table_size (data->clients[driver->type]) > 0)
				start_sensor (data, driver->type, TRUE, NULL, 0, NULL);
			else
				send_driver_changed_dbus_event (data, driver->type);
		}
		candidate->probing = FALSE;
		/* Metadata-only replacements inherit the admission-wave budget.
		 * End that wave even if the original snapshot has been retired. */
		gint index = sensor_candidate_index (data, candidate->path);
		if (index >= 0)
			((SensorCandidate *) g_ptr_array_index (data->candidates, index))->probing = FALSE;
	}
	data->selection_starts = NULL;
	data->selecting = FALSE;
	if (data->shutting_down)
		return;
	/* Publish all complete slots before any stream activation. An OPEN may
	 * dispatch remove/add and admit a replacement while the old call waits;
	 * owned attempt tokens prevent stale activation and allocator-address ABA. */
	if (data->selection_pending)
		queue_sensor_selection (data);
	for (guint i = 0; i < prepared->len && !data->shutting_down; i++)
		execute_start_attempt (data, g_ptr_array_index (prepared, i));
	if (data->shutting_down)
		return;
	if (data->selection_pending) {
		queue_sensor_selection (data);
	} else if (!any_sensors_left (data)) {
		data->ret = 0;
		g_message ("No sensors or missing kernel drivers for the sensors. Exiting");
		g_main_loop_quit (data->loop);
	}
}

static void
client_release (SensorData            *data,
		const char            *sender,
		DriverType             driver_type)
{
	GHashTable *ht;
	guint watch_id;
	if (data->shutting_down)
		return;

	ht = data->clients[driver_type];

	watch_id = GPOINTER_TO_UINT (g_hash_table_lookup (ht, sender));
	if (watch_id == 0) {
		g_debug ("Sender '%s' already released device, no-op", sender);
		return;
	}

	g_hash_table_remove (ht, sender);
	if (data->starts[driver_type]) {
		SensorStartAttempt *attempt = data->starts[driver_type];
		guint i;

		for (i = 0; i < attempt->pending->len; i++) {
			PendingClaim *claim = g_ptr_array_index (attempt->pending, i);
			if (claim->watch_id == watch_id && g_str_equal (claim->sender, sender) && claim->invocation) {
				GDBusMethodInvocation *invocation = g_steal_pointer (&claim->invocation);
				g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
					G_DBUS_ERROR_FAILED, "Sensor claim was released while starting");
			}
		}
	}

	if (driver_type_exists (data, driver_type) && DEVICE_FOR_TYPE(driver_type) &&
	    g_hash_table_size (ht) == 0) {
		SensorDevice *sensor_device = DEVICE_FOR_TYPE(driver_type);
		gboolean stop = !data->starts[driver_type] || data->starts[driver_type]->open_started;
		cancel_start_attempt (data, driver_type, "Sensor start has no remaining clients");
		if (stop)
			driver_set_polling (sensor_device, FALSE);
	}
}

static void
client_vanished_cb (GDBusConnection *connection,
		    const gchar     *name,
		    gpointer         user_data)
{
	SensorData *data = user_data;
	guint i;
	char *sender;

	if (name == NULL || data->shutting_down)
		return;

	sender = g_strdup (name);

	for (i = 0; i < NUM_SENSOR_TYPES; i++) {
		GHashTable *ht;
		guint watch_id;

		ht = data->clients[i];
		g_assert (ht);

		watch_id = GPOINTER_TO_UINT (g_hash_table_lookup (ht, sender));
		if (watch_id > 0)
			client_release (data, sender, i);
	}

	g_free (sender);
}

static gboolean
check_claim_permission (SensorData   *data,
			const char   *sender,
			GError      **error)
{
	g_autoptr(GError) local_error = NULL;
	g_autoptr(PolkitAuthorizationResult) result = NULL;
	g_autoptr(PolkitSubject) subject = NULL;

	subject = polkit_system_bus_name_new (sender);
	result = polkit_authority_check_authorization_sync (data->auth,
							    subject,
							    "net.hadess.SensorProxy.claim-sensor",
							    NULL,
							    POLKIT_CHECK_AUTHORIZATION_FLAGS_NONE,
							    NULL, &local_error);
	if (result == NULL ||
	    !polkit_authorization_result_get_is_authorized (result))
	{
		g_set_error (error, G_DBUS_ERROR,
			     G_DBUS_ERROR_ACCESS_DENIED,
			     "Not Authorized: %s", local_error ? local_error->message : "Sensor claim not allowed");
		return FALSE;
	}

	return TRUE;
}

static void
handle_generic_method_call (SensorData            *data,
			    const gchar           *sender,
			    const gchar           *object_path,
			    const gchar           *interface_name,
			    const gchar           *method_name,
			    GVariant              *parameters,
			    GDBusMethodInvocation *invocation,
			    DriverType             driver_type)
{
	GHashTable *ht;
	guint watch_id;

	g_debug ("Handling driver refcounting method '%s' for %s device",
		 method_name, driver_type_to_str (driver_type));

	ht = data->clients[driver_type];
	if (data->shutting_down) {
		g_dbus_method_invocation_return_error (invocation, G_DBUS_ERROR,
			G_DBUS_ERROR_FAILED, "Sensor proxy is shutting down");
		return;
	}

	if (g_str_has_prefix (method_name, "Claim")) {
		watch_id = GPOINTER_TO_UINT (g_hash_table_lookup (ht, sender));
		if (watch_id > 0) {
			if (data->starts[driver_type]) {
				start_attempt_add_claim (data->starts[driver_type], sender, watch_id, invocation);
				return;
			}
			g_debug ("Sender '%s' already claimed device, no-op", sender);
			g_dbus_method_invocation_return_value (invocation, NULL);
			return;
		}

		watch_id = g_bus_watch_name_on_connection (data->connection,
							   sender,
							   G_BUS_NAME_WATCHER_FLAGS_NONE,
							   NULL,
							   client_vanished_cb,
							   data,
							   NULL);
		g_hash_table_insert (ht, g_strdup (sender), GUINT_TO_POINTER (watch_id));

		if (driver_type_exists (data, driver_type) && DEVICE_FOR_TYPE(driver_type)) {
			/* No other clients for this sensor? Start it */
			if (g_hash_table_size (ht) == 1) {
				start_sensor (data, driver_type, FALSE, sender, watch_id, invocation);
			} else if (data->starts[driver_type]) {
				start_attempt_add_claim (data->starts[driver_type], sender, watch_id, invocation);
			} else {
				/* Client added while sensor is active already, can return the
				 * invocation immediately. */
				g_dbus_method_invocation_return_value (invocation, NULL);
			}
		} else {
			g_dbus_method_invocation_return_value (invocation, NULL);
		}
	} else if (g_str_has_prefix (method_name, "Release")) {
		client_release (data, sender, driver_type);
		g_dbus_method_invocation_return_value (invocation, NULL);
	}
}

static void
handle_method_call (GDBusConnection       *connection,
		    const gchar           *sender,
		    const gchar           *object_path,
		    const gchar           *interface_name,
		    const gchar           *method_name,
		    GVariant              *parameters,
		    GDBusMethodInvocation *invocation,
		    gpointer               user_data)
{
	SensorData *data = user_data;
	DriverType driver_type;
	g_autoptr(GError) error = NULL;

	if (g_strcmp0 (method_name, "ClaimAccelerometer") == 0 ||
	    g_strcmp0 (method_name, "ReleaseAccelerometer") == 0)
		driver_type = DRIVER_TYPE_ACCEL;
	else if (g_strcmp0 (method_name, "ClaimLight") == 0 ||
		 g_strcmp0 (method_name, "ReleaseLight") == 0)
		driver_type = DRIVER_TYPE_LIGHT;
	else if (g_strcmp0 (method_name, "ClaimProximity") == 0 ||
		 g_strcmp0 (method_name, "ReleaseProximity") == 0)
	        driver_type = DRIVER_TYPE_PROXIMITY;
	else {
		g_dbus_method_invocation_return_error (invocation,
						       G_DBUS_ERROR,
						       G_DBUS_ERROR_UNKNOWN_METHOD,
						       "Method '%s' does not exist on object %s",
						       method_name, object_path);
		return;
	}

	if (!check_claim_permission (data, sender, &error)) {
		g_dbus_method_invocation_return_gerror (invocation, error);
		return;
	}

	handle_generic_method_call (data, sender, object_path,
				    interface_name, method_name,
				    parameters, invocation, driver_type);
}

static GVariant *
handle_get_property (GDBusConnection *connection,
		     const gchar     *sender,
		     const gchar     *object_path,
		     const gchar     *interface_name,
		     const gchar     *property_name,
		     GError         **error,
		     gpointer         user_data)
{
	SensorData *data = user_data;

	g_assert (data->connection);

	if (g_strcmp0 (property_name, "HasAccelerometer") == 0)
		return g_variant_new_boolean (sensor_type_available (data, DRIVER_TYPE_ACCEL));
	if (g_strcmp0 (property_name, "AccelerometerOrientation") == 0)
		return g_variant_new_string (orientation_to_string (data->previous_orientation));
	if (g_strcmp0 (property_name, "AccelerometerTilt") == 0)
		return g_variant_new_string (tilt_to_string (data->previous_tilt));
	if (g_strcmp0 (property_name, "HasAmbientLight") == 0)
		return g_variant_new_boolean (sensor_type_available (data, DRIVER_TYPE_LIGHT));
	if (g_strcmp0 (property_name, "LightLevelUnit") == 0)
		return g_variant_new_string (data->uses_lux ? "lux" : "vendor");
	if (g_strcmp0 (property_name, "LightLevel") == 0)
		return g_variant_new_double (data->previous_level);
	if (g_strcmp0 (property_name, "HasProximity") == 0)
		return g_variant_new_boolean (sensor_type_available (data, DRIVER_TYPE_PROXIMITY));
	if (g_strcmp0 (property_name, "ProximityNear") == 0)
		return g_variant_new_boolean (data->previous_prox_near);

	return NULL;
}

static const GDBusInterfaceVTable interface_vtable =
{
	handle_method_call,
	handle_get_property,
	NULL
};

static void
handle_compass_method_call (GDBusConnection       *connection,
			    const gchar           *sender,
			    const gchar           *object_path,
			    const gchar           *interface_name,
			    const gchar           *method_name,
			    GVariant              *parameters,
			    GDBusMethodInvocation *invocation,
			    gpointer               user_data)
{
	SensorData *data = user_data;
	g_autoptr(GError) error = NULL;

	if (g_strcmp0 (method_name, "ClaimCompass") != 0 &&
	    g_strcmp0 (method_name, "ReleaseCompass") != 0) {
		g_dbus_method_invocation_return_error (invocation,
						       G_DBUS_ERROR,
						       G_DBUS_ERROR_UNKNOWN_METHOD,
						       "Method '%s' does not exist on object %s",
						       method_name, object_path);
		return;
	}

	if (!check_claim_permission (data, sender, &error)) {
		g_dbus_method_invocation_return_gerror (invocation, error);
		return;
	}

	handle_generic_method_call (data, sender, object_path,
				    interface_name, method_name,
				    parameters, invocation, DRIVER_TYPE_COMPASS);
}

static GVariant *
handle_compass_get_property (GDBusConnection *connection,
			     const gchar     *sender,
			     const gchar     *object_path,
			     const gchar     *interface_name,
			     const gchar     *property_name,
			     GError         **error,
			     gpointer         user_data)
{
	SensorData *data = user_data;

	g_assert (data->connection);

	if (g_strcmp0 (property_name, "HasCompass") == 0)
		return g_variant_new_boolean (sensor_type_available (data, DRIVER_TYPE_COMPASS));
	if (g_strcmp0 (property_name, "CompassHeading") == 0)
		return g_variant_new_double (data->previous_heading);

	return NULL;
}

static const GDBusInterfaceVTable compass_interface_vtable =
{
	handle_compass_method_call,
	handle_compass_get_property,
	NULL
};

static void
name_lost_handler (GDBusConnection *connection,
		   const gchar     *name,
		   gpointer         user_data)
{
	g_debug ("iio-sensor-proxy is already running, or it cannot own its D-Bus name. Verify installation.");
	exit (0);
}

static void
bus_acquired_handler (GDBusConnection *connection,
		      const gchar     *name,
		      gpointer         user_data)
{
	SensorData *data = user_data;
	const gchar * const subsystems[] = {
		"iio",
		"input",
		"platform",
#ifdef HAS_LIBSSC
		"misc",
#endif
		NULL
    };
	g_dbus_connection_register_object (connection,
					   SENSOR_PROXY_DBUS_PATH,
					   data->introspection_data->interfaces[0],
					   &interface_vtable,
					   data,
					   NULL,
					   NULL);

	g_dbus_connection_register_object (connection,
					   SENSOR_PROXY_COMPASS_DBUS_PATH,
					   data->introspection_data->interfaces[1],
					   &compass_interface_vtable,
					   data,
					   NULL,
					   NULL);

	/* Initialize DBus clients hash table before DBus is fully exposed */
	data->client = g_udev_client_new (subsystems);

	for (guint i = 0; i < NUM_SENSOR_TYPES; i++)
		data->clients[i] = create_clients_hash_table ();

	data->connection = g_object_ref (connection);
	/* Discovery can dispatch a nested main context. Observe events before
	 * even the first discover call, not after it has already reserved slots. */
	g_signal_connect (G_OBJECT (data->client), "uevent",
			  G_CALLBACK (sensor_changes), data);
}

static void
name_acquired_handler (GDBusConnection *connection,
		       const gchar     *name,
		       gpointer         user_data)
{
	SensorData *data = user_data;
	if (data->shutting_down)
		return;
	seed_sensor_candidates (data->client, data);
	g_clear_pointer (&data->seed_events, g_hash_table_unref);
	if (data->shutting_down)
		return;
	data->selection_ready = TRUE;
	select_sensor_candidates (data);
	if (!data->shutting_down && any_sensors_left (data)) {
		send_dbus_event (data, PROP_ALL);
		send_dbus_event (data, PROP_ALL_COMPASS);
	}
}

static gboolean
setup_dbus (SensorData *data,
	    gboolean    replace)
{
	GBytes *bytes;
	GBusNameOwnerFlags flags;

	bytes = g_resources_lookup_data ("/net/hadess/SensorProxy/net.hadess.SensorProxy.xml",
					 G_RESOURCE_LOOKUP_FLAGS_NONE,
					 NULL);
	data->introspection_data = g_dbus_node_info_new_for_xml (g_bytes_get_data (bytes, NULL), NULL);
	g_bytes_unref (bytes);
	g_assert (data->introspection_data != NULL);

	flags = G_BUS_NAME_OWNER_FLAGS_ALLOW_REPLACEMENT;
	if (replace)
		flags |= G_BUS_NAME_OWNER_FLAGS_REPLACE;

	data->name_id = g_bus_own_name (G_BUS_TYPE_SYSTEM,
					SENSOR_PROXY_DBUS_NAME,
					flags,
					bus_acquired_handler,
					name_acquired_handler,
					name_lost_handler,
					data,
					NULL);

	return TRUE;
}

static void
maybe_notify_sensor_startup_finished (SensorData *data,
				      DriverType  type)
{
	SensorStartAttempt *attempt = data->starts[type];
	if (attempt) {
		attempt->first_reading = TRUE;
		finish_start_attempt (data, type, attempt, NULL);
	}
}

static void
accel_changed_func (SensorDevice *sensor_device,
		    gpointer      readings_data,
		    gpointer      user_data)
{
	SensorData *data = user_data;
	AccelReadings *readings = (AccelReadings *) readings_data;
	OrientationUp orientation;
	Tilt tilt;
	if (data->shutting_down || data->faulted[DRIVER_TYPE_ACCEL] ||
	    DEVICE_FOR_TYPE(DRIVER_TYPE_ACCEL) != sensor_device)
		return;
	/* Invalid values must not poison orientation or satisfy a pending Claim's
	 * first-reading requirement, including for non-SSC sensor producers. */
	if (!isfinite (readings->accel_x) || !isfinite (readings->accel_y) ||
	    !isfinite (readings->accel_z) || !isfinite (readings->scale.x) ||
	    !isfinite (readings->scale.y) || !isfinite (readings->scale.z))
		return;

	//FIXME handle errors
	g_debug ("Accel sent by driver (quirk applied): %g, %g, %g (scale: %lf,%lf,%lf)",
		 readings->accel_x, readings->accel_y, readings->accel_z,
		 readings->scale.x, readings->scale.y, readings->scale.z);

	orientation = orientation_calc (data->previous_orientation,
					readings->accel_x, readings->accel_y, readings->accel_z,
					readings->scale);

	if (data->previous_orientation != orientation) {
		OrientationUp tmp;

		tmp = data->previous_orientation;
		data->previous_orientation = orientation;
		send_dbus_event (data, PROP_ACCELEROMETER_ORIENTATION);
		g_debug ("Emitted orientation changed: from %s to %s",
			 orientation_to_string (tmp),
			 orientation_to_string (data->previous_orientation));
	}

	tilt = tilt_calc (data->previous_tilt,
			  readings->accel_x, readings->accel_y, readings->accel_z,
			  readings->scale);

	if (data->previous_tilt != tilt) {
		Tilt tmp;

		tmp = data->previous_tilt;
		data->previous_tilt = tilt;
		send_dbus_event (data, PROP_ACCELEROMETER_TILT);
		g_debug ("Emitted tilt changed: from %s to %s",
			 tilt_to_string (tmp),
			 tilt_to_string (data->previous_tilt));
	}

	maybe_notify_sensor_startup_finished (data, DRIVER_TYPE_ACCEL);
}

static void
light_changed_func (SensorDevice *sensor_device,
		    gpointer      readings_data,
		    gpointer      user_data)
{
	SensorData *data = user_data;
	LightReadings *readings = (LightReadings *) readings_data;
	if (data->shutting_down || data->faulted[DRIVER_TYPE_LIGHT] ||
	    DEVICE_FOR_TYPE(DRIVER_TYPE_LIGHT) != sensor_device)
		return;

	//FIXME handle errors
	g_debug ("Light level sent by driver (quirk applied): %lf (unit: %s)",
		 readings->level, data->uses_lux ? "lux" : "vendor");

	if (data->previous_level != readings->level ||
	    data->uses_lux != readings->uses_lux) {
		gdouble tmp;

		tmp = data->previous_level;
		data->previous_level = readings->level;

		data->uses_lux = readings->uses_lux;

		send_dbus_event (data, PROP_LIGHT_LEVEL);
		g_debug ("Emitted light changed: from %lf to %lf",
			 tmp, data->previous_level);
	}

	maybe_notify_sensor_startup_finished (data, DRIVER_TYPE_LIGHT);
}

static void
compass_changed_func (SensorDevice *sensor_device,
                      gpointer      readings_data,
                      gpointer      user_data)
{
	SensorData *data = user_data;
	CompassReadings *readings = (CompassReadings *) readings_data;
	if (data->shutting_down || data->faulted[DRIVER_TYPE_COMPASS] ||
	    DEVICE_FOR_TYPE(DRIVER_TYPE_COMPASS) != sensor_device)
		return;

	//FIXME handle errors
	g_debug ("Heading sent by driver (quirk applied): %lf degrees",
	         readings->heading);

	if (data->previous_heading != readings->heading) {
		gdouble tmp;

		tmp = data->previous_heading;
		data->previous_heading = readings->heading;

		send_dbus_event (data, PROP_COMPASS_HEADING);
		g_debug ("Emitted heading changed: from %lf to %lf",
			 tmp, data->previous_heading);
	}

	maybe_notify_sensor_startup_finished (data, DRIVER_TYPE_COMPASS);
}

static void
proximity_changed_func (SensorDevice *sensor_device,
			gpointer      readings_data,
			gpointer      user_data)
{
	SensorData *data = user_data;
	ProximityReadings *readings = (ProximityReadings *) readings_data;
	if (data->shutting_down || data->faulted[DRIVER_TYPE_PROXIMITY] ||
	    DEVICE_FOR_TYPE(DRIVER_TYPE_PROXIMITY) != sensor_device)
		return;
	gboolean near;

	//FIXME handle errors
	g_debug ("Proximity sent by driver: %d",
	         readings->is_near);

	near = readings->is_near > 0;
	if (data->previous_prox_near != near) {
		ProximityNear tmp;

		tmp = data->previous_prox_near;
		data->previous_prox_near = near;

		send_dbus_event (data, PROP_PROXIMITY_NEAR);
		g_debug ("Emitted proximity changed: from %d to %d",
			 tmp, near);
	}

	maybe_notify_sensor_startup_finished (data, DRIVER_TYPE_PROXIMITY);
}

static ReadingsUpdateFunc
driver_type_to_callback_func (DriverType type)
{
	switch (type) {
	case DRIVER_TYPE_ACCEL:
		return accel_changed_func;
	case DRIVER_TYPE_LIGHT:
		return light_changed_func;
	case DRIVER_TYPE_COMPASS:
		return compass_changed_func;
	case DRIVER_TYPE_PROXIMITY:
		return proximity_changed_func;
	default:
		g_assert_not_reached ();
	}
}

static void
free_sensor_data (SensorData *data)
{
	guint i;

	if (data == NULL)
		return;
	data->shutting_down = TRUE;
	data->selection_pending = FALSE;
	g_clear_handle_id (&data->selection_idle, g_source_remove);
	g_clear_handle_id (&data->sigint_id, g_source_remove);
	g_clear_handle_id (&data->sigterm_id, g_source_remove);

	if (data->name_id != 0) {
		g_bus_unown_name (data->name_id);
		data->name_id = 0;
	}

	for (i = 0; i < NUM_SENSOR_TYPES; i++) {
		SensorDevice *old_device = DEVICE_FOR_TYPE(i);
		cancel_start_attempt (data, i, "Sensor proxy is shutting down");
		DEVICE_FOR_TYPE(i) = NULL;
		DRIVER_FOR_TYPE(i) = NULL;
		if (old_device)
			driver_close (old_device);
		g_clear_object (&UDEV_DEVICE_FOR_TYPE(i));
		g_clear_pointer (&data->clients[i], g_hash_table_unref);
	}
	g_clear_pointer (&data->candidates, g_ptr_array_unref);
	g_clear_pointer (&data->seed_events, g_hash_table_unref);

	g_clear_object (&data->auth);
	g_clear_pointer (&data->introspection_data, g_dbus_node_info_unref);
	g_clear_object (&data->connection);
	g_clear_object (&data->client);
	g_clear_pointer (&data->loop, g_main_loop_unref);
	g_free (data);
}

static void
sensor_changes (GUdevClient *client,
		gchar       *action,
		GUdevDevice *device,
		SensorData  *data)
{
	guint i;
	const char *path = g_udev_device_get_sysfs_path (device);
	if (data->shutting_down)
		return;
	g_debug ("Sensor changes: action = %s, device = %s",
		 action, path);
	if (!path)
		return;
	if (!data->selection_ready && data->seed_events)
		g_hash_table_add (data->seed_events, g_strdup (path));
	data->event_depth++;

	if (g_strcmp0 (action, "remove") == 0 ||
	    g_strcmp0 (action, "unbind") == 0 ||
	    g_strcmp0 (action, "offline") == 0) {
		SensorDevice *old_devices[NUM_SENSOR_TYPES] = { NULL };
		gboolean changed = retire_sensor_candidate (data, path);

		for (i = 0; i < NUM_SENSOR_TYPES; i++) {
			GUdevDevice *dev = UDEV_DEVICE_FOR_TYPE(i);

			if (!dev)
				continue;

			if (g_strcmp0 (path, g_udev_device_get_sysfs_path (dev)) == 0) {
				SensorStartAttempt *old_start = g_steal_pointer (&data->starts[i]);
				GHashTable *old_clients = data->clients[i];
				old_devices[i] = DEVICE_FOR_TYPE(i);
				changed = TRUE;

				g_debug ("Sensor type %s got removed (%s)",
					 driver_type_to_str (i),
					 g_udev_device_get_sysfs_path (dev));

				/* Detach before CLOSE can dispatch removal/replacement. An
				 * older frame must never clear a replacement's live slots. */
				g_clear_object (&UDEV_DEVICE_FOR_TYPE(i));
				DEVICE_FOR_TYPE(i) = NULL;
				DRIVER_FOR_TYPE(i) = NULL;
				data->faulted[i] = FALSE;
				data->clients[i] = create_clients_hash_table ();
				if (old_start) {
					start_attempt_cancel_deadline (old_start);
					start_attempt_reply (old_start, "Sensor removed while waiting for it to start up");
					start_attempt_unref (old_start);
				}
				g_hash_table_remove_all (old_clients);
				g_hash_table_unref (old_clients);
				send_driver_changed_dbus_event (data, i);
			}
		}
		/* Detach every type sharing the transport before the first close:
		 * its nested dispatch may already register a replacement transport. */
		for (i = 0; i < NUM_SENSOR_TYPES; i++) {
			if (old_devices[i])
				driver_close (old_devices[i]);
		}

		if (changed)
			queue_sensor_selection (data);
	} else if (g_strcmp0 (action, "add") == 0 ||
		   g_strcmp0 (action, "change") == 0 ||
		   g_strcmp0 (action, "bind") == 0 ||
		   g_strcmp0 (action, "online") == 0) {
		register_sensor_candidate (data, device, g_strcmp0 (action, "change") == 0);
		queue_sensor_selection (data);
	} else {
		/* Unknown actions do not authorize constructor traffic. Fence a
		 * queued source rather than admitting its potentially stale snapshot.
		 * Path moves are not inferred as physical replacement here. */
		if (retire_sensor_candidate (data, path))
			queue_sensor_selection (data);
	}
	data->event_depth--;
	if (data->selection_pending)
		queue_sensor_selection (data);
}

gboolean
termination_signal_handler (gpointer user_data)
{
	SensorData *data = user_data;

	g_debug ("Shutting down");
	/* A synchronous constructor may be pumping this context. Quit alone
	 * does not fence its returning result or remove deferred callbacks. */
	data->shutting_down = TRUE;
	data->selection_pending = FALSE;
	g_clear_handle_id (&data->selection_idle, g_source_remove);
	g_clear_handle_id (&data->sigint_id, g_source_remove);
	g_clear_handle_id (&data->sigterm_id, g_source_remove);
	g_main_loop_quit (data->loop);

	return G_SOURCE_REMOVE;
}

int main (int argc, char **argv)
{
	SensorData *data;
	g_autoptr(GOptionContext) option_context = NULL;
	g_autoptr(GError) error = NULL;
	gboolean verbose = FALSE;
	gboolean replace = FALSE;
	const GOptionEntry options[] = {
		{ "verbose", 'v', 0, G_OPTION_ARG_NONE, &verbose, "Show extra debugging information", NULL },
		{ "replace", 'r', 0, G_OPTION_ARG_NONE, &replace, "Replace the running instance of iio-sensor-proxy", NULL },
		{ NULL}
	};
	int ret = 0;

	setlocale (LC_ALL, "");
	option_context = g_option_context_new ("");
	g_option_context_add_main_entries (option_context, options, NULL);

	ret = g_option_context_parse (option_context, &argc, &argv, &error);
	if (!ret) {
		g_print ("Failed to parse arguments: %s\n", error->message);
		return EXIT_FAILURE;
	}

	if (verbose) {
		if (!g_setenv ("G_MESSAGES_DEBUG", "all", TRUE)) {
			g_warning ("Failed to enable debug");
			return EXIT_FAILURE;
		}
		g_debug ("Starting iio-sensor-proxy version "VERSION);
	}

	data = g_new0 (SensorData, 1);
	data->previous_orientation = ORIENTATION_UNDEFINED;
	data->previous_tilt = TILT_UNDEFINED;
	data->uses_lux = TRUE;
	data->candidates = g_ptr_array_new_with_free_func (sensor_candidate_unref);
	data->seed_events = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
	data->loop = g_main_loop_new (NULL, TRUE);
	data->sigint_id = g_unix_signal_add (SIGINT, termination_signal_handler, data);
	data->sigterm_id = g_unix_signal_add (SIGTERM, termination_signal_handler, data);

	/* Initialize callback state before bus ownership or any synchronous
	 * setup call can dispatch the context. A shutdown during setup must
	 * not be undone by subsequently starting the outer loop. */
	data->auth = polkit_authority_get_sync (NULL, NULL);
	if (!data->shutting_down) {
		setup_dbus (data, replace);
		g_main_loop_run (data->loop);
	}
	ret = data->ret;
	free_sensor_data (data);

	return ret;
}
