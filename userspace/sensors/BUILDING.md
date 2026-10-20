# Maintainer build — no system installation

This recipe builds the source snapshots in this directory on **native Linux
ARM64**. It stages only QMI/SSC into a fresh private prefix, builds the proxy
and runs seven explicitly selected fixture-only test binaries. Nothing is
installed into `/usr`, no service is enabled and no sensor is queried.
Do not run the commands with `sudo` or on a daily-use device as a substitute
for reviewed deployment packaging. Use a disposable development environment
with no hardware devices exposed; no network access is needed during build.

## Prerequisites and scope

Install build dependencies separately using your distribution's supported
process. The reference environment used GCC 14.2, binutils 2.44, Meson 1.7.0,
Ninja 1.12.1, Python 3.13, pkgconf 1.8.1, GLib 2.84.4, qrtr-glib 1.2.2,
protobuf-c 1.5.1 and protoc 3.21.12. The proxy additionally needs GUdev >=237,
GLib/GIO >=2.76, polkit development files and libm. Test configuration requires
Python psutil, python-dbusmock and PyGObject. The selection test starts its own
private D-Bus daemon; it does not contact the system bus. UMockdev is needed
for the wider integration matrix, not the seven test binaries below.
In Debian package terms these include:

```text
gcc-14 binutils meson ninja-build pkgconf python3
libglib2.0-dev libqrtr-glib-dev libprotobuf-c-dev protobuf-c-compiler
protobuf-compiler linux-libc-dev libgudev-1.0-dev libpolkit-gobject-1-dev
libudev-dev systemd-dev python3-psutil python3-dbusmock python3-gi
gir1.2-umockdev-1.0 umockdev dbus-daemon libxml2-utils
```

Package names/versions describe a reference, not a complete authenticated APT
lock or a promise of compatibility with every distribution. The block below
checks for at least 6 GiB free on the actual build filesystem before compiling.
This is an entry check, not a reservation or a guarantee that the build will
fit. `/tmp` may be a separate filesystem or memory-backed; choose a development
environment with adequate disk and memory, and retain failed outputs/logs.
No subproject download is allowed. GIR/VAPI, QMI firmware update and the legacy
SSC hardware/QRTR tests are intentionally disabled in this recipe.
The libssc recipe treats warnings as errors with the reference compiler;
new compiler diagnostics require review, not disabling that check silently.

## Build and selected tests

Start in `userspace/sensors` in a trusted checkout. `SOURCE.sha256` verifies
the exported bytes; it is not independently authenticated merely because it
is stored beside those bytes. Review the Git revision and `SOURCE.json`
provenance as well. No generated files should be written under `source/`.

This whole block runs in a subshell. A failure ends the block, not your
interactive terminal. Keep the printed output directory for diagnosis; do
not reuse a failed output directory as a clean build. It uses a private home,
cache and temporary directory, and resets inherited compiler/linker and
pkg-config sysroot overrides. This is build-environment hygiene, not a sandbox:
the disposable environment must provide the network/device isolation itself.

