---
id: how-to-reinstall-patched-kernel-from-usb
title: "Reinstall the Patched Kernel from USB or GitHub Releases"
# prettier-ignore
description: How-to guide for installing or reinstalling a Surface Pro 11 qcom-x1e kernel bundle from the live-USB payload or verified GitHub Release assets.
---

# How To: Reinstall the Patched Kernel from USB or GitHub Releases

Use this procedure after Ubuntu `apt` or an official kernel package has
displaced a Surface Pro 11-specific qcom-x1e kernel, or when installing a
downloaded kernel bundle for the first time. Release families differ: the
historical 7.0 build applied two local ath12k rfkill patches, while the current
`sp11v3` build starts from an immutable Johan G. kernel tag and adds the SP11
build-policy, 2.4 MHz DMIC, touchscreen device-tree, and exact-ABI module work.

## Purpose

Replacing an SP11-specific kernel can regress the Denali Wi-Fi, DMIC-clock, or
touchscreen path, depending on the stock kernel version. For `sp11v3`, the four
kernel packages and three touchscreen modules form one exact-ABI transaction;
installing only the `.deb` files does not provide a working touchscreen.

This procedure gets the pre-built patched kernel `.deb` files onto the Surface
and reinstalls them — no Docker build required. The packages can come from the
live USB payload **or** from the GitHub releases page; both install exactly the
same way.

## Prerequisites

- Root access on the Surface Pro 11.
- The patched kernel `.deb` packages, from one of the sources below.
- For an `sp11v3` touchscreen kernel, the complete release asset set, including
  its matching `gpi.ko`, `spi-geni-qcom.ko`, and `mshw0485_touch.ko` files,
  provenance manifest, and `SHA256SUMS`.
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

Browse the releases page and select the intended patched-kernel tag:

```
https://github.com/ooaklee/linux-surface-pro-11-oe/releases
```

The corrective v3 prerelease is
[`sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1`](https://github.com/ooaklee/linux-surface-pro-11-oe/releases/tag/sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1)
(experimental). The removed unsuffixed v3 tag is retired and must not be
reused.

For `sp11v3`, download the complete published asset set into a new directory,
fetch the release tag into the local repository, and run the semantic release
validator before installation:

```bash
TAG=sp11-qcom-x1e-7.2-rc5-jg-0sp11v3-r1
DEBS="$HOME/sp11-kernel-debs-$TAG"
mkdir -p "$DEBS"

gh release download "$TAG" \
  --repo ooaklee/linux-surface-pro-11-oe \
  --dir "$DEBS"

cd /path/to/linux-surface-pro-11-oe
git fetch https://github.com/ooaklee/linux-surface-pro-11-oe.git \
  "refs/tags/$TAG:refs/tags/$TAG"

./scripts/validate-sp11-touchscreen-release.sh \
  --dir "$DEBS" \
  --tag "$TAG" \
  --remote https://github.com/ooaklee/linux-surface-pro-11-oe.git
```

The validator checks exact checksum and asset membership, package roles and
ABI, module provenance and vermagic, the touchscreen device tree, and both the
local and remote tag targets. Without `gh`, download every asset listed on the
release page into one empty directory, fetch the tag as above, and run the same
validator.

For an older non-touchscreen release, downloading only its `.deb` files and
`SHA256SUMS` is sufficient for installation. In that narrower case,
`sha256sum -c SHA256SUMS --ignore-missing` verifies the downloaded packages but
does not validate the release's complete asset set.

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

- refuses to install unless another `qcom-x1e` kernel ABI is present as a GRUB
  fallback (pass `--allow-no-fallback` only if you accept live-USB recovery as
  your fallback). A genuinely fresh install that has only generic Ubuntu
  kernels (for example `7.0.0-32`/`7.0.0-22`, not a `-qcom-x1e` flavour) has
  no qualifying fallback and must pass `--allow-no-fallback`,
- installs the kernel `.deb` packages with `apt`, then
- runs `install-sp11-support.sh --installed-system`, which re-selects the
  rfkill-capable Denali OLED DTB and re-injects it into GRUB and initramfs, and
- for `sp11v3`, refuses a missing or mismatched three-module touchscreen bundle
  before package installation, then installs and verifies it in the exact
  target initramfs.

For `sp11v3`, the touchscreen installer also **repairs** a stale initramfs that
still embeds the stock in-tree `gpi`/`spi-geni-qcom` modules: it diverts (or
removes) the stock copies, runs `depmod`, rebuilds the initramfs, and verifies
that only the `updates/` overrides remain. See
[ADR-0053](../adr/adr-0053-sp11-touchscreen-stale-initramfs-repair.md).

> **The r1 release tags bundle the pre-repair installer**, which detects the
> stale stock modules and then refuses with
> `initramfs also contains a stock/duplicate`. If you hit that, either use a
> checkout of `main` (which includes the repair) or repair manually before
> re-running the touchscreen step:
>
> ```bash
> REL=7.2-rc5-jg-0sp11v3-qcom-x1e
> sudo rm -f /lib/modules/$REL/kernel/drivers/dma/qcom/gpi.ko*
> sudo rm -f /lib/modules/$REL/kernel/drivers/spi/spi-geni-qcom.ko*
> sudo depmod -a $REL
> sudo update-initramfs -u -k $REL
> ```

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

Do not use this fallback for an `sp11v3` touchscreen release: direct `dpkg`
does not install or verify the required out-of-tree module bundle. Obtain the
repository checkout and use the guarded flow above.

If you only have the `.deb` files and not a checkout of this repo, install them
directly only for a kernel-only release. This skips the fallback-kernel guard,
so make sure a known-good qcom-x1e kernel is still installed first:

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
# 7.2-rc5-jg-0sp11v3-qcom-x1e
```

For an `sp11v3` kernel, also verify the complete touchscreen boot path:

```bash
sudo ./scripts/troubleshoot-sp11-touchscreen.sh
```

## Privacy and Safety

The release manifest records the source family, immutable source commit,
applied project patches, and module provenance for that specific bundle. The
v3 release is built from the Johan G. 7.2-rc5 tag with the SP11 DMIC and
touchscreen changes; it is not the historical Ubuntu 7.0 two-patch build. No
device-specific data is included. Every kernel release is **experimental and
unsigned** — validate the published asset set before installing, and keep a
known-good qcom-x1e fallback kernel installed so the GRUB fallback guard can
protect the boot path.

## Related

- [Build a Patched qcom-x1e Kernel](how-to-build-patched-qcom-x1e-kernel.md) —
  full Docker build from source, and the `--install-only` payload install.
- [Wi-Fi RFkill Bring-Up Gate](/docs/adr/adr-0018-wifi-rfkill-bring-up-gate.md) —
  explanation of the hard-block issue.
