---
id: how-to-download-and-install-released-kernel-and-userspace
title: "Download and Install a Released Kernel and Userspace"
# prettier-ignore
description: How-to guide for downloading an exact released Surface Pro 11 kernel, retaining a bootable fallback, and installing its audited userspace support with Lexr.
---

# How To: Download and Install a Released Kernel and Userspace

Last reviewed: 2026-09-01

Use this guide to install an exact kernel release from the OE release channel,
keep the running kernel as a recovery path, and add the matching audited
userspace support. [Install Lexr on the device](https://github.com/ooaklee/lexr.sh/blob/main/docs/getting-started/install.md)
before starting this procedure.

## Before you begin

This procedure is for an installed Surface Pro 11 system running Debian or
Ubuntu. The target needs `apt-get`, `dpkg`, `dpkg-deb`, `update-initramfs`, and
the normal GRUB package hooks. Read the release notes for the installed Lexr
version because documentation on `main` can describe newer behaviour.

Resolve the executable once so the read-only checks and privileged operations
use the same reviewed binary:

```sh
LEXR="$(command -v lexr)"
"$LEXR" version
```

> [!WARNING]
> Released project kernels remain experimental and unsigned. Back up important
> data, keep a separate bootable recovery device, disable Secure Boot, and boot
> the existing Surface kernel successfully before treating it as the fallback.

The fallback must be the currently running, complete `-qcom-x1e` ABI, distinct
from the release being installed, with a usable module tree and GRUB entry.
Lexr rejects an incomplete fallback and a target ABI which already has kernel,
module, header, or GRUB state on the target.

## Download an exact kernel release

List the non-draft releases which contain a candidate image and modules pair,
then copy one exact tag into `KERNEL_REF`. An exact tag is reproducible;
`latest` can resolve to a different release later.

Choose a bundle path which has not held another download:

```sh
"$LEXR" kernel release list

KERNEL_REF="<exact-tag-shown-by-the-list>"
KERNEL_BUNDLE="$PWD/kernel-bundle"
RUNNING_ABI="$(uname -r)"

"$LEXR" kernel release download "$KERNEL_REF" \
  --headers \
  --output-dir "$KERNEL_BUNDLE"
```

Replace the angle-bracket placeholder with the tag exactly as listed. The
download verifies the release checksum manifest and records a local bundle
manifest. `--headers` selects both matching development-header packages; omit
it for a runtime-only image and modules installation.

## Preflight the kernel installation

Run the read-only preflight and dry run as your regular user:

```sh
"$LEXR" kernel preflight "$KERNEL_BUNDLE" \
  --root / \
  --fallback-abi "$RUNNING_ABI"

"$LEXR" kernel install "$KERNEL_BUNDLE" \
  --root / \
  --fallback-abi "$RUNNING_ABI" \
  --dry-run
```

Check the target root, new ABI, package set, initramfs and GRUB operations, and
retained fallback in the plan. These checks do not modify the system and do
not constitute physical hardware qualification.

Do not pass `--allow-unverified` to preflight or install to bypass a missing or
invalid checksum manifest for a published release.

## Install the kernel

Install only after the complete dry run is acceptable. Lexr never elevates
itself, so grant privilege only to the confirmed operation:

```sh
sudo "$LEXR" kernel install "$KERNEL_BUNDLE" \
  --root / \
  --fallback-abi "$RUNNING_ABI" \
  --yes
```

The real installation repeats preflight immediately before mutation, retains
the fallback, backs up GRUB, and verifies the installed package and boot state.
Keep the printed receipt. A failure triggers a bounded rollback attempt, but
the receipt may still require recovery action if rollback cannot finish.

Lexr does not reboot or explicitly select the default kernel. Package hooks
regenerate the normal GRUB configuration. When you are ready to test, reboot
through the normal system controls and select the new ABI deliberately. Keep
the fallback installed until the new kernel has passed the required boot and
hardware checks.

## Check userspace support

Inspect the complete system, then focus on the supported audio and IPTSD
features:

```sh
"$LEXR" doctor userspace

"$LEXR" userspace status \
  --feature audio \
  --feature iptsd
```

For automation, request JSON and inspect both its contents and the command's
exit status:

```sh
"$LEXR" userspace status --json
```

These commands perform a static, point-in-time inspection. They do not run
services, probe physical hardware, contact the network, or change the target.
An unfiltered report fails only for catalogue-required support. Explicitly
selected supported or experimental features also affect the exit status.

When more than one Surface ABI is installed and the active kernel pairing
matters, select it explicitly with `--kernel "$(uname -r)"`.

## Pull and install recommended userspace releases

The catalogue embedded in the recorded Lexr version resolves `recommended` to
the audited audio and IPTSD releases. It does not include platform firmware,
Bluetooth evidence, or camera support. Use a fresh cache root:

```sh
USERSPACE_CACHE="$PWD/lexr-userspace"

"$LEXR" userspace pull recommended \
  --cache-dir "$USERSPACE_CACHE"

"$LEXR" userspace install recommended \
  --from "$USERSPACE_CACHE" \
  --dry-run

sudo "$LEXR" userspace install recommended \
  --from "$USERSPACE_CACHE" \
  --yes
```

The dry run verifies both component bundles before mutation. The real install
applies components sequentially rather than as one cross-component atomic
transaction, so keep every receipt and follow any partial-result or reboot
instruction printed by Lexr. Userspace installation does not remove recognised
legacy workarounds implicitly.

After installation, and after rebooting when requested, check the active
kernel pairing again:

```sh
ACTIVE_ABI="$(uname -r)"
"$LEXR" doctor userspace --kernel "$ACTIVE_ABI"
```

Confirm that `uname -r` reports the ABI you intended to boot. A passing static
report is not a substitute for testing audio, touch, pen, suspend, and other
required hardware on the same device.

## Keep restricted and experimental support separate

Restricted platform firmware and the Bluetooth public-address evidence cannot
be pulled from the OE release channel. Acquire those only through Lexr's
[private same-device Windows hand-off](https://github.com/ooaklee/lexr.sh/blob/main/docs/user-guide/windows-handoff.md).
Hand-off contents are private device data and must not be committed, attached
to issues, published in releases, included in images, or placed in ordinary
support reports.

Camera support is experimental and is never part of `recommended`. Opt in to
its separate verified download only when you intend to follow the camera
qualification path:

```sh
"$LEXR" userspace pull camera \
  --cache-dir "$USERSPACE_CACHE"
```

Pulling a camera release does not install it. Follow the current
[Lexr userspace guide](https://github.com/ooaklee/lexr.sh/blob/main/docs/user-guide/userspace-support.md)
for its separate installation authority and compatibility requirements.

## Recover

If the new kernel does not boot or fails its device checks, select the retained
fallback ABI from GRUB. Keep the kernel and userspace receipts, bundle, cache,
and recovery device until the system has passed the intended qualification.
For an installed system which needs repair from removable media, follow
[Reinstall a Patched Kernel from USB](how-to-reinstall-patched-kernel-from-usb.md).

## Related guidance

- [Use Lexr from the OE Repository](how-to-use-lexr.md)
- [Lexr kernel management](https://github.com/ooaklee/lexr.sh/blob/main/docs/operator-manual/kernel-management.md)
- [Lexr userspace support](https://github.com/ooaklee/lexr.sh/blob/main/docs/user-guide/userspace-support.md)
- [Install Lexr](https://github.com/ooaklee/lexr.sh/blob/main/docs/getting-started/install.md)
