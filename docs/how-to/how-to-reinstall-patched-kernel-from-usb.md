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

- refuses to install unless another qcom-x1e kernel ABI is present as a GRUB
  fallback (pass `--allow-no-fallback` only if you accept live-USB recovery as
  your fallback),
- validates any required touchscreen bundle before changing the target,
- runs `install-sp11-support.sh --retire-loose-dtb-only` before package
  installation, removing the three project-managed loose-DTB artifacts and
  requiring a successful live-root `update-grub`,
- installs the kernel `.deb` packages with `apt` only after that retirement
  succeeds,
- runs the full `install-sp11-support.sh --installed-system` flow and requires
  its final live-root GRUB regeneration to succeed, and
- for `sp11v3`, refuses a missing or mismatched three-module touchscreen bundle
  and then installs and verifies it in the exact target initramfs.

It elevates with `sudo` as needed. If `--work-dir` points to a directory under
your home (e.g. `~/Downloads`), you may see a harmless `_apt` sandbox warning:
`pkgAcquire::Run (13: Permission denied)`. apt falls back to running as root
and the install completes normally. Retirement must happen before `apt` because
a legacy kernel post-install hook could otherwise run during package setup and
rewrite generated GRUB configuration before the new installer removes it. Any
initial retirement or GRUB-regeneration failure aborts before package
installation. A failure in the full installer's final GRUB pass also fails the
transaction instead of reporting success.

On the tested installed qcom-x1e Stubble path, each kernel uses the Denali DTB
embedded in its exact Stubble-wrapped EFI image. The support installer does
not select, copy, or inject a shared loose DTB. If
`/boot/sp11-denali.dtb` exists from an earlier release, it is left untouched
as inert recovery evidence; its presence or contents do not establish
live-FDT provenance.

### Minimal fallback (no repository checkout)

Do not use this fallback for an `sp11v3` touchscreen release: direct `dpkg`
does not install or verify the required out-of-tree module bundle. Obtain the
repository checkout and use the guarded flow above.

If you only have the `.deb` files and not a checkout of this repo, direct
`dpkg` is allowed only for a kernel-only release and only after verifying that
all three former managed artifacts are absent. This skips the fallback-kernel
guard, so first make sure a known-good qcom-x1e kernel is still installed:

```bash
for path in \
  /usr/local/sbin/sp11-grub-inject-dtb \
  /etc/kernel/postinst.d/zzzz-surface-pro-11-dtb \
  /etc/kernel/postrm.d/zzzz-surface-pro-11-dtb
do
  if sudo test -e "$path" || sudo test -L "$path"; then
    echo "Refusing direct dpkg while legacy managed artifact exists: $path" >&2
    exit 1
  fi
done

sudo dpkg -i "$DEBS"/linux-*.deb
```

On a legacy system where any managed artifact exists, do not run `dpkg` first.
Obtain the current repository and use the guarded flow above, or run the
reviewed retirement step and require it to succeed before package setup:

```bash
sudo ./scripts/install-sp11-support.sh --retire-loose-dtb-only
```

The reviewed retirement is preferred even when the three artifacts appear
absent because it also regenerates GRUB and fails closed. Direct `dpkg` does
not install or restore a loose-DTB injector. Do not treat an existing
`/boot/sp11-denali.dtb` as a fallback or as evidence of the active device tree.

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
- [Wi-Fi RFkill Bring-Up Gate](../adr/adr-0018-wifi-rfkill-bring-up-gate.md) —
  explanation of the hard-block issue.
