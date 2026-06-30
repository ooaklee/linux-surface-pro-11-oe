---
id: adr-0039-kde-plasma-desktop-option
title: "ADR0039: KDE Plasma Desktop Option"
# prettier-ignore
description: Architecture Decision Record (ADR) for shipping and installing KDE Plasma on the Surface Pro 11 instead of GNOME, since Kubuntu has no official ARM64 ISO.
---

# ADR0039: KDE Plasma Desktop Option

## Status

Accepted — adds a KDE Plasma path alongside the default GNOME concept ISO
(2026-06-30).

## Context

The Surface Pro 11 Ubuntu bring-up currently boots Canonical's
`resolute-desktop-arm64+x1e.iso` concept image, which ships GNOME. The live USB
builder (`scripts/build-sp11-live-usb-image.sh`) downloads this ISO verbatim and
packs it onto the `SP11DATA` partition without modifying the casper squashfs.

Kubuntu does not publish an official ARM64 ISO. The Reddit thread
[r/Kubuntu — Still no Kubuntu ARM ISO](https://www.reddit.com/r/Kubuntu/comments/1khrp7l/still_no_kubuntu_arm_iso/)
confirms this gap as of 2025. Users who want Plasma on Snapdragon X Elite
hardware currently have no official installation path.

The SP11 bring-up work is desktop-agnostic. The kernel, DTB injection, firmware
extraction, Wi-Fi rfkill fix, Bluetooth public-address helper, and audio
topology work are all independent of GNOME vs Plasma. Switching to Plasma only
replaces the desktop session and display manager; it does not affect any
`sp11-*` support helper.

## Decision

Provide two complementary paths to KDE Plasma on the Surface Pro 11:

### 1. Post-install desktop swap script

A small, reproducible payload script
(`scripts/sp11-install-kde-desktop.sh`) that installs `kubuntu-desktop` and
switches the display manager to SDDM on an already-installed Ubuntu system. This
mirrors the manual `sudo apt install kubuntu-desktop` flow but is tracked in git
and supports both a running installed system and a chroot target.

By default GNOME is kept alongside Plasma so the switch can be validated before
committing. A `--purge-gnome` flag removes `ubuntu-desktop`, `gdm3`, and
`gnome-shell` after Plasma is confirmed working.

### 2. Live USB remaster mode

A `--desktop kde` flag on `scripts/build-sp11-live-usb-image.sh` that remasters
the concept ISO's casper squashfs layer in the Docker build container before
packing it onto the USB image. The remaster:

1. unsquashfs the writable casper layer
2. chroot into the extracted root and `apt install kubuntu-desktop sddm`
3. pre-seed SDDM as the default display manager via debconf
4. repack the squashfs with `mksquashfs -comp xz`
5. rebuild the ISO with `xorriso -as mkisofs`

This produces a live USB that boots straight into Plasma without requiring a
post-install swap.

## Consequences

- The default build path (`--desktop gnome`) is unchanged; existing users see no
  difference.
- The `--desktop kde` path is experimental. It requires network access inside
  the Docker build container, roughly doubles build time, and increases the
  final USB image size because the Plasma stack is added to the casper squashfs.
- The post-install swap script is the recommended first path. It is faster to
  test and does not require rebuilding the USB image.
- Both paths are independent of the SP11 kernel/DTB/firmware bring-up. A user
  who installs Plasma still needs the patched `qcom-x1e` kernel, the Denali DTB,
  the audio topology, and the Bluetooth MAC helper exactly as documented in the
  README.
- SDDM replaces GDM as the display manager. The `sp11-grub-inject-dtb` and
  kernel postinst hooks are unaffected because they run before the display
  manager starts.

## Alternatives Considered

### Wait for an official Kubuntu ARM64 ISO

Rejected. The Reddit thread and Kubuntu release history show no current plan for
ARM64 ISOs. The SP11 bring-up cannot block on that.

### Ship a separate Kubuntu-based build pipeline

Rejected as the primary path. It would duplicate the concept ISO boot shim,
casper layer handling, and DTB injection work. Remastering the existing concept
ISO reuses all of that infrastructure.

### Remove GNOME by default in the post-install script

Rejected as the default. Keeping GNOME alongside Plasma lets users fall back if
Plasma has an unexpected issue on SP11 hardware. The `--purge-gnome` flag is
opt-in.

## Verification

- `bash -n scripts/sp11-install-kde-desktop.sh` — syntax check.
- `bash -n scripts/build-sp11-live-usb-image.sh` — syntax check.
- The post-install script is the primary verification target: run it on an
  installed SP11 system, confirm SDDM starts and the Plasma session is
  selectable, then optionally re-run with `--purge-gnome`.
- The `--desktop kde` remaster path is experimental and should be validated
  after the post-install script confirms Plasma works on SP11 hardware.

## Related

- [ADR0002: Boot Shim Image Strategy](adr-0002-boot-shim-image-strategy.md)
- [ADR0007: Auto DTB Extraction and Debug Entries](adr-0007-auto-dtb-extraction-and-debug-entries.md)
- [Install KDE Plasma desktop (payload script)](../../scripts/sp11-install-kde-desktop.sh)
- [Build live USB image (builder)](../../scripts/build-sp11-live-usb-image.sh)
