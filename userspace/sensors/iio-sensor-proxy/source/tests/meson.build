envs = environment()
envs.set ('top_builddir', meson.build_root())
envs.set ('top_srcdir', meson.source_root())

python3 = find_program('python3')
unittest_inspector = find_program('unittest_inspector.py')
r = run_command(unittest_inspector, files('integration-test.py'), check: true)
unit_tests = r.stdout().strip().split('\n')

foreach ut: unit_tests
    ut_args = files('integration-test.py')
    ut_args += ut
    test(ut,
         python3,
         args: ut_args,
         env: envs,
        )
endforeach

# These noninstalled fixtures include the real private implementation in
# dedicated translation units. No alternate decoder or production test API.
iio_buffer_test = executable('test-iio-buffer',
    ['test-iio-buffer.c', '../src/utils.c'],
    dependencies: [gio_dep, gudev_dep, mathlib_dep],
    include_directories: include_directories('../src'),
    install: false)
test('test-iio-buffer', iio_buffer_test)

# Four TU-local stdio/readback seams inject failures into the actual private
# helpers. No link wrappers, production hooks or sysfs/device access.
iio_sysfs_write_test = executable('test-iio-sysfs-write',
    ['test-iio-sysfs-write.c', '../src/utils.c'],
    dependencies: [gio_dep, gudev_dep, mathlib_dep],
    include_directories: include_directories('../src'),
    install: false)
test('test-iio-sysfs-write', iio_sysfs_write_test)

# Only device-I/O effects are fixture-provided. Metadata parsing, calibrated
# reading callbacks, driver close functions and object ref/unref remain real.
# These wrappers are confined to this executable, never the production daemon.
iio_acquisition_wraps = []
foreach operation : ['g_udev_device_get_property', 'g_udev_device_get_name',
                     'g_udev_device_get_sysfs_path', 'g_udev_device_get_device_file',
                     'g_udev_device_get_sysfs_attr', 'g_udev_device_get_sysfs_attr_uncached',
                     'buffer_drv_data_new', 'buffer_drv_data_free',
                     'enable_ring_buffer', 'disable_ring_buffer', 'is_buffer_usable',
                     'g_file_get_contents', 'iio_fixup_sampling_frequency']
    iio_acquisition_wraps += ['-Wl,--wrap=' + operation]
endforeach
iio_acquisition_test = executable('test-iio-acquisition',
    ['test-iio-acquisition.c', 'test-iio-acquisition-input.c',
     'test-iio-acquisition-poll.c', 'test-iio-acquisition-buffer.c',
     '../src/drivers.c', '../src/iio-buffer-utils.c', '../src/utils.c',
     '../src/accel-mount-matrix.c', '../src/accel-attributes.c', '../src/accel-scale.c'],
    dependencies: [gio_dep, gudev_dep, mathlib_dep],
    include_directories: include_directories('../src'),
    link_args: iio_acquisition_wraps,
    install: false)
test('test-iio-acquisition', iio_acquisition_test)

if libssc_dep.found()
    # Compile the real drivers with explicit fixture-only lifecycle effects.
    # The executable never initializes or streams an SSC sensor.
    ssc_claim_wraps = []
    foreach kind : ['accelerometer', 'light', 'compass', 'proximity']
        foreach operation : ['new', 'open', 'close']
            ssc_claim_wraps += ['-Wl,--wrap=ssc_sensor_' + kind + '_' + operation + '_sync']
        endforeach
    endforeach
    ssc_driver_wraps = ssc_claim_wraps + ['-Wl,--wrap=setup_mount_matrix', '-Wl,--wrap=setup_accel_location',
                                         '-Wl,--wrap=g_signal_lookup']
    ssc_driver_test = executable('test-ssc-drivers',
        ['test-ssc-drivers.c', '../src/drv-ssc-accel.c', '../src/drv-ssc-light.c',
         '../src/drv-ssc-compass.c', '../src/drv-ssc-proximity.c', '../src/drv-ssc-polling.c', '../src/drivers.c',
         '../src/accel-mount-matrix.c', '../src/accel-scale.c', '../src/accel-attributes.c', '../src/utils.c'],
        dependencies: [gio_dep, gudev_dep, libssc_dep, mathlib_dep],
        link_args: ssc_driver_wraps,
        install: false)
    test('test-ssc-drivers', ssc_driver_test)

    # The real daemon and drivers run on a private D-Bus/UMockdev testbed.
    # Only typed construction/OPEN/CLOSE effects are fixture-provided; this
    # executable is never installed and cannot contact the native provider.
    executable('iio-sensor-proxy-ssc-claim-test',
        sensor_proxy_sources + files('ssc-claim-provider.c'),
        dependencies: deps,
        include_directories: include_directories('../src'),
        # This accelerated policy is confined to the noninstalled test daemon.
        # Installed production keeps its independent 5000ms default.
        c_args: ['-DSSC_FIRST_READING_TIMEOUT_MSEC=750'],
        link_args: ssc_claim_wraps,
        install: false)

    r = run_command(unittest_inspector, files('ssc-test.py'), check: true)
    unit_tests = r.stdout().strip().split('\n')
    foreach ut: unit_tests
        ut_args = files('ssc-test.py')
        ut_args += ut
        test(ut,
             python3,
             args: ut_args,
             env: envs,
            )
    endforeach
endif
