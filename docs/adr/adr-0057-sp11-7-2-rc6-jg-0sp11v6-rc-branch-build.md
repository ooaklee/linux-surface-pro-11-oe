---
id: adr-0057-sp11-7-2-rc6-jg-0sp11v6-rc-branch-build
title: "ADR0057: SP11 7.2-rc6-jg-0sp11v6 rc-Branch Integration Build"
# prettier-ignore
description: Architecture Decision Record (ADR) for the Surface Pro 11 v6 rc6 kernel, built from the sp11/integration-7.2-rc branch of the ooaklee/linux_ms_dev_kit-sp11 fork on the jglathe 7.2-rc6 base.
---

# ADR0057: SP11 7.2-rc6-jg-0sp11v6 rc-Branch Integration Build

## Status

Accepted and hardware-verified (2026-08-18). The
`7.2-rc6-jg-0sp11v6-qcom-x1e` kernel is installed on the X1E80100 OLED
device: the kernel boots, the in-tree phase55 touchscreen works, and Wi-Fi
reconnects to the saved network on the new base. The build uses the same
SP11 integration delta as
[ADR-0056](adr-0056-sp11-7-2-rc5-jg-0sp11v6-integration-build.md), carried
forward onto the jglathe `7.2-rc6` base.

## Context

[ADR-0056](adr-0056-sp11-7-2-rc5-jg-0sp11v6-integration-build.md) built the
v6 kernel from `sp11/integration-7.2-rc5` at `7ee4adb3cb57f` (merge of pull
request #8) with the wsa884x PA-recovery profile and the in-tree phase55
touchscreen. jglathe subsequently published the `7.2-rc6` line, and the SP11
integration branch was renamed to `sp11/integration-7.2-rc` (pull request
#10) after absorbing the rc6 sync (pull request #9, `11c2e9198d914`).

The integration CI validator regressed at the rename: the checkpatch gate
scoped the style check to the first-parent line only when HEAD was the
upstream-sync merge, so once the rc6 tree entered the first-parent line the
gate started flagging upstream style patterns (for example an AMD display
driver `CODE_INDENT` error in `dce_clock_source.c`). Commit `e4dd61d2cb5f`
(`ci: scope checkpatch gate to the SP11-authored delta`) scopes the gate to
files the SP11 integration actually authored or modified; upstream-only
findings are reported for review without failing the build.

## Decision

Build the Surface Pro 11 kernel from the `sp11/integration-7.2-rc` branch of
`ooaklee/linux_ms_dev_kit-sp11` at commit
`5506be83f8084731b2d6c29f51266cd9365c7aa3` (merge of pull request #10,
`sp11/ci-track-renamed-branch`), using Debian ABI `0sp11v6` and kernel
release `7.2-rc6-jg-0sp11v6-qcom-x1e`. Apply no local patches at build time;
the branch carries the full SP11 delta on the jglathe `7.2-rc6-jg-0` base.

## Decision details

The integration branch at the rc6 build head carries, on top of the jglathe
`7.2-rc6-jg-0` base:

- In-tree phase55 MSHW0485 touchscreen stack (`mshw0485_touch`,
  `spi-geni-qcom` QSPI, `gpi` QSPI)
- `ASoC: wsa884x: recover PA faults and apply SP11 2S 4-ohm profile`
  (`40932bba5`): 2S supply detection, latched PA-fault recovery, and the
  2S/4-ohm OCP/PBR profile
- SP11 v6 package naming (`604fad833`), checkpatch cleanup (`0b1fb2d48`),
  and the CI checkpatch scoping fix (`e4dd61d2cb5f`)
- DP link-rate workaround (PR #2) and DWC3 USB resume quirk (PR #3)
- PSCI cluster idle-state disable (PR #5), volume rocker (PR #6), and
  platform-profile/fan (PR #7)

Build: docker container `sp11-kernel-build-ci` on `ubuntu:26.04`, targets
`binary-indep binary-qcom-x1e`, jobs 8. The `ubuntu:26.04` image is the
required default for the rc line (the kernel `debian/rules.d` hardcodes
`gcc-15`); the build script now defaults to it for `sp11/*` and
`jg/ubuntu-qcom-x1e-*` git branches.

## Consequences

- Single-source build: no local patches and no out-of-tree module bundle.
- The wsa884x 2S/4-ohm profile and PA-recovery logic are carried unchanged
  from v6; the machine driver caps the PA Volume controls at raw 6 (0 dB)
  and the digital volumes at 81 (-3 dB).
- The CI validator gates only the SP11-authored delta; upstream style
  findings no longer fail the integration checks.
- The rc6 build initially omitted the arch-all package; a rebuild with
  targets `binary-indep binary-qcom-x1e` is required to produce
  `linux-qcom-x1e-headers-7.2-rc6-jg-0sp11v6` for the release.
- Release `sp11-qcom-x1e-7.2-rc6-jg-0sp11v6` is prepared with debs,
  `SHA256SUMS`, release manifest, and source tarball.
