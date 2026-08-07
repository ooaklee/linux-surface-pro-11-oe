---
id: adr-0053-one-shot-experimental-kernel-boot
title: "ADR0053: One-Shot Experimental Kernel Boot"
# prettier-ignore
description: Architecture Decision Record (ADR) for queuing Surface Pro 11 experimental kernels through GRUB for one boot while retaining a boot-tested fallback and the persistent default.
---

# ADR0053: One-Shot Experimental Kernel Boot

## Status

Accepted (2026-08-07).

## Context

[ADR-0052](adr-0052-thin-sp11-kernel-integration-fork.md) introduces parallel
kernel feature branches for input, cameras, suspend, and platform support.
Those branches must be exercised on hardware without silently making an
unvalidated image the persistent boot default.

The installed Surface Pro 11 boot path uses GRUB's environment block for
`next_entry`. Generated Ubuntu GRUB configuration consumes that value, clears
and saves it before starting the selected entry, and marks the selection as a
one-shot boot. `grub-reboot` writes this field without changing the normal
configured default. The environment block also retains `saved_entry`, which
can disagree with both the running kernel and a title configured directly as
`GRUB_DEFAULT`. Preserving a stale saved entry would not preserve the declared
known-good fallback. A matching `saved_entry` is also ineffective when the
generated non-one-shot branch assigns a static default instead of consuming
`saved_entry`.

Storage such as LVM, MD RAID, or another arrangement where GRUB cannot save
its environment during boot can turn that nominal one-shot selection into a
repeated boot. GRUB also cannot safely update an environment block on every
filesystem; btrfs and ZFS are explicit exclusions. Environment identity,
filesystem support, and generated-config semantics are therefore all part of
the safety gate.

A loose DTB selected by GRUB is not authoritative on the tested hardware.
[ADR-0042](adr-0042-sp11-touchscreen-troubleshooting.md) established that the
kernel receives the DTB embedded in its Stubble-wrapped EFI image. A safe boot
selector cannot compensate for an incorrectly packaged device tree.

## Decision

Add `scripts/boot-sp11-kernel-once.sh` as the only automated path for selecting
an experimental feature-parity kernel during initial hardware validation. It
is read-only by default and changes GRUB state only when the operator passes
`--apply` explicitly.

The helper requires two exact, distinct `-qcom-x1e` ABIs:

- the experimental ABI to queue; and
- a fallback ABI that must be the kernel running the current session.

Requiring the fallback to be running proves that its image, initramfs, storage,
and basic boot path work on the target. The operator must additionally confirm
that the fallback passed the hardware checks required for the experiment.
Both ABIs must have non-empty kernel and initramfs files and one unambiguous,
non-recovery GRUB menu entry. The existing `saved_entry` must resolve exactly
to the fallback's composite GRUB ID or its exact composite title. The helper
reports a mismatch but never changes `saved_entry` itself.

The generated outer `next_entry` branch must assign `saved_entry` as its
non-one-shot default. A static `GRUB_DEFAULT` is rejected even when it already
names the declared fallback because it does not prove that the inspected
environment entry controls subsequent boots. The operator must set
`GRUB_DEFAULT=saved` in the effective GRUB defaults and run `update-grub`
before `grub-set-default` can establish the verified fallback.

The helper also asks `grub-probe` for the filesystem containing `grubenv`.
Only GRUB's ext-family filesystem identifiers (`ext2`, `ext3`, and `ext4`) are
accepted for this SP11 workflow. btrfs, ZFS, an empty probe result, and every
unrecognized filesystem fail closed. This narrow allowlist can be expanded
only after one-shot environment clearing is validated on the candidate
filesystem.

Before applying a selection, the helper verifies that:

- the generated GRUB configuration reads `next_entry`, clears and saves it,
  and marks the boot as one-shot;
- the generated non-one-shot branch consumes `saved_entry` rather than a
  static default;
- the environment block is readable and `findmnt` positively identifies its
  containing filesystem as writable;
- `grub-probe` identifies its filesystem as a verified ext-family format;
- no existing `next_entry` or stale `prev_saved_entry` would be overwritten;
- `saved_entry` resolves exactly to the declared fallback ABI;
- no GRUB storage abstraction known to prevent reliable environment writes is
  detected;
- both exact menu entries resolve to one composite submenu/entry selector; and
- the operator confirms that the experimental Stubble image already embeds
  the intended DTB.

When the generated configuration uses a static default, dry-run output is
marked blocked and explains that `GRUB_DEFAULT=saved` plus `update-grub` must
come before `grub-set-default`. When `saved_entry` does not identify the
fallback, it prints the exact `grub-set-default` command the operator may run
after independently validating that fallback. The helper runs none of these
commands. This makes changing the persistent recovery choice a separate,
reviewable action.

With `--apply`, the script must run as root, invoke `grub-reboot` once, read
the environment block again, and confirm that only the intended `next_entry`
was queued. It records the previous `saved_entry` value and refuses success if
that value changes. The helper never calls `reboot`, never edits `grub.cfg`,
and never changes the persistent default.

A typical dry run is:

```bash
sudo ./scripts/boot-sp11-kernel-once.sh \
  --experimental-abi 7.2-rc5-jg-0sp11exp1-qcom-x1e \
  --fallback-abi 7.2-rc5-jg-0sp11v3-qcom-x1e
```

After reviewing the resolved entries and independently validating the embedded
DTB, repeat the command with:

```text
--confirm-fallback-known-good --confirm-stubble-dtb --apply
```

The queued selection can be cancelled before reboot with:

```bash
sudo grub-editenv /boot/grub/grubenv unset next_entry
```

## Consequences

An experimental kernel can be selected without replacing the normal default,
and a successful preflight provides an exact record of the ABI and GRUB entry
that will be used. A running known-good kernel is not sufficient by itself:
the saved recovery entry must name the same ABI and the generated persistent
path must consume that entry before an experiment can be queued.

Installations whose GRUB environment is on btrfs, ZFS, an unrecognized
filesystem, or a storage abstraction with unreliable environment writes
cannot use this helper. They need a separately designed and validated recovery
mechanism rather than an override flag.

The mechanism reduces risk but cannot guarantee automatic recovery from every
failure. Firmware lockup, storage failure, a GRUB environment that becomes
unwritable, or an invalid Stubble-wrapped image may still require the GRUB menu
or recovery media. The known-good kernel must remain installed and recovery
media must remain available.

The fallback check intentionally prevents queuing an experiment while already
running a different kernel. Operators must first boot the known-good ABI, which
makes the safety state explicit instead of relying on package presence alone.

Initial hardware work now has a repeatable sequence: boot the known-good ABI,
run the helper in dry-run mode, queue one experimental boot, reboot separately,
collect the bounded validation evidence, and return to the fallback before the
next kernel change.

## Related

- [ADR-0042: Touchscreen Kernel Integration Troubleshooting](adr-0042-sp11-touchscreen-troubleshooting.md)
- [ADR-0049: JG 7.2-rc5-jg-0sp11v3 Touchscreen Kernel Build](adr-0049-sp11-7-2-rc5-jg-0sp11v3-touchscreen-build.md)
- [ADR-0051: Release and Tag Cleanup](adr-0051-release-and-tag-cleanup.md)
- [ADR-0052: Thin Surface Pro 11 Kernel Integration Fork](adr-0052-thin-sp11-kernel-integration-fork.md)
