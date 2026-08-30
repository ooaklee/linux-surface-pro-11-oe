---
id: adrs-adr014
title: "ADR014: Native IPTSD release transactions"
description: Architecture decision for compiled IPTSD builds, closed release validation, recoverable installation, and explicit live activation state.
---

## Status

Accepted on 2026-08-30.

## Context

The supported Surface Pro 11 pen integration combines two ARM64 executables, device configurations, systemd and udev integration, redistributed licences, corresponding source, and build provenance. Earlier command paths delegated validation, template rendering, and installation to repository or release-bundled shell scripts. That made the effective trust boundary larger than the CLI executable, allowed a release to carry code that would later run with elevated privilege, and made a dry run less complete than a real installation.

Building IPTSD still needs an ARM64 Linux toolchain and several upstream fallback dependencies. A container is an appropriate isolation boundary, but the host workflow must own the source identity, Docker arguments, recipe, image provenance, output limits, and final validation. Merely observing a successful container exit does not establish that the result is the reviewed release.

Installing several files and one deliberate service mask cannot be made filesystem-wide atomic. It therefore needs a recoverable transaction, mutation detection, and an honest distinction between durable installed files and later service activation.

## Decision

The userspace IPTSD domain will own one compiled release contract. It pins the upstream version, repository, commit and tree; the complete payload checksum manifest; the exact payload, configuration, template, documentation, licence and corresponding-source file sets; the two executable identities; and the three rendered integration outputs. Validation rejects links, special files, missing or additional members, malformed checksum paths, wrong executable modes, non-AArch64 ELF files, altered provenance, and any digest or size disagreement.

The native build workflow will validate the repository integration before starting Docker. It will use only bounded, argument-separated Docker operations on the host. The reviewed container recipe remains fixed in Go and runs inside the ARM64 container; the host does not invoke a repository build script. The workflow records the exact image ID and repository digest in build provenance, uses the compiled upstream source pins and forced access checks, and validates the resulting closed payload through the same native contract before reporting success. Build output must use a dedicated directory outside release payload data.

The installer will first verify every outer release artefact, copy the archive into a private staging directory, and securely stream XZ and TAR data through a bounded extractor that accepts only canonical directories and regular files beneath the fixed archive root. A dry run performs this complete extraction and release validation without checking privilege or changing the target. It returns every fixed target, the generic service mask, the private backup and receipt locations, and the exact live-root command plan.

Template rendering will replace only the four compiled executable paths in the three pinned templates. Each result must match its compiled size and SHA-256 before publication. No script, template expression, environment file, or release-provided path is executed or interpreted as installation policy.

Real installation requires elevated privilege. Every regular target is resolved beneath the selected root without following a final symbolic link. Existing regular files are hashed and copied into one mode-`0700` private transaction directory before publication. Each source is reopened and revalidated, written through a same-directory temporary file, flushed, renamed, and followed by directory synchronisation. Targets are re-observed immediately before replacement; a new link, special file, content change, mode change, or unexpected new file aborts the transaction. Failure before completion triggers reverse-order rollback, restoring verified backups and removing only unchanged files created by the transaction.

The generic `iptsd@.service` unit is the sole intentional installed link. An absent target becomes an exact `/dev/null` mask; an existing identical mask is retained; every other object or link target is rejected. The transaction writes a mode-`0600` receipt after all installed files and the mask are durable.

For the live root only, the installer then runs the fixed `systemctl` and `udevadm` sequence as separate arguments with per-command timeouts and bounded captured output. These operations disable the conflicting diagnostic daemon, stop generic IPTSD instances, reload systemd and udev state, retrigger hidraw devices, and wait for udev settlement. Alternate roots run no host service command. A command failure does not roll back already durable files: the result and receipt state that file installation succeeded while activation remains incomplete, and the CLI returns a non-zero error without discarding that state.

The compiled contract remains byte-compatible with the published `sp11-iptsd-v1` archive. Bundled installer and validator scripts may remain present for historical release compatibility, but the CLI neither requires nor executes them.

## Consequences

- IPTSD build and installation policy is reviewable and testable as Go code rather than transitively trusted release code.
- A dry run validates the same immutable release bytes and produces the same filesystem and command plan as a real installation.
- The published v1 release remains usable without regeneration.
- Build success now means the output matches the published closed payload, so a mutable or different builder image may complete compilation but fail final validation.
- Multi-file installation is recoverable but not globally atomic; another privileged process must not modify the fixed targets concurrently.
- Live activation failure is an explicit recoverable state, not evidence that durable files disappeared or that installation never began.