```sh
(
  set -eu
  umask 077
  test "$(uname -m)" = aarch64
  SENSOR_SOURCES=$(pwd -P)
  test -f "$SENSOR_SOURCES/libssc/SOURCE.json"
  sha256sum -c SOURCE.sha256
  SENSOR_BUILD_ROOT=$(mktemp -d /tmp/oe-native-sensors.XXXXXX)
  SENSOR_STAGE="$SENSOR_BUILD_ROOT/stage"
  printf 'Build output: %s\n' "$SENSOR_BUILD_ROOT"
  SENSOR_FREE_KIB=$(LC_ALL=C df -Pk "$SENSOR_BUILD_ROOT" | awk 'END { print $4 }')
  case "$SENSOR_FREE_KIB" in
    ''|*[!0-9]*) echo 'Unable to determine build-filesystem free space' >&2; exit 1 ;;
  esac
  if ! test "$SENSOR_FREE_KIB" -ge 6291456; then
    printf 'Build requires at least 6291456 available KiB (6 GiB); observed %s\n' "$SENSOR_FREE_KIB" >&2
    exit 1
  fi
  mkdir "$SENSOR_STAGE" "$SENSOR_BUILD_ROOT/home" \
    "$SENSOR_BUILD_ROOT/cache" "$SENSOR_BUILD_ROOT/tmp" \
    "$SENSOR_BUILD_ROOT/config" "$SENSOR_BUILD_ROOT/data"
  export HOME="$SENSOR_BUILD_ROOT/home"
  export XDG_CACHE_HOME="$SENSOR_BUILD_ROOT/cache"
  export XDG_CONFIG_HOME="$SENSOR_BUILD_ROOT/config"
  export XDG_DATA_HOME="$SENSOR_BUILD_ROOT/data"
  export TMPDIR="$SENSOR_BUILD_ROOT/tmp"
  export LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC
  export CC=gcc-14 CFLAGS= CPPFLAGS= CXXFLAGS= LDFLAGS=
  export PYTHONDONTWRITEBYTECODE=1
  export PKG_CONFIG_PATH= PKG_CONFIG_SYSROOT_DIR=
  export PKG_CONFIG_LIBDIR="$SENSOR_STAGE/lib/pkgconfig:/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
  export LD_LIBRARY_PATH="$SENSOR_STAGE/lib"
  export LD_BIND_NOW=1

  meson setup "$SENSOR_BUILD_ROOT/qmi" "$SENSOR_SOURCES/libqmi/source" \
    --prefix="$SENSOR_STAGE" --libdir=lib --wrap-mode=nodownload \
    -Dpkgconfig.relocatable=true -Ddefault_library=both -Dcollection=full \
    -Dqrtr=true -Dmbim_qmux=false -Dfirmware_update=false -Dudev=false \
    -Dintrospection=false -Dman=false -Dgtk_doc=false \
    -Dbash_completion=false -Dmm_runtime_check=false -Drmnet=false
  meson compile -C "$SENSOR_BUILD_ROOT/qmi" -j2
  meson install -C "$SENSOR_BUILD_ROOT/qmi" --no-rebuild
  test "$(pkg-config --variable=pcfiledir qmi-glib)" = "$SENSOR_STAGE/lib/pkgconfig"
  test "$(pkg-config --modversion qmi-glib)" = 1.39.1

  meson setup "$SENSOR_BUILD_ROOT/ssc" "$SENSOR_SOURCES/libssc/source" \
    --prefix="$SENSOR_STAGE" --libdir=lib --wrap-mode=nodownload \
    -Dpkgconfig.relocatable=true -Dintrospection=disabled -Dvapi=disabled \
    -Dbuild-tests=false -Dc_std=gnu11 -Dwarning_level=2 -Dwerror=true \
    -Dbuildtype=custom -Ddebug=true -Db_lundef=true -Doptimization=2 \
    -Db_sanitize=none '-Dc_args=["-DQMI_DISABLE_DEPRECATED","-fPIC"]' -Dstrip=false
  meson compile -C "$SENSOR_BUILD_ROOT/ssc" -j2
  meson install -C "$SENSOR_BUILD_ROOT/ssc" --no-rebuild
  test "$(pkg-config --variable=pcfiledir libssc)" = "$SENSOR_STAGE/lib/pkgconfig"
  test "$(pkg-config --modversion libssc)" = 0.4.7
  timeout --signal=TERM --kill-after=5s 10s "$SENSOR_STAGE/bin/ssccli" --help
  timeout --signal=TERM --kill-after=5s 10s "$SENSOR_STAGE/bin/ssccli" --version

  meson setup "$SENSOR_BUILD_ROOT/proxy" "$SENSOR_SOURCES/iio-sensor-proxy/source" \
    --prefix="$SENSOR_STAGE" --wrap-mode=nodownload \
    --libexecdir=libexec -Dgtk-tests=false -Dgtk_doc=false \
    -Dssc-support=enabled -Dtests=true \
    -Dudevrulesdir="$SENSOR_STAGE/lib/udev/rules.d" \
    -Dsystemdsystemunitdir="$SENSOR_STAGE/lib/systemd/system"
  meson compile -C "$SENSOR_BUILD_ROOT/proxy" -j2
  meson test -C "$SENSOR_BUILD_ROOT/proxy" --num-processes 1 --print-errorlogs \
    test-mount-matrix test-orientation test-ssc-drivers \
    test-iio-buffer test-iio-acquisition test-iio-sysfs-write test-sensor-selection
  printf 'Build and selected software tests completed: %s\n' "$SENSOR_BUILD_ROOT"
)
```

The proxy is deliberately **not installed**, even into the private prefix:
its service, D-Bus, udev and polkit policy need deployment review. Verify the
generated Meson dependency selection and `readelf -d` output before any later
packaging. Do not infer complete ABI or loader verification from a version
check alone. Do not run all tests blindly: retained upstream SSC tests may
contact transports, while proxy integration tests require their private bus
and UMockdev harness. The focused tests above exercise local fixtures, not
hardware or normal desktop services.

Reference software evidence includes additional sanitized and private-bus
checks described in [VALIDATION.md](VALIDATION.md); the short recipe does not
claim to reproduce that entire qualification matrix. Never interpret an
incomplete build, skipped dependency or zero exit from `--help` as permission
to install or activate the stack on a Surface.
