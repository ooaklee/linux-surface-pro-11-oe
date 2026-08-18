---
id: adr-0058-sp11-7-2-0-jg-0sp11v7-non-rc-integration-line
title: "ADR0058: SP11 7.2.0-jg-0sp11v7 Non-rc Integration Line"
# prettier-ignore
description: Architecture Decision Record (ADR) for the Surface Pro 11 non-rc integration line, built from the sp11/integration-7.2.x branch of the ooaklee/linux_ms_dev_kit-sp11 fork on the jglathe 7.2.0-jg-0 base.
---

# ADR0058: SP11 7.2.0-jg-0sp11v7 Non-rc Integration Line

## Status

Accepted (2026-08-18). The `sp11/integration-7.2.x` branch is the new
default integration line for non-rc Surface Pro 11 kernels, named
`7.2.0-jg-0sp11v7`. The `sp11/integration-7.2-rc` branch continues to
carry rc releases.

## Context

[ADR-0057](adr-0057-sp11-7-2-rc6-jg-0sp11v6-rc-branch-build.md) built the
v6 rc6 kernel from `sp11/integration-7.2-rc` on the jglathe `7.2-rc6`
base. jglathe subsequently published the stable
`jg/ubuntu-qcom-x1e-7.2.y` line (`7.2.0-jg-0`, commit `746b3477`), and the
SP11 integration needed a non-rc line to track it.

## Decision

- Create the `sp11/integration-7.2.x` branch from the rc head
  (`c014aab2a7`) as the new default integration branch.
- Sync the upstream `jg/ubuntu-qcom-x1e-7.2.y` line through an
  intermediary branch (`sp11/merge-upstream-7.2.y-into-integration`):
  merge `746b3477` into the rc line (pull request #12, merge commit
  `cb825d66`), then carry the synced state into `sp11/integration-7.2.x`
  (pull request #13).
- Name the non-rc build `7.2.0-jg-0sp11v7` (debian.qcom-x1e changelog
  entry and `CONFIG_VERSION_SIGNATURE`), keeping the v6 packages
  installable for rollback.
- Track both `sp11/integration-7.2-rc` and `sp11/integration-7.2.x` in
  the integration CI workflow.

## Consequences

- The kernel build workflow defaults to `sp11/integration-7.2.x` for new
  non-rc builds.
- The rc line remains for rc kernels; upstream syncs flow rc-first, then
  into the 7.2.x line.
- The v7 kernel package version is `7.2.0-jg-0sp11v7-qcom-x1e`.
