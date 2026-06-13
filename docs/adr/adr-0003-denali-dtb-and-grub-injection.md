---
id: adrs-adr003
title: "ADR003: Denali DTB and GRUB Injection"
# prettier-ignore
description: Architecture Decision Record (ADR) for requiring the Surface Pro 11 Denali device tree and injecting it through GRUB.
---

## Context

[ADR002](adr-0002-boot-shim-image-strategy.md) chooses a GRUB boot shim for
first boot. The Surface Pro 11 is identified in the upstream bring-up work by
the Denali device tree, `x1e80100-microsoft-denali.dtb`.

The Surface Laptop 7/Romulus device tree is not a safe substitute. The Surface
Pro 11 has different board wiring, Surface HID devices, firmware paths, and
known display/audio bring-up concerns.

The Surface Pro 11 Arch work injects the device tree from GRUB. Ubuntu's
standard GRUB generation may not preserve that line after kernel updates unless
we add a local hook.

## Decision

The live USB builder will require a compiled
`x1e80100-microsoft-denali.dtb` input and will add a GRUB `devicetree` command
for the live-USB boot entries.

Installed Ubuntu systems will use a helper that copies the Denali DTB to
`/boot/x1e80100-microsoft-denali.dtb` and injects a matching `devicetree`
line into generated GRUB menu entries. Kernel post-install and post-removal
hooks will rerun that helper after kernel changes.

## Consequences

Boot media cannot be produced until a Denali DTB is available from a kernel
package or local kernel build.

The installed-system helper is intentionally pragmatic. It patches
`/boot/grub/grub.cfg` after Ubuntu generates it, which is less elegant than a
native GRUB generator patch but easier to audit and iterate during bring-up.

When Ubuntu or linux-surface gains first-class Surface Pro 11 DTB handling, a
future ADR should replace this injection hook with the upstream-supported path.
