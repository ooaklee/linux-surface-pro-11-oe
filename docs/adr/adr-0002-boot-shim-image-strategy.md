---
id: adrs-adr002
title: "ADR002: Boot Shim Image Strategy"
# prettier-ignore
description: Architecture Decision Record (ADR) for using an ARM64 GRUB boot shim with the Ubuntu Snapdragon X concept ISO instead of remastering a full ISO first.
---

## Context

[ADR001](adr-0001-target-repo-and-scope.md) scopes this repository to an
Ubuntu bring-up kit for Surface Pro 11. A standard ARM64 Ubuntu ISO does not
carry the Surface Pro 11 Denali device tree or the exact boot arguments needed
for first boot. The Surface Laptop 7 Ubuntu notes use Canonical's Snapdragon X
concept images, while the Surface Pro 11 Arch work controls GRUB and device
tree injection in a custom image.

There are several possible image strategies:

- fully remaster a Ubuntu ISO,
- build a complete Ubuntu root filesystem image,
- write manual post-ISO instructions,
- build a small bootable shim that chain-loads the Ubuntu concept ISO with
  Surface Pro 11-specific boot data.

The first two options are heavier and slower to iterate. Manual post-ISO steps
do not solve the first-boot device-tree requirement.

## Decision

We will build a raw USB disk image containing:

- an ARM64 removable-media EFI System Partition with standalone GRUB,
- a Linux data partition labeled `SP11DATA`,
- the Ubuntu Snapdragon X concept ISO,
- the compiled Surface Pro 11 Denali DTB,
- optional local payload files for offline testing.

GRUB will loop-mount the Ubuntu ISO and boot its `casper` kernel/initrd while
injecting the Surface Pro 11 device tree and first-boot kernel arguments.

## Consequences

The first test image can be built without unpacking or repacking the Ubuntu ISO.

The image remains tied to the Ubuntu concept ISO layout. If Canonical changes
the ISO paths for `casper/vmlinuz` or `casper/initrd`, the builder must be
updated.

This approach does not by itself install all post-install support into the
target Ubuntu system. Installed-system support remains a separate script and
future packaging concern.
