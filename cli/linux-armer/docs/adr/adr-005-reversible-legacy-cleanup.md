---
id: adrs-adr005
title: "ADR005: Conservative and reversible legacy clean-up"
description: Architecture decision for removing and restoring obsolete Surface Pro 11 workarounds safely.
---

## Status

Accepted on 2026-08-30.

## Context

Kernel improvements can make older audio, touchscreen, or pen workarounds unnecessary or harmful. User systems may also contain locally modified files at the same paths. Blind deletion, broad directory matching, or running the entire CLI as root would risk removing unrelated configuration.

Clean-up decisions may need to be revisited after a kernel change, so an audit trail and recoverable originals are important.

## Decision

Clean-up will use a fixed, reviewed list of repository-owned legacy paths and explanatory rules. Scanning is read-only. Planning writes a strict JSON snapshot whose canonical target root, rule identifiers, original paths, object kinds, digests or symbolic-link text, and review details are revalidated before mutation. A later `apply` operation will ignore a newly appearing workaround until it is included in another reviewed plan.

A regular file will be recognised only when its required content markers match. A service-enablement symbolic link will be recognised only when it resolves to the exact retired unit compiled into its rule. Other file types, unexpected links, and marker mismatches will be reported for manual review and never removed automatically.

Applying clean-up will require the explicit `--yes` flag and a reviewed plan file. Before the first original path changes, the CLI will create and flush a prepared receipt below `/var/lib/linux-armer/backups`. Each entry will then be atomically renamed into a private directory on the original filesystem, verified against the plan, copied into its durable central backup, and removed from quarantine. This sequence ensures the entry removed from its original name is the entry preserved for recovery. Nested backup directories and receipt entries will be flushed before their corresponding destructive boundary.

A completed receipt will replace the prepared receipt only after every planned entry succeeds. An interrupted transaction will retain `receipt.pending.json`, any same-filesystem quarantine entry, and any completed backup paths. `clean restore` will accept either prepared or completed receipts, revalidate their compiled paths and recovery contents, and recreate missing entries without overwriting locally changed content. Recovery copies will remain after restoration.

Clean-up will remain a separate command group and never be an implicit part of image creation or userspace installation.

## Consequences

- Users can inspect and retain the exact plan before granting permission.
- Locally modified or unexpected content is preserved for manual handling.
- Recognised changes have crash-oriented quarantine, recoverable backups, and machine-readable prepared or completed receipts.
- A verified restore operation is available, but it deliberately refuses to overwrite changed paths.
- The maintained rule list covers only known historical workarounds; it is not a general system cleaner.
- Applying against a system root may require narrowly scoped elevated access.
