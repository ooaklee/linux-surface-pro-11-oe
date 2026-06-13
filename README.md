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

## Current Status

The Surface Pro 11 still needs a custom device tree and firmware handling. A
standard ARM64 Ubuntu ISO is not enough.

| Feature | Expected status | Notes |
| --- | --- | --- |
| Display | Experimental | Requires a Surface Pro 11 Denali DTB, such as Ubuntu's `x1e80100-microsoft-denali-oled.dtb` for X1E OLED devices, and the display workaround in the SP11 kernel work. |
| NVMe | Expected | Confirmed device uses standard NVMe storage. |
| USB-C boot | Expected | Use the USB-safe boot entry first. |
| Wi-Fi | Experimental | Uses WCN7850/Qualcomm FastConnect 7800 and needs the ath12k board-file fixup. |
| Bluetooth | Experimental | Firmware is present in Windows; Linux may still need MAC-address handling. |
| Keyboard/cover | Experimental | Windows exposes Surface HID keyboard devices. Linux support depends on the SP11 Surface Aggregator patches. |
| Touchscreen/pen | Not expected yet | SP11 Arch notes still list touchscreen and pen as not working. |
| Camera | Not expected yet | Camera support is not part of the first Ubuntu boot path. |
| Audio | Partial/risky | Upstream notes warn that speaker audio can be distorted. Keep volume low. |
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

To validate an already-built image without rebuilding:

```bash
./scripts/build-sp11-live-usb-image.sh \
  --validate-image build/sp11-ubuntu-live.img
```

Validation reports the image size and SHA-256 hash, GPT layout, ESP contents,
embedded GRUB menu hints, and the `/dtb/sp11-denali.dtb` file from the
`SP11DATA` partition.

The image contains:

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
3. Choose `Ubuntu for Surface Pro 11 (USB-safe, casper iso-scan)`.
4. If the screen goes black or the graphical installer does not appear, reboot
   and choose `Ubuntu for Surface Pro 11 (USB-safe text/debug, casper iso-scan)`.
5. If the casper `iso-scan` entries fail early, try
   `Ubuntu for Surface Pro 11 (USB-safe, ISO-native fallback)`.
6. If the live session boots, install Ubuntu to a new partition. Do not delete
   Windows.
7. After first boot into installed Ubuntu, mount the USB data partition and run:

```bash
cd /media/$USER/SP11DATA/support
sudo ./scripts/install-sp11-support.sh --installed-system
sudo sp11-grab-fw --download
sudo reboot
```

If you run firmware setup while booted from USB, the script leaves
`adsp_dtb.mbn` disabled to avoid the known aDSP USB reset failure. Enable aDSP
only after the root filesystem is on NVMe.

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
