---
id: adr-0056-sp11-7-2-rc5-jg-0sp11v6-integration-build
title: "ADR0056: SP11 7.2-rc5-jg-0sp11v6 Integration Fork Build"
# prettier-ignore
description: Architecture Decision Record (ADR) for the Surface Pro 11 v6 kernel, built from the sp11/integration-7.2-rc5 branch of the ooaklee/linux_ms_dev_kit-sp11 fork with the wsa884x 2S / PA-fault recovery and in-tree touchscreen.
---

# ADR0056: SP11 7.2-rc5-jg-0sp11v6 Integration Fork Build

## Status

Accepted and hardware-verified (2026-08-18). The
`7.2-rc5-jg-0sp11v6-qcom-x1e` kernel is installed on the X1E80100 OLED
device: the kernel boots, the in-tree phase55 touchscreen works, and speaker
audio works with the wsa884x PA-recovery profile active. A reboot onto this
build also cleared the choppy audio reported on the previous kernel.

## Context

[ADR-0054](adr-0054-sp11-7-2-rc5-jg-0sp11v4-intree-touchscreen-build.md)
carried the phase55 MSHW0485 touchscreen in tree on the
`sp11/qcom-x1e-7.2-rc5-touchscreen-intree` branch.
[ADR-0052](adr-0052-sp11-integration-fork-build.md) decided to build from the
`ooaklee/linux_ms_dev_kit-sp11` integration fork because the SP11-specific
DP link-rate and DWC3 USB resume fixes exist only there.

Separately, the wsa884x driver could wedge the left PA during sustained
full-volume playback, leaving only pops; the SP11 2S/4-ohm class-H profile and
latched PA-fault recovery address this. The v6 build merges all of the above
into one source branch so the kernel can be built with no local patches.

## Decision

Build the Surface Pro 11 kernel from the `sp11/integration-7.2-rc5` branch of
`ooaklee/linux_ms_dev_kit-sp11` at commit
`7ee4adb3cb57f34f247eb85cc217ff584e0e2be7` (merge of pull request #8,
`sp11/merge-intree-into-integration`), using Debian ABI `0sp11v6` and kernel
release `7.2-rc5-jg-0sp11v6-qcom-x1e`. Apply no local patches at build time;
the branch carries the full SP11 delta.

## Decision details

The integration branch at the v6 build head carries, on top of the jglathe
`7.2-rc5-jg-0` base:

- In-tree phase55 MSHW0485 touchscreen stack (`mshw0485_touch`,
  `spi-geni-qcom` QSPI, `gpi` QSPI), merged from the touchscreen-intree
  branch
- `ASoC: wsa884x: recover PA faults and apply SP11 2S 4-ohm profile`
  (`40932bba5`): 2S supply detection, latched PA-fault recovery, and the
  2S/4-ohm OCP/PBR profile
- SP11 v6 package naming (`604fad833`) and checkpatch cleanup (`0b1fb2d48`)
- DP link-rate workaround (PR #2) and DWC3 USB resume quirk (PR #3)
- PSCI cluster idle-state disable (PR #5), volume rocker (PR #6), and
  platform-profile/fan (PR #7)

Build: `docker-sp11-qcom-x1e-kernel-integration-7.2rc-sp11-v6` on
`ubuntu:26.04`, targets `binary-indep binary-qcom-x1e`, jobs 8. Packages:

- `linux-image-7.2-rc5-jg-0sp11v6-qcom-x1e`
- `linux-modules-7.2-rc5-jg-0sp11v6-qcom-x1e`
- `linux-headers-7.2-rc5-jg-0sp11v6-qcom-x1e`
- `linux-qcom-x1e-headers-7.2-rc5-jg-0sp11v6`

## Consequences

- Single-source build: no local patches and no out-of-tree module bundle;
  the v4-era `gpi.ko` / `spi-geni-qcom.ko` / `mshw0485_touch.ko` install
  step is gone.
- The wsa884x 2S/4-ohm profile is active (WSA MODE `Speaker`, PBR switch on);
  the machine driver caps the PA Volume controls at raw 6 (0 dB) and the
  digital volumes at 81 (-3 dB), matching the staged UCM values.
- Published as GitHub release `sp11-qcom-x1e-7.2-rc5-jg-0sp11v6` on
  `ooaklee/linux-surface-pro-11-oe` (support repo commit `b6fbbb9`) with
  debs, `SHA256SUMS`, release manifest, and source tarball.
- Audio routing is probe-backed on this kernel
  ([ADR-0035](adr-0035-audio-boot-race-alsactl.md) superseded);
  `sp11-wsa-routing.service` applies the WSA path with PCM1 closed and
  exercises a fresh graph at boot.

## Validation

- `uname -r` on the device: `7.2-rc5-jg-0sp11v6-qcom-x1e`
- `sp11-wsa-routing.service` enabled, active, exit 0
- Release assets hash-verified against the build artifacts
  (`SHA256SUMS`), including the source tarball

## References

- Release:
  https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.2-rc5-jg-0sp11v6
- Source branch:
  https://github.com/ooaklee/linux_ms_dev_kit-sp11/tree/sp11/integration-7.2-rc5
- Kernel patch sets archived: `patches/sp11-qcom-x1e-7.2-rc5-v5/`,
  `patches/sp11-qcom-x1e-7.2-rc5-v6/`
