# Ubuntu on Surface Pro 11 (Snapdragon X Elite)

This repository is an experimental Ubuntu bring-up kit for the Microsoft
Surface Pro 11 with Snapdragon X Elite (`X1E80100`). It uses the Surface Laptop
7 Ubuntu work as a reference, and ports the Surface Pro 11-specific pieces from
Dale Whinham's Arch Linux work.

The current verified target is:

| Item | Value |
| --- | --- |
| Device | Microsoft Surface Pro, 11th Edition |
| SKU | `Surface_Pro_11th_Edition_2076` |
| CPU | `Snapdragon(R) X 12-core X1E80100 @ 3.40 GHz` |
| Firmware/UEFI | `175.222.235`, dated 2026-02-23 |
| Internal disk | Samsung `MZ9L4512HBLU-00BMV-SAMSUNG`, 476.9 GiB NVMe |
| Windows source checked | Windows 11 Home Insider Preview build `29585` |

> Warning: this is not an official Ubuntu, Microsoft, or linux-surface release.
> Keep Windows installed, keep a recovery USB nearby, and expect regressions.

## Prerequisites

Prepare these before building or booting the installer:

- A Microsoft Surface Pro 11 with Snapdragon X Elite (`X1E80100`). This guide
  is not for Surface Laptop 7/Romulus devices or Intel Surface devices.
- A complete Windows backup and a saved BitLocker or Device Encryption recovery
  key. Suspend or decrypt Windows device encryption before resizing partitions
  or repeatedly booting experimental media.
- Secure Boot disabled in Surface UEFI.
- A Windows recovery USB or another confirmed way to restore the device if the
  Ubuntu install or bootloader setup fails.
- A USB-C flash drive, 16 GB or larger. The write script erases the entire
  selected disk.
- A macOS build host with Docker Desktop running, `git`, `diskutil`, and sudo
  access for writing the raw USB image. Keep at least 20 GB free for the ISO,
  Docker image/package setup, work directories, and generated raw images.
- Temporary networking for post-install firmware work. Wi-Fi is not working in
  the current live session, so prepare USB-C Ethernet, USB phone tethering, or
  a mounted Windows partition for `sp11-grab-fw --windows-root`.
- An external USB keyboard is recommended for installer recovery and text
  entry. The direct GRUB mode avoids the broken interactive GRUB menu, but
  normal keyboard text input in the desktop still needs confirmation.

## Current Status

The Surface Pro 11 still needs a custom device tree and firmware handling. A
standard ARM64 Ubuntu ISO is not enough.

Latest live-USB result, 2026-06-13: the `--grub-mode direct` image boots to the
Ubuntu desktop. The interactive GRUB menu still does not accept input or
auto-boot reliably, so direct mode is the verified live-USB path for now.

Latest installed-system result, 2026-06-13: after running the pre-reboot
installed-system prepare helper from the live USB, Ubuntu booted successfully
from the internal NVMe install without the USB root filesystem.

| Feature | Expected status | Notes |
| --- | --- | --- |
| Display | Working in live USB | Direct boot reached the Ubuntu desktop. Night Light and screen brightness controls work. |
| NVMe | Working for installed boot | Installed Ubuntu booted from `/dev/nvme0n1p5` with separate `/boot` and `/boot/efi` partitions after support setup. |
| USB-C boot | Working with direct mode | The normal GRUB menu can display entries but input and timeout are unreliable. Use `--grub-mode direct` for the verified path. |
| Touchpad | Working in live USB | The Surface cover touchpad works after the desktop starts. |
| Keyboard/cover | Partial | Backlight and function-key events are visible, but GRUB menu input remains unresolved. Normal text input still needs confirmation. |
| Wi-Fi | Probes but hard-blocked after installed boot | WCN7850/Qualcomm FastConnect 7800 binds to `ath12k_wifi7_pci`, loads firmware, and creates an interface, but `rfkill` reports `Hard blocked: yes`. This likely needs the SP11 `disable-rfkill` DTB/kernel handling from the Arch bring-up. |
| Bluetooth | Not working in live USB | Firmware is present in Windows; Linux may still need firmware and MAC-address handling. |
| Touchscreen/pen | Not working in live USB | SP11 Arch notes also list touchscreen and pen as not working. |
| Camera | Not expected yet | Camera support is not part of the first Ubuntu boot path. |
| Audio | Not working in live USB | GNOME reports `Dummy Output` when volume keys are pressed. Upstream speaker-audio work is still risky; keep volume low during future tests. |
| Suspend | Partial/risky | Prefer testing boot/install first. |

