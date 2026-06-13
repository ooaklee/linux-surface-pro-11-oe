---
id: adrs-adr011
title: "ADR011: GRUB EFI Console Input"
# prettier-ignore
description: Architecture Decision Record (ADR) for explicitly binding GRUB to EFI console input before trying Ventoy for Surface Pro 11 keyboard support.
---

## Context

[ADR002](adr-0002-boot-shim-image-strategy.md) chose a standalone ARM64 GRUB
boot shim. [ADR009](adr-0009-default-casper-iso-scan-boot.md) made the
`casper` `iso-scan` entry the default and embedded FDT support explicitly.

The first Surface Pro 11 boot test reached the custom GRUB menu, but the
attached Surface Flex Keyboard could not select a menu entry. The Surface
Laptop 7 Ubuntu notes recommend Ventoy because it enables keyboard support in
GRUB on that device class.

However, the Surface Pro 11 Arch image from `dwhinham/linux-surface-pro-11`
accepts the Flex Keyboard at GRUB on the target hardware. That image uses a
normal ARM64 `grub-install --removable` path, while this repository uses a
small `grub-mkstandalone` image with a hand-picked module list and no explicit
terminal input/output commands.

## Decision

Before switching to Ventoy, the standalone GRUB image will explicitly include
and initialize GRUB terminal input support:

- embed `terminal`, `keystatus`, and `read` alongside the existing boot
  modules,
- call `terminal_input console`.

This keeps the existing Surface Pro 11 DTB injection, `casper` `iso-scan`
kernel arguments, USB-safe aDSP blacklist, and validation workflow intact while
testing the smallest plausible input-path difference from the working Arch GRUB
path.

## Consequences

The next image tests whether the firmware-exposed EFI console input path is
available to our standalone GRUB image. If it works, the project keeps the
current raw-image workflow and avoids a Ventoy dependency.

The GRUB menu output path is intentionally left unchanged because the current
image already displays the menu. This test isolates input handling rather than
changing both input and output behavior at once.

If the Flex Keyboard still cannot control GRUB, a future ADR should evaluate a
larger bootloader change: either a `grub-install`-style on-disk GRUB module
tree that more closely matches the working Arch image, or a Ventoy-based
fallback that preserves the Surface Pro 11 DTB and boot arguments.
