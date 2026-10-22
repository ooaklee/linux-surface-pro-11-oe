# iio-sensor-proxy — native desktop sensor client

`source/` contains a downstream development snapshot based on upstream
[`ca0d5b08bd647afc5f8ead3ce00a44018fbc633f`](https://gitlab.freedesktop.org/hadess/iio-sensor-proxy/-/commit/ca0d5b08bd647afc5f8ead3ce00a44018fbc633f).
Meson reports 3.9; this is not a new upstream release. All 79 exported source
files are pinned in [SOURCE.json](SOURCE.json). No private build paths,
provider binaries, Windows drivers or local firmware captures are required.

## Downstream changes

This modified snapshot is published on 2026-10-20 as part of Leon Silcott's
SP11 integration work, retaining original authorship and copyright notices.
It contains the native SSC measurement adapter integration,
claim and polling lifecycle checks, bounded first-reading handling and
IIO input/buffer/polling corrections. Calibration admission distinguishes
an absent optional accelerometer scale/offset from an attribute read error,
rejects malformed calibration and delays sampling-frequency fixup until
calibration admission succeeds.

Candidate admission now tries usable alternatives after discovery or
construction failure, retains known alternatives when a type is occupied and
fences stale discovery/construction results after removal or shutdown. Stream
activation happens after admission, using owned attempt identities: an old
pending OPEN cannot hold up replacement admission or erase its claims. Releasing
the last future-intent client before activation sends neither OPEN nor STOP.
These are software-fixture results, not hardware sensor qualification.

Existing non-null GUdev calibration snapshots are copied, not proven fresh.
File-removal checks are not an atomic hotplug snapshot. Faulted SSC providers
retain the existing explicit CLOSE/Claim recovery policy; this change adds no
automatic stream-fault failover. It does not establish cancellation of a stuck
native constructor, arbitrary path-move recovery or safety under every external
event storm. Only SSC drivers with the startup-failure hook receive the bounded
first-reading deadline; legacy drivers retain their existing first-reading wait.
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

This component is not included in v26/v27 and has not been installed on a
Surface. Lexr 0.6.0-rc.1 contains an experimental build-only adapter for this
exact composition; sensor installation and activation remain disabled. See the
[shared Lexr boundary](../README.md#lexr-boundary).
