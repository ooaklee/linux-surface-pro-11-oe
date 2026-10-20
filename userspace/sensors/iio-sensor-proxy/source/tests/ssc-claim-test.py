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
        self.start('success', light=not hotplug)
        if hotplug:
            # add_device itself sends the add event. A second add for the same
            # source would correctly invalidate its still-active probe.
            self.light_node = self.light('probe-hotplug-light')
        self.assertEventually(lambda: bool(self.events('CONSTRUCT_BEGIN', 2)))
        client = self.client()
        if not hotplug:
            # Startup advertises discovery before its constructor returns.
            # Claim/Release must tolerate the not-yet-published DEVICE slot.
            claim = self.call(client)
            self.complete(claim)
            self.assertIsNone(claim['error'])
            release = self.call(client, 'ReleaseLight')
            self.complete(release)
            self.assertIsNone(release['error'])
        self.testbed.uevent(self.anchor_node, 'change')
        if not hotplug:
            # Startup construction runs outside the GUdev event handler, so
            # the unrelated change must really dispatch while it is gated.
            self.assertEventually(lambda: self.have_text_in_log(
                'Sensor changes: action = change, device = ' + self.anchor_node))
        else:
            # GUdev's event source is not recursive: a change queued while
            # handling add is delivered only after this constructor returns.
            # Do not fabricate nested GUdev dispatch in the provider seam.
            print('Probe coverage: queued unrelated GUdev change during hotplug constructor')
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
        '''queued unrelated GUdev change does not discard hotplug construction'''
        self._check_unrelated_constructor_event(hotplug=True)

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
