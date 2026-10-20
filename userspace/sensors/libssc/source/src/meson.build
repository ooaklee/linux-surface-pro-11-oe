# SPDX-License-Identifier: GPL-3.0-or-later
#
# libssc: Library to expose Qualcomm Sensor Core sensors
# Copyright (C) 2022-2026 Dylan Van Assche
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published
# by the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#  
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#

libssc_glib_inc = include_directories('.')

version_header = configure_file(
  input: 'libssc-version-private.h.in',
  output: '@BASENAME@',
  configuration: version_conf,
  install_dir: libssc_glib_pkgincludedir,
)

headers += files(
  'libssc.h',
  'libssc-sensor.h',
  'libssc-sensor-retirement.h',
  'libssc-sensor-sample.h',
  'libssc-sensor-proximity.h',
  'libssc-sensor-light.h',
  'libssc-sensor-accelerometer.h',
  'libssc-sensor-magnetometer.h',
  'libssc-sensor-compass.h',
  'libssc-sensor-gyroscope.h',
)

install_headers(
  headers, 
  install_dir: libssc_glib_pkgincludedir
)

sources += files(
  'libssc-lifetime.c',
  'libssc-sensor-sample.c',
  'libssc-common.c',
  'libssc-sensor.c',
  'libssc-sensor-proximity.c',
  'libssc-sensor-light.c',
  'libssc-sensor-accelerometer.c',
  'libssc-sensor-magnetometer.c',
  'libssc-sensor-compass.c',
  'libssc-sensor-gyroscope.c',
)

client_sources = files('libssc-client.c')
# This callback-heavy private TU alone retains its reviewed warning exception.
# Headers establish generation order without compiling codecs with that exception.
client_objects = static_library(
  'ssc-client-private-objects',
  client_sources,
  headers_gen,
  include_directories: includes,
  dependencies: external_deps,
  c_args: ['-Wno-unused-parameter'],
  pic: true,
  install: false,
)

cli_sources = files(
  'libssc-cli.c',
)

so_version = '2'

libssc = shared_library(
  'ssc',
  sources: sources,
  objects: client_objects.extract_all_objects(recursive: false),
  include_directories: includes,
  dependencies: deps,
  install: true,
  soversion: so_version,
  link_args: [
    '-Wl,--version-script=' + map_source[0].full_path()
  ],
)

ssccli = executable(
  'ssccli',
  sources: cli_sources,
  include_directories: includes,
  dependencies: external_deps,
  link_with: libssc,
  install: true,
)

ns = 'SSC'

pkg.generate(
  libraries: libssc,
  version: libssc_version,
  name: 'libssc',
  description: 'Library to access sensors of Qualcomm Sensor Core',
  subdirs: libssc_glib_include_subdir,
  requires: ['glib-2.0', 'gobject-2.0', 'gio-2.0', 'qmi-glib'],
)

introspection_opt = get_option('introspection')
vapi_opt = get_option('vapi')
if vapi_opt.enabled() and introspection_opt.disabled()
  error('VAPI generation requires introspection; do not disable it with vapi=enabled')
endif
gir_required = introspection_opt
if vapi_opt.enabled()
  gir_required = true
endif
gir_dep = dependency('gobject-introspection-1.0', required: gir_required)
if gir_dep.found()
  gnome = import('gnome')

  gir_files = gnome.generate_gir(libssc,
    includes: ['GLib-2.0', 'GObject-2.0', 'Gio-2.0', 'Qmi-1.0'],
    sources: [headers, sources, client_sources],
    dependencies: deps,
    include_directories: includes,
    fatal_warnings: introspection_opt.enabled() or vapi_opt.enabled(),
    namespace: ns,
    symbol_prefix: 'ssc',
    nsversion: so_version,
    export_packages: 'libssc',
    header: 'libssc.h',
    install: true,
  )

  vapigen = find_program('vapigen', required: vapi_opt)
  if vapigen.found()
    gnome.generate_vapi(
      'libssc',
      packages: ['gobject-2.0', 'glib-2.0', 'gio-2.0', 'Qmi-1.0'],
      sources: gir_files.get(0),
      install: true,
    )
  endif
endif
