# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added
- CI/CD using Forgejo Actions.

### Fixed
- Propagate the `GError` from the sensor open/close callbacks instead of
  dropping it, so callers no longer receive a `FALSE` result with a `NULL`
  error (which crashes consumers that dereference `error->message`).
- Import Protobuf Python classes for mocking tests.

## [0.4.4] - 2026-06-27

### Improved
- Search for libqrtr as well in lib64 directories in mocking server.

## [0.4.3] - 2026-05-31

### Improved
- Do not install mocking test files, only ssc-server to allow mocking libssc stuff on x86.
- Refer to build paths of Protobuf Python files for the ssc-server by injecting the path during build with meson.
- Inject the project version during build with meson into ssc-server as well.

## [0.4.2] - 2026-03-18

### Fixed
- Tests are more reliable in CI/CD.

## [0.4.1] - 2026-03-01

### Changed
- Increased discovery timeout to 100s.

## [0.4.0] - 2026-01-11

### Improved
- Updated build instructions.

### Added
- Extract mount matrix and apply it for accelerometers.

### Fixed
- Cleaned up white space.
- Fixed 2 memory leaks caused.
- Properly close QMI client.
- Do not initialize variables if not needed.
- Do not check for `NULL` when not needed.
- Move Xiaomi Davinci struct to private header.
- Add symbol list to avoid exposing more symbols.
- Deprecation warning of protobuf-c tool.
- Do not run tests if `Q_IPCRTR protocol` is not available.
- Skip tests on ARMv7/armhf due to floating point problems with protobuf-c decoding.
- Fix printf formats for sensor UIDs.
- ABI of compass signal.
- Reworked synchronous handling.

## [0.3.0] - 2025-12-26

### Added
- Gyroscope sensor support.
- Vala bindings generation.
- GObject introspection generation.

### Fixed
- Thread symbol leaking into global scope.

### Changed
- Drop reporting threads as these are not necessary.

## [0.2.2] - 2025-02-21

### Fixed
- Load libqrtr on Debian correctly for mocking SSC.
- Use `g_assert_no_error` in tests.
- Let meson look for Python instead of specifying the binary name when mocking.
- Add `g_cond` for report threads to avoid race conditions.

## [0.2.1] - 2025-01-12

### Fixed
- Mocking Protobuf messages are now stored in the right directory.
- Mocking binary and data are now installed in the right directory.

## [0.2.0] - 2025-01-11

### Added
- Unittests for CI/CD.
- Mocking SSC DSP with ssc-server to emulate DSP on non-Qualcomm environments.
- Release instructions in RELEASE.md.
- Set `G_LOG_DOMAIN` during build to 'libssc' for easier debugging.
- Wait for DSP to become available during boot.

### Changed
- Reduced API surface. All private interfaces are now excluded from public usage.
- API is now solely exposed through `libssc.h`.
- Use proper GErrors instead of g\_warning for errors.

### Fixed
- Passing GTask in libssc-sensor was missing.
- Light sensor intensity is always positive, reject negative measurements.
- Proximity sensor will always output a measurement now when opened.
- Document availability sensor attribute and specify QMI header length.
- Path to protoc and protoc-c for compiling ProtoBuff messages.
- Public headers are now correctly installed.
- Sync API race conditions.

## [0.1.6] - 2024-06-08

### Fixed
- Ownership of GError is now properly performed when using GTasks.
- Handle access denied to address family AF\_QIPCRTR in lockdown mode.
- Fix verbose argument for enabling debug mode in ssccli.
- Race condition if the sensor is rapidly probed by opening and closing it.

## [0.1.5] - 2024-05-17

### Fixed
- Fixed LICENSE to properly indicate GPLv3.
- Add architecture diagram referenced in reverse engineering notes.
- Fix .so library name to avoid twice 'lib': liblibssc.so

### Added
- Timeout parameter for ssccli.
- Flush stdout after each sensor measurement in ssccli.
- Add support for proximity sensor of xiaomi-davinci (SM7150).

### Changed
- Expanded README with proper description and link to landing page.
- Added build instructions to README.
- Added custom domain for landing page in README.

## [0.1.4] - 2023-08-19

### Fixed
- Link with math library.
- Assert QMI client not NULL during sensor disposing.

### Added
- Define unknown type in QMI Report messages as Report Type.

### Changed
- Update to latest libqmi API changes.
- Search for sensors with a non-zero sample rate such as sensors on Pixel 3A.

## [0.1.3] - 2023-05-20

### Fixed
- Release QMI client before sensor disposing.

## [0.1.2] - 2023-05-20

### Fixed
- Segfault with unknown parameter.
- Segfault during sensor disposing.

## [0.1.1] - 2023-05-01

### Fixed
- Fix format-security warning.

## [0.1.0] - 2023-05-01

Initial release.

<!-- links to diffs between releases -->
[0.1.0]: https://codeberg.org/DylanVanAssche/libssc/compare/01fe59f06aa107a556dd2cdf33e65fd6378eaf32...0.1.0
[0.1.1]: https://codeberg.org/DylanVanAssche/libssc/compare/0.1.0...0.1.1
[0.1.2]: https://codeberg.org/DylanVanAssche/libssc/compare/0.1.1...0.1.2
[0.1.3]: https://codeberg.org/DylanVanAssche/libssc/compare/0.1.2...0.1.3
[0.1.4]: https://codeberg.org/DylanVanAssche/libssc/compare/0.1.3...0.1.4
[0.1.5]: https://codeberg.org/DylanVanAssche/libssc/compare/0.1.4...0.1.5
[0.1.6]: https://codeberg.org/DylanVanAssche/libssc/compare/0.1.5...0.1.6
[0.2.0]: https://codeberg.org/DylanVanAssche/libssc/compare/0.1.6...v0.2.0
[0.2.1]: https://codeberg.org/DylanVanAssche/libssc/compare/v0.2.0...v0.2.1
[0.2.2]: https://codeberg.org/DylanVanAssche/libssc/compare/v0.2.1...v0.2.2
[0.3.0]: https://codeberg.org/DylanVanAssche/libssc/compare/v0.2.2...v0.3.0
[0.4.0]: https://codeberg.org/DylanVanAssche/libssc/compare/v0.3.0...v0.4.0
[0.4.1]: https://codeberg.org/DylanVanAssche/libssc/compare/v0.4.0...v0.4.1
[0.4.2]: https://codeberg.org/DylanVanAssche/libssc/compare/v0.4.1...v0.4.2
[0.4.3]: https://codeberg.org/DylanVanAssche/libssc/compare/v0.4.2...v0.4.3
[0.4.4]: https://codeberg.org/DylanVanAssche/libssc/compare/v0.4.3...v0.4.4
