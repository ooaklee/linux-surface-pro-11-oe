#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Private-bus tests of production Claim recovery with a provider-only seam."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

import dbusmock
from gi.repository import Gio, GLib

spec = importlib.util.spec_from_file_location(
    '_ssc_claim_base', Path(__file__).with_name('integration-test.py'))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)


class Claims(dbusmock.DBusTestCase):
    get_dbus_property = base.Tests.get_dbus_property
    get_compass_dbus_property = base.Tests.get_compass_dbus_property
    assertEventually = base.Tests.assertEventually
    have_text_in_log = base.Tests.have_text_in_log
    count_text_in_log = base.Tests.count_text_in_log

    @classmethod
    def setUpClass(cls):
        base.Tests.setUpClass.__func__(cls)
        cls.daemon_path = os.environ.get('SSC_CLAIM_DAEMON',
            os.path.join(os.environ.get('top_builddir', '.'), 'src',
                         'iio-sensor-proxy-ssc-claim-test'))
        if not os.access(cls.daemon_path, os.X_OK):
            raise RuntimeError('Build the non-installed SSC Claim test daemon first')
        print('SSC provider-only test daemon: ' + cls.daemon_path)

    @classmethod
    def tearDownClass(cls):
        base.Tests.tearDownClass.__func__(cls)

    def setUp(self):
        base.Tests.setUp(self)
        self.fixture = tempfile.TemporaryDirectory(prefix='ssc-claim-')
        self.addCleanup(self.fixture.cleanup)
        self.directory = Path(self.fixture.name)
        self.mode('success')

    def start_daemon(self, env=None, wrapper=None):
        # Apply loader ordering only to the daemon's private environment.
        # Python, the D-Bus clients and the mocked polkit process must not load
        # ASan. Preserve umockdev's existing preload for the child daemon.
        child_env = dict(os.environ if env is None else env)
        supplied = child_env.get('SSC_CLAIM_ASAN_PRELOAD')
        if supplied is not None:
            path = Path(supplied)
            if not path.is_absolute() or not path.is_file():
                raise RuntimeError('SSC_CLAIM_ASAN_PRELOAD must name an existing absolute ASan library')
            resolved = path.resolve(strict=True)
            if (not resolved.name.startswith('libasan.so.') or
                    any(character.isspace() or character == ':' for character in str(resolved))):
                raise RuntimeError('SSC_CLAIM_ASAN_PRELOAD must resolve to an unambiguous libasan.so.* path')
            existing = child_env.get('LD_PRELOAD', '')
            child_env['LD_PRELOAD'] = str(resolved) + (':' + existing if existing else '')
            print('SSC Claim daemon-only ASan preload: ' + str(resolved))
        base.Tests.start_daemon(self, child_env, wrapper)

    def stop_daemon(self):
        daemon = self.daemon
        if daemon is None:
            return
        termination = 'already-exited'
        try:
            if daemon.poll() is None:
                daemon.terminate()
                termination = 'SIGTERM'
            try:
                code = daemon.wait(timeout=10)
            except subprocess.TimeoutExpired:
                # Bounded cleanup is not success: preserve the full logs and
                # make the test fail if normal shutdown required SIGKILL.
                daemon.kill()
                termination = 'SIGKILL-fallback'
                daemon.wait(timeout=5)
                self.fail('SSC Claim daemon did not exit after bounded SIGTERM')
            finally:
                print('SSC_CLAIM_DAEMON_EXIT={} termination={}'.format(
                    daemon.returncode, termination))
            self.assertEqual(code, 0, 'SSC Claim daemon failed during normal shutdown')
        finally:
            self.daemon = None
            self.proxy = None

    def tearDown(self):
        polkit = self.polkitd
        try:
            self.stop_daemon()
        finally:
            # Keep diagnostic output even when shutdown or sanitizer checks
            # fail; the runner retains these complete harness streams.
            trace = self.directory / 'trace'
            if trace.exists():
                print('--- provider-only trace ---\n' + trace.read_text() + '--- end trace ---')
            if self.log:
                print('--- actual test-daemon stdout/stderr ---\n' +
                      Path(self.log.name).read_text() + '--- end daemon log ---')
                self.log_printed = True
            if polkit:
                if polkit.poll() is None:
                    polkit.terminate()
                try:
                    polkit.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    polkit.kill()
                    polkit.wait(timeout=5)
                if polkit.stdout:
                    polkit.stdout.close()
            self.polkitd = None
            if hasattr(self, 'testbed'):
                del self.testbed

    def run(self, result=None):
        try:
            super().run(result)
            if (result and result.errors + result.failures and getattr(self, 'log', None)
                    and not getattr(self, 'log_printed', False)):
                sys.stderr.write('\n--- actual test-daemon log ---\n' +
                                 Path(self.log.name).read_text() + '--- end log ---\n')
        finally:
            if getattr(self, 'log', None):
                self.log.close()

    def mode(self, value):
        (self.directory / 'mode').write_text(value)

    def trace(self):
        path = self.directory / 'trace'
        return path.read_text().splitlines() if path.exists() else []

    def events(self, event, sensor=None):
        return [line for line in self.trace() if line.split()[1] == event and
                (sensor is None or int(line.split()[0]) == sensor)]

    def light(self, name):
        return self.testbed.add_device('misc', name, None, [],
            ['NAME', '"SSC Claim Test Light"', 'DEVNAME', '/dev/fastrpc-test',
             'IIO_SENSOR_PROXY_TYPE', 'ssc-light'])

    def candidate_sensor(self, name, sensor_type):
        return self.testbed.add_device('misc', name, None, [],
            ['NAME', '"SSC Candidate Test"', 'DEVNAME', '/dev/fastrpc-test',
             'IIO_SENSOR_PROXY_TYPE', sensor_type])

    def candidate_accel(self, name, scale='0.000001'):
        return self.testbed.add_device('iio', name, None,
            ['name', 'Candidate IIO Accelerometer', 'in_accel_x_raw', '0',
             'in_accel_y_raw', '-256000000', 'in_accel_z_raw', '0',
             'in_accel_scale', scale, 'sampling_frequency', '5.2'],
            ['NAME', '"Candidate IIO Accelerometer"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-accel'])

    def candidate_light(self, name, level='73'):
        return self.testbed.add_device('iio', name, None,
            ['name', 'Candidate IIO Light', 'in_illuminance_input', level],
            ['NAME', '"Candidate IIO Light"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-als'])

    def start_candidate_daemon(self):
        # Do not assume availability before a gated constructor is admitted.
        # The input/fake-compass anchor also keeps all-failed light/accel cases
        # alive, so absence is a D-Bus assertion rather than a startup timeout.
        self.anchor_node = self.testbed.add_device('input', 'claim-anchor', None, [],
                                                  ['NAME', '"Power Button"'])
        env = os.environ.copy()
        env['FAKE_COMPASS'] = '1'
        env['SSC_CLAIM_FIXTURE_DIR'] = str(self.directory)
        self.start_daemon(env)

    def control_constructor(self, action, role, sensor_type='*', ordinal=1):
        self.assertIn(action, ('block', 'fail'))
        self.assertIn(role, ('discover', 'open'))
        (self.directory / ('construct-' + action + '-role')).write_text(
            '{} {} {}'.format(sensor_type, role, ordinal))

    def constructor_events(self, event, role, sensor_type=None):
        # Columns come from the typed provider seam, not the proxy's candidate
        # bookkeeping. Source identity is checked separately in actual logs.
        return [line for line in self.events(event)
                if line.split()[3] == role and
                (sensor_type is None or line.split()[2] == sensor_type)]

    def blocked_constructor(self, role, sensor_type=None):
        self.assertEventually(lambda: bool(self.constructor_events(
            'CONSTRUCT_ROLE_BEGIN', role, sensor_type)))
        return int(self.constructor_events('CONSTRUCT_ROLE_BEGIN', role, sensor_type)[-1].split()[0])

    def release_constructor(self, sensor):
        (self.directory / ('construct-release-' + str(sensor))).write_text('release')

    def wait_candidate_event(self, action, node):
        self.assertEventually(lambda: self.have_text_in_log(
            'Sensor changes: action = {}, device = {}'.format(action, node)))

    def start(self, mode, light=True):
        self.mode(mode)
        self.anchor_node = self.testbed.add_device('input', 'claim-anchor', None, [],
                                                  ['NAME', '"Power Button"'])
        if light:
            self.light_node = self.light('claim-light')
        env = os.environ.copy()
        env['FAKE_COMPASS'] = '1'
        env['SSC_CLAIM_FIXTURE_DIR'] = str(self.directory)
        self.start_daemon(env)
        self.assertEqual(self.get_dbus_property('HasAmbientLight'), light)

    def client(self):
        connection = Gio.DBusConnection.new_for_address_sync(
            self.test_bus.get_bus_address(),
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT |
            Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        self.addCleanup(self.close_connection, connection)
        return Gio.DBusProxy.new_sync(connection, Gio.DBusProxyFlags.DO_NOT_AUTO_START,
                                     None, base.SP, base.SP_PATH, base.SP, None)

    def call(self, client, method='ClaimLight'):
        result = {'done': False, 'error': None, 'remote_error': None, 'callbacks': 0}

        def finished(proxy, task, _data):
            result['callbacks'] += 1
            try:
                proxy.call_finish(task)
            except GLib.Error as error:
                result['error'] = str(error)
                result['remote_error'] = Gio.DBusError.get_remote_error(error)
            result['done'] = True

        client.call(method, None, Gio.DBusCallFlags.NONE, 5000, None, finished, None)
        return result

    def complete(self, *results):
        self.assertEventually(lambda: all(row['done'] for row in results))

    def opening(self):
        self.assertEventually(lambda: bool(self.events('OPEN_BEGIN')))
        return int(self.events('OPEN_BEGIN')[-1].split()[0])

    @staticmethod
    def close_connection(connection):
        if not connection.is_closed():
            connection.close_sync(None)

    def wait_past_test_deadline(self):
        # Only the noninstalled daemon is compiled with a 750ms policy. Keep
        # servicing the actual private bus for longer, without changing any
        # provider state or pretending a trace counter proves timer removal.
        finish = time.monotonic() + 1.1
        self.assertEventually(lambda: time.monotonic() >= finish, timeout=30)

    def assert_deadline_error(self, result):
        self.assertTrue(result['done'])
        self.assertEqual(result['callbacks'], 1)
        self.assertIsNotNone(result['remote_error'], 'Client-side timeout is not a proxy deadline reply')
        self.assertIn('SSC first valid reading deadline expired', result['error'])
        self.assertNotIn('Test fixture gate was not released', result['error'])

    def assert_no_native_fault(self, sensor):
        for event in ('STREAM_ERROR', 'OPEN_FAILED', 'GATE_TIMEOUT', 'CLOSE_INSIDE_ERROR'):
            self.assertFalse(self.events(event, sensor), 'Proxy deadline was confused with provider ' + event)

    def trigger_reading(self, sensor):
        (self.directory / ('sample-' + str(sensor))).write_text('sample')
        self.assertEventually(lambda: bool(self.events('FRESH_SAMPLE', sensor)))

    def release_gate(self, sensor):
        (self.directory / ('release-' + str(sensor))).write_text('release')

    def assert_recovered(self, sensor):
        self.assertEventually(lambda: bool(self.events('CLOSE_OK', sensor)))
        lines = self.trace()
        failed = next(i for i, line in enumerate(lines)
                      if line.startswith(str(sensor) + ' OPEN_FAILED '))
        closed = next(i for i, line in enumerate(lines)
                      if i > failed and line.startswith(str(sensor) + ' CLOSE_OK '))
        self.assertGreater(closed, failed)

    def test_failed_open_replies_to_all_waiters_and_retry(self):
        self.start('fail-block')
        first_client, second_client = self.client(), self.client()
        first = self.call(first_client)
        sensor = self.opening()
        duplicate = self.call(first_client)
        second = self.call(second_client)
        self.assertEventually(lambda: self.count_text_in_log(
            "Handling driver refcounting method 'ClaimLight'") >= 3)
        self.assertFalse(any(row['done'] for row in (first, duplicate, second)))
        self.release_gate(sensor)
        self.complete(first, duplicate, second)
        for row in (first, duplicate, second):
            self.assertIn('Injected SSC OPEN failure', row['error'])
        self.assert_recovered(sensor)
        self.mode('success')
        retry = self.call(first_client)
        self.complete(retry)
        self.assertIsNone(retry['error'])
        self.assertEventually(lambda:
            first_client.get_cached_property('LightLevel').unpack() == 42)
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 2)
        self.assertFalse(self.events('OPEN_REJECTED'))

    def test_early_sample_does_not_hide_open_failure(self):
        self.start('sample-fail-block')
        client = self.client()
        result = self.call(client)
        sensor = self.opening()
        self.assertEventually(lambda: bool(self.events('EARLY_SAMPLE', sensor)))
        self.assertFalse(result['done'], 'Claim succeeded before OPEN returned')
        self.release_gate(sensor)
        self.complete(result)
        self.assertIn('Injected SSC OPEN failure', result['error'])
        self.assert_recovered(sensor)

    def test_failed_close_is_retried_before_open(self):
        self.start('fail-block')
        (self.directory / 'close-fail').write_text('yes')
        client = self.client()
        failed = self.call(client)
        sensor = self.opening()
        self.release_gate(sensor)
        self.complete(failed)
        self.assertIn('Injected SSC OPEN failure', failed['error'])
        self.assertIn('Injected SSC CLOSE failure', failed['error'])
        self.assertTrue(self.events('CLOSE_FAILED', sensor))
        (self.directory / 'close-fail').write_text('no')
        self.mode('success')
        retry = self.call(client)
        self.complete(retry)
        self.assertIsNone(retry['error'])
        lines = self.trace()
        opened = [i for i, line in enumerate(lines)
                  if line.startswith(str(sensor) + ' OPEN_BEGIN ')]
        self.assertEqual(len(opened), 2)
        self.assertTrue(any(lines[i].startswith(str(sensor) + ' CLOSE_OK ')
                            for i in range(opened[0] + 1, opened[1])))
        self.assertFalse(self.events('OPEN_REJECTED'))

    def test_release_reclaim_during_open_then_retry(self):
        self.start('fail-block')
        client = self.client()
        old = self.call(client)
        sensor = self.opening()
        release = self.call(client, 'ReleaseLight')
        self.complete(old, release)
        self.assertIn('released while starting', old['error'])
        self.assertIsNone(release['error'])
        during = self.call(client)
        self.complete(during)
        self.assertIsNotNone(during['error'], 'Overlapping native OPEN cannot succeed')
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 1)
        self.mode('success')
        self.release_gate(sensor)
        self.assert_recovered(sensor)
        retry = self.call(client)
        self.complete(retry)
        self.assertIsNone(retry['error'])

    def test_removal_replacement_survives_stale_open_failure(self):
        self.start('fail-block')
        old_client, replacement_client = self.client(), self.client()
        old = self.call(old_client)
        old_sensor = self.opening()
        self.testbed.uevent(self.light_node, 'remove')
        self.complete(old)
        self.assertIn('Sensor removed', old['error'])
        self.assertEventually(lambda: not self.get_dbus_property('HasAmbientLight'))
        self.mode('success')
        replacement = self.light('claim-light-replacement')
        self.testbed.uevent(replacement, 'add')
        self.assertEventually(lambda: self.get_dbus_property('HasAmbientLight'))
        accepted = self.call(replacement_client)
        self.complete(accepted)
        self.assertIsNone(accepted['error'])
        new_sensor = int(self.events('OPEN_BEGIN')[-1].split()[0])
        self.assertNotEqual(old_sensor, new_sensor)
        self.release_gate(old_sensor)
        self.assert_recovered(old_sensor)
        joined = self.call(old_client)
        self.complete(joined)
        self.assertIsNone(joined['error'])
        self.assertEqual(len(self.events('OPEN_BEGIN', new_sensor)), 1)
        self.assertFalse(self.events('CLOSE_OK', new_sensor))
        released = self.call(replacement_client, 'ReleaseLight')
        self.complete(released)
        self.assertIsNone(released['error'])
        self.assertFalse(self.events('CLOSE_OK', new_sensor), 'Older failure erased a replacement claim')
        released = self.call(old_client, 'ReleaseLight')
        self.complete(released)
        self.assertIsNone(released['error'])
        self.assertTrue(self.events('CLOSE_OK', new_sensor))

    def test_legacy_unrequested_readings(self):
        base.Tests.test_unrequested_readings(self)

    def _check_unrelated_constructor_event(self, hotplug):
        # Discovery creates object 1; the device constructor creates object 2.
        # The gate runs the actual proxy context, not a duplicate probe model.
        (self.directory / 'construct-block-id').write_text('2')
        if not hotplug:
            self.light_node = self.light('claim-light')
        self.start_candidate_daemon()
        if hotplug:
            # add_device itself sends the add event. A second add for the same
            # source would correctly invalidate its still-active probe.
            self.light_node = self.light('probe-hotplug-light')
        self.assertEventually(lambda: bool(self.events('CONSTRUCT_BEGIN', 2)))
        self.assertFalse(self.get_dbus_property('HasAmbientLight'),
                         'A constructor in progress is not an admitted sensor')
        client = self.client()
        if not hotplug:
            # An absent-device Claim records future intent; Release must also
            # tolerate this not-yet-published DEVICE slot.
            claim = self.call(client)
            self.complete(claim)
            self.assertIsNone(claim['error'])
            release = self.call(client, 'ReleaseLight')
            self.complete(release)
            self.assertIsNone(release['error'])
        self.testbed.uevent(self.anchor_node, 'change')
        # Both startup and hotplug selection now run outside GUdev's event
        # handler. Require actual unrelated dispatch while either constructor
        # is still gated, not merely an event queued until after it returns.
        self.wait_candidate_event('change', self.anchor_node)
        self.assertIsNone(self.daemon.poll())
        (self.directory / 'construct-release-2').write_text('release')
        self.assertEventually(lambda: bool(self.events('CONSTRUCT_OK', 2)))
        self.assertEventually(lambda: self.have_text_in_log(
            'Sensor changes: action = change, device = ' + self.anchor_node))
        self.assertEventually(lambda: self.get_dbus_property('HasAmbientLight'))
        accepted = self.call(client)
        self.complete(accepted)
        self.assertIsNone(accepted['error'])
        self.assertEventually(lambda: client.get_cached_property('LightLevel').unpack() == 42)
        self.assertEqual(len(self.events('OPEN_BEGIN', 2)), 1)
        with open(self.log.name) as stream:
            self.assertNotIn('CRITICAL', stream.read())

    def test_startup_constructor_ignores_unrelated_event(self):
        '''nested unrelated GUdev change does not discard startup construction'''
        self._check_unrelated_constructor_event(hotplug=False)

    def test_hotplug_constructor_ignores_unrelated_event(self):
        '''nested unrelated GUdev change does not discard hotplug construction'''
        self._check_unrelated_constructor_event(hotplug=True)

    def test_candidate_startup_invalid_iio_uses_existing_ssc(self):
        '''A rejected earlier IIO OPEN cannot hide an enumerated SSC candidate.'''
        rejected = self.candidate_accel('candidate-invalid-iio', scale='junk')
        accepted = self.candidate_sensor('candidate-ssc-accel', 'ssc-accel')
        self.start_candidate_daemon()
        self.assertTrue(self.have_text_in_log('Invalid accelerometer scale'))
        self.assertEqual(base.Tests.read_sysfs_attr(self, rejected, 'sampling_frequency'), b'5.2')
        self.assertTrue(self.get_dbus_property('HasAccelerometer'))
        log = Path(self.log.name).read_text()
        first = 'Trying device {} of type accelerometer at IIO Poll accelerometer'.format(rejected)
        second = 'Trying device {} of type accelerometer at SSC accelerometer sensor'.format(accepted)
        self.assertLess(log.index(first), log.index(second))
        client = self.client()
        claimed = self.call(client, 'ClaimAccelerometer')
        self.complete(claimed)
        self.assertIsNone(claimed['error'])
        self.assertEqual(claimed['callbacks'], 1)
        self.assertEventually(lambda:
            client.get_cached_property('AccelerometerOrientation').unpack() == 'normal')
        opened = self.events('OPEN_BEGIN')
        self.assertEqual(len(opened), 1)
        sensor = int(opened[0].split()[0])
        self.assertTrue(self.constructor_events('CONSTRUCT_CALL', 'open', 'SSCSensorAccelerometer'))
        self.assertTrue(self.events('OPEN_OK', sensor))

    def test_candidate_startup_constructor_failure_uses_existing_alternative(self):
        '''A failed typed constructor is not a reservation or an automatic retry.'''
        nodes = {self.light('candidate-first-light'), self.light('candidate-second-light')}
        self.control_constructor('fail', 'open', 'SSCSensorLight')
        self.start_candidate_daemon()
        self.assertTrue(self.get_dbus_property('HasAmbientLight'))
        attempts = self.constructor_events('CONSTRUCT_CALL', 'open', 'SSCSensorLight')
        failures = self.constructor_events('CONSTRUCT_FAILED', 'open', 'SSCSensorLight')
        self.assertEqual(len(attempts), 2)
        self.assertEqual(len(failures), 1)
        failed_sensor = int(failures[0].split()[0])
        self.assertTrue(self.events('FINALIZED', failed_sensor))
        trying = [line.split('Trying device ', 1)[1].split(' of type ', 1)[0]
                  for line in Path(self.log.name).read_text().splitlines()
                  if ' of type ambient light sensor at SSC light sensor' in line]
        self.assertEqual(len(trying), 2)
        self.assertEqual(set(trying), nodes, 'Fallback must use the distinct preexisting source')
        client = self.client()
        claimed = self.call(client)
        self.complete(claimed)
        self.assertIsNone(claimed['error'])
        self.assertEventually(lambda: client.get_cached_property('LightLevel').unpack() == 42)
        self.assertEqual(len(self.events('OPEN_BEGIN')), 1)
        self.assertNotEqual(int(self.events('OPEN_BEGIN')[0].split()[0]), failed_sensor)
        self.testbed.uevent(self.anchor_node, 'change')
        self.wait_candidate_event('change', self.anchor_node)
        duplicate = self.call(client)
        self.complete(duplicate)
        self.assertIsNone(duplicate['error'])
        self.assertEqual(len(self.constructor_events('CONSTRUCT_CALL', 'open', 'SSCSensorLight')), 2)
        self.assertEqual(len(self.events('OPEN_BEGIN')), 1)

    def test_candidate_discovery_captures_hotplug(self):
        '''An add dispatched during startup discovery is retained for later selection.'''
        self.light_node = self.light('candidate-discovery-light')
        self.control_constructor('block', 'discover')
        self.start_candidate_daemon()
        sensor = self.blocked_constructor('discover')
        self.assertFalse(self.get_dbus_property('HasAmbientLight'))
        accel = self.candidate_accel('candidate-hotplug-accel')
        self.wait_candidate_event('add', accel)  # Actual nested GUdev dispatch.
        self.assertFalse(self.get_dbus_property('HasAccelerometer'),
                         'Selection must not run recursively inside discovery')
        self.release_constructor(sensor)
        self.assertEventually(lambda: self.get_dbus_property('HasAmbientLight') and
                              self.get_dbus_property('HasAccelerometer'))
        client = self.client()
        accel_claim, light_claim = self.call(client, 'ClaimAccelerometer'), self.call(client)
        self.complete(accel_claim, light_claim)
        self.assertIsNone(accel_claim['error'])
        self.assertIsNone(light_claim['error'])
        self.assertEventually(lambda: client.get_cached_property('LightLevel').unpack() == 42 and
                              client.get_cached_property('AccelerometerOrientation').unpack() == 'normal')
        self.assertEqual(len(self.constructor_events('CONSTRUCT_CALL', 'open', 'SSCSensorLight')), 1)
        self.assertEqual(len(self.events('OPEN_BEGIN')), 1, 'IIO polling must not use a typed SSC OPEN')

    def test_candidate_pending_source_remove_during_constructor(self):
        '''Removing a different registered source retires it before its turn.'''
        nodes = {
            'SSCSensorLight': (self.light('candidate-pending-light'), 'HasAmbientLight',
                               'ClaimLight', 'LightLevel', 42),
            'SSCSensorProximity': (self.candidate_sensor('candidate-pending-proximity', 'ssc-proximity'),
                                   'HasProximity', 'ClaimProximity', 'ProximityNear', True),
        }
        self.control_constructor('block', 'open')
        self.start_candidate_daemon()
        sensor = self.blocked_constructor('open')
        active_type = self.constructor_events('CONSTRUCT_ROLE_BEGIN', 'open')[-1].split()[2]
        self.assertIn(active_type, nodes)
        removed_type = next(kind for kind in nodes if kind != active_type)
        removed = nodes[removed_type]
        self.testbed.uevent(removed[0], 'remove')
        self.wait_candidate_event('remove', removed[0])
        self.testbed.remove_device(removed[0])
        self.release_constructor(sensor)
        active = nodes[active_type]
        self.assertEventually(lambda: self.get_dbus_property(active[1]))
        self.assertFalse(self.get_dbus_property(removed[1]))
        self.assertFalse(self.constructor_events('CONSTRUCT_CALL', 'open', removed_type),
                         'A removed pending source must never be opened from the old snapshot')
        client = self.client()
        claimed = self.call(client, active[2])
        self.complete(claimed)
        self.assertIsNone(claimed['error'])
        self.assertEventually(lambda: client.get_cached_property(active[3]).unpack() == active[4])
        self.assertEqual(len(self.events('OPEN_BEGIN')), 1)
        self.assertEqual(int(self.events('OPEN_BEGIN')[0].split()[0]), sensor)

    def _check_candidate_shutdown(self, role):
        self.light_node = self.light('candidate-shutdown-light')
        self.control_constructor('block', role, 'SSCSensorLight')
        self.start_candidate_daemon()
        sensor = self.blocked_constructor(role, 'SSCSensorLight')
        self.assertFalse(self.get_dbus_property('HasAmbientLight'))
        observer, changes = self.observe_availability()
        self.assertFalse(observer.get_cached_property('HasAmbientLight').unpack())
        self.daemon.terminate()
        self.assertEventually(lambda: self.have_text_in_log('Shutting down'))
        self.assertIsNone(self.daemon.poll(), 'The constructor must still be returning through production code')
        self.release_constructor(sensor)
        self.assertEventually(lambda: self.daemon.poll() is not None)
        self.stop_daemon()  # Requires actual graceful exit0, including under SAN.
        self.assertFalse(any(row.get('HasAmbientLight', False) for row in changes),
                         'A constructor returning after shutdown published availability')
        self.assertFalse(any('LightLevel' in row for row in changes), 'Shutdown delivered unclaimed readings')
        self.assertFalse(self.events('OPEN_BEGIN'))
        self.assertFalse(self.events('GATE_TIMEOUT'))
        self.assertEqual(len(self.events('FINALIZED', sensor)), 1)
        # Gio clears cached properties when the service loses its bus name;
        # the recorded signal payloads above still prove no TRUE publication.
        self.assertEventually(lambda: observer.get_name_owner() is None)
        self.assertIsNone(observer.get_cached_property('HasAmbientLight'))

    def test_candidate_shutdown_during_discovery(self):
        self._check_candidate_shutdown('discover')

    def test_candidate_shutdown_during_open_constructor(self):
        self._check_candidate_shutdown('open')

    def test_candidate_successful_owner_survives_queued_alternative(self):
        '''A valid in-progress owner wins; queued and later alternates cannot preempt it.'''
        self.light_node = self.light('candidate-owner-light')
        self.control_constructor('block', 'open', 'SSCSensorLight')
        self.start_candidate_daemon()
        sensor = self.blocked_constructor('open', 'SSCSensorLight')
        alternate = self.candidate_light('candidate-queued-iio-light')
        self.wait_candidate_event('add', alternate)
        self.assertFalse(self.get_dbus_property('HasAmbientLight'))
        self.release_constructor(sensor)
        self.assertEventually(lambda: self.get_dbus_property('HasAmbientLight'))
        client = self.client()
        claimed = self.call(client)
        self.complete(claimed)
        self.assertIsNone(claimed['error'])
        self.assertEventually(lambda: client.get_cached_property('LightLevel').unpack() == 42)
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 1)
        self.assertFalse(self.events('CLOSE_OK', sensor))
        self.testbed.set_attribute(alternate, 'in_illuminance_input', '99')
        self.testbed.uevent(alternate, 'change')
        self.wait_candidate_event('change', alternate)
        later = self.candidate_light('candidate-later-iio-light', level='101')
        self.wait_candidate_event('add', later)
        duplicate = self.call(client)
        self.complete(duplicate)
        self.assertIsNone(duplicate['error'])
        self.assertEqual(client.get_cached_property('LightLevel').unpack(), 42)
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 1)
        self.assertEqual(len(self.constructor_events('CONSTRUCT_CALL', 'open', 'SSCSensorLight')), 1)
        self.assertFalse(self.events('CLOSE_OK', sensor), 'An alternate detached the accepted owner')

    def test_candidate_future_intent_replacement_survives_stale_auto_start(self):
        '''Future intent auto-start cannot serialize a replacement behind stale OPEN.'''
        self.light_node = self.light('candidate-future-intent-light')
        self.control_constructor('block', 'open', 'SSCSensorLight')
        self.mode('fail-block')
        self.start_candidate_daemon()
        old_sensor = self.blocked_constructor('open', 'SSCSensorLight')
        self.assertFalse(self.get_dbus_property('HasAmbientLight'))
        old_client, replacement_client = self.client(), self.client()
        future = self.call(old_client)
        self.complete(future)
        self.assertIsNone(future['error'], 'Absent-device Claim must record future intent')
        self.assertEqual(future['callbacks'], 1)
        self.assertFalse(self.events('OPEN_BEGIN'), 'Native OPEN ran before constructor admission')
        self.release_constructor(old_sensor)
        self.assertEqual(self.opening(), old_sensor)
        self.assertTrue(self.events('CONSTRUCT_OK', old_sensor))
        self.assertFalse(self.events('OPEN_FAILED', old_sensor))

        self.testbed.uevent(self.light_node, 'remove')
        self.wait_candidate_event('remove', self.light_node)
        self.assertEventually(lambda: not self.get_dbus_property('HasAmbientLight'))
        self.mode('success')
        replacement = self.light('candidate-future-intent-replacement')
        self.wait_candidate_event('add', replacement)
        # This ordering is the regression oracle: do not release the stale
        # polling OPEN to manufacture progress in the constructor selector.
        self.assertEventually(lambda: self.get_dbus_property('HasAmbientLight'))
        accepted = self.call(replacement_client)
        self.complete(accepted)
        self.assertIsNone(accepted['error'])
        self.assertEventually(lambda: replacement_client.get_cached_property('LightLevel').unpack() == 42)
        new_sensor = int(self.events('OPEN_BEGIN')[-1].split()[0])
        self.assertNotEqual(old_sensor, new_sensor)
        self.assertEqual(len(self.events('OPEN_BEGIN', new_sensor)), 1)
        self.assertFalse(self.events('OPEN_FAILED', old_sensor))
        self.assertFalse(self.events('CLOSE_OK', old_sensor))
        self.assertFalse(self.events('GATE_TIMEOUT'))

        self.release_gate(old_sensor)
        self.assert_recovered(old_sensor)
        self.assertEqual(future['callbacks'], 1, 'A stale auto-start replied again to old future intent')
        self.assertIsNone(future['error'])
        joined = self.call(old_client)
        self.complete(joined)
        self.assertIsNone(joined['error'])
        self.assertEqual(len(self.events('OPEN_BEGIN', new_sensor)), 1)
        self.assertFalse(self.events('CLOSE_OK', new_sensor), 'Stale auto-start closed the replacement owner')
        released = self.call(replacement_client, 'ReleaseLight')
        self.complete(released)
        self.assertIsNone(released['error'])
        self.assertFalse(self.events('CLOSE_OK', new_sensor), 'Stale auto-start erased a replacement claim')
        released = self.call(old_client, 'ReleaseLight')
        self.complete(released)
        self.assertIsNone(released['error'])
        self.assertEqual(len(self.events('CLOSE_OK', new_sensor)), 1)

    def observe_availability(self):
        observer = self.client()  # distinct bus name; never claims the sensor
        changes = []
        observer.connect('g-properties-changed',
                         lambda _proxy, changed, _invalidated: changes.append(changed.unpack()))
        return observer, changes

    def assert_fault_then_ready(self, observer, changes):
        values = lambda: [row['HasAmbientLight'] for row in changes if 'HasAmbientLight' in row]
        self.assertEventually(lambda: False in values() and True in values()[values().index(False) + 1:])
        self.assertTrue(observer.get_cached_property('HasAmbientLight').unpack())
        self.assertEqual(observer.get_cached_property('LightLevel').unpack(), 0)
        for changed in changes:
            self.assertEqual(set(changed), {'HasAmbientLight'}, 'Readings reached an unclaimed observer')

    def trigger_fault(self, sensor):
        (self.directory / ('fault-' + str(sensor))).write_text('fault')
        self.assertEventually(lambda: bool(self.events('STREAM_ERROR', sensor)))

    def test_invalid_first_light_samples_wait_for_valid_reading(self):
        '''Invalid adapter signals cannot complete Claim or poison its cache.'''
        self.start('invalid-first-trigger')
        observer, changes = self.observe_availability()
        client = self.client()
        first = self.call(client)
        sensor = self.opening()
        self.assertEventually(lambda: bool(self.events('OPEN_OK_NO_VALID_SAMPLE', sensor)))
        self.assertEventually(lambda: bool(self.events('READING_TRIGGER_ARMED', sensor)))
        self.assertEqual(len(self.events('INVALID_SAMPLE', sensor)), 4)
        duplicate = self.call(client)
        self.assertEventually(lambda: self.count_text_in_log(
            "Handling driver refcounting method 'ClaimLight'") >= 2)
        self.assertFalse(first['done'], 'Invalid data completed the first Claim')
        self.assertFalse(duplicate['done'], 'Duplicate Claim bypassed first-valid-reading wait')
        self.assertEqual(self.get_dbus_property('LightLevel'), 0)
        self.assertEqual(client.get_cached_property('LightLevel').unpack(), 0)
        self.assertEqual(observer.get_cached_property('LightLevel').unpack(), 0)
        self.assertTrue(observer.get_cached_property('HasAmbientLight').unpack())
        self.assertEqual(changes, [], 'Invalid data changed an unclaimed observer')
        (self.directory / ('sample-' + str(sensor))).write_text('sample')
        self.assertEventually(lambda: bool(self.events('FRESH_SAMPLE', sensor)))
        self.complete(first, duplicate)
        self.assertIsNone(first['error'])
        self.assertIsNone(duplicate['error'])
        self.assertEventually(lambda: client.get_cached_property('LightLevel').unpack() == 42)
        self.assertEqual(observer.get_cached_property('LightLevel').unpack(), 0)
        self.assertEqual(changes, [], 'Valid claimed data reached an unclaimed observer')
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 1)
        self.assertFalse(self.events('CLOSE_OK', sensor))
        self.assertFalse(self.events('STREAM_ERROR', sensor))

    def _check_open_stream_fault(self, early):
        self.start('sample-stream-fault-block' if early else 'stream-fault-block')
        observer, changes = self.observe_availability()
        client = self.client()
        failed = self.call(client)
        sensor = self.opening()
        self.assertEventually(lambda: bool(self.events('STREAM_ERROR', sensor)))
        self.complete(failed)
        self.assertIn('Injected SSC stream error', failed['error'])
        self.assertFalse(self.get_dbus_property('HasAmbientLight'))
        self.assertFalse(self.events('CLOSE_OK', sensor), 'CLOSE ran while native OPEN was still gated')
        self.assertFalse(self.events('CLOSE_INSIDE_ERROR'))
        if early:
            self.assertTrue(self.events('EARLY_SAMPLE', sensor))
        self.release_gate(sensor)
        self.assertEventually(lambda: bool(self.events('OPEN_ACK_TRUE_AFTER_FAULT', sensor)))
        self.assertEventually(lambda: bool(self.events('CLOSE_OK', sensor)))
        self.assert_fault_then_ready(observer, changes)
        self.mode('success')
        retry = self.call(client)
        self.complete(retry)
        self.assertIsNone(retry['error'])
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 2)
        self.assertFalse(self.events('OPEN_REJECTED'))
        self.assertFalse(self.events('CLOSE_INSIDE_ERROR'))

    def test_stream_error_before_first_reading_fails_claim(self):
        self._check_open_stream_fault(early=False)

    def test_stream_error_after_early_reading_fails_claim(self):
        self._check_open_stream_fault(early=True)

    def test_stream_error_during_open_retains_failed_close_diagnostic(self):
        '''An unwind CLOSE failure is retained after the original Claim failed.'''
        self.start('stream-fault-block')
        (self.directory / 'close-fail').write_text('yes')
        observer, changes = self.observe_availability()
        client = self.client()
        failed = self.call(client)
        sensor = self.opening()
        self.complete(failed)
        self.assertIn('Injected SSC stream error', failed['error'])
        self.assertFalse(self.get_dbus_property('HasAmbientLight'))
        self.assertFalse(self.events('CLOSE_OK', sensor))
        self.release_gate(sensor)
        self.assertEventually(lambda: bool(self.events('OPEN_ACK_TRUE_AFTER_FAULT', sensor)))
        self.assertEventually(lambda: bool(self.events('CLOSE_FAILED', sensor)))
        self.assertEventually(lambda: self.have_text_in_log('SSC recovery CLOSE failed'))
        diagnostic = [line for line in Path(self.log.name).read_text().splitlines()
                      if 'Sensor stream failure for ambient light sensor:' in line
                      and 'SSC recovery CLOSE failed' in line]
        self.assertTrue(diagnostic, 'Failed cleanup disappeared with the canceled Claim attempt')
        self.assertIn('Injected SSC stream error', diagnostic[-1])
        self.assertIn('Injected SSC CLOSE failure', diagnostic[-1])
        self.assertFalse(observer.get_cached_property('HasAmbientLight').unpack())
        self.assertFalse(self.get_dbus_property('HasAmbientLight'))
        self.assertFalse(self.events('CLOSE_OK', sensor))
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 1,
                         'Failed recovery must not reopen automatically')
        self.assertFalse(self.events('CLOSE_INSIDE_ERROR'))
        (self.directory / 'close-fail').write_text('no')
        self.mode('success')
        retry = self.call(client)
        self.complete(retry)
        self.assertIsNone(retry['error'])
        self.assert_fault_then_ready(observer, changes)
        self.assertEventually(lambda: client.get_cached_property('LightLevel').unpack() == 42)
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 2)
        lines = self.trace()
        failed_close = next(i for i, line in enumerate(lines)
                            if line.startswith(str(sensor) + ' CLOSE_FAILED '))
        recovered_close = next(i for i, line in enumerate(lines)
                               if i > failed_close and line.startswith(str(sensor) + ' CLOSE_OK '))
        fresh_open = max(i for i, line in enumerate(lines)
                         if line.startswith(str(sensor) + ' OPEN_BEGIN '))
        self.assertLess(recovered_close, fresh_open)
        self.assertFalse(self.events('OPEN_REJECTED'))

    def test_stream_error_after_open_before_first_reading_fails_waiters(self):
        '''A later stream error resolves Claims still waiting after OPEN ACK.'''
        self.start('silent-fault-trigger')
        observer, changes = self.observe_availability()
        first_client, second_client = self.client(), self.client()
        first = self.call(first_client)
        sensor = self.opening()
        self.assertEventually(lambda: bool(self.events('OPEN_OK_NO_SAMPLE', sensor)))
        duplicate = self.call(first_client)
        second = self.call(second_client)
        self.assertEventually(lambda: self.count_text_in_log(
            "Handling driver refcounting method 'ClaimLight'") >= 3)
        self.assertFalse(any(row['done'] for row in (first, duplicate, second)),
                         'Native OPEN ACK without a sample must not complete Claim')
        self.trigger_fault(sensor)
        self.complete(first, duplicate, second)
        for row in (first, duplicate, second):
            self.assertIn('Injected SSC stream error', row['error'])
        self.assert_fault_then_ready(observer, changes)
        self.assertTrue(self.events('CLOSE_OK', sensor))
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 1,
                         'Recovery must not reopen without a fresh Claim')
        self.assertFalse(self.events('CLOSE_INSIDE_ERROR'))
        self.mode('success')
        retry = self.call(first_client)
        self.complete(retry)
        self.assertIsNone(retry['error'])
        self.assertEventually(lambda: first_client.get_cached_property('LightLevel').unpack() == 42)
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 2)
        self.assertFalse(self.events('OPEN_REJECTED'))

    def test_stream_error_after_claim_clears_active_claims(self):
        self.start('success-fault-trigger')
        observer, changes = self.observe_availability()
        client = self.client()
        accepted = self.call(client)
        self.complete(accepted)
        self.assertIsNone(accepted['error'])
        sensor = self.opening()
        self.trigger_fault(sensor)
        self.assert_fault_then_ready(observer, changes)
        self.assertTrue(self.events('CLOSE_OK', sensor))
        self.assertEqual(client.get_cached_property('LightLevel').unpack(), 42)
        self.assertFalse(self.events('CLOSE_INSIDE_ERROR'))
        self.mode('success')
        fresh = self.call(client)  # the former claim must no longer be a no-op
        self.complete(fresh)
        self.assertIsNone(fresh['error'])
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 2)

    def test_stream_recovery_close_failure_allows_manual_retry(self):
        self.start('success-fault-trigger')
        observer, changes = self.observe_availability()
        client = self.client()
        accepted = self.call(client)
        self.complete(accepted)
        self.assertIsNone(accepted['error'])
        sensor = self.opening()
        (self.directory / 'close-fail').write_text('yes')
        self.trigger_fault(sensor)
        self.assertEventually(lambda: bool(self.events('CLOSE_FAILED', sensor)))
        self.assertEventually(lambda: not observer.get_cached_property('HasAmbientLight').unpack())
        self.assertFalse(self.get_dbus_property('HasAmbientLight'))
        self.assertFalse(self.events('CLOSE_OK', sensor))
        (self.directory / 'close-fail').write_text('no')
        self.mode('success')
        retry = self.call(client)
        self.complete(retry)
        self.assertIsNone(retry['error'])
        self.assert_fault_then_ready(observer, changes)
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 2)
        self.assertFalse(self.events('OPEN_REJECTED'))
        self.assertFalse(self.events('CLOSE_INSIDE_ERROR'))

    def test_replacement_survives_deferred_stream_recovery(self):
        '''replacement is preserved while an old deferred native CLOSE is gated'''
        self.start('success-fault-trigger')
        client, replacement_client = self.client(), self.client()
        accepted = self.call(client)
        self.complete(accepted)
        self.assertIsNone(accepted['error'])
        old_sensor = self.opening()
        (self.directory / 'close-block-id').write_text(str(old_sensor))
        self.trigger_fault(old_sensor)
        self.assertEventually(lambda: bool(self.events('CLOSE_BEGIN', old_sensor)))
        self.assertFalse(self.get_dbus_property('HasAmbientLight'))
        self.testbed.uevent(self.light_node, 'remove')
        self.assertEventually(lambda: self.have_text_in_log(
            'Sensor type ambient light sensor got removed'))
        self.mode('success')
        replacement = self.light('stream-replacement')
        self.assertEventually(lambda: self.get_dbus_property('HasAmbientLight'))
        fresh = self.call(replacement_client)
        self.complete(fresh)
        self.assertIsNone(fresh['error'])
        new_sensor = int(self.events('OPEN_BEGIN')[-1].split()[0])
        self.assertNotEqual(old_sensor, new_sensor)
        (self.directory / ('close-release-' + str(old_sensor))).write_text('release')
        self.assertEventually(lambda: bool(self.events('CLOSE_OK', old_sensor)))
        self.assertTrue(self.get_dbus_property('HasAmbientLight'))
        joined = self.call(client)
        self.complete(joined)
        self.assertIsNone(joined['error'])
        self.assertEqual(len(self.events('OPEN_BEGIN', new_sensor)), 1)
        self.assertFalse(self.events('CLOSE_OK', new_sensor))
        self.assertFalse(self.events('CLOSE_INSIDE_ERROR'))

    def test_first_reading_deadline_replies_to_all_waiters_and_retry(self):
        self.start('silent-reading-trigger')
        observer, changes = self.observe_availability()
        first_client, second_client = self.client(), self.client()
        first = self.call(first_client)
        sensor = self.opening()
        self.assertEventually(lambda: bool(self.events('HEALTHY_OPEN_RETURN', sensor)))
        duplicate = self.call(first_client)
        second = self.call(second_client)
        self.assertEventually(lambda: self.count_text_in_log(
            "Handling driver refcounting method 'ClaimLight'") >= 3)
        self.assertFalse(any(row['done'] for row in (first, duplicate, second)))
        self.complete(first, duplicate, second)
        for result in (first, duplicate, second):
            self.assert_deadline_error(result)
        self.assert_fault_then_ready(observer, changes)
        self.assertTrue(self.events('CLOSE_OK', sensor))
        self.assertEqual(first_client.get_cached_property('LightLevel').unpack(), 0)
        self.assertEqual(second_client.get_cached_property('LightLevel').unpack(), 0)
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 1, 'Timeout must not authorize automatic OPEN')
        self.assert_no_native_fault(sensor)
        self.mode('success')
        retry = self.call(first_client)
        self.complete(retry)
        self.assertIsNone(retry['error'])
        self.assertEventually(lambda: first_client.get_cached_property('LightLevel').unpack() == 42)
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 2)
        self.assertFalse(self.events('OPEN_REJECTED'))

    def test_first_reading_deadline_invalid_only_samples_do_not_reset(self):
        self.start('invalid-only-trigger')
        observer, changes = self.observe_availability()
        client = self.client()
        result = self.call(client)
        sensor = self.opening()
        self.assertEventually(lambda: len(self.events('INVALID_SAMPLE', sensor)) >= 6)
        self.assertFalse(result['done'], 'Invalid public measurements completed Claim')
        self.complete(result)
        self.assert_deadline_error(result)
        self.assert_fault_then_ready(observer, changes)
        self.assertEqual(client.get_cached_property('LightLevel').unpack(), 0)
        self.assertFalse(self.events('FRESH_SAMPLE', sensor))
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 1)
        self.assert_no_native_fault(sensor)

    def test_first_valid_reading_before_deadline_survives_old_timer(self):
        self.start('silent-reading-trigger')
        observer, changes = self.observe_availability()
        client = self.client()
        result = self.call(client)
        sensor = self.opening()
        self.assertEventually(lambda: bool(self.events('READING_TRIGGER_ARMED', sensor)))
        self.assertFalse(result['done'])
        self.trigger_reading(sensor)
        self.complete(result)
        self.assertIsNone(result['error'])
        self.assertEventually(lambda: client.get_cached_property('LightLevel').unpack() == 42)
        self.wait_past_test_deadline()
        duplicate = self.call(client)
        self.complete(duplicate)
        self.assertIsNone(duplicate['error'])
        self.assertEqual(self.get_dbus_property('LightLevel'), 42)
        self.assertTrue(self.get_dbus_property('HasAmbientLight'))
        self.assertEqual(observer.get_cached_property('LightLevel').unpack(), 0)
        self.assertEqual(changes, [], 'Unclaimed observer received readings or stale availability fault')
        self.assertFalse(self.events('CLOSE_OK', sensor), 'Old timer closed a successfully claimed sensor')
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 1)
        self.assert_no_native_fault(sensor)

    def test_first_reading_last_release_cancels_deadline(self):
        self.start('silent-reading-trigger')
        client = self.client()
        pending = self.call(client)
        sensor = self.opening()
        self.assertEventually(lambda: bool(self.events('HEALTHY_OPEN_RETURN', sensor)))
        released = self.call(client, 'ReleaseLight')
        self.complete(pending, released)
        self.assertIn('released while starting', pending['error'])
        self.assertIsNone(released['error'])
        self.assertEventually(lambda: bool(self.events('CLOSE_OK', sensor)))
        self.wait_past_test_deadline()
        self.mode('success')
        retry = self.call(client)
        self.complete(retry)
        self.assertIsNone(retry['error'])
        self.assertEventually(lambda: client.get_cached_property('LightLevel').unpack() == 42)
        self.assertEqual(len(self.events('CLOSE_OK', sensor)), 1)
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 2)
        self.assert_no_native_fault(sensor)

    def test_first_reading_disconnect_cancels_deadline(self):
        self.start('silent-reading-trigger')
        departing = self.client()
        pending = self.call(departing)
        sensor = self.opening()
        self.assertEventually(lambda: bool(self.events('HEALTHY_OPEN_RETURN', sensor)))
        self.close_connection(departing.get_connection())
        self.complete(pending)
        self.assertIsNotNone(pending['error'])
        self.assertIsNone(pending['remote_error'], 'A disconnected caller must not receive a later deadline reply')
        self.assertEventually(lambda: bool(self.events('CLOSE_OK', sensor)))
        self.wait_past_test_deadline()
        self.mode('success')
        client = self.client()
        fresh = self.call(client)
        self.complete(fresh)
        self.assertIsNone(fresh['error'])
        self.assertEventually(lambda: client.get_cached_property('LightLevel').unpack() == 42)
        self.assertEqual(len(self.events('CLOSE_OK', sensor)), 1)
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 2)
        self.assert_no_native_fault(sensor)

    def test_first_reading_release_preserves_other_waiter_deadline(self):
        self.start('silent-reading-trigger')
        first_client, second_client = self.client(), self.client()
        first = self.call(first_client)
        sensor = self.opening()
        second = self.call(second_client)
        self.assertEventually(lambda: self.count_text_in_log(
            "Handling driver refcounting method 'ClaimLight'") >= 2)
        released = self.call(first_client, 'ReleaseLight')
        self.complete(first, released)
        self.assertIn('released while starting', first['error'])
        self.assertIsNone(released['error'])
        self.assertFalse(second['done'], 'Releasing one sender canceled a different sender')
        self.complete(second)
        self.assert_deadline_error(second)
        self.assertEventually(lambda: bool(self.events('CLOSE_OK', sensor)))
        self.assert_no_native_fault(sensor)

    def test_first_reading_timeout_close_failure_requires_close_before_retry(self):
        self.start('silent-reading-trigger')
        observer, changes = self.observe_availability()
        (self.directory / 'close-fail').write_text('yes')
        client = self.client()
        pending = self.call(client)
        sensor = self.opening()
        self.complete(pending)
        self.assert_deadline_error(pending)
        self.assertEventually(lambda: bool(self.events('CLOSE_FAILED', sensor)))
        self.assertEventually(lambda: self.have_text_in_log('SSC recovery CLOSE failed'))
        diagnostics = [line for line in Path(self.log.name).read_text().splitlines()
                       if 'SSC recovery CLOSE failed' in line]
        self.assertTrue(any('SSC first valid reading deadline expired' in line and
                            'Injected SSC CLOSE failure' in line for line in diagnostics))
        self.assertFalse(observer.get_cached_property('HasAmbientLight').unpack())
        blocked = self.call(client)
        self.complete(blocked)
        self.assertIn('Injected SSC CLOSE failure', blocked['error'])
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 1)
        self.assertFalse(self.events('CLOSE_OK', sensor))
        (self.directory / 'close-fail').write_text('no')
        self.mode('success')
        retry = self.call(client)
        self.complete(retry)
        self.assertIsNone(retry['error'])
        self.assert_fault_then_ready(observer, changes)
        self.assertEventually(lambda: client.get_cached_property('LightLevel').unpack() == 42)
        lines = self.trace()
        recovered = next(i for i, line in enumerate(lines) if line.startswith(str(sensor) + ' CLOSE_OK '))
        reopened = max(i for i, line in enumerate(lines) if line.startswith(str(sensor) + ' OPEN_BEGIN '))
        self.assertLess(recovered, reopened)
        self.assert_no_native_fault(sensor)

    def test_first_reading_timeout_reentrant_claim_during_close(self):
        self.start('silent-reading-trigger')
        client, nested_client = self.client(), self.client()
        pending = self.call(client)
        sensor = self.opening()
        (self.directory / 'close-block-id').write_text(str(sensor))
        self.assertEventually(lambda: bool(self.events('CLOSE_BEGIN', sensor)))
        self.complete(pending)
        self.assert_deadline_error(pending)
        during = self.call(nested_client)
        self.complete(during)
        self.assertIsNotNone(during['remote_error'])
        self.assertIn('pending', during['error'].lower())
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 1)
        self.assertFalse(self.events('CLOSE_OK', sensor))
        (self.directory / ('close-release-' + str(sensor))).write_text('release')
        self.assertEventually(lambda: bool(self.events('CLOSE_OK', sensor)))
        self.mode('success')
        retry = self.call(nested_client)
        self.complete(retry)
        self.assertIsNone(retry['error'])
        self.assertEventually(lambda: nested_client.get_cached_property('LightLevel').unpack() == 42)
        self.assertEqual(len(self.events('OPEN_BEGIN', sensor)), 2)
        self.assert_no_native_fault(sensor)

    def test_first_reading_removal_replacement_cancels_old_deadline(self):
        self.start('silent-reading-trigger')
        old_client, fresh_client = self.client(), self.client()
        pending = self.call(old_client)
        old_sensor = self.opening()
        self.testbed.uevent(self.light_node, 'remove')
        self.complete(pending)
        self.assertIn('Sensor removed', pending['error'])
        self.mode('success')
        self.light('deadline-replacement')
        self.assertEventually(lambda: self.get_dbus_property('HasAmbientLight'))
        accepted = self.call(fresh_client)
        self.complete(accepted)
        self.assertIsNone(accepted['error'])
        new_sensor = int(self.events('OPEN_BEGIN')[-1].split()[0])
        self.assertNotEqual(old_sensor, new_sensor)
        self.wait_past_test_deadline()
        joined = self.call(old_client)
        self.complete(joined)
        self.assertIsNone(joined['error'])
        self.assertEventually(lambda: fresh_client.get_cached_property('LightLevel').unpack() == 42)
        self.assertTrue(self.get_dbus_property('HasAmbientLight'))
        self.assertFalse(self.events('CLOSE_OK', new_sensor), 'Old attempt timer closed replacement owner')
        self.assertEqual(len(self.events('OPEN_BEGIN', new_sensor)), 1)
        self.assert_no_native_fault(old_sensor)
        self.assert_no_native_fault(new_sensor)

    def test_first_reading_shutdown_cancels_pending_timer(self):
        self.start('silent-reading-trigger')
        client = self.client()
        pending = self.call(client)
        sensor = self.opening()
        self.assertEventually(lambda: bool(self.events('HEALTHY_OPEN_RETURN', sensor)))
        self.stop_daemon()  # Actual SIGTERM/exit0 is checked, including under SAN.
        self.complete(pending)
        self.assertIsNotNone(pending['error'])
        self.assertNotIn('SSC first valid reading deadline expired', pending['error'])
        self.assertEqual(pending['callbacks'], 1)
        self.assertEqual(len(self.events('CLOSE_OK', sensor)), 1)
        self.assert_no_native_fault(sensor)

    def test_first_reading_deadline_starts_after_open_returns(self):
        self.start('silent-reading-trigger-block')
        client = self.client()
        pending = self.call(client)
        sensor = self.opening()
        self.wait_past_test_deadline()
        self.assertFalse(pending['done'], 'First-reading policy incorrectly bounded a still-pending OPEN')
        self.assertFalse(self.events('HEALTHY_OPEN_RETURN', sensor))
        self.assertFalse(self.events('CLOSE_OK', sensor))
        self.release_gate(sensor)
        self.assertEventually(lambda: bool(self.events('HEALTHY_OPEN_RETURN', sensor)))
        self.complete(pending)
        self.assert_deadline_error(pending)
        self.assertEventually(lambda: bool(self.events('CLOSE_OK', sensor)))
        self.assert_no_native_fault(sensor)


if __name__ == '__main__':
    if 'umockdev' not in os.environ.get('LD_PRELOAD', ''):
        os.execvp('umockdev-wrapper', ['umockdev-wrapper', sys.executable] + sys.argv)
    unittest.main()
