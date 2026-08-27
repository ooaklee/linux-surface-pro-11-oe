---
id: how-to-install-sp11-firmware
title: "Install Surface Pro 11 Firmware"
# prettier-ignore
description: How-to guide for installing Qualcomm display, GPU, aDSP, and cDSP firmware on the Surface Pro 11 (Snapdragon X Elite X1E80100, Denali).
---

# How To: Install Surface Pro 11 Firmware

Use this procedure after the first installed boot to make the Surface Pro 11
display/GPU and audio DSP firmware available to Linux.

## Purpose

The Surface Pro 11 (Snapdragon X Elite X1E80100, Denali) needs proprietary
Qualcomm firmware that is not stored in this repository. The
`scripts/sp11-grab-fw.sh` helper installs the display/GPU firmware, including
`qcdxkmsuc8380.mbn`, and, separately, firmware for the audio DSP (aDSP) and
compute DSP (cDSP).

The Denali kernel looks for the GPU firmware below
`qcom/x1e80100/microsoft/Denali/`. The helper installs the canonical file at
`qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn` and creates this relative symlink:

```text
qcom/x1e80100/microsoft/Denali/qcdxkmsuc8380.mbn -> ../qcdxkmsuc8380.mbn
```

The symlink is a small alias, not a second copy of the firmware; it lets the
Denali-specific firmware lookup find the canonical file stored one directory
higher.

## Prerequisites

- Surface Pro 11 with the Snapdragon X Elite X1E80100 platform, booted into
  the installed Linux system.
- A current checkout of this repository or its copied support directory.
- Root access; the helper exits with `Run as root.` otherwise.
- For download mode, a working network connection and `cabextract`, `curl`,
  and `jq`. If any are missing, the helper prints the appropriate `apt`
  install command.
- For Windows-root mode, the mounted NTFS root containing the `Windows`
  directory. This mode does not need network access.

## Procedure

1. Enter the repository or copied support directory.

```bash
cd /path/to/linux-surface-pro-11-oe
```

2. Choose one firmware source and run the helper as root.