## Recommended Path

Use the custom live-USB image builder in this repo. It creates a small ARM64
GRUB boot shim, stores the Ubuntu Snapdragon X concept ISO on a Linux data
partition, and injects the Surface Pro 11 device tree at boot.

This avoids remastering the Ubuntu ISO while still giving us the SP11-specific
`devicetree` line that stock ISO boot paths lack.

### 1. Build the USB Image

On macOS, the builder uses Docker Desktop with an ARM64 Ubuntu container. It
can download the current Ubuntu Snapdragon X concept ISO. If that ISO includes
a Surface Pro 11 X1E Denali DTB in its casper layers, the builder extracts it
automatically:

```bash
./scripts/build-sp11-live-usb-image.sh \
  --iso https://people.canonical.com/~platform/images/ubuntu-concept/resolute-desktop-arm64+x1e.iso \
  --out build/sp11-ubuntu-live.img \
  --validate
```

If auto extraction fails, or if you need a different Surface Pro 11 variant,
provide a DTB explicitly:

```bash
./scripts/build-sp11-live-usb-image.sh \
  --iso build/input/ubuntu-x1e.iso \
  --dtb build/input/x1e80100-microsoft-denali.dtb \
  --out build/sp11-ubuntu-live.img
```

An explicit DTB can come from a kernel package that includes SP11 support, or
from a local build of `dwhinham/kernel-surface-pro-11`. Do not substitute the
Surface Laptop 7/Romulus DTB.

The first build can take a while. Expect a multi-gigabyte ISO download, Docker
image/package setup, DTB extraction from Ubuntu's layered `casper/*.squashfs`
files, ext4 filesystem creation, raw-image assembly, and optional validation.
On Docker Desktop for macOS, the raw image copy/write phases can look quiet for
several minutes.

If GRUB displays the menu but the countdown never auto-boots and keyboard input
does not select an entry, build a diagnostic image that bypasses the GRUB menu
and immediately boots the default USB-safe `casper` path:

```bash
./scripts/build-sp11-live-usb-image.sh \
  --iso path/to/ubuntu-x1e.iso \
  --grub-mode direct \
  --work-dir build/work-direct-boot \
  --out build/sp11-ubuntu-live-direct.img \
  --validate
```

The direct mode is intentionally diagnostic. It removes the interactive GRUB
fallback entries for that image, so keep a normal menu image available while
testing. If direct mode stops before the Ubuntu kernel starts, note the last
message on screen; a stop around `Searching for SP11DATA...` points to an
earlier GRUB storage or partition-discovery problem.

To validate an already-built image without rebuilding:

```bash
./scripts/build-sp11-live-usb-image.sh \
  --validate-image build/sp11-ubuntu-live.img
```

Validation reports the image size and SHA-256 hash, GPT layout, ESP contents,
embedded GRUB menu or direct-boot hints, and the `/dtb/sp11-denali.dtb` file
from the `SP11DATA` partition.

The normal menu image contains:

- an ARM64 removable-media EFI bootloader,
- a USB-safe GRUB entry with `modprobe.blacklist=qcom_q6v5_pas`,
- a USB-safe text/debug GRUB entry for black-screen or installer debugging,
- an ISO-native fallback GRUB entry for loopback debugging,
- a normal GRUB entry for later NVMe-installed boot testing,
- the Ubuntu concept ISO,
- the extracted or provided DTB as `/dtb/sp11-denali.dtb`,
- optional local payload files from `payload/`,
- this repo's README, ADRs, tools, and support scripts under `/support` on the
  USB data partition.

The direct-boot diagnostic image replaces the interactive GRUB menu entries
with the same USB-safe `casper` path used by the first menu entry.

### 2. Write the USB

On macOS, verify the disk first:

```bash
diskutil list /dev/disk4
diskutil info /dev/disk4
```

Then write it:

```bash
./scripts/write-image-to-macos-disk.sh build/sp11-ubuntu-live.img /dev/disk4
```

The script refuses to write unless the disk is external, removable, and USB.
Writing the image also takes several minutes because it streams the full raw
image to the USB device.

