# Surface Pro 11 Live USB Test - 2026-06-13

## Image

The successful boot used the direct GRUB diagnostic image from
[ADR014](adr/adr-0014-direct-grub-autoboot-diagnostic.md). This image bypasses
the interactive GRUB menu and immediately boots the USB-safe `casper`
`iso-scan` path with the Surface Pro 11 Denali DTB.

## Result

The direct image booted successfully to the Ubuntu desktop.

## Observed Working

- Desktop session starts.
- Display works.
- Touchpad works after the desktop starts.
- Screen brightness controls work.
- Night Light works.
- Function-key events are visible in the desktop; volume keys display the
  output UI.

## Observed Not Working

- Wi-Fi does not work in the live session.
- Bluetooth does not work in the live session.
- Touchscreen does not work in the live session.
- Audio does not work in the live session; the desktop reports
  `Dummy Output`.

## Open Questions

- Whether normal keyboard text input works after the desktop starts still needs
  explicit confirmation.
- Whether the installed NVMe system can boot without the USB depends on
  installed-system GRUB DTB injection and support setup.
- Wi-Fi needs follow-up on firmware and ath12k board-file fixup from the
  installed system.
- Bluetooth, touchscreen, and audio need separate bring-up work after the boot
  and install path is stable.
