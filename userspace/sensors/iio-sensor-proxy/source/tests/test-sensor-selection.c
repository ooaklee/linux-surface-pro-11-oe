/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Selection/lifetime tests of the actual private proxy translation unit.
 *
 * Driver descriptors below are transparent effect fixtures, not real sensor
 * providers: no constructor, INIT, OPEN, device fd or firmware is contacted.
 * Only GUdev path/enumeration metadata is replaced locally. Selection,
 * candidate ownership, event handling, publication, teardown and scheduling
 * are the included production implementation, not a duplicate model.
 * Direct event-handler calls from fixture effects exercise controlled
 * reentrancy; they do not claim GUdev's native event source is recursive.
 */
#include <gio/gio.h>
#include <gudev/gudev.h>

static const gchar *fixture_sysfs_path (GUdevDevice *device);
static GList *fixture_query_subsystem (GUdevClient *client, const gchar *subsystem);

#define g_udev_device_get_sysfs_path fixture_sysfs_path
#define g_udev_client_query_by_subsystem fixture_query_subsystem
#define main sensor_proxy_under_test_main
#include "../src/iio-sensor-proxy.c"
#undef main
#undef g_udev_client_query_by_subsystem
#undef g_udev_device_get_sysfs_path

enum {
        FIXTURE_ACCEL = 1,
        FIXTURE_LIGHT_FIRST = 3,
        FIXTURE_LIGHT_SECOND = 4,
        FIXTURE_COMPASS = 6,
        FIXTURE_DRIVER_COUNT = 15
};

#define DRIVER_BIT(index) (G_GUINT64_CONSTANT (1) << (index))

typedef struct {
        char *path;
        char *subsystem;
        guint64 supported;
        guint64 reject_open;
        guint discovered[FIXTURE_DRIVER_COUNT];
        guint opened[FIXTURE_DRIVER_COUNT];
        guint closed[FIXTURE_DRIVER_COUNT];
        guint started[FIXTURE_DRIVER_COUNT];
        guint stopped[FIXTURE_DRIVER_COUNT];
} FixtureNode;

typedef struct {
        FixtureNode *node; /* The fixture owns its metadata object until teardown. */
        guint driver;
} FixtureOpen;

typedef enum {
        HOOK_NONE,
        HOOK_REMOVE_LATER,
        HOOK_REPLACE_SOURCE,
        HOOK_SHUTDOWN,
        HOOK_CHANGE_EACH_DISCOVERY,
        HOOK_REMOVE_DURING_ENUMERATION,
        HOOK_ADD_DURING_ENUMERATION,
        HOOK_CHANGE_DURING_ENUMERATION,
        HOOK_ASSERT_PREPARED_LIGHT,
        HOOK_RELEASE_PREPARED_LIGHT,
        HOOK_ASSERT_DETACHED,
        HOOK_REPLACE_DURING_CLOSE
} FixtureHook;

typedef struct {
        SensorData *data;
        GPtrArray *nodes;
        FixtureHook hook;
        GUdevDevice *trigger;
        GUdevDevice *other;
        guint trigger_driver;
        guint hook_calls;
        guint enumeration_calls;
        gboolean duplicate_seed;
        GDBusConnection *future_client;
        SensorStartAttempt *observed_prepared; /* Identity only, never test-owned. */
} SelectionFixture;

static SelectionFixture *current_fixture;
static GTestDBus *private_bus;

static FixtureNode *
node_data (GUdevDevice *device)
{
        FixtureNode *node;
        g_assert_true (G_UDEV_IS_DEVICE (device));
        node = g_object_get_data (G_OBJECT (device), "selection-fixture-node");
        g_assert_nonnull (node);
        return node;
}

static const gchar *
fixture_sysfs_path (GUdevDevice *device)
{
        return node_data (device)->path;
}

static GList *
fixture_query_subsystem (GUdevClient *client, const gchar *subsystem)
{
        SelectionFixture *fixture = current_fixture;
        GList *result = NULL;
        (void) client;
        g_assert_nonnull (fixture);
        fixture->enumeration_calls++;
        for (guint n = 0; n < fixture->nodes->len; n++) {
                GUdevDevice *device = g_ptr_array_index (fixture->nodes, n);
                FixtureNode *node = node_data (device);
                /* Enumeration must finish before the first effect fixture is
                 * called. Each result owns its real metadata GObject ref. */
                for (guint d = 0; d < FIXTURE_DRIVER_COUNT; d++) {
                        g_assert_cmpuint (node->discovered[d], ==, 0);
                        g_assert_cmpuint (node->opened[d], ==, 0);
                }
                if (g_strcmp0 (node->subsystem, subsystem) != 0)
                        continue;
                result = g_list_append (result, g_object_ref (device));
                if (fixture->duplicate_seed)
                        result = g_list_append (result, g_object_ref (device));
        }
        if (fixture->hook == HOOK_REMOVE_DURING_ENUMERATION &&
            g_strcmp0 (subsystem, "platform") == 0) {
                /* The iio snapshot already owns a ref, but seed insertion
                 * has not begun. Its later remove must beat that snapshot. */
                fixture->hook = HOOK_NONE;
                fixture->hook_calls++;
                sensor_changes (NULL, "remove", fixture->trigger, fixture->data);
        }
        if ((fixture->hook == HOOK_ADD_DURING_ENUMERATION ||
             fixture->hook == HOOK_CHANGE_DURING_ENUMERATION) &&
            g_strcmp0 (subsystem, "platform") == 0) {
                gboolean adding = fixture->hook == HOOK_ADD_DURING_ENUMERATION;
                FixtureNode *node = node_data (fixture->trigger);
                fixture->hook = HOOK_NONE;
                fixture->hook_calls++;
                g_free (node->subsystem);
                node->subsystem = g_strdup ("iio");
                sensor_changes (NULL, adding ? "add" : "change",
                                fixture->trigger, fixture->data);
        }
        return result;
}