### 3. Boot the Surface

1. Disable Secure Boot in the Surface UEFI.
2. Boot from the USB.
3. For the normal menu image, choose
   `Ubuntu for Surface Pro 11 (USB-safe, casper iso-scan)`.
4. If the GRUB menu accepts no input or never auto-boots, rebuild and write the
   direct image with `--grub-mode direct`.
5. If the screen goes black or the graphical installer does not appear, reboot
   and choose `Ubuntu for Surface Pro 11 (USB-safe text/debug, casper iso-scan)`.
6. If the casper `iso-scan` entries fail early, try
   `Ubuntu for Surface Pro 11 (USB-safe, ISO-native fallback)`.
7. If the live session boots, install Ubuntu to a new partition. Do not delete
   Windows.

### 4. Install Ubuntu Carefully

Proceed with installation only if Windows is backed up, BitLocker recovery
information is saved, Secure Boot is disabled, and you have a recovery path
through the live USB. Use manual partitioning or an installer option that keeps
Windows intact.

Because the live USB relies on explicit GRUB DTB injection, do not assume the
installed system can boot without support setup. After the installer finishes,
choose the option to continue testing instead of rebooting, keep the USB
plugged in, and configure the installed target before the first USB-free boot.
The USB image includes a helper for this under `/support/scripts`. If the
installer leaves the installed root mounted at `/target`, run:

```bash
SP11DEV="$(blkid -L SP11DATA)"
test -n "$SP11DEV" || { echo "SP11DATA partition not found; run lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS."; exit 1; }
SP11DATA="$(findmnt -rn -S "$SP11DEV" -o TARGET | head -n 1)"
if [ -z "$SP11DATA" ]; then
  SP11DATA=/mnt/sp11data
  sudo mkdir -p "$SP11DATA"
  sudo mount "$SP11DEV" "$SP11DATA"
fi
test -d /target/etc || { echo "Mount the installed Ubuntu root at /target first."; exit 1; }
cd "$SP11DATA/support"
sudo ./scripts/prepare-sp11-installed-system.sh --target /target
sudo reboot
```

If `/target` is not mounted, mount the installed Ubuntu root partition there
first. If the installed system fails to boot, boot the direct live USB again
and use it as the recovery environment.

If GRUB reports `file '/boot/sp11-denali.dtb' not found` on an installed
system with a separate `/boot` partition, rerun the current support helper.
Older helper versions always injected `/boot/sp11-denali.dtb`; the current
helper derives `/sp11-denali.dtb` vs `/boot/sp11-denali.dtb` from the generated
GRUB kernel path.

After first successful boot into installed Ubuntu, mount the USB data partition
and rerun the support helpers on the installed system:

```bash
SP11DEV="$(blkid -L SP11DATA)"
test -n "$SP11DEV" || { echo "SP11DATA partition not found; run lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS."; exit 1; }
SP11DATA="$(findmnt -rn -S "$SP11DEV" -o TARGET | head -n 1)"
if [ -z "$SP11DATA" ]; then
  SP11DATA=/mnt/sp11data
  sudo mkdir -p "$SP11DATA"
  sudo mount "$SP11DEV" "$SP11DATA"
fi
cd "$SP11DATA/support"
sudo ./scripts/finish-sp11-installed-system.sh --download --reboot
```

Firmware download requires temporary networking, such as USB-C Ethernet or USB
phone tethering. Without networking, mount the Windows partition and use
`--windows-root` instead of `--download`:

```bash
sudo ./scripts/finish-sp11-installed-system.sh \
  --windows-root /path/to/windows \
  --reboot
```

If you run firmware setup while booted from USB, the script leaves
`adsp_dtb.mbn` disabled to avoid the known aDSP USB reset failure. Enable aDSP
only after the root filesystem is on NVMe.

If Wi-Fi still toggles back off after installed boot, collect the rfkill
diagnostic bundle:

```bash
cd "$SP11DATA/support"
sudo ./scripts/troubleshoot-sp11-wifi-rfkill.sh --try-unblock
```

The current verified installed-system failure is `phy0` hard-blocked by
`rfkill` even after firmware loads and the WCN7850 interface is created. That
points to missing ath12k `disable-rfkill` kernel/DTB handling rather than a
missing board file.

## Test Notes

