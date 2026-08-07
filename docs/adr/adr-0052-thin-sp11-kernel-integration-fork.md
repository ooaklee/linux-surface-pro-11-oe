---
id: adr-0052-thin-sp11-kernel-integration-fork
title: "ADR0052: Thin Surface Pro 11 Kernel Integration Fork"
# prettier-ignore
description: Architecture Decision Record (ADR) for using a thin Johan G. kernel fork while retaining packaging, validation, evidence, and releases in the Surface Pro 11 support repository.
---

# ADR0052: Thin Surface Pro 11 Kernel Integration Fork

## Status

Accepted (2026-08-07).

## Context

The current Surface Pro 11 OLED kernel starts from Johan G.'s
`jg/ubuntu-qcom-x1e-7.2-rc5-jg-0` tag and applies project patch directories at
build time. That workflow is suitable for bounded DMIC and touchscreen
changes. Full feature parity introduces longer-lived, interacting kernel work
for camera sensors and CAMSS graphs, G6 HID reports, pen, cpuidle, platform
profile, and volume keys.

Developing all of those changes only as numbered release patches would make
cross-subsystem review and upstream submission difficult. Treating a permanent
kernel fork as the product would create the opposite problem: packaging,
hardware evidence, installers, and public releases would become coupled to a
large moving kernel repository.

The public feature demonstration establishes feasibility but its implementation
is unavailable. The public ACPI tables establish names and resources but do not
provide complete Linux implementations. The project therefore needs a clean,
reviewable integration area with explicit source boundaries.

ADR001 chose a dedicated Ubuntu support repository and anticipated that it
could evolve without forking reference projects. That remains the right scope
for packaging and releases, but it is too restrictive for a multi-subsystem
kernel integration programme.

## Decision

The project will use
[`ooaklee/linux_ms_dev_kit-sp11`](https://github.com/ooaklee/linux_ms_dev_kit-sp11)
as a thin kernel integration fork.

This decision partially supersedes ADR001 only where ADR001 treats avoiding a
fork as a consequence of the dedicated-repository boundary. ADR001's target
device, Ubuntu focus, and ownership of packaging, documentation, and release
workflows remain in force.

The fork began with two branches at Johan G.'s immutable commit
`8f953dd060bc6e8fb86ca2ea8a92f258141c0169`:

- `sp11/base-jg-7.2-rc5-jg-0` is the protected, immutable baseline; and
- `sp11/integration-7.2-rc5` is the advancing combined development branch.

Repository ruleset `20540758` protects branches matching
`refs/heads/sp11/base-*` from deletion and non-fast-forward updates. CI checks
the public branch identities without requesting repository-administration
access. The ruleset itself remains an external repository-setting control and
is reviewed in GitHub when the baseline changes.

The CI foundation was reviewed in thin-fork pull request 1 and squash-merged
as `971b5af85ed0c7283ffb33430badeac9b5575057`. Repository ruleset `20545185`
protects `refs/heads/sp11/integration-7.2-rc5` from deletion and
non-fast-forward updates and requires the strict `Validate integration delta`
check. That check verifies ancestry from the immutable base, rejects private or
generated artifacts, runs `git diff --check`, and applies strict kernel
`checkpatch.pl` review to the integration delta.

The baseline configuration records separate expected commits for the protected
base and the advancing integration branch. The base identity never changes.
Each accepted integration update changes its expected commit and source-ledger
row in the corresponding support-repository change, so CI verifies both refs
without incorrectly requiring them to remain equal forever.

Feature work follows the project branch convention with bounded names such as
`lsp11-x-volume-keys-7.2-rc5`, `lsp11-x-g6-hid-raw-7.2-rc5`,
`lsp11-x-camera-ov13858-7.2-rc5`, and
`lsp11-x-suspend-cpuidle-7.2-rc5`. Every feature branch records its baseline
and intended upstream destination. Generic driver and binding changes are
prepared for their subsystem upstream rather than accumulating indefinitely
in the fork.

This `linux-surface-pro-11-oe` repository remains responsible for:

- build recipes and exported patch series;
- co-installable Debian package ABIs;
- UCM, PipeWire, IPTSD, and desktop integration;
- live images and guarded installation;
- sanitized hardware evidence and validation matrices;
- release manifests, source assets, checksums, and rollback instructions; and
- public ADRs and how-to documentation.

The fork will not contain private lab endpoints, credentials, Windows binaries,
firmware, private traces, or unredistributable research inputs. A successful
feature is exported back into this repository only after its source commit,
patch ancestry, exact ABI, and hardware result are recorded.

The current v3 kernel remains the known-good fallback. Experimental kernel
branches are tested through one-shot boot selection before they are allowed to
become a normal default. Rebase work and feature diagnosis are not combined in
the same hardware experiment.

## Consequences

Kernel changes can be reviewed and tested as ordinary commits without making a
large kernel fork the release product.

The project must keep three identities aligned for every build: Johan G. or
upstream baseline, thin-fork source commit, and support-repository commit. This
adds manifest work but prevents a binary from being attributed to the wrong
source.

Some changes may remain temporarily in the integration fork while upstream
interfaces settle. Each such change needs an owner, an upstream destination,
and an explicit removal or rebase gate.

Camera work can proceed in parallel with audio and input work, but sensor
branches merge one at a time after raw-frame validation. Pen work remains
dependent on a stable G6 raw-report interface. IR illumination remains disabled
until the IR sensor and a fail-safe control path have been validated.

The fork can be discarded or recreated from a newer immutable Johan G. or
upstream baseline once its remaining delta is exported, which limits long-term
maintenance cost.

## Related

- [Feature-Parity Source Ledger](../sp11-feature-parity-source-ledger.md)
- [ADR001: Target Repo and Scope](adr-0001-target-repo-and-scope.md)
- [ADR047: JG 7.2-rc5-jg-0 Kernel Build](adr-0047-jglathe-qcom-7-2-rc5-jg-0-build.md)
- [ADR049: JG 7.2-rc5-jg-0sp11v3 Touchscreen Build](adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md)
- [ADR050: Touchscreen Clean-Install and Release Flow](adr-0050-sp11-touchscreen-clean-install-release-flow.md)
- [ADR051: Release and Tag Cleanup](adr-0051-release-and-tag-cleanup.md)
