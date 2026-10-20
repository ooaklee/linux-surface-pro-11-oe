add_test_setup(
  'mocking',
  exe_wrapper: join_paths(meson.global_build_root(), 'mocking', 'ssc_server', 'ssc-server'),
  is_default: true
)

test(
  'tests-general',
  executable('tests-general', 'general.c', link_with: libssc, dependencies: deps),
  env: [
    'G_TEST_SRCDIR=@0@'.format(meson.current_source_dir()),
    'G_TEST_BUILDDIR=@0@'.format(meson.current_build_dir()),
  ],
  protocol: 'exitcode',
  suite: 'service',
  is_parallel: false,
)

test(
  'tests-proximity',
  executable('tests-proximity', 'proximity.c', link_with: libssc, dependencies: deps),
  env: [
    'G_TEST_SRCDIR=@0@'.format(meson.current_source_dir()),
    'G_TEST_BUILDDIR=@0@'.format(meson.current_build_dir()),
  ],
  protocol: 'exitcode',
  suite: 'service',
  is_parallel: false,
)

test(
  'tests-light',
  executable('tests-light', 'light.c', link_with: libssc, dependencies: deps),
  env: [
    'G_TEST_SRCDIR=@0@'.format(meson.current_source_dir()),
    'G_TEST_BUILDDIR=@0@'.format(meson.current_build_dir()),
  ],
  protocol: 'exitcode',
  suite: 'service',
  is_parallel: false,
)

test(
  'tests-accelerometer',
  executable('tests-accelerometer', 'accelerometer.c', link_with: libssc, dependencies: deps),
  env: [
    'G_TEST_SRCDIR=@0@'.format(meson.current_source_dir()),
    'G_TEST_BUILDDIR=@0@'.format(meson.current_build_dir()),
  ],
  protocol: 'exitcode',
  suite: 'service',
  is_parallel: false,
)

test(
  'tests-compass',
  executable('tests-compass', 'compass.c', link_with: libssc, dependencies: deps),
  env: [
    'G_TEST_SRCDIR=@0@'.format(meson.current_source_dir()),
    'G_TEST_BUILDDIR=@0@'.format(meson.current_build_dir()),
  ],
  protocol: 'exitcode',
  suite: 'service',
  is_parallel: false,
)

test(
  'tests-magnetometer',
  executable('tests-magnetometer', 'magnetometer.c', link_with: libssc, dependencies: deps),
  env: [
    'G_TEST_SRCDIR=@0@'.format(meson.current_source_dir()),
    'G_TEST_BUILDDIR=@0@'.format(meson.current_build_dir()),
  ],
  protocol: 'exitcode',
  suite: 'service',
  is_parallel: false,
)

test(
  'tests-no-service',
  executable('tests-no-service', 'no-service.c', link_with: libssc, dependencies: deps),
  env: [
    'G_TEST_SRCDIR=@0@'.format(meson.current_source_dir()),
    'G_TEST_BUILDDIR=@0@'.format(meson.current_build_dir()),
  ],
  protocol: 'exitcode',
  suite: 'no-service',
  is_parallel: false,
)

