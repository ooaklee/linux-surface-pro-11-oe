# iio-sensor-proxy — native desktop sensor client

`source/` contains a downstream development snapshot based on upstream
[`ca0d5b08bd647afc5f8ead3ce00a44018fbc633f`](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/commit/ca0d5b08bd647afc5f8ead3ce00a44018fbc633f).
Meson reports 3.9; this is not a new upstream release. All 78 exported source
files are pinned in [SOURCE.json](SOURCE.json). No private build paths,
provider binaries, Windows drivers or local firmware captures are required.

## Downstream changes

This modified snapshot is published on 2026-10-20 as part of Leon Silcott's
SP11 integration work, retaining original authorship and copyright notices.
It contains the native SSC measurement adapter integration,
claim and polling lifecycle checks, bounded first-reading handling and
IIO input/buffer/polling corrections. The latest accepted change distinguishes
an absent optional accelerometer scale/offset from an attribute read error,
rejects malformed calibration and delays sampling-frequency fixup until
calibration admission succeeds.

Existing non-null GUdev calibration snapshots are copied, not proven fresh.
File-removal checks are not an atomic hotplug snapshot. Sensor candidate
selection can still miss an alternate device when the first discovered
candidate fails; that follow-up is not repaired by this publication.
See [VALIDATION.md](../VALIDATION.md) for the exact software-only boundary.

Build against [this libssc](../libssc/README.md) and its pinned dependency,
following [BUILDING.md](../BUILDING.md). The reference uses no real sensor
traffic. Do not replace the distro service, install its udev/D-Bus/polkit
files, enable automatic rotation or run `monitor-sensor` on hardware yet.
Matching version strings alone do not establish provider compatibility.

## Licensing and status

Retain [COPYING](source/COPYING) and all individual notices. The project is
GPL-3.0-or-later with file-specific legacy test notices; credits include
Bastien Nocera, Purism, Dylan Van Assche and other upstream contributors.
[The upstream README](source/README.md) is preserved as upstream context,
not an instruction to deploy this experimental build.

This component is not included in v26/v27, has not been installed on a Surface
and is not currently supported by a Lexr sensor adapter. See the
[shared Lexr boundary](../README.md#lexr-boundary).
