---
id: adr-0055-retire-installed-loose-dtb-injection
title: "ADR0055: Retire Installed Loose-DTB Injection on the Tested Stubble Path"
# prettier-ignore
description: Architecture Decision Record (ADR) for retiring shared loose-DTB injection from the tested installed qcom-x1e Stubble boot path.
---

# ADR0055: Retire Installed Loose-DTB Injection on the Tested Stubble Path

## Status

Accepted (2026-08-07).

Repository implementation is complete. Migration of an existing target and
privileged verification of the generated GRUB configuration, embedded DTB,
and active FDT remain pending under P0.7 of the
[full-feature-parity execution plan](../sp11-full-feature-parity-execution-plan.md).

## Context

Device-side evidence in ADR-0042 established that the tested installed
qcom-x1e Stubble image registers its per-kernel embedded DTB in the EFI
Configuration Table and that GRUB's loose `devicetree` command does not
determine the live FDT. A shared `/boot/sp11-denali.dtb` cannot preserve exact
kernel/DTB pairing across co-installed ABIs. Directly rewriting generated
`grub.cfg` therefore adds mutable boot state without providing a valid
per-kernel fallback.

## Decision

For the tested installed Stubble path, stop installing or invoking
`sp11-grub-inject-dtb`. Remove only the project-managed helper and its
`zzzz-surface-pro-11-dtb` post-install and post-removal hooks.

If `/boot/sp11-denali.dtb` exists from an earlier release, leave it
byte-for-byte untouched as inert recovery evidence. Do not select, replace,
rename, chmod, delete, or use it as evidence of the live FDT.

The retire-only operation is a transaction. Before moving any managed leaf, it
records the three exact leaves and the historical loose-DTB identity. On the
live root it also snapshots the prior `grub.cfg` and `grubenv` in private
same-filesystem backup directories. It commits only after `update-grub`
succeeds, all three leaves remain absent, generated `grub.cfg` has no
project-managed loose-DTB line, and both the historical loose DTB and `grubenv`
remain unchanged.

Any failure restores the exact managed leaves and prior `grub.cfg`. If a path
acquires a different occupant during the transaction, rollback does not delete
it; the original remains in a reported mode-0700 recovery backup and the
operator must not reboot or run `apt` or `dpkg` until the conflict is reviewed.
An offline `--root` retirement uses the same bounded leaf transaction but does
not execute target binaries or modify target GRUB state. The installed-system
preparation helper may regenerate GRUB after entering the target chroot, where
that target is `/`.

A guarded kernel-package transaction runs
`install-sp11-support.sh --retire-loose-dtb-only` before invoking `apt` or
`dpkg`, so a legacy kernel hook cannot run during package setup. Retirement or
live-root GRUB-regeneration failure aborts the transaction. Only then may the
packages and the full installed-system support flow be applied.

Kernel DTB provenance and feature validation use the DTB embedded in the exact
Stubble EFI image and the active FDT after boot.

This decision does not change live-USB `/dtb/sp11-denali.dtb` handling, which
belongs to a different boot path.

## Consequences

Kernel package hooks no longer patch generated `grub.cfg`. Existing loose-DTB
bytes remain available for historical comparison or manual recovery analysis,
but no supported installed Stubble path consumes or maintains that file.

Legacy non-Stubble boot chains are no longer claimed as supported by the
installed-system helper. Supporting one would require a separate per-ABI
design, test matrix, and ADR.