/* drivers.h's real accelerometer admission wrapper uses these metadata-only
 * helpers. This fixture has no board location policy or mount-matrix oracle. */
AccelLocation
setup_accel_location (GUdevDevice *device)
{
        g_assert_nonnull (node_data (device));
        return ACCEL_LOCATION_DISPLAY;
}

const char *
accel_location_to_string (AccelLocation location)
{
        g_assert_cmpint (location, ==, ACCEL_LOCATION_DISPLAY);
        return "display";
}

static void
fixture_effect_hook (GUdevDevice *source, guint driver, gboolean discovery)
{
        SelectionFixture *fixture = current_fixture;
        if (fixture->trigger != source)
                return;
        if (fixture->hook == HOOK_CHANGE_EACH_DISCOVERY && discovery) {
                fixture->hook_calls++;
                /* A feedback implementation that loses earlier attempt bits
                 * must fail finitely instead of hanging this test process. */
                g_assert_cmpuint (fixture->hook_calls, <=, G_N_ELEMENTS (drivers));
                sensor_changes (NULL, "change", source, fixture->data);
                /* Two changes within one driver call require propagation of
                 * probing as well as the entire previously tried bitmap. */
                sensor_changes (NULL, "change", source, fixture->data);
                return;
        }
        if (discovery || fixture->trigger_driver != driver)
                return;
        switch (fixture->hook) {
        case HOOK_REMOVE_LATER:
                fixture->hook = HOOK_NONE;
                fixture->hook_calls++;
                sensor_changes (NULL, "remove", fixture->other, fixture->data);
                break;
        case HOOK_REPLACE_SOURCE:
                fixture->hook = HOOK_NONE;
                fixture->hook_calls++;
                sensor_changes (NULL, "add", fixture->other, fixture->data);
                break;
        case HOOK_SHUTDOWN:
                fixture->hook = HOOK_NONE;
                fixture->hook_calls++;
                g_assert_cmpint (termination_signal_handler (fixture->data), ==, G_SOURCE_REMOVE);
                g_assert_true (fixture->data->shutting_down);
                break;
        case HOOK_ASSERT_PREPARED_LIGHT:
        case HOOK_RELEASE_PREPARED_LIGHT: {
                gboolean releasing = fixture->hook == HOOK_RELEASE_PREPARED_LIGHT;
                SensorStartAttempt *attempt = fixture->data->starts[DRIVER_TYPE_LIGHT];
                FixtureNode *light = node_data (fixture->other);
                const char *sender = g_dbus_connection_get_unique_name (fixture->future_client);
                fixture->hook = HOOK_NONE;
                fixture->hook_calls++;
                g_assert_true (fixture->data->selecting);
                g_assert_nonnull (fixture->data->selection_starts);
                g_assert_nonnull (attempt);
                g_assert_true (start_attempt_is_current (fixture->data, DRIVER_TYPE_LIGHT, attempt));
                g_assert_true (attempt->data == fixture->data);
                g_assert_cmpint (attempt->type, ==, DRIVER_TYPE_LIGHT);
                g_assert_false (attempt->open_started);
                g_assert_false (attempt->open_done);
                g_assert_cmpuint (GPOINTER_TO_UINT (g_hash_table_lookup (attempt->members, sender)), >, 0);
                g_assert_cmpuint (light->started[FIXTURE_LIGHT_FIRST], ==, 0);
                g_assert_cmpuint (light->stopped[FIXTURE_LIGHT_FIRST], ==, 0);
                fixture->observed_prepared = attempt;
                if (releasing) {
                        client_release (fixture->data, sender, DRIVER_TYPE_LIGHT);
                        /* The admission pass still owns the canceled token.
                         * Do not retain/dereference it from this fixture. */
                        g_assert_null (fixture->data->starts[DRIVER_TYPE_LIGHT]);
                        g_assert_cmpuint (g_hash_table_size (fixture->data->clients[DRIVER_TYPE_LIGHT]), ==, 0);
                        g_assert_cmpuint (light->started[FIXTURE_LIGHT_FIRST], ==, 0);
                        g_assert_cmpuint (light->stopped[FIXTURE_LIGHT_FIRST], ==, 0);
                }
                break;
        }
        default:
                break;
        }
}

static gboolean
fixture_discover (GUdevDevice *device, guint driver)
{
        FixtureNode *node = node_data (device);
        g_assert_cmpuint (driver, <, FIXTURE_DRIVER_COUNT);
        node->discovered[driver]++;
        if (!(node->supported & DRIVER_BIT (driver)))
                return FALSE;
        fixture_effect_hook (device, driver, TRUE);
        return TRUE;
}

static SensorDevice *
fixture_open (GUdevDevice *device, guint driver)
{
        FixtureNode *node = node_data (device);
        SensorDevice *sensor;
        FixtureOpen *opened;
        g_assert_true ((node->supported & DRIVER_BIT (driver)) != 0);
        node->opened[driver]++;
        fixture_effect_hook (device, driver, FALSE);
        if (node->reject_open & DRIVER_BIT (driver))
                return NULL;
        sensor = g_new0 (SensorDevice, 1);
        opened = g_new0 (FixtureOpen, 1);
        opened->node = node;
        opened->driver = driver;
        sensor->name = g_strdup (node->path);
        sensor->priv = opened;
        return sensor;
}

