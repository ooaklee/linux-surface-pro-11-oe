---
id: how-to-reinstall-patched-kernel-from-usb
title: "Reinstall the Patched Kernel from USB or GitHub Releases"
# prettier-ignore
description: How-to guide for reinstalling the patched qcom-x1e kernel over a stock Ubuntu kernel that lacks ath12k disable-rfkill support, using either the live-USB payload or the GitHub release .deb packages.
---

# How To: Reinstall the Patched Kernel from USB or GitHub Releases

Use this procedure after Ubuntu `apt` or an official kernel package has
overwritten the patched qcom-x1e kernel. The patched kernel carries two
patches (`0001` and `0002` from `patches/ubuntu-qcom-x1e-7.0/`) that skip
ath12k rfkill configuration on Denali, resolving the intermittent WCN7850
Wi-Fi hard-block.

## Purpose

Ubuntu ships a stock `linux-image-*-qcom-x1e` kernel that does not include
`disable-rfkill` support for the Denali WCN7850 devicetree node. When a kernel
update or reinstall replaces the patched kernel, Wi-Fi may reappear
hard-blocked (`rfkill list` shows `Hard blocked: yes` for `phy0`).

This procedure gets the pre-built patched kernel `.deb` files onto the Surface
and reinstalls them — no Docker build required. The packages can come from the
live USB payload **or** from the GitHub releases page; both install exactly the
same way.

## Prerequisites

- Root access on the Surface Pro 11.
- The patched kernel `.deb` packages, from one of the sources below.
- A checkout of this repository on the Surface — either the live USB
  `SP11DATA/support` directory, or a `git clone` — so the guarded installer and
  its post-install support helper are available.
- A known-good qcom-x1e kernel already installed as a GRUB fallback. The
  installer refuses to proceed without one (so a bad kernel cannot leave the
  device unbootable).

## 1. Get the kernel packages

Pick whichever source is available and point `DEBS` at the directory that holds
the kernel `.deb` files — three for a standard qcom-x1e build, four for the
jglathe tree (7.1.1+), which adds a `linux-qcom-x1e-headers-*_all.deb` common
headers package. The install step in section 2 is identical either way; the
guarded installer accepts either payload.

**Option A — from the live USB (SP11DATA partition):**

The build copies the packages to `payload/kernel-debs/` on the data partition.

```bash
# Mount the USB data partition if it is not already mounted:
SP11DEV="$(blkid -L SP11DATA)"
SP11DATA="$(findmnt -rn -S "$SP11DEV" -o TARGET | head -n1)"
if [ -z "$SP11DATA" ]; then
  SP11DATA=/mnt/sp11data
  sudo mkdir -p "$SP11DATA"
  sudo mount "$SP11DEV" "$SP11DATA"
fi

DEBS="$SP11DATA/payload/kernel-debs"
ls "$DEBS"/linux-*.deb
```

**Option B — from GitHub releases (Surface has Wi-Fi, Ethernet, or tethering):**

Browse the releases page and pick the newest patched-kernel tag:

```
https://github.com/ooaklee/linux-surface-pro-11-oe/releases
```

At the time of writing the current tag is
`sp11-qcom-x1e-7.0.0-22.22-rfkill1`. Download the kernel `.deb` packages plus
the `SHA256SUMS` file into a working directory. With the GitHub CLI:

```bash
DEBS=~/sp11-kernel-debs
TAG=sp11-qcom-x1e-7.0.0-22.22-rfkill1

gh release download "$TAG" \
  --repo ooaklee/linux-surface-pro-11-oe \
  --pattern 'linux-*.deb' \
  --pattern 'SHA256SUMS' \
  --dir "$DEBS"
```

Or, without `gh`, download each asset with `wget` (replace the tag if newer):

```bash
DEBS=~/sp11-kernel-debs
mkdir -p "$DEBS" && cd "$DEBS"
BASE=https://github.com/ooaklee/linux-surface-pro-11-oe/releases/download/sp11-qcom-x1e-7.0.0-22.22-rfkill1
wget "$BASE/linux-headers-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64.deb"
wget "$BASE/linux-image-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64.deb"
wget "$BASE/linux-modules-7.0.0-22-qcom-x1e_7.0.0-22.22_arm64.deb"
wget "$BASE/SHA256SUMS"
```

Verify the downloads before installing:

```bash
cd "$DEBS"
sha256sum -c SHA256SUMS --ignore-missing
# Expect: each linux-*.deb line printed as "OK"
```

## 2. Install the patched kernel

Run the guarded installer from your repository checkout, pointing `--work-dir`
at the `$DEBS` directory from section 1. This is the same command for both the
USB and the GitHub packages.

```bash
# From the USB checkout:   cd "$SP11DATA/support"
# From a git clone:        cd /path/to/linux-surface-pro-11-oe
cd "$SP11DATA/support"

./scripts/build-sp11-qcom-x1e-kernel.sh \
  --work-dir "$DEBS" \
  --install-only
```

`--install-only`:

- refuses to install unless another qcom-x1e kernel ABI is present as a GRUB
  fallback (pass `--allow-no-fallback` only if you accept live-USB recovery as
  your fallback),
- installs the kernel `.deb` packages with `apt`, then
- runs `install-sp11-support.sh --installed-system`, which re-selects the
  rfkill-capable Denali OLED DTB and re-injects it into GRUB and initramfs.

It elevates with `sudo` as needed. If `--work-dir` points to a directory under
your home (e.g. `~/Downloads`), you may see a harmless `_apt` sandbox warning:
`pkgAcquire::Run (13: Permission denied)`. apt falls back to running as root
and the install completes normally. The DTB `postrm`/`postinst` hooks also run
automatically during the `dpkg` step:

```
Setting up linux-image-7.0.0-22-qcom-x1e (7.0.0-22.22) ...
/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb:
Using Surface Pro 11 DTB: /usr/lib/firmware/7.0.0-22-qcom-x1e/device-tree/qcom/x1e80100-microsoft-denali-oled.dtb
Injected Surface Pro 11 DTB into /boot/grub/grub.cfg
...
Found installed fallback qcom-x1e kernel ABI: 7.0.0-32-qcom-x1e
Installed Surface Pro 11 support helpers into /
```

### Minimal fallback (no repository checkout)

If you only have the `.deb` files and not a checkout of this repo, install them
directly. This skips the fallback-kernel guard, so make sure a known-good
qcom-x1e kernel is still installed first:

```bash
sudo dpkg -i "$DEBS"/linux-*.deb
```

The Denali DTB is re-injected automatically by the
`/etc/kernel/postinst.d/zzzz-surface-pro-11-dtb` hook that the support setup
installed on first boot — you will see `Injected Surface Pro 11 DTB into
/boot/grub/grub.cfg` in the output. If that hook is missing, install it by
running `./scripts/install-sp11-support.sh --installed-system` from a repository
checkout.

## 3. Reboot

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

The GitHub release ships the standard Ubuntu kernel binaries with two small
open-source patches applied; no device-specific data is included. The release
is **experimental and unsigned** — verify each package against the published
`SHA256SUMS` before installing (section 1), and keep a known-good qcom-x1e
fallback kernel installed so the GRUB fallback guard can protect the boot path.

## Related

- [Build a Patched qcom-x1e Kernel](how-to-build-patched-qcom-x1e-kernel.md) —
  full Docker build from source, and the `--install-only` payload install.
- [Wi-Fi RFkill Bring-Up Gate](/docs/adr/adr-0018-wifi-rfkill-bring-up-gate.md) —
  explanation of the hard-block issue.
