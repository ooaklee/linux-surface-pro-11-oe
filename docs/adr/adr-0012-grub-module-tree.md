---
id: adrs-adr012
title: "ADR012: GRUB Module Tree"
# prettier-ignore
description: Architecture Decision Record (ADR) for replacing the single standalone GRUB image with an on-ESP GRUB module tree after Surface Pro 11 keyboard input still failed at GRUB.
---

## Context

[ADR011](adr-0011-grub-efi-console-input.md) added explicit EFI console input
binding to the standalone GRUB image. Testing on the Surface Pro 11 still
reached GRUB and displayed all four menu entries, but the Surface Flex Keyboard
could not move through the menu.

The same target hardware can use the Flex Keyboard in the GRUB menu from the
Surface Pro 11 Arch image. That image is built with a more normal
`grub-install --target=arm64-efi --removable` flow and an on-disk GRUB module
tree, rather than a single `grub-mkstandalone` EFI binary carrying a small
hand-picked module set.

Running `grub-install` directly inside the Docker-based macOS builder is
awkward because GRUB tries to canonicalize container and mounted filesystem
paths. The project still needs a Docker-friendly build path.

## Decision

The USB builder will keep the raw-image workflow but change the ESP GRUB layout
to more closely match a normal removable GRUB install:

- generate `EFI/BOOT/BOOTAA64.EFI` with `grub-mkimage`,
- set the GRUB prefix to `/boot/grub`,
- embed a small early GRUB config that searches for the `SP11EFI` partition
  and loads `/boot/grub/grub.cfg`,
- copy `grub.cfg` to `/boot/grub/grub.cfg` on the ESP,
- copy the full `/usr/lib/grub/arm64-efi` module tree to
  `/boot/grub/arm64-efi` on the ESP.

The existing Surface Pro 11 GRUB menu, DTB injection, `casper` `iso-scan`
arguments, and USB-safe aDSP blacklist remain unchanged.

## Consequences

The ESP carries more files, and image validation must check the GRUB module
tree as well as the removable EFI binary's embedded bootstrap config.

The bootloader layout is closer to the known-working Surface Pro 11 Arch image
without requiring privileged loop mounts or `grub-install` in Docker Desktop.

If this still does not enable the Flex Keyboard at GRUB, the remaining likely
paths are an exact `grub-install`-produced layout from an ARM64 Linux system,
using the Arch GRUB package artifacts directly, or a Ventoy experiment that
preserves the Surface Pro 11 DTB and boot arguments.