static void
fixture_polling (SensorDevice *sensor, gboolean enabled)
{
        FixtureOpen *opened = sensor->priv;
        if (enabled)
                opened->node->started[opened->driver]++;
        else
                opened->node->stopped[opened->driver]++;
}

static void
assert_shared_slots_detached (SensorData *data)
{
        g_assert_null (data->devices[DRIVER_TYPE_LIGHT]);
        g_assert_null (data->devices[DRIVER_TYPE_COMPASS]);
        g_assert_null (data->drivers[DRIVER_TYPE_LIGHT]);
        g_assert_null (data->drivers[DRIVER_TYPE_COMPASS]);
        g_assert_null (data->udev_devices[DRIVER_TYPE_LIGHT]);
        g_assert_null (data->udev_devices[DRIVER_TYPE_COMPASS]);
}

static void
fixture_close (SensorDevice *sensor)
{
        SelectionFixture *fixture = current_fixture;
        FixtureOpen *opened = sensor->priv;
        FixtureNode *node = opened->node;
        node->closed[opened->driver]++;
        if (fixture->trigger && node == node_data (fixture->trigger) &&
            (fixture->hook == HOOK_ASSERT_DETACHED ||
             fixture->hook == HOOK_REPLACE_DURING_CLOSE)) {
                assert_shared_slots_detached (fixture->data);
                fixture->hook_calls++;
                g_assert_cmpuint (fixture->data->event_depth, >, 0);
                if (fixture->hook == HOOK_REPLACE_DURING_CLOSE && fixture->hook_calls == 1)
                        sensor_changes (NULL, "add", fixture->other, fixture->data);
                /* A native CLOSE can dispatch the context. No queued
                 * replacement is allowed to construct inside this teardown. */
                for (guint n = 0; n < 8; n++)
                        g_main_context_iteration (NULL, FALSE);
                if (fixture->hook == HOOK_REPLACE_DURING_CLOSE) {
                        FixtureNode *replacement = node_data (fixture->other);
                        g_assert_cmpuint (fixture->data->selection_idle, ==, 0);
                        for (guint d = 0; d < FIXTURE_DRIVER_COUNT; d++)
                                g_assert_cmpuint (replacement->opened[d], ==, 0);
                }
                assert_shared_slots_detached (fixture->data);
        }
        g_free (opened);
        g_free (sensor);
}

#define DEFINE_EFFECT_DRIVER(symbol, index, kind) \
static gboolean symbol##_fixture_discover (GUdevDevice *device) \
{ return fixture_discover (device, index); } \
static SensorDevice *symbol##_fixture_open (GUdevDevice *device) \
{ return fixture_open (device, index); } \
SensorDriver symbol = { \
        .driver_name = "selection-fixture-" #symbol, .type = kind, \
        .discover = symbol##_fixture_discover, .open = symbol##_fixture_open, \
        .set_polling = fixture_polling, .close = fixture_close \
}

DEFINE_EFFECT_DRIVER (iio_buffer_accel, 0, DRIVER_TYPE_ACCEL);
DEFINE_EFFECT_DRIVER (iio_poll_accel, 1, DRIVER_TYPE_ACCEL);
DEFINE_EFFECT_DRIVER (input_accel, 2, DRIVER_TYPE_ACCEL);
DEFINE_EFFECT_DRIVER (iio_buffer_light, 3, DRIVER_TYPE_LIGHT);
DEFINE_EFFECT_DRIVER (iio_poll_light, 4, DRIVER_TYPE_LIGHT);
DEFINE_EFFECT_DRIVER (hwmon_light, 5, DRIVER_TYPE_LIGHT);
DEFINE_EFFECT_DRIVER (fake_compass, 6, DRIVER_TYPE_COMPASS);
DEFINE_EFFECT_DRIVER (fake_light, 7, DRIVER_TYPE_LIGHT);
DEFINE_EFFECT_DRIVER (iio_buffer_compass, 8, DRIVER_TYPE_COMPASS);
DEFINE_EFFECT_DRIVER (iio_poll_proximity, 9, DRIVER_TYPE_PROXIMITY);
DEFINE_EFFECT_DRIVER (input_proximity, 10, DRIVER_TYPE_PROXIMITY);
#ifdef HAS_LIBSSC
DEFINE_EFFECT_DRIVER (ssc_proximity, 11, DRIVER_TYPE_PROXIMITY);
DEFINE_EFFECT_DRIVER (ssc_light, 12, DRIVER_TYPE_LIGHT);
DEFINE_EFFECT_DRIVER (ssc_accel, 13, DRIVER_TYPE_ACCEL);
DEFINE_EFFECT_DRIVER (ssc_compass, 14, DRIVER_TYPE_COMPASS);
#endif

static void
fixture_node_free (gpointer value)
{
        FixtureNode *node = value;
        g_free (node->path);
        g_free (node->subsystem);
        g_free (node);
}

