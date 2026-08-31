# Surface Pro 11 Installed NVMe Boot Test - 2026-06-13

Last reviewed: 2026-08-30

> [!IMPORTANT]
> **Immutable historical evidence — not a current procedure.**
> This record preserves the installed-boot result observed on 13 June 2026.
> Its helper references, paths, workaround assumptions, and next step describe
> that test only and must not be followed on a current installation.

## Current Read-Only Checks

Validate the generated installation ISO before using it, then inspect the
installed kernel and platform-firmware state after boot:

```sh
lexr image validate <generated.iso>
lexr doctor userspace --feature kernel --feature firmware
```

The image validator checks ISO structure and version-bound boot artefacts. The
doctor reads static filesystem and package state. Neither command proves that
the machine can boot from NVMe, validates a live GRUB transition, or changes
the installed system. NVMe boot remains an intentional physical qualification
boundary and is not a capability claimed by the CLI.

## Context

The successful live-USB path from
[ADR015](adr/adr-0015-direct-live-desktop-and-install-gate.md) required a
pre-reboot installed-system setup step before testing USB-free boot. The setup
flow is documented in
[ADR016](adr/adr-0016-usb-data-mount-and-installed-system-helpers.md).

The installed Ubuntu root was mounted at `/target` from the live session, and
the support prepare helper was run against that target before reboot.

## Result

The installed Ubuntu system booted successfully from the internal NVMe storage
without using the USB as the root filesystem.

Reported mounted filesystems after boot:

| Mount point | Device | Notes |
| --- | --- | --- |
| `/` | `/dev/nvme0n1p5` | Installed Ubuntu root filesystem. |
| `/boot` | `/dev/nvme0n1p6` | Separate boot filesystem. |
| `/boot/efi` | `/dev/nvme0n1p1` | Existing EFI system partition. |

## Significance

The installed-system GRUB DTB injection and support setup were sufficient for
first USB-free NVMe boot on the verified Surface Pro 11 target.

The first installed boot also exposed a follow-up GRUB path issue: systems
with a separate `/boot` filesystem can report `file '/boot/sp11-denali.dtb'
not found` from GRUB, because GRUB sees the `/boot` filesystem as its root and
therefore needs `devicetree /sp11-denali.dtb`. This is tracked by
[ADR017](adr/adr-0017-grub-dtb-path-for-separate-boot.md).

This does not yet prove full hardware support. Wi-Fi, Bluetooth, touchscreen,
audio, camera, and suspend still require post-install bring-up and validation.

## Historical Next Step (Superseded)

> [!CAUTION]
> The broad installed-system finish helper described below is retired as
> current guidance. The paragraph is retained only to preserve the dated test
> record; do not run that helper on a current installation.

Run the installed-system finish helper after booting from NVMe. That helper
installs firmware, applies the temporary WCN7850 Wi-Fi board-file fixup, and
refreshes initramfs after the fixup succeeds.
