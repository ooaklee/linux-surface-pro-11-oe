---
id: adrs-adr013
title: "ADR013: Standalone GRUB External Keyboard Test"
# prettier-ignore
description: Architecture Decision Record (ADR) for reverting the active USB image builder to the known-visible standalone GRUB menu and testing installation with an external keyboard.
---

## Context

[ADR011](adr-0011-grub-efi-console-input.md) tested explicit GRUB EFI console
input binding after the first Surface Pro 11 boot reached the custom GRUB menu
but the Surface Flex Keyboard could not select an entry. That image still
displayed all four menu entries, but the Flex Keyboard remained unusable in
GRUB.

[ADR012](adr-0012-grub-module-tree.md) then tested a closer approximation of a
normal removable GRUB install by using an on-ESP GRUB module tree and an
embedded bootstrap config. Surface Pro 11 testing regressed: the machine still
reached GRUB, but no menu entries appeared.

An external keyboard is now available for testing. The original standalone
`grub-mkstandalone` image is the last known image that reliably displayed the
expected four Surface Pro 11 boot entries on the target device.

## Decision

The active USB image builder will revert to the original standalone
`grub-mkstandalone` bootloader layout from [ADR002](adr-0002-boot-shim-image-strategy.md)
and [ADR009](adr-0009-default-casper-iso-scan-boot.md) for the next test image.

The GRUB console-input and module-tree experiments from
[ADR011](adr-0011-grub-efi-console-input.md) and
[ADR012](adr-0012-grub-module-tree.md) will remain as historical records, but
they will not describe the active builder behavior.

The next test will use the external keyboard to select GRUB entries and attempt
to enter the Ubuntu live environment or installer. If installation works with
the external keyboard, the README should be updated in a later change to list
an external USB keyboard as a first-install prerequisite or known workaround
until Surface Flex Keyboard support in GRUB is understood.

## Consequences

This restores the image to the known-visible GRUB menu behavior and prioritizes
testing the Ubuntu live/install path over solving Surface Flex Keyboard input
inside GRUB immediately.

Surface Flex Keyboard input in GRUB remains unresolved. The previous failed
experiments narrow the remaining likely bootloader paths to a true
`grub-install`-produced removable layout, reusing more of the working Surface
Pro 11 Arch image's GRUB artifacts, or a Ventoy-based boot path that preserves
the Surface Pro 11 DTB and boot arguments.

If the external-keyboard install path works, the project can document that
workaround separately while continuing keyboard bring-up as a follow-up.