static GUdevDevice *
fixture_node (SelectionFixture *fixture, const char *path,
              const char *subsystem, guint64 supported, guint64 reject_open)
{
        GUdevDevice *device = g_object_new (G_UDEV_TYPE_DEVICE, NULL);
        FixtureNode *node = g_new0 (FixtureNode, 1);
        node->path = g_strdup (path);
        node->subsystem = g_strdup (subsystem);
        node->supported = supported;
        node->reject_open = reject_open;
        g_object_set_data_full (G_OBJECT (device), "selection-fixture-node", node,
                                fixture_node_free);
        g_ptr_array_add (fixture->nodes, device);
        return device; /* Borrowed from fixture->nodes. */
}

static void
fixture_setup (SelectionFixture *fixture, gconstpointer unused)
{
        g_autoptr(GError) error = NULL;
        SensorData *data = g_new0 (SensorData, 1);
        (void) unused;
        g_assert_null (current_fixture);
        fixture->nodes = g_ptr_array_new_with_free_func (g_object_unref);
        fixture->data = data;
        current_fixture = fixture;
        data->loop = g_main_loop_new (NULL, FALSE);
        data->candidates = g_ptr_array_new_with_free_func (sensor_candidate_unref);
        data->selection_ready = TRUE;
        data->previous_orientation = ORIENTATION_UNDEFINED;
        data->previous_tilt = TILT_UNDEFINED;
        data->uses_lux = TRUE;
        for (guint i = 0; i < NUM_SENSOR_TYPES; i++)
                data->clients[i] = create_clients_hash_table ();
        data->connection = g_dbus_connection_new_for_address_sync (
                g_test_dbus_get_bus_address (private_bus),
                G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
                G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION,
                NULL, NULL, &error);
        g_assert_no_error (error);
        g_assert_nonnull (data->connection);
        g_dbus_connection_set_exit_on_close (data->connection, FALSE);
}

static void
fixture_teardown (SelectionFixture *fixture, gconstpointer unused)
{
        g_autoptr(GDBusConnection) connection = g_object_ref (fixture->data->connection);
        g_autoptr(GError) error = NULL;
        (void) unused;
        fixture->hook = HOOK_NONE;
        free_sensor_data (fixture->data);
        fixture->data = NULL;
        g_assert_true (g_dbus_connection_close_sync (connection, NULL, &error));
        g_assert_no_error (error);
        if (fixture->future_client) {
                /* free_sensor_data already removed the actual bus-name watch;
                 * its callback cannot retain a pointer to the freed data. */
                g_assert_true (g_dbus_connection_close_sync (fixture->future_client, NULL, &error));
                g_assert_no_error (error);
                g_clear_object (&fixture->future_client);
        }
        g_ptr_array_unref (fixture->nodes);
        current_fixture = NULL;
}

static void
fixture_drain (SelectionFixture *fixture)
{
        for (guint n = 0; n < 128 &&
             (fixture->data->selection_idle || fixture->data->selection_pending); n++)
                g_main_context_iteration (NULL, FALSE);
        g_assert_false (fixture->data->selecting);
        g_assert_cmpuint (fixture->data->event_depth, ==, 0);
        g_assert_false (fixture->data->selection_pending);
        g_assert_cmpuint (fixture->data->selection_idle, ==, 0);
}

static void
fixture_select (SelectionFixture *fixture)
{
        select_sensor_candidates (fixture->data);
        fixture_drain (fixture);
}

static void
fixture_register (SelectionFixture *fixture, GUdevDevice *device)
{
        register_sensor_candidate (fixture->data, device, FALSE);
}

static void
fixture_keeper (SelectionFixture *fixture)
{
        GUdevDevice *device = fixture_node (fixture, "/fixture/keeper", "input",
                                           DRIVER_BIT (FIXTURE_COMPASS), 0);
        fixture_register (fixture, device);
}

static void
assert_selected (SelectionFixture *fixture, DriverType type,
                 GUdevDevice *source, SensorDriver *driver)
{
        g_assert_nonnull (fixture->data->devices[type]);
        g_assert_true (fixture->data->udev_devices[type] == source);
        g_assert_true (fixture->data->drivers[type] == driver);
        g_assert_true (fixture->data->devices[type]->drv == driver);
}

