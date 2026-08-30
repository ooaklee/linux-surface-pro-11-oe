# Surface Pro 11 iptsd integration

This directory integrates an unmodified, pinned upstream `iptsd` with the
Surface Pro 11 kernel's private HIDRAW compatibility device. The kernel keeps
ownership of panel mode and direct touchscreen input; `iptsd` decodes only the
DFT stylus stream and creates the standard pen input device.

The pinned source is upstream `iptsd` v3.1.0 at commit
`a83bc1232f7096f8b33b50fdbda249cd640de670`, tree
`06c6e812873e117930eca60b8a32cec40fd13281`. See `SOURCE.env` for the
machine-readable identity. `scripts/build-sp11-iptsd-docker.sh` verifies both
identifiers before building the two required ARM64 binaries.

The integration supports the X1P/LCD (`045e:0c80`) and X1E/OLED (`045e:0c83`)
variants through two device presets. They disable `iptsd` touchscreen
synthesis, preventing a duplicate touch device, while leaving stylus
processing enabled. Panel size and orientation continue to come from the
metadata feature report rather than hard-coded configuration.

The udev, systemd, and sleep lifecycle is adapted from the MIT-licensed
`turbineBMW/surface-pro-11-linux` integration at commit
`05e5335bc72476d44390336701cf03efa5fd0165`; its license is retained as
`LICENSE.integration`. That project provides useful hardware evidence, but its
transport differs from this kernel bridge and does not replace validation of
this integration.

Upstream `iptsd` is GPL-2.0-or-later. A payload build includes its complete
source plus the exact Meson fallback sources and patches linked into the ARM64
binaries. Do not distribute only the binaries.

## Build

```sh
./scripts/build-sp11-iptsd-docker.sh --copy-to-payload
```

The payload installer verifies `SHA256SUMS`, installs the binaries under
`/usr/local/libexec`, installs device-specific presets under
`/usr/local/share/iptsd`, and installs the lifecycle rules. The OpenEmbedded
recipe builds the same pinned iptsd commit against the dependency versions in
the selected OE release and installs under the standard `/usr` prefix.
Recipe parse and package-build validation in a supported BitBake environment
remain pending; the Docker payload build does not validate the OE recipe.

The legacy `g6-pen` daemon and production `sp11-iptsd` service must never run
at the same time. A generic `iptsd` package/service is also mutually exclusive:
the OE recipe conflicts with it and the local installer masks its template.
`/dev/g6ts-heat` and `g6-pen` remain available for controlled diagnostic and
replay work only.

The X1E/OLED installed-system path passed live Phase 84 validation on
`7.2.0-jg-0sp11v19-qcom-x1e`: hover/lift, continuous stylus input, pressure
from 0 through 3309, variation on both tilt axes, and the barrel button worked
with balanced IRQ/report accounting and no panel resets, transport/protocol
errors, or daemon restarts. Normal one-, two-, and three-finger touch also
worked as expected. Separate X1P hardware validation, eraser transitions,
comprehensive touch/gesture regression, forced transport recovery, and repeated
suspend/resume remain release gates.

Unmodified iptsd v3.1.0 advertises `BTN_STYLUS` but not `BTN_STYLUS2`.
Second/top-button support is therefore outside this integration candidate.
