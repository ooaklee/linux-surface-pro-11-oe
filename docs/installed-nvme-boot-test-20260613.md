# Surface Pro 11 Installed NVMe Boot Test - 2026-06-13

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

## Next Steps

Run the installed-system finish helper after booting from NVMe. That helper
installs firmware, applies the temporary WCN7850 Wi-Fi board-file fixup, and
refreshes initramfs after the fixup succeeds.
