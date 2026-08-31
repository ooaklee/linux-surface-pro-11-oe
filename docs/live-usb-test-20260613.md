# Surface Pro 11 Live USB Test - 2026-06-13

Last reviewed: 2026-08-30

> [!IMPORTANT]
> **Immutable historical evidence — not a current procedure.**
> This record preserves one live-USB observation from 13 June 2026. Its image
> design, results, open questions, helper assumptions, and kernel state are not
> current installation or troubleshooting instructions.

## Current Validation and Guarded Write Flow

Validate a newly generated ISO before writing it to media:

```sh
lexr image validate <generated.iso>
lexr image devices
lexr image write <generated.iso> \
  --device <whole-device> \
  --dry-run

sudo lexr image write <generated.iso> \
  --device <whole-device> \
  --confirm '<exact phrase from the current dry run>'
```

Review the fresh whole-device inventory and exact dry-run confirmation before
running the privileged command. The real command requires effective root,
writes, reads back, verifies and ejects the selected removable medium; the CLI
never elevates itself.

After booting, inspect the relevant static filesystem and package state with:

```sh
lexr doctor userspace \
  --feature kernel \
  --feature firmware \
  --feature wifi \
  --feature bluetooth \
  --feature audio \
  --feature touchscreen
lexr doctor hardware wifi bluetooth audio touchscreen
```

`image validate` checks the generated ISO and its version-bound boot
artefacts; the write workflow additionally verifies the bytes read back from
the selected medium. Neither proves that the target hardware will boot. The
userspace doctor checks static state, while the hardware doctor adds bounded
live evidence without changing devices, radio blocks, services, networking or
audio routing. Physical boot, network association, playback, touch interaction
and suspend/resume are intentional hardware qualification boundaries rather
than capabilities claimed by the CLI. Wi-Fi and Bluetooth commands used
outside the doctor can expose SSIDs, BSSIDs, MAC addresses, and paired-device
names, which must be redacted before publication.

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
