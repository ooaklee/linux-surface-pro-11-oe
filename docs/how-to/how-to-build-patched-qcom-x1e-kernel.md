---
id: how-to-build-patched-qcom-x1e-kernel
title: "Build a Patched qcom-x1e Kernel"
# prettier-ignore
description: How-to guide for building and testing a Surface Pro 11 qcom-x1e kernel with ath12k disable-rfkill support.
---

# How To: Build a Patched qcom-x1e Kernel

Use this procedure when Wi-Fi probes on Surface Pro 11 but remains
hard-blocked by rfkill, and `scripts/troubleshoot-sp11-wifi-rfkill.sh` reports
that the installed ath12k modules do not contain `disable-rfkill` support.

## Purpose

The firmware and board-file helpers are enough for WCN7850 to probe, load
firmware, and create an interface. On Surface Pro 11, Wi-Fi still needs ath12k
to skip rfkill configuration for the Denali WCN7850 devicetree node.

This procedure builds Ubuntu qcom-x1e kernel packages with the targeted
Surface Pro 11 rfkill patches.

## Prerequisites

- Installed Ubuntu on Surface Pro 11, booting from internal NVMe.
- Temporary networking through USB-C Ethernet, USB phone tethering, or another
  non-Wi-Fi path.
- Secure Boot disabled.
- The direct live USB kept nearby as a recovery environment.
- At least 40 GB free disk space for the kernel source, build tree, and
  generated `.deb` packages.
- AC power connected. Kernel builds can take a long time.
- An older known-good qcom-x1e kernel still installed. Do not run
  `apt autoremove` before this experiment.

## Procedure

1. Mount the `SP11DATA` USB partition and enter the support directory.

```bash
SP11DEV="$(blkid -L SP11DATA)"
test -n "$SP11DEV" || { echo "SP11DATA partition not found."; exit 1; }
SP11DATA="$(findmnt -rn -S "$SP11DEV" -o TARGET | head -n 1)"
if [ -z "$SP11DATA" ]; then
  SP11DATA=/mnt/sp11data
  sudo mkdir -p "$SP11DATA"
  sudo mount "$SP11DEV" "$SP11DATA"
fi
cd "$SP11DATA/support"
```

2. Confirm the current failure mode.

```bash
sudo ./scripts/troubleshoot-sp11-wifi-rfkill.sh --try-unblock
```

Continue only if Wi-Fi is still hard-blocked and the ath12k module scan says
`disable-rfkill support not found`.

3. Build from the installed Ubuntu source package version.

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --install-deps \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build"
```

This can take hours. The helper writes a manifest at:

```text
$HOME/sp11-qcom-x1e-kernel-build/sp11-kernel-build-manifest.txt
```

If apt source download fails because source repositories are disabled, enable
source entries for the same Ubuntu/PPA repositories that provide the installed
qcom-x1e packages, run `sudo apt update`, and rerun the command. By default the
helper derives the source package and version from the running kernel packages,
starting with `linux-modules-$(uname -r)`. Use `--source-version candidate`
only when you intentionally want to build the apt source candidate instead.

4. Install the generated qcom-x1e kernel packages.

The helper can do this directly:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build" \
  --install-only
```

The helper refuses to install if it cannot find another installed qcom-x1e
kernel ABI to use as a GRUB fallback. Do not override that guard unless you are
comfortable recovering through the direct live USB:

```bash
./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$HOME/sp11-qcom-x1e-kernel-build" \
  --install-only \
  --allow-no-fallback
```

For debugging, inspect the generated package list before installing:

```bash
cat "$HOME/sp11-qcom-x1e-kernel-build/sp11-kernel-debs.txt"
```

Use `--install-only` for the actual install so the fallback-kernel guard and
post-install support helper run consistently.

5. Confirm GRUB still injects the Surface Pro 11 DTB.

```bash
grep -n "devicetree .*sp11-denali" /boot/grub/grub.cfg | head
```

For the verified separate `/boot` layout, the entries should use:

```text
devicetree /sp11-denali.dtb
```

6. Reboot and choose the patched kernel.

```bash
sudo reboot
```

If the patched kernel fails, use GRUB advanced options to boot an older
known-good qcom-x1e kernel such as the verified `7.0.0-22-qcom-x1e` entry, or
boot the direct live USB and rerun the installed support helper.

## Expected Output

The build should produce qcom-x1e kernel `.deb` packages under the selected
work directory, including image, modules, and headers packages.

After booting the patched kernel, `uname -r` may still show the same ABI string
as the source package because the local build can reinstall that ABI in place.
The important validation is whether the loaded ath12k module and device tree
now expose `disable-rfkill`.

## Validation

After reboot, rerun:

```bash
cd "$SP11DATA/support"
sudo ./scripts/troubleshoot-sp11-wifi-rfkill.sh --try-unblock
```

Passing validation for the patch experiment means:

- `DT has disable-rfkill`,
- `disable-rfkill support found in ...ath12k...`,
- Wi-Fi `phy0` no longer reports `Hard blocked: yes`.

That proves the rfkill gate moved. It does not prove Bluetooth, suspend,
touchscreen, audio, camera, or long-term Wi-Fi stability.

## Privacy and Safety

Do not commit generated kernel source trees, `.deb` packages, firmware files,
or logs containing local network configuration.

Keep the previous qcom-x1e kernel installed until the patched kernel has booted
and the rfkill result is known. Avoid `apt autoremove` during this experiment.

## Troubleshooting

If apt source download fails, enable matching source repositories for the
running qcom-x1e kernel source and rerun `sudo apt update`.

If a patch does not apply, stop and record the source package version. The
Ubuntu qcom-x1e source may have changed enough that the patch needs to be
refreshed.

If the build runs out of disk space, remove the work directory and rerun with a
larger filesystem:

```bash
rm -rf "$HOME/sp11-qcom-x1e-kernel-build"
```

If the patched kernel boots but Wi-Fi is still hard-blocked, save the full
troubleshooting output and compare the DT and ath12k support lines first.

## Related Documents

- [ADR018: Wi-Fi rfkill Bring-Up Gate](../adr/adr-0018-wifi-rfkill-bring-up-gate.md)
- [ADR019: Patched qcom-x1e Kernel for Wi-Fi rfkill](../adr/adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md)
- [Surface Pro 11 Wi-Fi rfkill test after qcom-x1e upgrade](../installed-wifi-rfkill-upgrade-test-20260613.md)
