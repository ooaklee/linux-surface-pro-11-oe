#!/usr/bin/python3

# iio-sensor-proxy integration test suite
#
# Run in built tree to test local built binaries, or from anywhere else to test
# system installed binaries.
#
# Copyright: (C) 2011 Martin Pitt <martin.pitt@ubuntu.com>
# (C) 2021 Bastien Nocera <hadess@hadess.net>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

import os
import sys
import dbus
import dbusmock
import gi
import tempfile
import psutil
import subprocess
import unittest
import locale
import struct
import time

try:
    from gi.repository import GLib
    from gi.repository import Gio
except ImportError as e:
    sys.stderr.write('PyGobject not available for Python 3, or missing GI typelibs: %s\n' % str(e))
    sys.exit(1)

try:
    gi.require_version('UMockdev', '1.0')
    from gi.repository import UMockdev
except ImportError:
    sys.stderr.write('umockdev not available (https://github.com/martinpitt/umockdev)\n')
    sys.exit(1)


SP = 'net.hadess.SensorProxy'
SP_PATH = '/net/hadess/SensorProxy'
SP_COMPASS = 'net.hadess.SensorProxy.Compass'
SP_COMPASS_PATH = '/net/hadess/SensorProxy/Compass'

class Tests(dbusmock.DBusTestCase):

    @classmethod
    def setUpClass(cls):
        # run from local build tree if we are in one, otherwise use system instance
        builddir = os.getenv('top_builddir', '.')
        print(os.path.join(builddir, 'src', 'iio-sensor-proxy'))
        if os.access(os.path.join(builddir, 'src', 'iio-sensor-proxy'), os.X_OK):
            cls.daemon_path = os.path.join(builddir, 'src', 'iio-sensor-proxy')
            cls.monitor_sensor_path = os.path.join(builddir, 'src', 'monitor-sensor')
            print('Testing binaries from local build tree (%s)' % cls.daemon_path)
        elif os.environ.get('UNDER_JHBUILD', False):
            jhbuild_prefix = os.environ['JHBUILD_PREFIX']
            cls.daemon_path = os.path.join(jhbuild_prefix, 'libexec', 'iio-sensor-proxy')
            cls.monitor_sensor_path = os.path.join(jhbuild_prefix, 'bin', 'monitor-sensor')
            print('Testing binaries from JHBuild (%s)' % cls.daemon_path)
        else:
            cls.daemon_path = None
            with open('/usr/lib/systemd/system/iio-sensor-proxy.service') as f:
                for line in f:
                    if line.startswith('ExecStart='):
                        cls.daemon_path = line.split('=', 1)[1].strip()
                        break
            assert cls.daemon_path, 'could not determine daemon path from systemd .service file'
            cls.monitor_sensor_path = '/usr/bin/monitor-sensor'
            print('Testing installed system binary (%s)' % cls.daemon_path)

        # fail on CRITICALs on client and server side
        GLib.log_set_always_fatal(GLib.LogLevelFlags.LEVEL_WARNING |
                                  GLib.LogLevelFlags.LEVEL_ERROR |
                                  GLib.LogLevelFlags.LEVEL_CRITICAL)
        os.environ['G_DEBUG'] = 'fatal_warnings'

        # set up a fake system D-BUS
        cls.test_bus = Gio.TestDBus.new(Gio.TestDBusFlags.NONE)
        cls.test_bus.up()
        try:
            del os.environ['DBUS_SESSION_BUS_ADDRESS']
        except KeyError:
            pass
        os.environ['DBUS_SYSTEM_BUS_ADDRESS'] = cls.test_bus.get_bus_address()

        cls.dbus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        cls.dbus_con = cls.get_dbus(True)

        # Some test outputs require the daemon to run under the fr locale:
        # so check if that's available
        try:
            old_loc = locale.setlocale(locale.LC_ALL, 'fr_FR.UTF-8')
            locale.setlocale(locale.LC_ALL, old_loc)
	    # We need to make sure the decimal point is correct as on musl libc the above
	    # succeeds yet the tests just fail due to the output being in unexpected format
            cls.has_fr = locale.localeconv()["decimal_point"] == ","
        except:
            cls.has_fr = False

    @classmethod
    def tearDownClass(cls):
        cls.test_bus.down()
        dbusmock.DBusTestCase.tearDownClass()

    def setUp(self):
        '''Set up a local umockdev testbed.

        The testbed is initially empty.
        '''
        self.testbed = UMockdev.Testbed.new()
        self.polkitd, obj_polkit = self.spawn_server_template(
            'polkitd', {}, stdout=subprocess.PIPE)
        obj_polkit.SetAllowed(['net.hadess.SensorProxy.claim-sensor'])

        self.proxy = None
        self.log = None
        self.daemon = None

    def run(self, result=None):
        super(Tests, self).run(result)
        if result and len(result.errors) + len(result.failures) > 0 and self.log:
            with open(self.log.name) as f:
                sys.stderr.write('\n-------------- daemon log: ----------------\n')
                sys.stderr.write(f.read())
                sys.stderr.write('------------------------------\n')

    def tearDown(self):
        del self.testbed
        self.stop_daemon()

        if self.polkitd:
            try:
                self.polkitd.kill()
            except OSError:
                pass
            self.polkitd.wait()
        self.polkitd = None

    #
    # Daemon control and D-BUS I/O
    #

    def start_daemon(self, env = None, wrapper = None):
        '''Start daemon and create DBus proxy.

        When done, this sets self.proxy as the Gio.DBusProxy for power-profiles-daemon.
        '''
        if not env:
            env = os.environ.copy()
        env['G_DEBUG'] = 'fatal-criticals'
        env['G_MESSAGES_DEBUG'] = 'all'
        env['UMOCKDEV_DEBUG'] = 'all'
        # note: Python doesn't propagate the setenv from Testbed.new(), so we
        # have to do that ourselves
        env['UMOCKDEV_DIR'] = self.testbed.get_root_dir()
        self.log = tempfile.NamedTemporaryFile()
        timeout_multiplier = 1
        if wrapper:
            daemon_path = wrapper + [ self.daemon_path ]
        else:
            daemon_path = [ self.daemon_path ]
        if os.getenv('VALGRIND') != None:
            daemon_path = ['valgrind'] + daemon_path + ['-v']
            timeout_multiplier = 10
        else:
            daemon_path = daemon_path + ['-v']

        self.daemon = subprocess.Popen(daemon_path,
                                       env=env, stdout=self.log,
                                       stderr=subprocess.STDOUT)

        # wait until the daemon gets online
        timeout = 100 * timeout_multiplier
        while timeout > 0:
            time.sleep(0.1)
            timeout -= 1
            try:
                self.get_dbus_property('HasAccelerometer')
                break
            except GLib.GError:
                pass
        else:
            self.fail('daemon did not start in 10 seconds')

        self.proxy = Gio.DBusProxy.new_sync(
            self.dbus, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None, SP,
            SP_PATH, SP, None)

        self.assertEqual(self.daemon.poll(), None, 'daemon crashed')

    def stop_daemon(self):
        '''Stop the daemon if it is running.'''

        if self.daemon:
            try:
                for child in psutil.Process(self.daemon.pid).children(recursive=True):
                    child.kill()
                self.daemon.kill()
            except OSError:
                pass
            self.daemon.wait()
        self.daemon = None
        self.proxy = None

    def get_dbus_property(self, name):
        '''Get property value from daemon D-Bus interface.'''

        proxy = Gio.DBusProxy.new_sync(
            self.dbus, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None, SP,
            SP_PATH, 'org.freedesktop.DBus.Properties', None)
        return proxy.Get('(ss)', SP, name)

    def get_compass_dbus_property(self, name):
        '''Get property value from daemon compass D-Bus interface.'''

        proxy = Gio.DBusProxy.new_sync(
            self.dbus, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None, SP,
            SP_COMPASS_PATH, 'org.freedesktop.DBus.Properties', None)
        return proxy.Get('(ss)', SP_COMPASS, name)

    def have_text_in_log(self, text):
        return self.count_text_in_log(text) > 0

    def count_text_in_log(self, text):
        with open(self.log.name) as f:
            return f.read().count(text)

    def read_sysfs_attr(self, device, attribute):
        with open(os.path.join(self.testbed.get_root_dir() + device, attribute), 'rb') as f:
            return f.read()
        return None

    def read_file(self, path):
        with open(path, 'rb') as f:
            return f.read()
        return None

    def assertEventually(self, condition, message=None, timeout=50):
        '''Assert that condition function eventually returns True.

        Timeout is in deciseconds, defaulting to 50 (5 seconds). message is
        printed on failure.
        '''
        while timeout >= 0:
            context = GLib.MainContext.default()
            while context.iteration(False):
                pass
            if condition():
                break
            timeout -= 1
            time.sleep(0.1)
        else:
            self.fail(message or 'timed out waiting for ' + str(condition))

    #
    # Actual test cases
    #

    def test_hwmon_light(self):
        '''hwmon light'''
        hwmon = self.testbed.add_device('platform', 'hwmon-als', None,
            ['light', '(128,128)'],
            ['IIO_SENSOR_PROXY_TYPE', 'hwmon-als']
        )
        self.start_daemon()
        self.assertEqual(self.get_dbus_property('HasAmbientLight'), True)
        self.assertEqual(self.get_dbus_property('HasAccelerometer'), False)

        # Default values
        self.assertEqual(self.get_dbus_property('LightLevelUnit'), 'lux')
        self.assertEqual(self.get_dbus_property('LightLevel'), 0)

        self.proxy.ClaimLight()
        self.assertEqual(int(self.get_dbus_property('LightLevel')), 50)
        self.assertEqual(self.get_dbus_property('LightLevelUnit'), 'vendor')

        self.testbed.set_attribute(hwmon, 'light', '(255,255)')
        # DEFAULT_POLL_TIME
        time.sleep(0.5)
        self.assertEqual(self.get_dbus_property('LightLevel'), 100)

        # process = subprocess.Popen(['gdbus', 'introspect', '--system', '--dest', 'net.hadess.SensorProxy', '--object-path', '/net/hadess/SensorProxy'])
        # print (self.get_dbus_property('Foo'))

        self.stop_daemon()

    def test_fake_light(self):
        '''fake light'''
        self.testbed.add_device('input', 'fake-light', None,
            [],
            ['NAME', '"Power Button"']
        )
        env = os.environ.copy()
        env['FAKE_LIGHT_SENSOR'] = '1'
        self.start_daemon(env)
        self.assertEqual(self.get_dbus_property('HasAmbientLight'), True)
        self.assertEqual(self.get_dbus_property('HasAccelerometer'), False)

        # Default values
        self.assertEqual(self.get_dbus_property('LightLevelUnit'), 'lux')
        self.assertEqual(self.get_dbus_property('LightLevel'), 0)

        self.proxy.ClaimLight()
        self.assertEqual(self.get_dbus_property('LightLevel'), 0.0)
        self.assertEqual(self.get_dbus_property('LightLevelUnit'), 'lux')

        self.assertEventually(lambda: int(self.get_dbus_property('LightLevel')) == 1.0)
        self.assertEqual(self.get_dbus_property('LightLevelUnit'), 'lux')

        # process = subprocess.Popen(['gdbus', 'introspect', '--system', '--dest', 'net.hadess.SensorProxy', '--object-path', '/net/hadess/SensorProxy'])
        # print (self.get_dbus_property('Foo'))

        self.stop_daemon()

    def test_fake_compass(self):
        '''fake compass'''
        self.testbed.add_device('input', 'fake-compass', None,
            [],
            ['NAME', '"Power Button"']
        )
        env = os.environ.copy()
        env['FAKE_COMPASS'] = '1'
        self.start_daemon(env)
        self.assertEqual(self.get_dbus_property('HasAmbientLight'), False)
        self.assertEqual(self.get_compass_dbus_property('HasCompass'), True)

        # Default values
        compass_proxy = Gio.DBusProxy.new_sync(
            self.dbus, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None, SP,
            SP_COMPASS_PATH, SP_COMPASS, None)
        compass_proxy.ClaimCompass()

        self.assertEqual(int(self.get_compass_dbus_property('CompassHeading')), 10)
        self.assertEventually(lambda: int(self.get_compass_dbus_property('CompassHeading')) == 20)

        self.stop_daemon()

    def test_iio_accel_base_location(self):
        '''iio accel base location'''

        self.testbed.add_device('iio', 'iio-accel', None,
            ['in_accel_x_raw', '0',
             'in_accel_y_raw', '-25.6',
             'in_accel_z_raw', '0',
             'in_accel_scale', '10',
             'label', 'accel-base',
             'sampling_frequency', '5.2',
             'name', 'IIO Test Accelerometer'],
            ['NAME', '"IIO Accelerometer"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-accel']
        )
        self.testbed.add_device('input', 'fake-compass', None,
            [],
            ['NAME', '"Power Button"']
        )
        env = os.environ.copy()
        env['FAKE_COMPASS'] = '1'

        self.start_daemon(env)
        self.assertEqual(self.get_compass_dbus_property('HasCompass'), True)
        self.assertEqual(self.get_dbus_property('HasAccelerometer'), False)
        self.stop_daemon()

    def test_iio_poll_accel(self):
        '''iio poll accel'''
        accel = self.testbed.add_device('iio', 'iio-accel', None,
            ['in_accel_x_raw', '0',
             'in_accel_y_raw', '-25.6',
             'in_accel_z_raw', '0',
             'in_accel_scale', '10',
             'sampling_frequency', '5.2',
             'name', 'IIO Test Accelerometer'],
            ['NAME', '"IIO Accelerometer"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-accel']
        )
        self.start_daemon()
        self.assertEqual(self.get_dbus_property('HasAmbientLight'), False)
        self.assertEqual(self.get_dbus_property('HasAccelerometer'), True)

        # Default values
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'undefined')
        self.assertEqual(self.get_dbus_property('AccelerometerTilt'), 'undefined')
        self.assertEqual(self.read_sysfs_attr(accel, 'sampling_frequency'), b'10')

        self.proxy.ClaimAccelerometer()
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'normal')
        self.assertEqual(self.get_dbus_property('AccelerometerTilt'), 'vertical')

        self.testbed.set_attribute(accel, 'in_accel_x_raw', '-25.6')
        self.testbed.set_attribute(accel, 'in_accel_y_raw', '0')
        self.assertEventually(lambda: self.get_dbus_property('AccelerometerOrientation') == 'right-up')

        self.testbed.set_attribute(accel, 'in_accel_z_raw', '-25.6')
        self.assertEventually(lambda: self.get_dbus_property('AccelerometerTilt') == 'tilted-down')

        self.testbed.set_attribute(accel, 'in_accel_z_raw', '72.4')
        self.assertEventually(lambda: self.get_dbus_property('AccelerometerTilt') == 'face-up')

        self.stop_daemon()

    def test_iio_poll_light(self):
        '''iio poll light'''
        iio = self.testbed.add_device('iio', 'iio-als', None,
            ['integration_time', '1',
             'in_illuminance_input', '10',
             'in_illuminance_scale', '1.0'],
            ['NAME', '"IIO Light Sensor"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-als']
        )
        self.start_daemon()
        self.assertEqual(self.get_dbus_property('HasAmbientLight'), True)
        self.assertEqual(self.get_dbus_property('HasAccelerometer'), False)

        # Default values
        self.assertEqual(self.get_dbus_property('LightLevelUnit'), 'lux')
        self.assertEqual(self.get_dbus_property('LightLevel'), 0)

        self.proxy.ClaimLight()
        self.assertEqual(int(self.get_dbus_property('LightLevel')), 10)
        self.assertEqual(self.get_dbus_property('LightLevelUnit'), 'lux')

        self.testbed.set_attribute(iio, 'in_illuminance_input', '30')
        self.assertEventually(lambda: self.get_dbus_property('LightLevel') == 30)

        self.stop_daemon()

    def test_iio_poll_accel_raw_rejection_recovery(self):
        '''claimed polling drops missing/junk axes, accepts zero and recovers'''
        accel = self.testbed.add_device('iio', 'acquisition-poll', None,
            ['in_accel_x_raw', '0', 'in_accel_y_raw', '-256',
             'in_accel_z_raw', '0', 'in_accel_scale', '1',
             'sampling_frequency', '10', 'name', 'Acquisition Poll'],
            ['NAME', '"Acquisition Poll"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-accel'])
        self.start_daemon()
        self.assertTrue(self.get_dbus_property('HasAccelerometer'))
        self.proxy.ClaimAccelerometer()
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'normal')
        guard = 'Ignoring accelerometer reading with invalid raw axis'
        published = 'Accel sent by driver (quirk applied)'
        previous_guard = self.count_text_in_log(guard)
        # This is only the fresh UMockdev-owned sysfs attribute, not a host
        # sysfs file. Keep x absent while changing y, so no partial valid
        # vector can turn the cached orientation during the rejection phase.
        mock_x_raw = self.testbed.get_root_dir() + accel + '/in_accel_x_raw'
        os.unlink(mock_x_raw)
        self.testbed.set_attribute(accel, 'in_accel_y_raw', '0')
        self.assertEventually(lambda: self.count_text_in_log(guard) > previous_guard)
        previous_published = self.count_text_in_log(published)
        previous_guard = self.count_text_in_log(guard)
        with open(mock_x_raw, 'w') as mock_file:
            mock_file.write('1junk')
        self.assertEventually(lambda: self.count_text_in_log(guard) > previous_guard)
        self.assertEqual(self.count_text_in_log(published), previous_published)
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'normal')
        self.assertEqual(self.proxy.get_cached_property('AccelerometerOrientation').unpack(),
                         'normal')
        self.testbed.set_attribute(accel, 'in_accel_x_raw', '-256')
        self.assertEventually(lambda:
                              self.get_dbus_property('AccelerometerOrientation') == 'right-up')
        # A valid all-zero vector is delivered and holds the previous state;
        # it must not be confused with the malformed-read rejection path.
        previous_published = self.count_text_in_log(published)
        self.testbed.set_attribute(accel, 'in_accel_x_raw', '0')
        self.assertEventually(lambda:
                              self.count_text_in_log(published) > previous_published)
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'right-up')
        self.testbed.set_attribute(accel, 'in_accel_x_raw', '4294967295')
        self.assertEventually(lambda:
                              self.get_dbus_property('AccelerometerOrientation') == 'left-up')
        self.proxy.ReleaseAccelerometer()
        self.assertEqual(self.daemon.poll(), None)
        self.stop_daemon()

    def test_iio_poll_accel_calibration_before_matrix(self):
        '''partial per-axis scale and fractional offset precede frame rotation'''
        accel = self.testbed.add_device('iio', 'acquisition-calibration', None,
            ['in_accel_x_raw', '0', 'in_accel_y_raw', '2',
             'in_accel_z_raw', '0', 'in_accel_scale', '1',
             'in_accel_x_scale', '10', 'in_accel_x_offset', '1.25',
             'in_accel_mount_matrix', '0,1,0;1,0,0;0,0,1',
             'sampling_frequency', '10', 'name', 'Acquisition Calibration'],
            ['NAME', '"Acquisition Calibration"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-accel'])
        self.start_daemon()
        self.assertTrue(self.get_dbus_property('HasAccelerometer'))
        self.proxy.ClaimAccelerometer()
        # ((0 + 1.25) * 10, 2 * 1, 0 * 1), then swap x/y => (2,12.5,0).
        # Dropping partial x_scale, omitting offset, or scaling after the
        # matrix instead yields a different orientation.
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'bottom-up')
        self.assertTrue(self.have_text_in_log(
            'Accel sent by driver (quirk applied): 2, 12.5, 0 (scale: 1.000000,1.000000,1.000000)'))
        self.testbed.set_attribute(accel, 'in_accel_x_raw', '-2')
        self.assertEventually(lambda:
                              self.get_dbus_property('AccelerometerOrientation') == 'normal')
        self.assertTrue(self.have_text_in_log(
            'Accel sent by driver (quirk applied): 2, -7.5, 0 (scale: 1.000000,1.000000,1.000000)'))
        self.proxy.ReleaseAccelerometer()
        self.assertEqual(self.daemon.poll(), None)
        self.stop_daemon()

    def test_iio_poll_accel_invalid_scale(self):
        '''invalid IIO scales cannot create an accelerometer or guessed scale'''
        # Keep the service alive even after the accelerometer constructor
        # rejects its metadata; this compass is not claimed or polled.
        self.testbed.add_device('input', 'invalid-scale-anchor', None, [],
                                ['NAME', '"Power Button"'])
        env = os.environ.copy()
        env['FAKE_COMPASS'] = '1'
        cases = [
            ('nan', ['in_accel_scale', 'nan']),
            ('inf', ['in_accel_scale', 'inf']),
            ('junk', ['in_accel_x_scale', '1', 'in_accel_y_scale', '1junk',
                      'in_accel_z_scale', '1']),
            ('zero', ['in_accel_x_scale', '1', 'in_accel_y_scale', '0',
                      'in_accel_z_scale', '1'])]
        # One candidate per process ensures all four bad metadata cases
        # actually reach OPEN, rather than only the first discovered node.
        for value, scale_attributes in cases:
            with self.subTest(scale=value):
                accel = self.testbed.add_device('iio', 'invalid-scale-' + value, None,
                    ['in_accel_x_raw', '0', 'in_accel_y_raw', '-256',
                     'in_accel_z_raw', '0', 'sampling_frequency', '10',
                     'name', 'Invalid Scale Accelerometer'] + scale_attributes,
                    ['NAME', '"Invalid Scale Accelerometer"',
                     'IIO_SENSOR_PROXY_TYPE', 'iio-poll-accel'])
                try:
                    self.start_daemon(env.copy())
                    self.assertTrue(self.get_compass_dbus_property('HasCompass'))
                    self.assertFalse(self.get_dbus_property('HasAccelerometer'))
                    self.assertEqual(self.get_dbus_property('AccelerometerOrientation'),
                                     'undefined')
                    self.assertTrue(self.have_text_in_log(
                        'Found IIO poll accelerometer at ' + accel))
                    self.assertTrue(self.have_text_in_log('Invalid accelerometer scale for'))
                    self.assertFalse(self.have_text_in_log('Accel read from IIO on'))
                    self.assertEqual(self.daemon.poll(), None)
                finally:
                    self.stop_daemon()
                    self.testbed.remove_device(accel)

    def _check_poll_calibration_rejection_recovery(self, label, changes,
                                                    reason, unreadable=None):
        # A fake compass keeps the real production daemon and its private
        # D-Bus interface alive after OPEN rejects the only accelerometer.
        anchor = self.testbed.add_device('input', 'calibration-anchor-' + label,
                                        None, [], ['NAME', '"Power Button"'])
        env = os.environ.copy()
        env['FAKE_COMPASS'] = '1'
        attributes = {
            'in_accel_x_raw': '0', 'in_accel_y_raw': '2',
            'in_accel_z_raw': '0', 'in_accel_scale': '1',
            'in_accel_x_scale': '10', 'in_accel_x_offset': '1.25',
            'in_accel_mount_matrix': '0,1,0;1,0,0;0,0,1',
            'sampling_frequency': '5.2', 'name': 'Rejected Calibration'}
        attributes.update(changes)
        accel = self.testbed.add_device('iio', 'calibration-rejected-' + label,
            None, [item for pair in attributes.items() for item in pair],
            ['NAME', '"Rejected Calibration"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-accel'])
        mock_unreadable = None
        if unreadable is not None:
            # chmod is not a read-error fixture when tests run as root.
            # Replace only this owned UMockdev attribute with a directory:
            # GUdev returns NULL and the error-bearing read must see EISDIR,
            # not treat it as absent and use valid lower-priority metadata.
            mock_unreadable = self.testbed.get_root_dir() + accel + '/' + unreadable
            os.unlink(mock_unreadable)
            os.mkdir(mock_unreadable)
        try:
            self.start_daemon(env.copy())
            self.assertTrue(self.get_compass_dbus_property('HasCompass'))
            self.assertFalse(self.get_dbus_property('HasAccelerometer'))
            self.assertEqual(self.get_dbus_property('AccelerometerOrientation'),
                             'undefined')
            self.assertEqual(self.get_dbus_property('AccelerometerTilt'), 'undefined')
            self.assertTrue(self.have_text_in_log(
                'Found IIO poll accelerometer at ' + accel))
            self.assertTrue(self.have_text_in_log(
                'Invalid accelerometer ' + reason + ' for'))
            if unreadable is not None:
                self.assertTrue(self.have_text_in_log(
                    "Could not read optional attribute '" + accel + '/' + unreadable + "':"))
            self.assertEqual(self.read_sysfs_attr(accel, 'sampling_frequency'), b'5.2')
            # The existing API accepts Claim without an available device as
            # future hotplug intent. It must not invent a reading or admit
            # this rejected node; do not change that API to make Claim fail.
            self.proxy.ClaimAccelerometer()
            time.sleep(0.8)  # exceed the unchanged 700 ms polling interval
            self.assertFalse(self.get_dbus_property('HasAccelerometer'))
            self.assertEqual(self.get_dbus_property('AccelerometerOrientation'),
                             'undefined')
            self.assertEqual(self.get_dbus_property('AccelerometerTilt'), 'undefined')
            self.assertFalse(self.have_text_in_log('Accel read from IIO on'))
            self.assertFalse(self.have_text_in_log('Accel sent by driver'))
            self.assertEqual(self.read_sysfs_attr(accel, 'sampling_frequency'), b'5.2')
            self.proxy.ReleaseAccelerometer()
            self.assertEqual(self.daemon.poll(), None)
        finally:
            self.stop_daemon()
            if mock_unreadable is not None:
                os.rmdir(mock_unreadable)
            self.testbed.remove_device(accel)

        # Use a fresh device AND process: this is actual corrected admission,
        # not an assumption that GUdev refreshes cached calibration strings.
        corrected = self.testbed.add_device('iio', 'calibration-corrected-' + label,
            None,
            ['in_accel_x_raw', '0', 'in_accel_y_raw', '2',
             'in_accel_z_raw', '0', 'in_accel_scale', '1',
             'in_accel_x_scale', '10', 'in_accel_x_offset', '1.25',
             'in_accel_mount_matrix', '0,1,0;1,0,0;0,0,1',
             'sampling_frequency', '5.2', 'name', 'Corrected Calibration'],
            ['NAME', '"Corrected Calibration"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-accel'])
        try:
            self.start_daemon(env.copy())
            self.assertTrue(self.get_compass_dbus_property('HasCompass'))
            self.assertTrue(self.get_dbus_property('HasAccelerometer'))
            self.assertEqual(self.read_sysfs_attr(corrected, 'sampling_frequency'), b'10')
            self.proxy.ClaimAccelerometer()
            self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'bottom-up')
            self.assertTrue(self.have_text_in_log(
                'Accel sent by driver (quirk applied): 2, 12.5, 0 (scale: 1.000000,1.000000,1.000000)'))
            self.testbed.set_attribute(corrected, 'in_accel_x_raw', '-2')
            self.assertEventually(lambda:
                                  self.get_dbus_property('AccelerometerOrientation') == 'normal')
            self.assertTrue(self.have_text_in_log(
                'Accel sent by driver (quirk applied): 2, -7.5, 0 (scale: 1.000000,1.000000,1.000000)'))
            self.proxy.ReleaseAccelerometer()
            self.assertEqual(self.daemon.poll(), None)
        finally:
            self.stop_daemon()
            self.testbed.remove_device(corrected)
            self.testbed.remove_device(anchor)

    def test_iio_poll_accel_invalid_offset_no_sampling_write_recovery(self):
        '''late-axis and fractional malformed offsets reject before sampling writes'''
        cases = [
            ('late-z', {'in_accel_offset': '0', 'in_accel_y_offset': '0',
                        'in_accel_z_offset': '1.25junk'}),
            ('fractional-x', {'in_accel_offset': '0',
                              'in_accel_x_offset': '1.25junk'})]
        for label, changes in cases:
            with self.subTest(offset=label):
                self._check_poll_calibration_rejection_recovery(label, changes, 'offset')

    def test_iio_poll_accel_unreadable_scale_no_fallback_recovery(self):
        '''a real scale read error cannot fall through to valid common scale'''
        self._check_poll_calibration_rejection_recovery(
            'unreadable-scale', {}, 'scale', unreadable='in_accel_x_scale')

    def test_iio_poll_accel_unreadable_offset_no_fallback_recovery(self):
        '''a real offset read error cannot fall through to valid common offset'''
        self._check_poll_calibration_rejection_recovery(
            'unreadable-offset', {'in_accel_offset': '0'}, 'offset',
            unreadable='in_accel_x_offset')

    def test_iio_poll_proximity(self):
        '''iio poll proximity'''
        prox = self.testbed.add_device('iio', 'iio-proximity', None,
            ['in_proximity_nearlevel', '128',
             'in_proximity_raw', '256',
             'name', 'IIO Test Proximity Sensor'],
            ['NAME', '"IIO Proximity Sensor"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-proximity']
        )
        self.start_daemon()
        self.assertEqual(self.get_dbus_property('HasAmbientLight'), False)
        self.assertEqual(self.get_dbus_property('HasAccelerometer'), False)
        self.assertEqual(self.get_dbus_property('HasProximity'), True)

        # Default values
        self.assertEqual(self.get_dbus_property('ProximityNear'), False)

        self.proxy.ClaimProximity()
        self.assertEqual(self.get_dbus_property('ProximityNear'), True)

        self.testbed.set_attribute(prox, 'in_proximity_raw', '0')
        self.assertEventually(lambda: self.get_dbus_property('ProximityNear') == False)

        self.testbed.set_attribute(prox, 'in_proximity_raw', '129')
        self.assertEventually(lambda: self.get_dbus_property('ProximityNear') == True)

        # Test margin
        self.testbed.set_attribute(prox, 'in_proximity_raw', '127')
        self.assertEventually(lambda: self.get_dbus_property('ProximityNear') == True)

        self.stop_daemon()

    def test_iio_poll_proximity0(self):
        '''iio poll proximity0'''
        prox = self.testbed.add_device('iio', 'iio-proximity', None,
            ['in_proximity_nearlevel', '128',
             'in_proximity0_raw', '256',
             'name', 'IIO Test Proximity Sensor'],
            ['NAME', '"IIO Proximity Sensor"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-proximity']
        )
        self.start_daemon()
        self.assertEqual(self.get_dbus_property('HasAmbientLight'), False)
        self.assertEqual(self.get_dbus_property('HasAccelerometer'), False)
        self.assertEqual(self.get_dbus_property('HasProximity'), True)

        # Default values
        self.assertEqual(self.get_dbus_property('ProximityNear'), False)

        self.proxy.ClaimProximity()
        self.assertEqual(self.get_dbus_property('ProximityNear'), True)

        self.testbed.set_attribute(prox, 'in_proximity0_raw', '0')
        self.assertEventually(lambda: self.get_dbus_property('ProximityNear') == False)

        self.testbed.set_attribute(prox, 'in_proximity0_raw', '129')
        self.assertEventually(lambda: self.get_dbus_property('ProximityNear') == True)

        # Test margin
        self.testbed.set_attribute(prox, 'in_proximity0_raw', '127')
        self.assertEventually(lambda: self.get_dbus_property('ProximityNear') == True)

        self.stop_daemon()

    def test_input_accel(self):
        '''input accelerometer'''
        top_srcdir = os.getenv('top_srcdir', '.')
        script = ['umockdev-run', '-d', top_srcdir + '/tests/input-accel-device',
                  '-i', '/dev/input/event4=%s/tests/input-accel-capture.ioctl' % (top_srcdir),
                  '--']

        self.start_daemon(wrapper=script)

        self.assertEqual(self.get_dbus_property('HasAccelerometer'), True)
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'undefined')

        self.proxy.ClaimAccelerometer()
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'normal')

        self.stop_daemon()

    def test_input_proximity(self):
        '''input proximity'''
        top_srcdir = os.getenv('top_srcdir', '.')
        script = ['umockdev-run', '-d', top_srcdir + '/tests/input-proximity-data/device',
                  '-i', '/dev/input/event4=%s/tests/input-proximity-data/ioctl' % (top_srcdir),
                  '--']

        self.start_daemon(wrapper=script)

        self.assertEqual(self.get_dbus_property('HasProximity'), True)
        self.assertEqual(self.get_dbus_property('ProximityNear'), False)

        self.stop_daemon()

    def test_iio_buffer_accel(self):
        '''iio buffer accel'''
        top_srcdir = os.getenv('top_srcdir', '.')
        mock_dev_data = self.testbed.get_root_dir() + '/iio-dev-data.bin'
        accel = self.testbed.add_device('iio', 'iio-buffer-accel0', None,
            ['name', 'IIO Test Accelerometer',
             'buffer/enable', '0',
             'trigger/current_trigger', '',
             'scan_elements/in_accel_x_en', '0',
             'scan_elements/in_accel_x_index', '0',
             'scan_elements/in_accel_x_type', 'le:s16/32>>0',
             'scan_elements/in_accel_y_en', '0',
             'scan_elements/in_accel_y_index', '1',
             'scan_elements/in_accel_y_type', 'le:s16/32>>0',
             'scan_elements/in_accel_z_en', '0',
             'scan_elements/in_accel_z_index', '2',
             'scan_elements/in_accel_z_type', 'le:s16/32>>0',
             'scan_elements/in_timestamp_en', '1',
             'scan_elements/in_timestamp_index', '3',
             'scan_elements/in_timestamp_type', 'le:s64/64>>0'],
            ['NAME', '"IIO Accelerometer"',
             'DEVNAME', '/dev/iio-buffer-accel-test',
             'IIO_SENSOR_PROXY_TYPE', 'iio-buffer-accel']
        )
        trigger = self.testbed.add_device('iio', 'trigger0', None,
            ['name', 'accel_3d-dev0'],
            []
        )
        data = self.read_file(top_srcdir + '/tests/iio-buffer-accel-data/orientation-normal.bin')
        with open(mock_dev_data,'wb') as mock_file:
            mock_file.write(data)
        self.start_daemon()
        self.assertEqual(self.get_dbus_property('HasAmbientLight'), False)
        self.assertEqual(self.get_dbus_property('HasAccelerometer'), True)

        # Default values
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'undefined')
        self.assertEqual(self.read_sysfs_attr(accel, 'buffer/enable'), b'0')
        self.assertEqual(self.read_sysfs_attr(accel, 'scan_elements/in_accel_x_en'), b'1')
        self.assertEqual(self.read_sysfs_attr(accel, 'scan_elements/in_accel_y_en'), b'1')
        self.assertEqual(self.read_sysfs_attr(accel, 'scan_elements/in_accel_z_en'), b'1')

        with open(mock_dev_data,'wb') as mock_file:
            mock_file.write(data)
        self.proxy.ClaimAccelerometer()
        time.sleep(1)
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'normal')
        os.remove(mock_dev_data)

        time.sleep(1)
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'normal')

        data = self.read_file(top_srcdir + '/tests/iio-buffer-accel-data/orientation-left-up.bin')
        with open(mock_dev_data,'wb') as mock_file:
            mock_file.write(data)
        time.sleep(1)
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'left-up')
        os.remove(mock_dev_data)

        data = self.read_file(top_srcdir + '/tests/iio-buffer-accel-data/orientation-normal.bin')
        with open(mock_dev_data,'wb') as mock_file:
            mock_file.write(data)
        time.sleep(1)
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'normal')
        os.remove(mock_dev_data)

        self.stop_daemon()

    def test_driver_buffer_without_trigger(self):
        '''buffer driver picking without trigger'''
        top_srcdir = os.getenv('top_srcdir', '.')
        mock_dev_data = self.testbed.get_root_dir() + '/iio-dev-data.bin'
        accel = self.testbed.add_device('iio', 'iio-buffer-accel0', None,
            ['name', 'IIO Test Accelerometer',
             'buffer/enable', '0',
             'scan_elements/in_accel_x_en', '0',
             'scan_elements/in_accel_x_index', '0',
             'scan_elements/in_accel_x_type', 'le:s16/32>>0',
             'scan_elements/in_accel_y_en', '0',
             'scan_elements/in_accel_y_index', '1',
             'scan_elements/in_accel_y_type', 'le:s16/32>>0',
             'scan_elements/in_accel_z_en', '0',
             'scan_elements/in_accel_z_index', '2',
             'scan_elements/in_accel_z_type', 'le:s16/32>>0',
             'scan_elements/in_timestamp_en', '1',
             'scan_elements/in_timestamp_index', '3',
             'scan_elements/in_timestamp_type', 'le:s64/64>>0'],
            ['NAME', '"IIO Accelerometer"',
             'DEVNAME', '/dev/iio-buffer-accel-test-no-trigger',
             'IIO_SENSOR_PROXY_TYPE', 'iio-buffer-accel']
        )

        data = self.read_file(top_srcdir + '/tests/iio-buffer-accel-data/orientation-normal.bin')
        with open(mock_dev_data,'wb') as mock_file:
            mock_file.write(data)
        self.start_daemon()

        self.assertEqual(self.get_dbus_property('HasAmbientLight'), False)
        self.assertEqual(self.get_dbus_property('HasAccelerometer'), True)
        self.assertEqual(self.have_text_in_log('iio-buffer-accel'), True)

        self.stop_daemon()

    def test_iio_buffer_accel_missing_axis(self):
        '''an admitted x/y-only buffer reaches the scan guard, never a reading'''
        mock_dev_data = self.testbed.get_root_dir() + '/iio-dev-data.bin'
        accel = self.testbed.add_device('iio', 'iio:device0', None,
            ['name', 'numeric-missing-z',
             'in_accel_x_raw', '0', 'in_accel_y_raw', '-256',
             'in_accel_scale', '1.0', 'in_accel_offset', '0.0',
             'sampling_frequency', '10',
             'buffer/enable', '0', 'buffer/length', '128',
             'trigger/current_trigger', '',
             'scan_elements/in_accel_x_en', '0',
             'scan_elements/in_accel_x_index', '0',
             'scan_elements/in_accel_x_type', 'le:s16/32>>0',
             'scan_elements/in_accel_y_en', '0',
             'scan_elements/in_accel_y_index', '1',
             'scan_elements/in_accel_y_type', 'le:s16/32>>0',
             'scan_elements/in_timestamp_en', '1',
             'scan_elements/in_timestamp_index', '2',
             'scan_elements/in_timestamp_type', 'le:s64/64>>0'],
            ['NAME', '"Numeric Missing Z"', 'DEVNAME', '/dev/iio:device0',
             'IIO_SENSOR_PROXY_TYPE', 'iio-buffer-accel'])
        self.testbed.add_device('iio', 'trigger0', None,
                                ['name', 'numeric-missing-z-dev0'], [])
        self.testbed.add_device('input', 'missing-axis-anchor', None, [],
                                ['NAME', '"Power Button"'])
        env = os.environ.copy()
        env['FAKE_COMPASS'] = '1'
        # Exactly one 16-byte scan: two 32-bit slots carrying signed16
        # values, then an aligned 64-bit timestamp. There is no z slot or
        # metadata; using the old 24-byte x/y/z fixture would be inconsistent.
        data = struct.pack('<iiq', 0, -256, 0)
        self.assertEqual(len(data), 16)
        with open(mock_dev_data, 'wb') as mock_file:
            mock_file.write(data)
        self.start_daemon(env)
        self.assertTrue(self.get_compass_dbus_property('HasCompass'))
        self.assertTrue(self.get_dbus_property('HasAccelerometer'))
        self.assertTrue(self.have_text_in_log('Found IIO buffer accelerometer at ' + accel))
        self.assertEqual(self.read_sysfs_attr(accel, 'buffer/enable'), b'0')
        self.assertEqual(self.read_sysfs_attr(accel, 'scan_elements/in_accel_x_en'), b'1')
        self.assertEqual(self.read_sysfs_attr(accel, 'scan_elements/in_accel_y_en'), b'1')
        self.assertFalse(os.path.exists(self.testbed.get_root_dir() + accel +
                                       '/scan_elements/in_accel_z_en'))
        claim = {'done': False, 'error': None}

        def finished(proxy, task, _data):
            try:
                proxy.call_finish(task)
            except GLib.Error as error:
                claim['error'] = error
            claim['done'] = True

        self.proxy.call('ClaimAccelerometer', None, Gio.DBusCallFlags.NONE,
                        10000, None, finished, None)
        guard = 'Ignoring accelerometer scan with missing axis'
        self.assertEventually(lambda: self.have_text_in_log(guard))
        # The exact guard log proves discovery and process_scan were reached.
        # A metadata/trigger/open failure is not a passing result here.
        self.assertFalse(claim['done'])
        self.assertEqual(self.read_sysfs_attr(accel, 'buffer/enable'), b'1')
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'undefined')
        self.assertEqual(self.get_dbus_property('AccelerometerTilt'), 'undefined')
        self.assertEqual(self.proxy.get_cached_property('AccelerometerOrientation').unpack(),
                         'undefined')
        self.assertEqual(self.proxy.get_cached_property('AccelerometerTilt').unpack(),
                         'undefined')
        # The synchronous property round-trips above are a server barrier;
        # dispatch any already-delivered async reply before checking pending.
        context = GLib.MainContext.default()
        for _ in range(64):
            if not context.pending():
                break
            context.iteration(False)
        self.assertFalse(context.pending())
        self.assertFalse(claim['done'])
        self.assertFalse(self.have_text_in_log('Accel read from IIO on'))
        self.assertFalse(self.have_text_in_log('Accel sent by driver'))
        self.proxy.ReleaseAccelerometer()
        self.assertEventually(lambda: claim['done'])
        self.assertIsNotNone(claim['error'])
        self.assertEqual(Gio.DBusError.get_remote_error(claim['error']),
                         'org.freedesktop.DBus.Error.Failed')
        self.assertIn('Sensor claim was released while starting', str(claim['error']))
        self.assertEqual(self.read_sysfs_attr(accel, 'buffer/enable'), b'0')
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'undefined')
        self.assertEqual(self.daemon.poll(), None)
        self.stop_daemon()

    def test_iio_buffer_accel_invalid_metadata(self):
        '''buffer constructor rejects explicit bad metadata without admission'''
        self.testbed.add_device('input', 'invalid-buffer-anchor', None, [],
                                ['NAME', '"Power Button"'])
        self.testbed.add_device('iio', 'trigger0', None,
                                ['name', 'acquisition-invalid-dev0'], [])
        env = os.environ.copy()
        env['FAKE_COMPASS'] = '1'
        attributes = {
            'name': 'acquisition-invalid', 'sampling_frequency': '10',
            'buffer/enable': '0', 'buffer/length': '128',
            'trigger/current_trigger': '',
            'scan_elements/in_accel_x_en': '0',
            'scan_elements/in_accel_x_index': '0',
            'scan_elements/in_accel_x_type': 'le:s16/32>>0',
            'scan_elements/in_accel_y_en': '0',
            'scan_elements/in_accel_y_index': '1',
            'scan_elements/in_accel_y_type': 'le:s16/32>>0',
            'scan_elements/in_accel_z_en': '0',
            'scan_elements/in_accel_z_index': '2',
            'scan_elements/in_accel_z_type': 'le:s16/32>>0',
            'scan_elements/in_timestamp_en': '1',
            'scan_elements/in_timestamp_index': '3',
            'scan_elements/in_timestamp_type': 'le:s64/64>>0'}
        cases = [
            ('type', {'scan_elements/in_accel_x_type': 'le:s16/24>>0'},
             'invalid or unsupported scan type'),
            ('index', {'scan_elements/in_accel_y_index': '0'}, 'duplicate scan index'),
            ('scale', {'in_accel_scale': '1', 'in_accel_x_scale': 'nan'},
             'invalid scale'),
            ('offset', {'in_accel_offset': '0', 'in_accel_x_offset': '1junk'},
             'invalid offset'),
            ('enable', {'scan_elements/in_accel_x_en': '2'}, None)]
        mock_dev_data = self.testbed.get_root_dir() + '/iio-dev-data.bin'
        with open(mock_dev_data, 'wb') as mock_file:
            mock_file.write(struct.pack('<iii4xq', 0, -256, 0, 0))
        # Fresh daemon/device per subcase: every rejection reaches its real
        # construction gate, not merely a node ignored after an earlier one.
        for label, changes, reason in cases:
            with self.subTest(metadata=label):
                values = attributes.copy()
                values.update(changes)
                flat_attributes = [item for pair in values.items() for item in pair]
                accel = self.testbed.add_device('iio', 'iio:device0', None,
                    flat_attributes,
                    ['NAME', '"Invalid Buffer"', 'DEVNAME', '/dev/iio:device0',
                     'IIO_SENSOR_PROXY_TYPE', 'iio-buffer-accel'])
                try:
                    self.start_daemon(env.copy())
                    self.assertTrue(self.get_compass_dbus_property('HasCompass'))
                    self.assertFalse(self.get_dbus_property('HasAccelerometer'))
                    self.assertEqual(self.get_dbus_property('AccelerometerOrientation'),
                                     'undefined')
                    self.assertTrue(self.have_text_in_log(
                        'Found associated trigger (acquisition-invalid-dev0)'))
                    if reason is None:
                        self.assertTrue(self.have_text_in_log(
                            "Invalid IIO enable flag '" + accel +
                            '/scan_elements/in_accel_x_en' + "'"))
                        self.assertTrue(self.have_text_in_log('Failed to enable any sensors'))
                    else:
                        self.assertTrue(self.have_text_in_log(
                            "Invalid IIO scan metadata in '" + accel + "': " + reason))
                        self.assertTrue(self.have_text_in_log(
                            'Problem reading scan element information: ' + accel))
                    self.assertFalse(self.have_text_in_log(
                        'Found IIO buffer accelerometer at ' + accel))
                    self.assertFalse(self.have_text_in_log('Accel sent by driver'))
                    self.assertEqual(self.daemon.poll(), None)
                finally:
                    self.stop_daemon()
                    self.testbed.remove_device(accel)

    def test_iio_buffer_accel_fractional_offset(self):
        '''actual unsigned32 scan preserves fractional offset and unity output'''
        mock_dev_data = self.testbed.get_root_dir() + '/iio-dev-data.bin'
        accel = self.testbed.add_device('iio', 'iio:device0', None,
            ['name', 'acquisition-fractional', 'sampling_frequency', '10',
             'in_accel_scale', '1', 'in_accel_offset', '0',
             'in_accel_x_offset', '-4294967294.875', 'in_accel_y_offset', '-0.5',
             'buffer/enable', '0', 'buffer/length', '128',
             'trigger/current_trigger', '',
             'scan_elements/in_accel_x_en', '0',
             'scan_elements/in_accel_x_index', '0',
             'scan_elements/in_accel_x_type', 'le:u32/32>>0',
             'scan_elements/in_accel_y_en', '0',
             'scan_elements/in_accel_y_index', '1',
             'scan_elements/in_accel_y_type', 'le:u32/32>>0',
             'scan_elements/in_accel_z_en', '0',
             'scan_elements/in_accel_z_index', '2',
             'scan_elements/in_accel_z_type', 'le:u32/32>>0',
             'scan_elements/in_timestamp_en', '1',
             'scan_elements/in_timestamp_index', '3',
             'scan_elements/in_timestamp_type', 'le:s64/64>>0'],
            ['NAME', '"Fractional Buffer"', 'DEVNAME', '/dev/iio:device0',
             'IIO_SENSOR_PROXY_TYPE', 'iio-buffer-accel'])
        self.testbed.add_device('iio', 'trigger0', None,
                                ['name', 'acquisition-fractional-dev0'], [])
        # x/y/z occupy byte0/4/8; timestamp has alignment8 at byte16. The
        # four bytes after z are real scan padding, not another channel.
        data = struct.pack('<III4xQ', 0xffffffff, 0, 0, 0)
        self.assertEqual(len(data), 24)
        with open(mock_dev_data, 'wb') as mock_file:
            mock_file.write(data)
        self.start_daemon()
        self.assertTrue(self.get_dbus_property('HasAccelerometer'))
        self.assertTrue(self.have_text_in_log('Found IIO buffer accelerometer at ' + accel))
        self.assertEqual(self.read_sysfs_attr(accel, 'buffer/enable'), b'0')
        self.proxy.ClaimAccelerometer()
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'normal')
        self.assertTrue(self.have_text_in_log(
            ': 0.125, -0.5, 0 (scale 1.000000,1.000000,1.000000)'))
        self.assertTrue(self.have_text_in_log(
            'Accel sent by driver (quirk applied): 0.125, -0.5, 0 (scale: 1.000000,1.000000,1.000000)'))
        self.assertEqual(self.read_sysfs_attr(accel, 'buffer/enable'), b'1')
        data = struct.pack('<III4xQ', 0xfffffffe, 0, 0, 0)
        with open(mock_dev_data, 'wb') as mock_file:
            mock_file.write(data)
        self.assertEventually(lambda:
                              self.get_dbus_property('AccelerometerOrientation') == 'right-up')
        self.assertTrue(self.have_text_in_log(
            ': -0.875, -0.5, 0 (scale 1.000000,1.000000,1.000000)'))
        self.proxy.ReleaseAccelerometer()
        self.assertEqual(self.read_sysfs_attr(accel, 'buffer/enable'), b'0')
        self.assertEqual(self.daemon.poll(), None)
        self.stop_daemon()

    def test_iio_broken_buffer_accel(self):
        '''iio sensor reporting broken buffer support'''
        top_srcdir = os.getenv('top_srcdir', '.')
        mock_dev_data = self.testbed.get_root_dir() + '/iio-dev-data.bin'
        accel = self.testbed.add_device('iio', 'iio-buffer-accel0', None,
            ['name', 'IIO Test Accelerometer',
             'buffer/enable', '0',
             'trigger/current_trigger', '',
             'scan_elements/in_accel_x_en', '0',
             'scan_elements/in_accel_x_index', '0',
             'scan_elements/in_accel_x_type', 'le:s16/32>>0',
             'scan_elements/in_accel_y_en', '0',
             'scan_elements/in_accel_y_index', '1',
             'scan_elements/in_accel_y_type', 'le:s16/32>>0',
             'scan_elements/in_accel_z_en', '0',
             'scan_elements/in_accel_z_index', '2',
             'scan_elements/in_accel_z_type', 'le:s16/32>>0',
             'scan_elements/in_timestamp_en', '1',
             'scan_elements/in_timestamp_index', '3',
             'scan_elements/in_timestamp_type', 'le:s64/64>>0'],
            ['NAME', '"IIO Accelerometer"',
             'DEVNAME', '/dev/iio-buffer-accel-test',
             'IIO_SENSOR_PROXY_TYPE', 'iio-buffer-accel iio-poll-accel']
        )
        trigger = self.testbed.add_device('iio', 'trigger0', None,
            ['name', 'accel_3d-dev0'],
            []
        )
        self.start_daemon()
        self.assertEqual(self.have_text_in_log('Built channel array'), True)
        self.assertEqual(self.have_text_in_log('Disabled sensor'), True)
        self.assertEqual(self.have_text_in_log('Found IIO poll accelerometer'), True)
        self.assertEqual(self.get_dbus_property('HasAccelerometer'), True)

        self.stop_daemon()

    def test_unclaimed_hotplug_availability(self):
        '''unclaimed observers learn about both types on one hotplugged device'''
        self._check_hotplug_availability(claim_before=False)

    def test_claimed_hotplug_availability(self):
        '''pre-existing claims keep first readings private during hotplug'''
        self._check_hotplug_availability(claim_before=True)

    def test_unrequested_readings(self):
        '''unrequested property updates'''
        self.testbed.add_device('input', 'fake-light', None,
            [],
            ['NAME', '"Power Button"']
        )
        env = os.environ.copy()
        env['FAKE_LIGHT_SENSOR'] = '1'
        self.start_daemon(env)
        self.assertEqual(self.get_dbus_property('HasAmbientLight'), True)

        ctx = GLib.main_context_default()

        self.proxy.ClaimLight()
        self.assertEqual(self.get_dbus_property('LightLevel'), 0.0)
        self.proxy.ReleaseLight()

        self.assertEqual(self.get_dbus_property('LightLevel'), 0.0)

        self.proxy.ClaimLight()
        self.assertEqual(self.get_dbus_property('LightLevel'), 1.0)
        self.proxy.ReleaseLight()

        self.assertEqual(self.get_dbus_property('LightLevel'), 1.0)

        monitor = subprocess.Popen(self.monitor_sensor_path)
        self.assertEventually(lambda: int(self.get_dbus_property('LightLevel')) == 2.0)
        monitor.kill()

        # Catch up with main loop signals
        while ctx.pending():
            ctx.iteration(True)

        # We shouldn't have received light level properties updates
        res = self.proxy.get_cached_property('LightLevel')
        self.assertEqual(res.unpack(), 1.0)
        self.assertTrue(int(self.get_dbus_property('LightLevel') > 1.0))

        self.stop_daemon()

    def test_iio_scale_decimal_separator(self):
        '''scale decimal separator'''
        top_srcdir = os.getenv('top_srcdir', '.')
        mock_dev_data = self.testbed.get_root_dir() + '/iio-dev-data.bin'
        accel = self.testbed.add_device('iio', 'iio-buffer-accel0', None,
            ['name', 'IIO Test Accelerometer',
             'buffer/enable', '0',
             'trigger/current_trigger', '',
             'in_accel_scale', '0.000010\n',
             'in_accel_offset', '0.0\n',
             'in_accel_mount_matrix', '1, 0, 0; 0, 1, 0; 0, 0, 1\n',
             'scan_elements/in_accel_x_en', '0',
             'scan_elements/in_accel_x_index', '0',
             'scan_elements/in_accel_x_type', 'le:s16/32>>0',
             'scan_elements/in_accel_y_en', '0',
             'scan_elements/in_accel_y_index', '1',
             'scan_elements/in_accel_y_type', 'le:s16/32>>0',
             'scan_elements/in_accel_z_en', '0',
             'scan_elements/in_accel_z_index', '2',
             'scan_elements/in_accel_z_type', 'le:s16/32>>0',
             'scan_elements/in_timestamp_en', '1',
             'scan_elements/in_timestamp_index', '3',
             'scan_elements/in_timestamp_type', 'le:s64/64>>0'],
            ['NAME', '"IIO Accelerometer"',
             'DEVNAME', '/dev/iio-buffer-accel-test',
             'IIO_SENSOR_PROXY_TYPE', 'iio-buffer-accel']
        )
        trigger = self.testbed.add_device('iio', 'trigger0', None,
            ['name', 'accel_3d-dev0'],
            []
        )
        env = os.environ.copy()
        env['LC_NUMERIC'] = 'fr_FR.UTF-8'
        data = self.read_file(top_srcdir + '/tests/iio-buffer-accel-data/orientation-normal.bin')
        with open(mock_dev_data,'wb') as mock_file:
            mock_file.write(data)
        self.start_daemon(env=env)

        self.assertEqual(self.get_dbus_property('HasAccelerometer'), True)
        with open(mock_dev_data,'wb') as mock_file:
            mock_file.write(data)
        self.proxy.ClaimAccelerometer()
        self.assertEqual(self.have_text_in_log('Accel sent by driver'), True)
        self.assertEqual(self.have_text_in_log('scale: 0,000000,0,000000,0,000000'), False)
        if self.has_fr:
            self.assertEqual(self.have_text_in_log('scale: 0,000010,0,000010,0,000010'), True)
        self.stop_daemon()

    def test_iio_scale_decimal_separator_offset(self):
        '''scale decimal separator with specific offset'''
        top_srcdir = os.getenv('top_srcdir', '.')
        mock_dev_data = self.testbed.get_root_dir() + '/iio-dev-data.bin'
        accel = self.testbed.add_device('iio', 'iio-buffer-accel0', None,
            ['name', 'IIO Test Accelerometer',
             'buffer/enable', '0',
             'trigger/current_trigger', '',
             'in_accel_scale', '0.000010\n',
             'in_accel_x_offset', '0.0\n',
             'in_accel_mount_matrix', '1, 0, 0; 0, 1, 0; 0, 0, 1\n',
             'scan_elements/in_accel_x_en', '0',
             'scan_elements/in_accel_x_index', '0',
             'scan_elements/in_accel_x_type', 'le:s16/32>>0',
             'scan_elements/in_accel_y_en', '0',
             'scan_elements/in_accel_y_index', '1',
             'scan_elements/in_accel_y_type', 'le:s16/32>>0',
             'scan_elements/in_accel_z_en', '0',
             'scan_elements/in_accel_z_index', '2',
             'scan_elements/in_accel_z_type', 'le:s16/32>>0',
             'scan_elements/in_timestamp_en', '1',
             'scan_elements/in_timestamp_index', '3',
             'scan_elements/in_timestamp_type', 'le:s64/64>>0'],
            ['NAME', '"IIO Accelerometer"',
             'DEVNAME', '/dev/iio-buffer-accel-test',
             'IIO_SENSOR_PROXY_TYPE', 'iio-buffer-accel']
        )
        trigger = self.testbed.add_device('iio', 'trigger0', None,
            ['name', 'accel_3d-dev0'],
            []
        )
        env = os.environ.copy()
        env['LC_NUMERIC'] = 'fr_FR.UTF-8'
        data = self.read_file(top_srcdir + '/tests/iio-buffer-accel-data/orientation-normal.bin')
        with open(mock_dev_data,'wb') as mock_file:
            mock_file.write(data)
        self.start_daemon(env=env)

        self.assertEqual(self.get_dbus_property('HasAccelerometer'), True)

        self.stop_daemon()

    def test_sampling_freq_available_integer(self):
        'Check whether the sampling frequency gets corrected to >= 10Hz, integer numbers sorted low to high'

        accel = self.testbed.add_device('iio', 'iio-accel', None,
            ['in_accel_x_raw', '0',
             'in_accel_y_raw', '-256000000',
             'in_accel_z_raw', '0',
             'in_accel_scale', '0.000001',
             'sampling_frequency', '5.2',
             # Real world example taken from LSM303DA accelerometer
             'sampling_frequency_available', '3 6 12 25 50 100 200 400 800 1600',
             'name', 'IIO Test Accelerometer'],
            ['NAME', '"IIO Accelerometer"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-accel']
        )
        self.start_daemon()
        self.assertEqual(self.get_dbus_property('HasAccelerometer'), True)
        self.assertEqual(self.read_sysfs_attr(accel, 'sampling_frequency'), b'12')
        self.stop_daemon()

    def test_sampling_freq_available_double(self):
        'Check whether the sampling frequency gets corrected to >= 10Hz, double numbers sorted high to low'

        accel = self.testbed.add_device('iio', 'iio-accel', None,
            ['in_accel_x_raw', '0',
             'in_accel_y_raw', '-256000000',
             'in_accel_z_raw', '0',
             'in_accel_scale', '0.000001',
             'sampling_frequency', '5.2',
             # Real world example taken from drivers/iio/accel/mma8452.c
             'sampling_frequency_available', '800.000000 400.000000 200.000000 100.000000 50.000000 12.500000 6.250000 1.560000',
             'name', 'IIO Test Accelerometer'],
            ['NAME', '"IIO Accelerometer"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-accel']
        )
        self.start_daemon()
        self.assertEqual(self.get_dbus_property('HasAccelerometer'), True)
        self.assertEqual(self.read_sysfs_attr(accel, 'sampling_frequency'), b'12.5')
        self.stop_daemon()

    def test_iio_scale_decimal_separator2(self):
        '''scale decimal separator polling'''
        accel = self.testbed.add_device('iio', 'iio-accel', None,
            ['in_accel_x_raw', '0',
             'in_accel_y_raw', '-256000000',
             'in_accel_z_raw', '0',
             'in_accel_scale', '0.000001',
             'sampling_frequency', '5.2',
             'name', 'IIO Test Accelerometer'],
            ['NAME', '"IIO Accelerometer"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-accel']
        )
        env = os.environ.copy()
        env['LC_NUMERIC'] = 'fr_FR.UTF-8'
        self.start_daemon(env=env)

        self.proxy.ClaimAccelerometer()
        self.assertEqual(self.have_text_in_log('Accel read from IIO on'), True)
        self.assertEqual(self.have_text_in_log('scale 1,000000,1,000000,1,000000'), False)
        if self.has_fr:
            self.assertEqual(self.have_text_in_log('scale 0,000001,0,000001,0,000001'), True)

        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'normal')

        self.testbed.set_attribute(accel, 'in_accel_x_raw', '-256000000')
        self.testbed.set_attribute(accel, 'in_accel_y_raw', '0')
        self.assertEventually(lambda: self.get_dbus_property('AccelerometerOrientation') == 'right-up')

        self.stop_daemon()

    #
    # Helper methods
    #

    def _check_hotplug_availability(self, claim_before):
        # Keep the daemon alive while neither of the tested types exists.
        # This fake compass is never polled; no SSC provider is contacted.
        self.testbed.add_device('input', 'hotplug-anchor', None, [],
                                ['NAME', '"Power Button"'])
        env = os.environ.copy()
        env['FAKE_COMPASS'] = '1'
        self.start_daemon(env)

        # A new connection is essential: another proxy on self.dbus would
        # share the claimant's bus name and receive its private readings.
        connection = Gio.DBusConnection.new_for_address_sync(
            self.test_bus.get_bus_address(),
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT |
            Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        self.addCleanup(connection.close_sync, None)
        self.assertNotEqual(connection.get_unique_name(),
                            self.dbus.get_unique_name())
        observer = Gio.DBusProxy.new_sync(
            connection, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None,
            SP, SP_PATH, SP, None)
        events = []
        invalidations = []
        observer.connect('g-properties-changed',
                         lambda _proxy, changed, invalidated:
                         (events.append(changed.unpack()),
                          invalidations.extend(invalidated)))

        cached = lambda proxy, name: proxy.get_cached_property(name).unpack()
        self.assertFalse(cached(observer, 'HasAccelerometer'))
        self.assertFalse(cached(observer, 'HasAmbientLight'))
        self.assertEqual(cached(observer, 'AccelerometerOrientation'), 'undefined')
        self.assertEqual(cached(observer, 'LightLevel'), 0)

        if claim_before:
            self.proxy.ClaimAccelerometer()
            self.proxy.ClaimLight()

        # One synthetic IIO node carries both types, just as a single SSC
        # transport can do. Exercise the real generic hotplug loop without
        # adding hardware rules or faking an SSC transport response.
        device = self.testbed.add_device('iio', 'hotplug-shared', None,
            ['name', 'Hotplug Test Sensors',
             'in_accel_x_raw', '0',
             'in_accel_y_raw', '-256000000',
             'in_accel_z_raw', '0',
             'in_accel_scale', '0.000001',
             'in_illuminance_input', '42'],
            ['NAME', '"Hotplug Test Sensors"',
             'IIO_SENSOR_PROXY_TYPE', 'iio-poll-accel iio-poll-als'])
        self.testbed.uevent(device, 'add')

        self.assertEventually(lambda: cached(observer, 'HasAccelerometer'))
        self.assertEventually(lambda: cached(observer, 'HasAmbientLight'))
        self.assertIn({'HasAccelerometer': True}, events)
        self.assertIn({'HasAmbientLight': True}, events)

        if not claim_before:
            self.proxy.ClaimAccelerometer()
            self.proxy.ClaimLight()

        self.assertEventually(lambda:
                              cached(self.proxy, 'AccelerometerOrientation') == 'normal')
        self.assertEventually(lambda: cached(self.proxy, 'LightLevel') == 42)
        self.assertEqual(cached(observer, 'AccelerometerOrientation'), 'undefined')
        self.assertEqual(cached(observer, 'LightLevel'), 0)

        # Existing claimants have received measurements, but the independent
        # unclaimed observer must only receive availability booleans.
        self.assertTrue(events)
        for changed in events:
            self.assertEqual(len(changed), 1)
            self.assertLessEqual(set(changed), {'HasAccelerometer', 'HasAmbientLight'})
        self.assertEqual(invalidations, [])

        # Leave the node in place until the daemon processes its removal;
        # the anchor prevents this from merely testing daemon disappearance.
        self.testbed.uevent(device, 'remove')
        self.assertEventually(lambda: not cached(observer, 'HasAccelerometer'))
        self.assertEventually(lambda: not cached(observer, 'HasAmbientLight'))
        self.assertIn({'HasAccelerometer': False}, events)
        self.assertIn({'HasAmbientLight': False}, events)
        for changed in events:
            self.assertEqual(len(changed), 1)
            self.assertLessEqual(set(changed), {'HasAccelerometer', 'HasAmbientLight'})
        self.assertEqual(invalidations, [])
        self.assertEqual(self.get_dbus_property('AccelerometerOrientation'), 'undefined')
        self.assertEqual(self.daemon.poll(), None, 'daemon exited despite anchor')
        self.testbed.remove_device(device)

    @classmethod
    def _props_to_str(cls, properties):
        '''Convert a properties dictionary to uevent text representation.'''

        prop_str = ''
        if properties:
            for k, v in properties.items():
                prop_str += '%s=%s\n' % (k, v)
        return prop_str

if __name__ == '__main__':
    # run ourselves under umockdev
    if 'umockdev' not in os.environ.get('LD_PRELOAD', ''):
        os.execvp('umockdev-wrapper', ['umockdev-wrapper'] + sys.argv)

    unittest.main()
