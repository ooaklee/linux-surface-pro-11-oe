---
id: adr-0052-sp11-integration-fork-build
title: "ADR0052: Build from the SP11 Integration Kernel Fork"
# prettier-ignore
description: Architecture Decision Record (ADR) for building the Surface Pro 11 kernel from the ooaklee/linux_ms_dev_kit-sp11 integration fork (sp11/integration-7.2-rc5) instead of cloning the upstream jglathe tree directly.
---

# ADR0052: Build from the SP11 Integration Kernel Fork

## Status

Proposed (2026-08-10).

## Context

The Surface Pro 11 kernel was previously built by cloning the upstream
jglathe tree (`jg/ubuntu-qcom-x1e-7.2-rc5-jg-0`) and applying SP11-specific
patches at build time from `patches/jglathe-qcom-x1e-7.2-rc5` and
`patches/sp11-qcom-x1e-7.2-rc5-v3`. The touchscreen driver and QSPI support
were then applied as out-of-tree modules via `patches/sp11-touchscreen`.

Two SP11-specific kernel patches have now been merged into the integration
fork `ooaklee/linux_ms_dev_kit-sp11` branch `sp11/integration-7.2-rc5`:

1. **DP link-rate workaround** (PR #2, `7dccfdf7a`): the ATNA30DW01-1 OLED
   panel reports `dpcd[DP_MAX_LINK_RATE] == 0`, causing `drm/msm/dp` probe
   failure. The quirk overrides it to `DP_LINK_BW_8_1` for the SP11 only.

2. **DWC3 USB resume quirk** (PR #3, `ed88c4e60`): the SP11 gates USB2 PHY
   power during deep sleep. The `snps,reinit-phy-on-resume` quirk forces a
   full `phy_exit()` + `phy_init()` cycle on resume, preventing USB device
   corruption. Adapted from the Surface Laptop 7 community patch by Oliver
   White.

These patches are not available when building from the upstream jglathe
tree directly — they exist only in the integration fork. Building from the
fork ensures the kernel image includes both fixes without requiring
additional local patch directories.

## Decision

Build the Surface Pro 11 kernel from the integration fork by changing the
`--git-url` and `--git-branch` parameters. Keep the existing patch
directories unchanged — the fork carries the SP11 kernel deltas but not the
Debian packaging annotations.

### Build command

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11.git \
  --git-branch sp11/integration-7.2-rc5 \
  --image ubuntu:26.04 \
  --patch-dirs "patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v3" \
  --build-target "binary-indep binary-qcom-x1e" \
  --work-dir build/docker-sp11-qcom-x1e-kernel-integration-7.2rc-sp11-v3 \
  --linux-work-volume sp11-qcom-x1e-kernel-build-integration-7.2rc-sp11-v3 \
  --copy-to-payload \
  --reset-source \
  --jobs 8
```

### What changes

| Parameter | Before (ADR-0049) | After (this ADR) |
|---|---|---|
| `--git-url` | `https://github.com/jglathe/linux_ms_dev_kit.git` | `https://github.com/ooaklee/linux_ms_dev_kit-sp11.git` |
| `--git-branch` | `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0` | `sp11/integration-7.2-rc5` |
| `--patch-dirs` | `patches/jglathe-qcom-x1e-7.2-rc5 patches/sp11-qcom-x1e-7.2-rc5-v3` | unchanged |
| `--work-dir` | `build/docker-sp11-qcom-x1e-kernel-jg-7.2rc-sp11-v3` | `build/docker-sp11-qcom-x1e-kernel-integration-7.2rc-sp11-v3` |
| `--linux-work-volume` | `sp11-qcom-x1e-kernel-build-jg-7.2rc-sp11-v3` | `sp11-qcom-x1e-kernel-build-integration-7.2rc-sp11-v3` |

### What stays the same

- **Patch directories**: `patches/jglathe-qcom-x1e-7.2-rc5` (Debian
  annotations fix for `CONFIG_VERSION_SIGNATURE`) and
  `patches/sp11-qcom-x1e-7.2-rc5-v3` (2.4 MHz DMIC clock, touchscreen DTS
  node, Debian build naming) are still applied at build time. The fork
  carries the SP11 kernel source deltas but not the Debian packaging
  annotations — these remain build-time patches.

- **Touchscreen modules**: `scripts/build-sp11-touchscreen-modules.sh`
  builds the geocausa QSPI/HID-over-SPI modules as out-of-tree overrides
  against the installed kernel headers. This flow is unchanged.

- **Existing builds**: The v2 and v3 builds from ADR-0048 and ADR-0049
  remain valid. The fork is a superset of the jglathe base — it descends
  from `8f953dd` (the same commit as `jg/ubuntu-qcom-x1e-7.2-rc5-jg-0`)
  with two additional SP11-specific commits.

### Patch applicability verification

All patch directories were verified to apply cleanly on top of the
integration fork's `sp11/integration-7.2-rc5` HEAD (`88b64724b4`):

| Patch | Applies |
|---|---|
| `jglathe-qcom-x1e-7.2-rc5/0001-debian-qcom-x1e-update-annotations-for-7.2-rc5-jg-0.patch` | yes |
| `sp11-qcom-x1e-7.2-rc5-v3/0001-arm64-dts-qcom-x1-denali-use-2.4-MHz-DMIC-clock.patch` | yes |
| `sp11-qcom-x1e-7.2-rc5-v3/0002-arm64-dts-qcom-x1-denali-enable-mshw0485-touchscreen.patch` | yes |
| `sp11-qcom-x1e-7.2-rc5-v3/0003-debian-qcom-x1e-name-SP11-v3-build.patch` | yes (after annotations patch) |
| `sp11-touchscreen/0001-dma-qcom-gpi-Add-QSPI-protocol-support.patch` | yes |
| `sp11-touchscreen/0002-spi-geni-qcom-Add-QSPI-1-4-4-mode-support.patch` | yes |

## Fork branch structure

```
8f953dd  jg/ubuntu-qcom-x1e-7.2-rc5-jg-0  (jglathe base, immutable)
  │
  ├── 7dccfdf7  drm/msm/dp: Work around bogus maximum link rate (PR #2)
  ├── d38a7a34  ci: allow checkpatch.pl without a full kernel tree checkout
  ├── 8d06d988  usb: dwc3: add reinit-phy-on-resume quirk (PR #3, patch 1)
  ├── c493d68a  dt-bindings: usb: dwc3: document snps,reinit-phy-on-resume
  ├── ed88c4e6  arm64: dts: qcom: x1-denali: enable phy-reinit-on-resume for USB
  ├── 7aa3feca  ci: only fail on checkpatch ERROR-level findings
  │
  └── 88b64724  Merge PR #3  ← sp11/integration-7.2-rc5 HEAD
```

All SP11-specific kernel deltas are reviewed through pull requests with
the `Validate integration delta` CI gate (checkpatch + binary/artifact
detection + base-commit ancestry check). The branch is protected by a
GitHub ruleset requiring the status check to pass before merge.

## Future direction

As SP11-specific patches move from the packaging repo's patch directories
into the integration fork (see issue #34 for the touchscreen kernel
patches), the `--patch-dirs` list will shrink. The end goal is for the
integration fork to carry all SP11 kernel deltas, leaving only the Debian
packaging annotations as build-time patches.

## Consequences

- **Positive**: The built kernel now includes the DP workaround and USB
  resume quirk without manual patch management.
- **Positive**: The integration fork's CI gate validates each patch before
  it reaches the build, reducing the risk of build-time patch conflicts.
- **Positive**: Existing builds (v2, v3) remain unaffected — the fork is a
  superset of the same base.
- **Negative**: The build now depends on the `ooaklee/linux_ms_dev_kit-sp11`
  fork being available. If the fork is unavailable, the build falls back to
  the jglathe URL (but loses the SP11-specific patches).
- **Neutral**: The `--work-dir` and `--linux-work-volume` names change to
  avoid collisions with the existing jglathe build caches.
