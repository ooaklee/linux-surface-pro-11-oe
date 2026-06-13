---
id: adrs-adr015
title: "ADR015: Direct Live Desktop and Install Gate"
# prettier-ignore
description: Architecture Decision Record (ADR) for treating direct GRUB boot as the verified live-USB path and allowing cautious installation only with pre-reboot installed-system support setup.
---

## Context

[ADR014](adr-0014-direct-grub-autoboot-diagnostic.md) added a direct GRUB boot
mode because the Surface Pro 11 could display the GRUB menu but neither normal
keyboard input nor the configured timeout reliably advanced into a boot entry.

The direct image successfully booted to the Ubuntu desktop on the Surface Pro
11. This confirms that the USB image layout, Ubuntu concept ISO, Denali DTB
injection, USB-safe kernel arguments, display path, and live desktop path are
viable enough for install testing.

The live session still has important hardware gaps:

- Wi-Fi does not work.
- Bluetooth does not work.
- Touchscreen does not work.
- Audio reports `Dummy Output`.
- Touchpad works.
- Screen brightness and Night Light work.
- Function-key events are visible in the desktop.

The installed NVMe system is not guaranteed to boot independently just because
the live USB boots. The live USB injects the Surface Pro 11 DTB from its custom
GRUB config, while an installed Ubuntu system needs its generated GRUB config
patched to include the same DTB handling.

## Decision

The project will treat `--grub-mode direct` as the currently verified live-USB
boot path.

Installation may proceed as a cautious experiment only when Windows is kept
intact and the live USB remains available as a recovery environment. The
installed Ubuntu target should receive this repository's support setup before
the first USB-free reboot:

- install support helpers into the target root,
- preserve the known-good live-USB kernel arguments, including `arm64.nopauth`,
- generate the installed system's GRUB config,
- inject the Surface Pro 11 Denali DTB into `/boot/grub/grub.cfg`,
- refresh initramfs,
- then reboot and test whether NVMe boot works without the USB.

The README will document the `/target` setup flow for the common case where
the installer leaves the installed root mounted after installation.

## Consequences

The next test can answer whether the installed Ubuntu system can boot from
NVMe without relying on the USB boot shim.

This decision does not claim the system is generally usable yet. Lack of Wi-Fi,
Bluetooth, touchscreen, and audio remain open bring-up issues.

If the installed system fails to boot, the direct live USB remains the recovery
path for inspecting and repairing the installed root.

If USB-free boot succeeds, the project should update the README from
experimental install guidance to a clearer post-install checklist and continue
with Wi-Fi, Bluetooth, touchscreen, and audio bring-up.