static void
test_fallback_same_source (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *source = fixture_node (fixture, "/fixture/same", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST) | DRIVER_BIT (FIXTURE_LIGHT_SECOND),
                DRIVER_BIT (FIXTURE_LIGHT_FIRST));
        FixtureNode *node = node_data (source);
        (void) unused;
        fixture_register (fixture, source);
        fixture_select (fixture);
        assert_selected (fixture, DRIVER_TYPE_LIGHT, source, &iio_poll_light);
        g_assert_cmpuint (node->opened[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node->opened[FIXTURE_LIGHT_SECOND], ==, 1);
        fixture_select (fixture);
        g_assert_cmpuint (node->opened[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node->opened[FIXTURE_LIGHT_SECOND], ==, 1);
}

static void
test_fallback_existing_alternate (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *bad = fixture_node (fixture, "/fixture/bad", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), DRIVER_BIT (FIXTURE_LIGHT_FIRST));
        GUdevDevice *good = fixture_node (fixture, "/fixture/good", "platform",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        (void) unused;
        fixture_register (fixture, bad);
        fixture_register (fixture, good);
        fixture_select (fixture);
        assert_selected (fixture, DRIVER_TYPE_LIGHT, good, &iio_buffer_light);
        g_assert_cmpuint (node_data (bad)->opened[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (good)->opened[FIXTURE_LIGHT_FIRST], ==, 1);
}

static void
test_multitype (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *source = fixture_node (fixture, "/fixture/shared", "iio",
                DRIVER_BIT (FIXTURE_ACCEL) | DRIVER_BIT (FIXTURE_LIGHT_FIRST) |
                DRIVER_BIT (FIXTURE_LIGHT_SECOND), DRIVER_BIT (FIXTURE_LIGHT_FIRST));
        (void) unused;
        fixture_register (fixture, source);
        fixture_select (fixture);
        assert_selected (fixture, DRIVER_TYPE_ACCEL, source, &iio_poll_accel);
        assert_selected (fixture, DRIVER_TYPE_LIGHT, source, &iio_poll_light);
        g_assert_cmpuint (node_data (source)->opened[FIXTURE_ACCEL], ==, 1);
        g_assert_cmpuint (node_data (source)->closed[FIXTURE_ACCEL], ==, 0);
}

static void
test_stale_snapshot_removed (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *first = fixture_node (fixture, "/fixture/first", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), DRIVER_BIT (FIXTURE_LIGHT_FIRST));
        GUdevDevice *later = fixture_node (fixture, "/fixture/later", "platform",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        (void) unused;
        fixture_register (fixture, first);
        fixture_register (fixture, later);
        fixture_keeper (fixture);
        fixture->hook = HOOK_REMOVE_LATER;
        fixture->trigger = first;
        fixture->other = later;
        fixture->trigger_driver = FIXTURE_LIGHT_FIRST;
        fixture_select (fixture);
        g_assert_cmpuint (fixture->hook_calls, ==, 1);
        g_assert_null (fixture->data->devices[DRIVER_TYPE_LIGHT]);
        g_assert_cmpuint (node_data (later)->discovered[FIXTURE_LIGHT_FIRST], ==, 0);
        g_assert_cmpuint (node_data (later)->opened[FIXTURE_LIGHT_FIRST], ==, 0);
}

static void
test_same_path_replacement (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *old = fixture_node (fixture, "/fixture/reused", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        GUdevDevice *replacement = fixture_node (fixture, "/fixture/reused", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        (void) unused;
        fixture_register (fixture, old);
        fixture_keeper (fixture);
        fixture->hook = HOOK_REPLACE_SOURCE;
        fixture->trigger = old;
        fixture->other = replacement;
        fixture->trigger_driver = FIXTURE_LIGHT_FIRST;
        fixture_select (fixture);
        assert_selected (fixture, DRIVER_TYPE_LIGHT, replacement, &iio_buffer_light);
        g_assert_cmpuint (node_data (old)->opened[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (old)->closed[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (replacement)->opened[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (replacement)->closed[FIXTURE_LIGHT_FIRST], ==, 0);
}

static void
test_shutdown_during_open (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *first = fixture_node (fixture, "/fixture/shutdown-first", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        GUdevDevice *later = fixture_node (fixture, "/fixture/shutdown-later", "platform",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        (void) unused;
        fixture_register (fixture, first);
        fixture_register (fixture, later);
        fixture->hook = HOOK_SHUTDOWN;
        fixture->trigger = first;
        fixture->trigger_driver = FIXTURE_LIGHT_FIRST;
        select_sensor_candidates (fixture->data);
        g_assert_true (fixture->data->shutting_down);
        g_assert_null (fixture->data->devices[DRIVER_TYPE_LIGHT]);
        g_assert_cmpuint (fixture->data->selection_idle, ==, 0);
        g_assert_cmpuint (node_data (first)->closed[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (later)->discovered[FIXTURE_LIGHT_FIRST], ==, 0);
        g_assert_cmpuint (node_data (later)->opened[FIXTURE_LIGHT_FIRST], ==, 0);
}

static void
test_preserve_faulted_winner (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *winner = fixture_node (fixture, "/fixture/winner", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        GUdevDevice *alternate = fixture_node (fixture, "/fixture/alternate", "platform",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        SensorDevice *identity;
        (void) unused;
        fixture_register (fixture, winner);
        fixture_select (fixture);
        identity = fixture->data->devices[DRIVER_TYPE_LIGHT];
        fixture->data->faulted[DRIVER_TYPE_LIGHT] = TRUE;
        fixture_register (fixture, alternate);
        fixture_select (fixture);
        g_assert_true (fixture->data->devices[DRIVER_TYPE_LIGHT] == identity);
        g_assert_false (sensor_type_available (fixture->data, DRIVER_TYPE_LIGHT));
        g_assert_cmpuint (node_data (winner)->opened[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (alternate)->discovered[FIXTURE_LIGHT_FIRST], ==, 0);
        g_assert_cmpuint (node_data (alternate)->opened[FIXTURE_LIGHT_FIRST], ==, 0);
}

static void
test_all_rejections_finite (SelectionFixture *fixture, gconstpointer unused)
{
        guint64 pair = DRIVER_BIT (FIXTURE_LIGHT_FIRST) | DRIVER_BIT (FIXTURE_LIGHT_SECOND);
        GUdevDevice *a = fixture_node (fixture, "/fixture/reject-a", "iio", pair, pair);
        GUdevDevice *b = fixture_node (fixture, "/fixture/reject-b", "platform", pair, pair);
        (void) unused;
        fixture_register (fixture, a);
        fixture_register (fixture, b);
        fixture_keeper (fixture);
        fixture_select (fixture);
        fixture_select (fixture);
        queue_sensor_selection (fixture->data);
        fixture_drain (fixture);
        g_assert_null (fixture->data->devices[DRIVER_TYPE_LIGHT]);
        for (guint n = 0; n < 2; n++) {
                FixtureNode *node = node_data (n == 0 ? a : b);
                g_assert_cmpuint (node->discovered[FIXTURE_LIGHT_FIRST], ==, 1);
                g_assert_cmpuint (node->discovered[FIXTURE_LIGHT_SECOND], ==, 1);
                g_assert_cmpuint (node->opened[FIXTURE_LIGHT_FIRST], ==, 1);
                g_assert_cmpuint (node->opened[FIXTURE_LIGHT_SECOND], ==, 1);
        }
}

static void
test_inflight_change_bounded (SelectionFixture *fixture, gconstpointer unused)
{
        guint64 pair = DRIVER_BIT (FIXTURE_LIGHT_FIRST) | DRIVER_BIT (FIXTURE_LIGHT_SECOND);
        GUdevDevice *source = fixture_node (fixture, "/fixture/feedback", "iio", pair, 0);
        (void) unused;
        fixture_register (fixture, source);
        fixture_keeper (fixture);
        fixture->hook = HOOK_CHANGE_EACH_DISCOVERY;
        fixture->trigger = source;
        fixture_select (fixture);
        g_assert_cmpuint (fixture->hook_calls, ==, 2);
        g_assert_cmpuint (node_data (source)->discovered[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (source)->discovered[FIXTURE_LIGHT_SECOND], ==, 1);
        g_assert_cmpuint (node_data (source)->opened[FIXTURE_LIGHT_FIRST], ==, 0);
        g_assert_cmpuint (node_data (source)->opened[FIXTURE_LIGHT_SECOND], ==, 0);
        g_assert_null (fixture->data->devices[DRIVER_TYPE_LIGHT]);
}

static void
test_known_alternate_after_remove (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *winner = fixture_node (fixture, "/fixture/removed-winner", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        GUdevDevice *alternate = fixture_node (fixture, "/fixture/known-alternate", "platform",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        (void) unused;
        fixture_register (fixture, winner);
        fixture_register (fixture, alternate);
        fixture_select (fixture);
        g_assert_cmpuint (node_data (alternate)->discovered[FIXTURE_LIGHT_FIRST], ==, 0);
        sensor_changes (NULL, "remove", winner, fixture->data);
        fixture_drain (fixture);
        assert_selected (fixture, DRIVER_TYPE_LIGHT, alternate, &iio_buffer_light);
        g_assert_cmpuint (node_data (winner)->closed[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (alternate)->opened[FIXTURE_LIGHT_FIRST], ==, 1);
}

static void
test_all_types_detached_before_close (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *source = fixture_node (fixture, "/fixture/removed-shared", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST) | DRIVER_BIT (FIXTURE_COMPASS), 0);
        (void) unused;
        fixture_register (fixture, source);
        fixture_select (fixture);
        assert_selected (fixture, DRIVER_TYPE_LIGHT, source, &iio_buffer_light);
        assert_selected (fixture, DRIVER_TYPE_COMPASS, source, &fake_compass);
        fixture->hook = HOOK_ASSERT_DETACHED;
        fixture->trigger = source;
        sensor_changes (NULL, "remove", source, fixture->data);
        fixture_drain (fixture);
        g_assert_cmpuint (fixture->hook_calls, ==, 2);
        g_assert_cmpuint (node_data (source)->closed[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (source)->closed[FIXTURE_COMPASS], ==, 1);
}

static void
test_replacement_deferred_during_close (SelectionFixture *fixture, gconstpointer unused)
{
        guint64 pair = DRIVER_BIT (FIXTURE_LIGHT_FIRST) | DRIVER_BIT (FIXTURE_COMPASS);
        GUdevDevice *old = fixture_node (fixture, "/fixture/close-reuse", "iio", pair, 0);
        GUdevDevice *replacement = fixture_node (fixture, "/fixture/close-reuse", "iio", pair, 0);
        (void) unused;
        fixture_register (fixture, old);
        fixture_select (fixture);
        fixture->hook = HOOK_REPLACE_DURING_CLOSE;
        fixture->trigger = old;
        fixture->other = replacement;
        /* This real idle predates removal. CLOSE's nested context pump must
         * consume it without selecting, then let the outer epilogue requeue. */
        queue_sensor_selection (fixture->data);
        g_assert_cmpuint (fixture->data->selection_idle, >, 0);
        sensor_changes (NULL, "remove", old, fixture->data);
        fixture_drain (fixture);
        g_assert_cmpuint (fixture->hook_calls, ==, 2);
        assert_selected (fixture, DRIVER_TYPE_LIGHT, replacement, &iio_buffer_light);
        assert_selected (fixture, DRIVER_TYPE_COMPASS, replacement, &fake_compass);
        g_assert_cmpuint (node_data (old)->closed[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (old)->closed[FIXTURE_COMPASS], ==, 1);
        g_assert_cmpuint (node_data (replacement)->opened[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (replacement)->opened[FIXTURE_COMPASS], ==, 1);
}

static void
test_seed_duplicates (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *bad = fixture_node (fixture, "/fixture/seed-bad", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), DRIVER_BIT (FIXTURE_LIGHT_FIRST));
        GUdevDevice *good = fixture_node (fixture, "/fixture/seed-good", "platform",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        (void) unused;
        fixture->duplicate_seed = TRUE;
        seed_sensor_candidates (NULL, fixture->data);
        g_assert_cmpuint (fixture->enumeration_calls, >=, 3);
        g_assert_cmpuint (fixture->data->candidates->len, ==, 2);
        fixture_select (fixture);
        assert_selected (fixture, DRIVER_TYPE_LIGHT, good, &iio_buffer_light);
        g_assert_cmpuint (node_data (bad)->opened[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (good)->opened[FIXTURE_LIGHT_FIRST], ==, 1);
}

static void
test_seed_removed_before_register (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *removed = fixture_node (fixture, "/fixture/seed-removed", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        GUdevDevice *keeper = fixture_node (fixture, "/fixture/seed-keeper", "input",
                DRIVER_BIT (FIXTURE_COMPASS), 0);
        (void) unused;
        fixture->data->selection_ready = FALSE;
        fixture->data->seed_events = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
        fixture->hook = HOOK_REMOVE_DURING_ENUMERATION;
        fixture->trigger = removed;
        seed_sensor_candidates (NULL, fixture->data);
        g_assert_cmpuint (fixture->hook_calls, ==, 1);
        g_assert_true (g_hash_table_contains (fixture->data->seed_events,
                                             node_data (removed)->path));
        g_assert_cmpint (sensor_candidate_index (fixture->data, node_data (removed)->path), ==, -1);
        g_clear_pointer (&fixture->data->seed_events, g_hash_table_unref);
        fixture->data->selection_ready = TRUE;
        fixture_select (fixture);
        assert_selected (fixture, DRIVER_TYPE_COMPASS, keeper, &fake_compass);
        g_assert_null (fixture->data->devices[DRIVER_TYPE_LIGHT]);
        g_assert_cmpuint (node_data (removed)->discovered[FIXTURE_LIGHT_FIRST], ==, 0);
        g_assert_cmpuint (node_data (removed)->opened[FIXTURE_LIGHT_FIRST], ==, 0);
}

static void
test_seed_added_during_enumeration (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *added = fixture_node (fixture, "/fixture/seed-added", "not-enumerated",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        (void) unused;
        fixture->data->selection_ready = FALSE;
        fixture->data->seed_events = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
        fixture->hook = HOOK_ADD_DURING_ENUMERATION;
        fixture->trigger = added;
        seed_sensor_candidates (NULL, fixture->data);
        g_assert_cmpuint (fixture->hook_calls, ==, 1);
        g_clear_pointer (&fixture->data->seed_events, g_hash_table_unref);
        fixture->data->selection_ready = TRUE;
        fixture_select (fixture);
        assert_selected (fixture, DRIVER_TYPE_LIGHT, added, &iio_buffer_light);
        g_assert_cmpuint (node_data (added)->opened[FIXTURE_LIGHT_FIRST], ==, 1);
}

static void
test_seed_changed_during_enumeration (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *old = fixture_node (fixture, "/fixture/seed-changed", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        GUdevDevice *fresh = fixture_node (fixture, "/fixture/seed-changed", "not-enumerated",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        (void) unused;
        fixture->data->selection_ready = FALSE;
        fixture->data->seed_events = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
        fixture->hook = HOOK_CHANGE_DURING_ENUMERATION;
        fixture->trigger = fresh;
        seed_sensor_candidates (NULL, fixture->data);
        g_assert_cmpuint (fixture->hook_calls, ==, 1);
        g_clear_pointer (&fixture->data->seed_events, g_hash_table_unref);
        fixture->data->selection_ready = TRUE;
        fixture_select (fixture);
        assert_selected (fixture, DRIVER_TYPE_LIGHT, fresh, &iio_buffer_light);
        g_assert_cmpuint (node_data (old)->discovered[FIXTURE_LIGHT_FIRST], ==, 0);
        g_assert_cmpuint (node_data (fresh)->opened[FIXTURE_LIGHT_FIRST], ==, 1);
}

static void
fixture_future_light_client (SelectionFixture *fixture)
{
        g_autoptr(GError) error = NULL;
        const char *sender;
        guint watch;
        fixture->future_client = g_dbus_connection_new_for_address_sync (
                g_test_dbus_get_bus_address (private_bus),
                G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT |
                G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION, NULL, NULL, &error);
        g_assert_no_error (error);
        g_assert_nonnull (fixture->future_client);
        g_dbus_connection_set_exit_on_close (fixture->future_client, FALSE);
        sender = g_dbus_connection_get_unique_name (fixture->future_client);
        g_assert_cmpstr (sender, !=, g_dbus_connection_get_unique_name (fixture->data->connection));
        /* Actual private-bus identity/watch, not a fabricated nonzero watch ID.
         * This models the existing successful Claim intent while no LIGHT
         * device exists; D-Bus method/authorization coverage is elsewhere. */
        watch = g_bus_watch_name_on_connection (fixture->data->connection, sender,
                G_BUS_NAME_WATCHER_FLAGS_NONE, NULL, client_vanished_cb,
                fixture->data, NULL);
        g_assert_cmpuint (watch, >, 0);
        g_hash_table_insert (fixture->data->clients[DRIVER_TYPE_LIGHT],
                             g_strdup (sender), GUINT_TO_POINTER (watch));
}

static void
test_future_client_activation_after_selection (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *light = fixture_node (fixture, "/fixture/prepared-light", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        GUdevDevice *compass = fixture_node (fixture, "/fixture/later-compass", "platform",
                DRIVER_BIT (FIXTURE_COMPASS), 0);
        SensorStartAttempt *attempt;
        (void) unused;
        fixture_future_light_client (fixture);
        fixture_register (fixture, light);
        fixture_register (fixture, compass);
        fixture->hook = HOOK_ASSERT_PREPARED_LIGHT;
        fixture->trigger = compass;
        fixture->other = light;
        fixture->trigger_driver = FIXTURE_COMPASS;
        fixture_select (fixture);
        g_assert_cmpuint (fixture->hook_calls, ==, 1);
        assert_selected (fixture, DRIVER_TYPE_LIGHT, light, &iio_buffer_light);
        assert_selected (fixture, DRIVER_TYPE_COMPASS, compass, &fake_compass);
        attempt = fixture->data->starts[DRIVER_TYPE_LIGHT];
        g_assert_nonnull (attempt);
        g_assert_true (attempt == fixture->observed_prepared);
        g_assert_true (attempt->open_started);
        g_assert_true (attempt->open_done);
        g_assert_true (attempt->open_ok);
        /* Fixture polling intentionally emits no reading: this remains the
         * same current first-reading token, not a hardware stream receipt. */
        g_assert_false (attempt->first_reading);
        g_assert_null (fixture->data->selection_starts);
        g_assert_cmpuint (node_data (light)->started[FIXTURE_LIGHT_FIRST], ==, 1);
        g_assert_cmpuint (node_data (light)->stopped[FIXTURE_LIGHT_FIRST], ==, 0);
}

static void
test_future_client_release_before_activation (SelectionFixture *fixture, gconstpointer unused)
{
        GUdevDevice *light = fixture_node (fixture, "/fixture/canceled-light", "iio",
                DRIVER_BIT (FIXTURE_LIGHT_FIRST), 0);
        GUdevDevice *compass = fixture_node (fixture, "/fixture/canceling-compass", "platform",
                DRIVER_BIT (FIXTURE_COMPASS), 0);
        (void) unused;
        fixture_future_light_client (fixture);
        fixture_register (fixture, light);
        fixture_register (fixture, compass);
        fixture->hook = HOOK_RELEASE_PREPARED_LIGHT;
        fixture->trigger = compass;
        fixture->other = light;
        fixture->trigger_driver = FIXTURE_COMPASS;
        fixture_select (fixture);
        g_assert_cmpuint (fixture->hook_calls, ==, 1);
        assert_selected (fixture, DRIVER_TYPE_LIGHT, light, &iio_buffer_light);
        assert_selected (fixture, DRIVER_TYPE_COMPASS, compass, &fake_compass);
        g_assert_null (fixture->data->starts[DRIVER_TYPE_LIGHT]);
        g_assert_null (fixture->data->selection_starts);
        g_assert_cmpuint (g_hash_table_size (fixture->data->clients[DRIVER_TYPE_LIGHT]), ==, 0);
        g_assert_cmpuint (node_data (light)->started[FIXTURE_LIGHT_FIRST], ==, 0);
        g_assert_cmpuint (node_data (light)->stopped[FIXTURE_LIGHT_FIRST], ==, 0);
        fixture_select (fixture);
        /* These zero-effect checks cover canceled activation. Final fixture
         * destruction still uses the normal generic driver_close STOP. */
        g_assert_cmpuint (node_data (light)->started[FIXTURE_LIGHT_FIRST], ==, 0);
        g_assert_cmpuint (node_data (light)->stopped[FIXTURE_LIGHT_FIRST], ==, 0);
}

#define SELECTION_TEST(name, function) \
        g_test_add ("/sensor-selection/" name, SelectionFixture, NULL, \
                    fixture_setup, function, fixture_teardown)

int
main (int argc, char **argv)
{
        int result;
        g_test_init (&argc, &argv, NULL);
        private_bus = g_test_dbus_new (G_TEST_DBUS_NONE);
        g_test_dbus_up (private_bus);
        SELECTION_TEST ("fallback-same-source", test_fallback_same_source);
        SELECTION_TEST ("fallback-existing-alternate", test_fallback_existing_alternate);
        SELECTION_TEST ("multitype", test_multitype);
        SELECTION_TEST ("stale-snapshot-removed", test_stale_snapshot_removed);
        SELECTION_TEST ("same-path-replacement", test_same_path_replacement);
        SELECTION_TEST ("shutdown-during-open", test_shutdown_during_open);
        SELECTION_TEST ("preserve-faulted-winner", test_preserve_faulted_winner);
        SELECTION_TEST ("all-rejections-finite", test_all_rejections_finite);
        SELECTION_TEST ("inflight-change-bounded", test_inflight_change_bounded);
        SELECTION_TEST ("known-alternate-after-remove", test_known_alternate_after_remove);
        SELECTION_TEST ("all-types-detached-before-close", test_all_types_detached_before_close);
        SELECTION_TEST ("replacement-deferred-during-close", test_replacement_deferred_during_close);
        SELECTION_TEST ("seed-duplicates", test_seed_duplicates);
        SELECTION_TEST ("seed-removed-before-register", test_seed_removed_before_register);
        SELECTION_TEST ("seed-added-during-enumeration", test_seed_added_during_enumeration);
        SELECTION_TEST ("seed-changed-during-enumeration", test_seed_changed_during_enumeration);
        SELECTION_TEST ("future-client-activation-after-selection", test_future_client_activation_after_selection);
        SELECTION_TEST ("future-client-release-before-activation", test_future_client_release_before_activation);
        result = g_test_run ();
        g_test_dbus_down (private_bus);
        g_object_unref (private_bus);
        return result;
}
