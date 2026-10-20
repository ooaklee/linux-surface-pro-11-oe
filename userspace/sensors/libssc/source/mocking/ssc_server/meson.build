pymod = import('python')
python = pymod.find_installation()
python.dependency()
python_gen = []

msgs = [
  'common',
  'sensor-suid',
  'sensor-proximity',
  'sensor-light',
  'sensor-accelerometer',
  'sensor-magnetometer',
  'sensor-rotationvector',
  'sensor-gyroscope',
]

mocking_sources = files(
  'qmi.py',
  'ssc.py',
  '__init__.py',
)
python.install_sources(mocking_sources, subdir: 'ssc_server')

ssc_server_conf = configuration_data()
ssc_server_conf.set('VERSION', libssc_version)
ssc_server_conf.set('LIBSSC_MAJOR_VERSION', libssc_version_major)
ssc_server_conf.set('LIBSSC_MINOR_VERSION', libssc_version_minor)
ssc_server_conf.set('LIBSSC_PATCH_VERSION', libssc_version_patch)
ssc_server_conf.set('LIBSSC_MOCKING_PYTHON_BUILD_PATH', join_paths(meson.global_build_root(), 'mocking'))

ssc_server = configure_file(
  input: 'ssc-server.in',
  output: '@BASENAME@',
  configuration: ssc_server_conf,
  install_dir: installed_tests_execdir,
)

foreach m: msgs
  name = 'ssc-' + m

  # Python
  python_name = 'ssc_' + m.replace('-', '_')
  protobuf_python_gen = custom_target (
    python_name + '_py',
    input: join_paths(meson.global_source_root(), 'data', name + '.proto'),
    output: [python_name + '_pb2.py'],
    command: [protoc_tool, '--proto_path=' + join_paths(meson.global_source_root(), 'data'), '--python_out=' + '@OUTDIR@', name + '.proto'],
    install: true,
    install_dir: [join_paths(python.get_install_dir(), 'ssc_server')]
  )
  python_gen += protobuf_python_gen[0]
endforeach

# Make the SSC Server available during tests
ssc_server_dep = custom_target(
  'ssc-mocking',
  input: mocking_sources,
  output: ['qmi.py', 'ssc.py', 'ssc-server', 'ssc-server-tests'],
  command: ['cp', '@INPUT@', '@OUTDIR@'],
  build_by_default: true,
  depends: [python_gen]
)

subdir('data')