- [2026-06-13 direct live USB test](docs/live-usb-test-20260613.md)
- [2026-06-13 installed NVMe boot test](docs/installed-nvme-boot-test-20260613.md)
- [2026-06-13 installed Wi-Fi rfkill test](docs/installed-wifi-rfkill-test-20260613.md)

## Decision Records

The major bring-up decisions are recorded in `docs/adr/`:

- [ADR001: Target Repo and Scope](docs/adr/adr-0001-target-repo-and-scope.md)
- [ADR002: Boot Shim Image Strategy](docs/adr/adr-0002-boot-shim-image-strategy.md)
- [ADR003: Denali DTB and GRUB Injection](docs/adr/adr-0003-denali-dtb-and-grub-injection.md)
- [ADR004: Firmware Extraction Policy](docs/adr/adr-0004-firmware-extraction-policy.md)
- [ADR005: Wi-Fi Board Fixup](docs/adr/adr-0005-wifi-board-fixup.md)
- [ADR006: Build and Write Guardrails](docs/adr/adr-0006-build-and-write-guardrails.md)
- [ADR007: Auto DTB Extraction and Debug Entries](docs/adr/adr-0007-auto-dtb-extraction-and-debug-entries.md)
- [ADR008: Ubuntu Denali DTB Variants](docs/adr/adr-0008-ubuntu-denali-dtb-variants.md)
- [ADR009: Default Casper ISO Scan Boot](docs/adr/adr-0009-default-casper-iso-scan-boot.md)
- [ADR010: Image Validation Workflow](docs/adr/adr-0010-image-validation-workflow.md)
- [ADR011: GRUB EFI Console Input](docs/adr/adr-0011-grub-efi-console-input.md)
- [ADR012: GRUB Module Tree](docs/adr/adr-0012-grub-module-tree.md)
- [ADR013: Standalone GRUB External Keyboard Test](docs/adr/adr-0013-standalone-grub-external-keyboard-test.md)
- [ADR014: Direct GRUB Autoboot Diagnostic](docs/adr/adr-0014-direct-grub-autoboot-diagnostic.md)
- [ADR015: Direct Live Desktop and Install Gate](docs/adr/adr-0015-direct-live-desktop-and-install-gate.md)
- [ADR016: USB Data Mount and Installed-System Helpers](docs/adr/adr-0016-usb-data-mount-and-installed-system-helpers.md)
- [ADR017: GRUB DTB Path for Separate Boot](docs/adr/adr-0017-grub-dtb-path-for-separate-boot.md)
- [ADR018: Wi-Fi rfkill Bring-Up Gate](docs/adr/adr-0018-wifi-rfkill-bring-up-gate.md)

## Windows Firmware

The verified Windows install contains the expected firmware inputs:

- `qcdxkmsuc8380.mbn`
- `adsp_dtbs.elf`
- `qcadsp8380.mbn`
- `cdsp_dtbs.elf`
- `qccdsp8380.mbn`
- `adspr.jsn`, `adsps.jsn`, `adspua.jsn`, `battmgr.jsn`, `cdspr.jsn`

They are installed from Windows driver-store paths such as:

- `surfacepro_ext_adsp8380.inf_arm64_3cc952aaca3564ae`
- `qcnspmcdm_ext_cdsp8380.inf_arm64_4a8c3ebe3aad408a`
- `qcdx8380.inf_arm64_*`

Do not commit proprietary firmware blobs to this repository.

## Useful Commands on Windows

Run this only when we need to refresh the hardware report:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\collect-sp11-windows-diagnostics.ps1
```

The collector writes:

```text
%USERPROFILE%\Desktop\sp11-linux-checks\sp11-linux-checks-<timestamp>.zip
```

## Sources

- Surface Laptop 7 Ubuntu notes: <https://github.com/bryce-hoehn/linux-surface-laptop-7>
- Surface Pro 11 Arch notes: <https://github.com/dwhinham/linux-surface-pro-11>
- linux-surface: <https://github.com/linux-surface/linux-surface>
- Ubuntu Snapdragon X concept images: <https://people.canonical.com/~platform/images/ubuntu-concept/>
- Fedora Snapdragon WoA install notes: <https://fedoraproject.org/wiki/Snapdragon_WoA_Laptop_Install>
- Surface Pro 11 support discussion: <https://github.com/linux-surface/linux-surface/issues/1962>
