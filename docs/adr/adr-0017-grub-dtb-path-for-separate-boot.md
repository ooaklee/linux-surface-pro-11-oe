---
id: adrs-adr017
title: "ADR017: GRUB DTB Path for Separate Boot"
# prettier-ignore
description: Architecture Decision Record (ADR) for deriving the installed-system GRUB devicetree path from the generated kernel path so separate /boot layouts work.
---

## Status

Superseded for current installed Stubble-packaged kernels (2026-07-18).

The path correction remains useful historical context and may still apply to
boot chains that honor GRUB's `devicetree` command. On the tested installed
Surface Pro 11 system, [ADR-0042](adr-0042-sp11-touchscreen-troubleshooting.md)
shows that Stubble's embedded EFI Configuration Table FDT remains active
regardless of whether GRUB resolves the loose DTB path correctly.

## Context

[ADR003](adr-0003-denali-dtb-and-grub-injection.md) requires installed Ubuntu
systems to inject a Surface Pro 11 Denali DTB into generated GRUB menu entries.
[ADR015](adr-0015-direct-live-desktop-and-install-gate.md) and
[ADR016](adr-0016-usb-data-mount-and-installed-system-helpers.md) then use that
injection during the installed-system bring-up path.

The first verified installed NVMe boot used a separate `/boot` partition. Linux
mounted that partition at `/boot`, so the DTB existed at
`/boot/sp11-denali.dtb` from Linux's point of view. GRUB, however, generated
kernel entries against the boot partition itself. In that layout, GRUB sees the
same file as `/sp11-denali.dtb`, not `/boot/sp11-denali.dtb`.

The earlier injector always emitted `devicetree /boot/sp11-denali.dtb`. On the
separate `/boot` install this produced a GRUB warning:
`file '/boot/sp11-denali.dtb' not found`.

## Decision

The installed-system DTB injector will derive the GRUB `devicetree` path from
each generated `linux` line:

- if the kernel path starts with `/boot/`, inject `devicetree /boot/sp11-denali.dtb`;
- otherwise, inject `devicetree /sp11-denali.dtb`.

The injector will also remove old Surface Pro 11 `devicetree` lines that use
either `/boot/...` or `/...` before adding the current line, so rerunning the
helper remains idempotent.

The DTB file will continue to be installed at `/boot/sp11-denali.dtb` from the
running Linux system's perspective. That path is correct regardless of whether
`/boot` is a directory on the root filesystem or a separate mounted filesystem.

## Consequences

Installed systems with a separate `/boot` partition should no longer show the
GRUB `file '/boot/sp11-denali.dtb' not found` warning.

Installed systems without a separate `/boot` partition continue to use the
existing `/boot/sp11-denali.dtb` GRUB path.

Wi-Fi, Bluetooth, touchscreen, audio, and other hardware bring-up should not be
evaluated until the boot path no longer reports a missing DTB, because a
missing DTB can leave the kernel with an incomplete hardware description.
