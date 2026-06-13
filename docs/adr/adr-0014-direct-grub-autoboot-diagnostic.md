---
id: adrs-adr014
title: "ADR014: Direct GRUB Autoboot Diagnostic"
# prettier-ignore
description: Architecture Decision Record (ADR) for adding an optional direct GRUB boot mode when the Surface Pro 11 GRUB menu is visible but does not accept input or auto-boot.
---

## Context

[ADR013](adr-0013-standalone-grub-external-keyboard-test.md) restored the
active image builder to the known-visible standalone GRUB menu and planned to
test entry selection with an external keyboard. The Surface Pro 11 continued to
show the GRUB menu, but the default entry did not auto-boot after the configured
timeout.

The Surface Flex Keyboard backlight key can still cycle brightness modes. That
shows the keyboard has power and local keyboard or firmware behavior, but it
does not prove that normal key events are reaching GRUB.

Because the GRUB timeout also does not advance into the default entry, buying a
new keyboard may not be the fastest next diagnostic. The failure could be in
the GRUB menu/input loop itself, or the firmware may be repeatedly presenting
an input event that keeps GRUB from timing out.

## Decision

The USB image builder will keep the normal interactive GRUB menu as the default
behavior, but add an optional `--grub-mode direct` diagnostic mode.

Direct mode embeds a GRUB config that immediately executes the same USB-safe
`casper` `iso-scan` path used by the first menu entry:

- search for the `SP11DATA` partition,
- loop-mount `/iso/ubuntu-x1e.iso`,
- load the Ubuntu kernel and initrd,
- inject `/dtb/sp11-denali.dtb`,
- pass the existing Surface Pro 11 and USB-safe aDSP blacklist arguments,
- call `boot` without creating an interactive GRUB menu.

## Consequences

If direct mode boots Ubuntu, the current blocker is likely the GRUB menu/input
path rather than the ISO, DTB, or core kernel arguments.

If direct mode also stalls before the kernel starts, the failure is likely
earlier than keyboard handling and should be investigated as a standalone GRUB,
firmware, or storage discovery problem.

Direct mode intentionally removes the fallback menu entries for that image.
Users should keep a normal menu image available for broader troubleshooting.
If direct mode stops around `Searching for SP11DATA...`, the likely issue is
earlier GRUB storage or partition discovery rather than keyboard input.

This mode does not solve Surface Flex Keyboard input in GRUB. It is a temporary
bring-up diagnostic to unblock live-USB boot testing without requiring a
working keyboard at the GRUB menu.
