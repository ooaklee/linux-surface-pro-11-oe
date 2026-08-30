---
id: adrs-adr005
title: "ADR005: Conservative and reversible legacy cleanup"
description: Architecture decision for removing obsolete Surface Pro 11 workarounds safely.
---

## Status

Accepted on 2026-08-30.

## Context

Kernel improvements can make older audio, touchscreen, or pen workarounds unnecessary or harmful. User systems may also contain locally modified files at the same paths. Blind deletion, broad directory matching, or running the entire CLI as root would risk removing unrelated configuration.

Cleanup decisions may need to be revisited after a kernel change, so an audit trail and recoverable originals are important.

## Decision

Cleanup will use a fixed, reviewed list of repository-owned legacy paths and explanatory rules. Scanning and planning are read-only. A regular file is recognized only when its required content markers match; symlinks at specifically known paths can be recognized by path. Other file types and marker mismatches are reported for manual review and are never removed automatically.

Applying cleanup will require the explicit `--yes` flag. Before removal, each recognized entry will be copied into a timestamped backup below `/var/lib/linux-armer/backups`. A JSON receipt will record original paths, backup paths, rule identifiers, and available digests. Cleanup path resolution must remain within the selected root.

Cleanup remains a separate command group and is never an implicit part of image creation.

## Consequences

- Users can inspect exactly what would change before granting permission.
- Locally modified or unexpected content is preserved for manual handling.
- Recognized changes have recoverable backups and a machine-readable receipt.
- The maintained rule list covers only known historical workarounds; it is not a general system cleaner.
- Applying against a system root may require narrowly scoped elevated access.
