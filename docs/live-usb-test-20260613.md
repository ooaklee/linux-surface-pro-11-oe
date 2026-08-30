# Surface Pro 11 Live USB Test - 2026-06-13

> [!IMPORTANT]
> **Immutable historical evidence — not a current procedure.**
> This record preserves one live-USB observation from 13 June 2026. Its image
> design, results, open questions, helper assumptions, and kernel state are not
> current installation or troubleshooting instructions.

## Current Read-Only Checks

Validate a newly generated ISO before writing it to media:

```sh
linux-armer image validate <generated.iso>
```

After booting, inspect the relevant static filesystem and package state with:

```sh
linux-armer doctor userspace \
  --feature kernel \
  --feature firmware \
  --feature wifi \
  --feature bluetooth \
  --feature audio \
  --feature touchscreen
```

`image validate` checks the generated ISO and its version-bound boot
artefacts; it does not prove that a written USB device or the target hardware
will boot. The doctor does not probe live devices, scan or associate with
networks, start services, play audio, or exercise touch input. Wi-Fi and
Bluetooth commands used outside the doctor can expose SSIDs, BSSIDs, MAC
addresses, and paired-device names, which must be redacted before publication.

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
