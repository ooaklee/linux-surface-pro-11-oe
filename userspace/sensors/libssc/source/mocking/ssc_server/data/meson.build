pymod = import('python')
python = pymod.find_installation()
python.dependency()

mocking_config_sources = files(
  'sensor-accelerometer.json',
  'sensor-magnetometer.json',
  'sensor-proximity.json',
  'sensor-rotationvector.json',
  'sensor-light.json',
  'sensor-no-sample-rate.json',
  'sensor-registry.json',
  'sensor-unavailable.json'
)

custom_target(
  'copy-mocking-configure',
  input: mocking_config_sources,
  output: ['sensor-accelerometer.json', 'sensor-magnetometer.json', 'sensor-proximity.json', 'sensor-rotationvector.json', 'sensor-light.json', 'sensor-no-sample-rate.json', 'sensor-registry.json', 'sensor-unavailable.json'],
  command: ['cp', '@INPUT@', '@OUTDIR@'],
  build_by_default: true
)

python.install_sources(mocking_config_sources, subdir: join_paths('ssc_server', 'data'))