Download mode is the default. It finds the latest version in the
[`WOA-Project/Qualcomm-Reference-Drivers`](https://github.com/WOA-Project/Qualcomm-Reference-Drivers)
`Surface/8380_DEN` driver set (for example, `200.0.49.0`), downloads its CABs,
and extracts the matching files:

```bash
sudo ./scripts/sp11-grab-fw.sh --download
```

A CAB is a Microsoft driver archive, and WOA means Windows on Arm. The helper
downloads three CAB archives from GitHub, extracts only the required files
into a temporary directory, and removes the temporary downloads afterward.
The duration depends on network speed. A `Downloading <name>...` line may stay
on screen while each CAB transfers; do not interrupt the helper mid-download.

Alternatively, copy the newest matching files from a mounted Windows root.
Quote the path if it contains spaces:

```bash
sudo ./scripts/sp11-grab-fw.sh --windows-root "/path/to/mounted/Windows volume"
```

The Windows-root mode searches `Windows/System32` and
`Windows/System32/DriverStore/FileRepository` and selects the newest matching
copy of each file. It does not download anything.

3. If necessary, select a different destination or aDSP policy.

aDSP means audio digital signal processor. Its DTB is the device-tree firmware
that describes how that processor is wired to the system. "Enabled" means the
file keeps the name the kernel loads; "disabled" means it is renamed
`adsp_dtb.mbn.disabled` so the kernel skips it.

The supported options are:

- `--dest DIR` changes the firmware root from the default `/lib/firmware`.
- `--usb-safe` or `--disable-adsp` renames `adsp_dtb.mbn` to
  `adsp_dtb.mbn.disabled` after installation. Use this to protect a live USB
  root from resets caused by the aDSP DTB.
- `--enable-adsp` leaves `adsp_dtb.mbn` enabled.
- `--adsp-auto` applies the default automatic policy.
- `-h` or `--help` prints usage information.

If `--dest` is used, substitute that directory for `/lib/firmware` in the
validation commands. A custom destination is mainly for staging or testing
because the running system normally searches `/lib/firmware`.

With the default `--adsp-auto` policy, the helper detects the device backing
the root filesystem. It disables `adsp_dtb.mbn` only when root does **not**
appear to be on NVMe, providing USB-safe live-boot protection. On an NVMe root,
the aDSP DTB stays enabled. The automatic check may not recognize encrypted,
LVM, or other indirect root layouts as NVMe. If an installed internal-disk
system is reported as non-NVMe, rerun the helper with `--enable-adsp`.

4. Wait for the helper to finish.

After installing the files, it creates the Denali GPU symlink. If
`update-initramfs` is installed, the helper attempts to refresh all existing
initramfs images by running:

```bash
update-initramfs -u -k all
```

This refresh is best-effort: review any errors it prints.

After the **first** firmware installation, reboot before checking the GPU or
audio devices. Drivers that already failed to load missing firmware may not
automatically reprobe when the files appear. This extra reboot is not needed
after later kernel upgrades.

### Firmware persists across kernel installs

Install this firmware once after the first boot. The firmware files and Denali
symlink live permanently under `/lib/firmware`; they are not tied to any
kernel version. Kernel package installation normally rebuilds the new
kernel's initramfs. Firmware needed only after the root filesystem is mounted
— including this GPU firmware — can remain in
`/lib/firmware` without appearing in the initramfs image. **Do not rerun the
firmware helper after each kernel installation or upgrade.**

Rerun it only when:

- `/lib/firmware` has been wiped or the operating system has been reinstalled;
- a newer WOA driver set is wanted; or
- troubleshooting a missing-device or firmware-load issue.

The GPU firmware is intentionally not bundled in the initramfs by default. It
loads from the root filesystem at runtime after root is mounted. Its absence
from `lsinitramfs` output is therefore normal and expected, not a defect.

## Expected Output

The helper reports the source version in download mode, one `Installed
<path>` line for each firmware file found, and a line for the GPU symlink. This
example is abbreviated:

```text
Using WOA driver set: 200.0.49.0
Installed /lib/firmware/qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn
Installed /lib/firmware/qcom/x1e80100/microsoft/Denali/qcadsp8380.mbn
Installed /lib/firmware/qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn
Linked /lib/firmware/qcom/x1e80100/microsoft/Denali/qcdxkmsuc8380.mbn -> ../qcdxkmsuc8380.mbn
Root appears to be NVMe; leaving aDSP DTB enabled.
```

A complete run prints 11 `Installed` lines: GPU firmware and its Purwa
companion, aDSP and cDSP firmware, their DTBs, and their JSON payloads. It
prints no `not found in cab` or `not found under` warnings. Warnings do not
stop the helper, so review them before relying on the installation. On a
non-NVMe root, the aDSP policy line instead reports that `adsp_dtb.mbn` was
disabled. If `update-initramfs` is installed, its best-effort output follows;
review any errors it prints.

The complete source-to-destination mapping is:

| Source file | Destination below `/lib/firmware` |
| --- | --- |
| `qcdxkmsuc8380.mbn` | `qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn` |
| `qcdxkmsucpurwa.mbn` | `qcom/x1e80100/microsoft/qcdxkmsucpurwa.mbn` |
| `adsp_dtbs.elf` | `qcom/x1e80100/microsoft/Denali/adsp_dtb.mbn` |
| `qcadsp8380.mbn` | `qcom/x1e80100/microsoft/Denali/qcadsp8380.mbn` |
| `adspr.jsn` | `qcom/x1e80100/microsoft/Denali/adspr.jsn` |
| `adsps.jsn` | `qcom/x1e80100/microsoft/Denali/adsps.jsn` |
| `adspua.jsn` | `qcom/x1e80100/microsoft/Denali/adspua.jsn` |
| `battmgr.jsn` | `qcom/x1e80100/microsoft/Denali/battmgr.jsn` |
| `cdsp_dtbs.elf` | `qcom/x1e80100/microsoft/Denali/cdsp_dtb.mbn` |
| `qccdsp8380.mbn` | `qcom/x1e80100/microsoft/Denali/qccdsp8380.mbn` |
| `cdspr.jsn` | `qcom/x1e80100/microsoft/Denali/cdspr.jsn` |

## Validation

Inspect the installed files and the Denali symlink:

```bash
ls -la /lib/firmware/qcom/x1e80100/microsoft/
ls -la /lib/firmware/qcom/x1e80100/microsoft/Denali/
readlink -f /lib/firmware/qcom/x1e80100/microsoft/Denali/qcdxkmsuc8380.mbn
```

The resolved symlink should print:

```text
/lib/firmware/qcom/x1e80100/microsoft/qcdxkmsuc8380.mbn
```

After rebooting into the intended kernel, check for a GPU render node and
relevant kernel messages:

```bash
ls -l /dev/dri/renderD*
dmesg | grep -iE 'adreno|msm|qcdx|firmware'
```

The firmware listing and resolved symlink prove that the expected files are
on disk. Successful device checks show at least one `renderD*` node and
firmware-load messages without fatal errors. The integrated Qualcomm GPU is
not a PCI VGA device, so a PCI VGA search may legitimately find nothing. These
checks confirm that the running system exposes graphics; they do not by
themselves validate every display or audio path.

## Privacy and Safety

The extracted firmware blobs are proprietary. Never commit `.mbn`, `.cab`, or
`.elf` files, extracted payloads, or copies of the Windows driver store to this
repository.

The automatic aDSP policy protects live USB boots because enabling the aDSP
DTB there can reset USB and interrupt access to the root filesystem. Leave the
default policy in place until the system is installed on NVMe, or explicitly
use `--usb-safe` while booted from USB.

Before sharing logs or commands, remove personal mount paths, account names,
and other machine-specific information.

## Troubleshooting

If download mode reports missing tools, install them and rerun the helper:

```bash
sudo apt install cabextract curl jq
```

If download mode fails with a GitHub API, DNS, proxy, or interrupted-transfer
error, verify network connectivity and rerun the helper. It safely recreates
its temporary download directory.

If aDSP was disabled because the root filesystem was not on NVMe, boot the
installed NVMe system and rerun the helper with `--enable-adsp`.

If `Warning: X not found in cab` appears, the upstream WOA driver layout may
have changed. Confirm the current CAB contents and update the helper's mapping
before relying on that driver set.

If the GPU is still not detected after installation, inspect the kernel log
for firmware-load failures and confirm that the Denali symlink is not broken:

```bash
dmesg | grep -i firmware
readlink -f /lib/firmware/qcom/x1e80100/microsoft/Denali/qcdxkmsuc8380.mbn
```

## Related Documents

- [ADR004: Firmware Extraction Policy](../adr/adr-0004-firmware-extraction-policy.md)
- [How To: Bring Up Audio on Surface Pro 11](how-to-bring-up-audio.md)
- [Project README](../../README.md)
