---
id: adrs-adr016
title: "ADR016: USB Data Mount and Installed-System Helpers"
# prettier-ignore
description: Architecture Decision Record (ADR) for explicitly mounting the SP11DATA USB partition and replacing fragile installed-system copy-paste commands with support helpers.
---

## Context

[ADR015](adr-0015-direct-live-desktop-and-install-gate.md) allows cautious
installation testing after the direct live USB successfully reached the Ubuntu
desktop. That decision requires users to configure the installed Ubuntu target
before the first USB-free reboot, because the installed system needs the same
Surface Pro 11 DTB and boot arguments that make the live USB viable.

The first README instructions used `findmnt -S LABEL=SP11DATA` to locate the
USB data partition. Testing showed this is not enough. During a live USB boot,
Ubuntu mounts the looped ISO as `/cdrom`, while the underlying ext4 data
partition labeled `SP11DATA` may remain unmounted. `findmnt` only reports
mounted filesystems, so it can return nothing even though the USB partition is
present and discoverable through `blkid -L SP11DATA`.

The original install guidance also required users to type long sequences of
privileged commands at the most error-prone point of the process: after the
installer completes, while `/target` and multiple bind mounts must be handled
correctly.

[ADR003](adr-0003-denali-dtb-and-grub-injection.md) requires Denali DTB
injection for installed systems. [ADR004](adr-0004-firmware-extraction-policy.md)
and [ADR005](adr-0005-wifi-board-fixup.md) define post-install firmware and
Wi-Fi fixup work that should also be easy to rerun from the USB support
payload.

## Decision

The README will explicitly mount the USB data partition before using support
files:

- find the device with `blkid -L SP11DATA`,
- reuse an existing mount if the device is already mounted,
- otherwise mount it at `/mnt/sp11data`,
- run helper scripts from `$SP11DATA/support`.

The project will ship installed-system helper scripts in the USB support
payload:

- `scripts/prepare-sp11-installed-system.sh` prepares `/target` before the
  first USB-free boot. It installs support helpers into the target root, copies
  the known USB Denali DTB into the target `/boot`, bind-mounts the required
  pseudo-filesystems, regenerates GRUB, injects the DTB, refreshes initramfs,
  and cleans up bind mounts on exit.
- `scripts/finish-sp11-installed-system.sh` runs after the first successful
  installed-system boot. It reinstalls support helpers, installs firmware from
  either public CAB downloads or a mounted Windows root, applies the temporary
  Wi-Fi board-file fixup, refreshes initramfs after a successful Wi-Fi fixup,
  and optionally reboots.

Firmware and Wi-Fi helper scripts will print explicit package-install guidance
when required tools are missing, so users can recover without guessing package
names.

## Consequences

The live installer flow no longer depends on the USB data partition being
auto-mounted by the desktop session. This matches the observed live
environment, where `df -h` can show `/cdrom` backed by `/dev/loop0` while no
`SP11DATA` mount is present.

The most dangerous install-time commands now live in reviewed scripts instead
of README copy-paste blocks. Users still need to run privileged setup, but the
commands are shorter and the scripts can perform checks, cleanup, and consistent
error reporting.

The support helper scripts remain unavailable until `SP11DATA` is mounted. The
README therefore keeps the mount commands inline rather than relying on a mount
helper stored on the partition it would need to mount.

The prepare helper copies the USB DTB into the installed `/boot` before GRUB
injection. This reduces dependence on the installed kernel package already
carrying the exact Denali DTB variant.

The finish helper may run `update-initramfs` more than once during a complete
firmware and Wi-Fi setup. This costs time, but it keeps the final initramfs in
sync with the files installed by the firmware and Wi-Fi fixup helpers.
