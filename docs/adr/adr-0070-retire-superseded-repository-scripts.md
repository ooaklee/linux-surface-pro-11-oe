---
id: adr-0070-retire-superseded-repository-scripts
title: "ADR0070: Retire Superseded Repository Scripts"
# prettier-ignore
description: Architecture Decision Record (ADR) for removing the legacy OE script, shell-test and helper-tool execution surface after its maintained outcomes moved to Lexr.
---

# ADR0070: Retire Superseded Repository Scripts

## Status

Accepted on 2026-08-31.

## Context

The OE repository accumulated shell, Python, PowerShell and C helpers while
Surface Pro 11 support was being discovered. Some became maintained image,
kernel, userspace, firmware, Bluetooth, camera, diagnostic and media-writing
workflows. Others installed temporary workarounds which the current kernel,
FullIO userspace or direct hybrid-ISO design superseded.

Leaving those files beside Lexr would expose two operator APIs. A thin Go
wrapper around a repository helper would still leave policy in an untyped
subprocess and would prevent the released binary from operating independently.
Deleting them without an outcome register, however, could hide a recovery or
specialist workflow which had not been replaced.

The pinned Lexr revision resolves that boundary in its
[native-workflow migration decision](https://github.com/ooaklee/lexr.sh/blob/main/docs/adr/adr-010-native-cli-workflow-migration.md).
It records a typed native owner, explicit retirement or specialist rehoming for
the complete historical inventory and for the six associated root-level tests
and tools. Completion of that software migration does not claim that every
physical hardware gate has passed.

## Decision

- Remove all 39 files tracked beneath OE's former `scripts/` tree.
- Remove the three shell integration tests and three root helper tools which
  existed only to validate or support that script surface.
- Remove the final kernel-script test workflow together with the already
  superseded OE kernel-build and IPTSD-integration workflows. Lexr owns the
  maintained native tests and automation.
- Retain the actual patch files, userspace sources and fixtures, OpenEmbedded
  recipes, device evidence and visual assets. They remain OE inputs or audit
  records rather than orchestration helpers.
- Mark the eight patch-set README files as archived compatibility evidence.
  Current kernel builds use one reviewed source ref and do not silently inject
  those directories.
- Make current how-to guides use Lexr commands. Dated reports and historical
  ADR bodies may retain the commands that produced their evidence, but an
  explicit notice must prevent readers from treating them as current setup or
  remediation instructions.
- Keep the root `build/` ignore boundary anchored, retain every payload,
  firmware and package ignore rule, remove obsolete script/binary exceptions,
  and ignore generated diagnostic archives.

No generic script runner or compatibility command is introduced. If a future
workflow is missing, it must receive an explicit owner and safety contract
rather than reviving the retired execution surface implicitly.

## Consequences

- A released Lexr binary owns every maintained operator workflow without
  requiring the OE checkout's former helper directory.
- Current documentation and automation cannot accidentally make a retired
  workaround supported again merely because its executable file remains.
- Historical reasoning stays reviewable in Git, dated evidence and ADRs.
- Patch bytes and userspace integration inputs remain available for provenance
  and OpenEmbedded builds even though their earlier orchestration is retired.
- Validation moves to Lexr's Go tests, Windows contract tests, native IPTSD
  integration workflow and guarded release workflows. Hardware acceptance
  remains a separate, explicit device gate.

## Alternatives Considered

**Keep the scripts as undocumented fallbacks (rejected).** Their presence would
still create a second, drifting API and invite use of obsolete workarounds.

**Delete the patch, userspace and evidence trees as well (rejected).** Those
trees contain source inputs and provenance which remain independently useful;
they are not interchangeable with the retired orchestration layer.

**Move every historical helper into Lexr (rejected).** Retired workarounds and
specialist source-maintainer tasks should not become permanent public CLI
features.
