# libssc — native sensor development snapshot

`source/` contains downstream native Linux libssc sources based on
[`4e4c6c8cc702a754bd700506c01961aaf971a23b`](https://codeberg.org/DylanVanAssche/libssc/commit/4e4c6c8cc702a754bd700506c01961aaf971a23b).
Its development version is **0.4.7**, not an upstream 0.4.7 release. Meson,
pkg-config and `ssccli --version` report the numeric `0.4.7`; the inventory's
`0.4.7-development` is a snapshot label, not the pkg-config version string.
[SOURCE.json](SOURCE.json) pins the exported bytes and executable modes.
Only upstream `utils/strace.txt`, an unnecessary raw Android diagnostic
capture, is excluded for data minimization; its original hash and exclusion
reason are recorded. Production sources and licence notices are retained.

## Downstream changes

This modified snapshot is published on 2026-10-20 as part of Leon Silcott's
SP11 integration work; original authorship and copyright notices remain.
Compared with its upstream base, it includes owned discovery inventories,
explicit selected-UID initialization, bounded lifecycle/receipt handling,
an owned semantic-sample API, CLI inspection/metadata support and focused
test/build corrections. It preserves the prior 83 versioned exports and
adds 14 sample exports at 0.4.7. This is a userspace API change, not a kernel
driver or a GLINK transport repair.

`ssccli` is built from the same sources. Build-only checks use `--help` and
`--version`: discovery or streaming is **not** a harmless build smoke test.
UID selection does not prove physical sensor placement, mounting, calibration
or timestamp-clock identity. Unknown properties remain unknown.

Build after [the pinned libqmi](../libqmi/README.md) using
[BUILDING.md](../BUILDING.md). GIR/VAPI and the legacy QRTR suite are disabled
in the accepted build recipe; a broad `meson test` invocation is not equivalent
to the bounded software tests already performed. Do not install these sources
over system libraries or activate firmware as part of this source check.

## Licensing and status

The original GPL-3.0-or-later source notices and [LICENSE](source/LICENSE) are
retained, including Dylan Van Assche and other libssc contributors.
[The upstream README](source/README.md) remains unchanged; its system-install
guidance is not the qualification recipe for this experimental snapshot.

This is source-only and not hardware-qualified, bundled with v26/v27 or
currently installable by Lexr. See [the integration boundary](../README.md)
and [validation limits](../VALIDATION.md).
