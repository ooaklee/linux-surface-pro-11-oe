# Surface Pro 11 Live USB Test - 2026-06-13

> Historical note: this report preserves the configuration and conclusions
> recorded at the time. The successful live-USB `/dtb/sp11-denali.dtb` path
> remains separate and unchanged. Later evidence showed that installed loose
> DTB injection was not authoritative on the tested Stubble path; ADR-0055
> retires that installed mechanism.

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
- At the time, USB-free NVMe boot was recorded as depending on installed GRUB
  DTB injection and support setup. Later embedded-DTB evidence and ADR-0055
  corrected that installed-path conclusion.
- Wi-Fi needs follow-up on firmware and ath12k board-file fixup from the
  installed system.
- Bluetooth, touchscreen, and audio need separate bring-up work after the boot
  and install path is stable.
