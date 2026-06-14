---
id: how-to-reinstall-patched-kernel-from-usb
title: "Reinstall the Patched Kernel from USB or GitHub Releases"
# prettier-ignore
description: How-to guide for reinstalling the patched qcom-x1e kernel over a stock Ubuntu kernel that lacks ath12k disable-rfkill support.
---

# How To: Reinstall the Patched Kernel from USB or GitHub Releases

Use this procedure after Ubuntu `apt` or an official kernel package has
overwritten the patched qcom-x1e kernel. The patched kernel carries two
patches (`0001` and `0002` from `patches/ubuntu-qcom-x1e-7.0/`) that
skip ath12k rfkill configuration on Denali, resolving the intermittent
WCN7850 Wi-Fi hard-block.

## Purpose

Ubuntu ships a stock `linux-image-*-qcom-x1e` kernel that does not include
`disable-rfkill` support for the Denali WCN7850 devicetree node. When a
kernel update or reinstall replaces the patched kernel, Wi-Fi may reappear
hard-blocked (`rfkill list` shows `Hard blocked: yes` for `phy0`).

This procedure gets the pre-built patched kernel `.deb` files onto the
Surface and reinstalls them — no Docker build required.

## Prerequisites

- Root access on the Surface Pro 11.
- The live USB (SP11DATA partition) inserted in the Surface, or network
  access to download from GitHub releases.
- A known-good patched kernel version that matches (or is newer than) the
  currently installed stock kernel.

## Obtaining the debs

Choose one of:

**Option A — from the USB data partition (if you pre-staged them):**

```bash
ls /mnt/sp11data/support/kmod/linux-*.deb
```

**Option B — download from GitHub releases (Surface has Wi-Fi or Ethernet):**

```
https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.0.0-22.22-rfkill1
```

Download the three `.deb` packages to `~/Downloads`:

```bash
cd ~/Downloads
# Download linux-headers-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64.deb
# Download linux-image-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64.deb
# Download linux-modules-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64.deb
```

## Procedure

### 1. Install the patched kernel debs

```bash
sudo dpkg -i linux-*.deb
```

Expected output (the DTB postrm/postinst hooks run automatically):

```
Preparing to unpack linux-headers-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64.deb ...
Unpacking linux-headers-7.0.0-22-qcom-x1e (7.0.0-22.22) over (7.0.0-22.22) ...
Preparing to unpack linux-image-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64.deb ...
Unpacking linux-image-7.0.0-22-qcom-x1e (7.0.0-22.22) over (7.0.0-22.22) ...
/etc/kernel/postrm.d/zzzz-surface-pro-11-dtb:
Using Surface Pro 11 DTB: /usr/lib/firmware/7.0.0-22-qcom-x1e/device-tree/qcom/x1e80100-microsoft-denali-oled.dtb
Injected Surface Pro 11 DTB into /boot/grub/grub.cfg
Preparing to unpack linux-modules-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64.deb ...
Unpacking linux-modules-7.0.0-22-qcom-x1e (7.0.0-22.22) over (7.0.0-22.22) ...
Setting up linux-headers-7.0.0-22-qcom-x1e (7.0.0-22.22) ...
Setting up linux-modules-7.0.0-22-qcom-x1e (7.0.0-22.22) ...
Setting up linux-image-7.0.0-22-qcom-x1e (7.0.0-22.22) ...
Processing triggers for linux-image-7.0.0-22-qcom-x1e (7.0.0-22.22) ...
/etc/kernel/postinst.d/dracut:
dracut: Generating /boot/initrd.img-7.0.0-22-qcom-x1e
/etc/kernel/postinst.d/zz-update-grub:
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-7.0.0-22-qcom-x1e
Found initrd image: /boot/initrd.img-7.0.0-22-qcom-x1e
done
/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb:
Using Surface Pro 11 DTB: /usr/lib/firmware/7.0.0-22-qcom-x1e/device-tree/qcom/x1e80100-microsoft-denali-oled.dtb
Injected Surface Pro 11 DTB into /boot/grub/grub.cfg
```

### 2. Re-run the installed-system support script

This ensures the Wi-Fi board fixup and rfkill unblock helper are in place,
and re-injects the Denali DTB into GRUB and initramfs:

```bash
sudo /mnt/sp11data/support/scripts/install-sp11-support.sh --installed-system
```

With the USB not inserted, run from the installed copy:

```bash
sudo /usr/local/sbin/finish-sp11-installed-system
```

Expected output:

```
Generating grub configuration file ...
Found linux image: /boot/vmlinuz-7.0.0-22-qcom-x1e
Found initrd image: /boot/initrd.img-7.0.0-22-qcom-x1e
done
Using Surface Pro 11 DTB: /usr/lib/firmware/7.0.0-22-qcom-x1e/device-tree/qcom/x1e80100-microsoft-denali-oled.dtb
Injected Surface Pro 11 DTB into /boot/grub/grub.cfg
update-initramfs: Generating /boot/initrd.img-7.0.0-22-qcom-x1e
Installed Surface Pro 11 support helpers into /
```

### 3. Reboot

```bash
sudo reboot
```

## Validation

After reboot, confirm Wi-Fi is no longer hard-blocked:

```bash
rfkill list
```

Expected output for `phy0`:

```
1: phy0: Wireless LAN
    Soft blocked: no
    Hard blocked: no
```

Verify the running kernel:

```bash
uname -r
# 7.0.0-22-qcom-x1e
```

## Privacy and Safety

The GitHub release ships the standard Ubuntu kernel binaries with two
small open-source patches applied. No device-specific data is included.
The `.deb` packages are signed with the Ubuntu kernel signing key.

## Related

- [Build a Patched qcom-x1e Kernel](how-to-build-patched-qcom-x1e-kernel.md) —
  full Docker build from source.
- [Wi-Fi RFkill Bring-Up Gate](/docs/adr/adr-0018-wifi-rfkill-bring-up-gate.md) —
  explanation of the hard-block issue.
