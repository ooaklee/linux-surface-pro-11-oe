---
id: how-to-reinstall-patched-kernel-from-usb
title: "Reinstall the Patched Kernel from USB or a Release"
# prettier-ignore
description: How-to guide for validating, preflighting, and installing a Surface Pro 11 qcom-x1e kernel bundle with Lexr.sh.
---

# How To: Reinstall the Patched Kernel from USB or a Release

Last reviewed: 2026-08-31

Use the `lexr` companion to install one version-bound Surface Pro 11
kernel package set while retaining a known-good qcom-x1e fallback. The native
installer does not use repository scripts, install an out-of-tree touchscreen
bundle, change the default GRUB entry, or reboot the computer.

The current kernel contains the touchscreen drivers in-tree. Do not install an
old `sp11v3` bundle or copy separate `gpi.ko`, `spi-geni-qcom.ko`, or
`mshw0485_touch.ko` files into a current kernel.

## Prerequisites

- Root access for the final installation only.
- A Linux ARM64 `lexr` executable. A live image created with
  `--companion-source-dir` carries the compatibility executable at
  `/cdrom/sp11/companion/bin/linux-arm64/lexr`; an image built without
  that explicit option does not contain the companion.
- One coherent Surface `linux-image` and `linux-modules` package pair. Matching
  headers may be included as a pair.
- `SHA256SUMS` from the same release.
- A distinct, known-good qcom-x1e ABI already installed and available through
  GRUB.
- Recovery media kept available throughout testing.

If the image includes the companion, copy it to a writable path before running
it:

```bash
install -m 0755 \
  /cdrom/sp11/companion/bin/linux-arm64/lexr \
  /tmp/lexr
LEXR=/tmp/lexr
```

If `lexr` is already installed, use `LEXR=lexr` instead.

## 1. Obtain a verified bundle

### From a release with networking

List candidate releases, then download one exact package set:

```bash
"$LEXR" kernel release list

bundle_dir="$PWD/kernel-bundle"
"$LEXR" kernel release download "<release-tag>" \
  --output-dir "$bundle_dir" \
  --headers
```

Without `--repository`, both commands use the established
[`ooaklee/linux-surface-pro-11-oe` release channel](https://github.com/ooaklee/linux-surface-pro-11-oe/releases).
Use `--repository <owner/name>` only for an explicitly reviewed compatible
alternative. Lexr's own release page contains CLI binaries and their checksum
manifest, not kernel or device-support assets.

The download command requires the selected packages to be covered by that
release's `SHA256SUMS`, verifies their bytes, and writes the normal kernel
bundle manifest atomically. Omit `--headers` when development headers are not
needed.

For a release prepared with the current native release contract, downloading
every published asset into a new empty directory permits the stronger
closed-directory check:

```bash
complete_release_dir="$PWD/complete-kernel-release"
# Download every published asset into "$complete_release_dir" first.
"$LEXR" kernel release validate "$complete_release_dir"
```

That check also verifies corresponding source, explicit licence evidence,
public provenance, generated notes, and exact directory membership. It is
stricter than the package-only download operation.

### From offline USB storage

Copy the release's package files and `SHA256SUMS` into one writable directory.
Do not mix files from two releases:

```bash
bundle_dir="$PWD/kernel-bundle"
mkdir "$bundle_dir"
cp /path/to/offline-release/linux-*.deb "$bundle_dir/"
cp /path/to/offline-release/SHA256SUMS "$bundle_dir/"
```

Inspect the local pair before any privileged action:

```bash
"$LEXR" kernel inspect "$bundle_dir"
```

## 2. Identify the fallback ABI

The fallback must be a different installed Surface qcom-x1e kernel. If the
currently running kernel is the fallback, record it directly:

```bash
fallback_abi="$(uname -r)"
printf '%s\n' "$fallback_abi"
```

Do not use a generic distribution ABI as a substitute. The preflight refuses
to continue unless it can verify the selected fallback's kernel, modules,
device trees, initramfs, and GRUB evidence beneath the explicit target root.

## 3. Run the read-only preflight

```bash
"$LEXR" kernel preflight "$bundle_dir" \
  --root / \
  --fallback-abi "$fallback_abi"
```

Review the target ABI, package count, device-tree count, checksum status, and
planned commands. Preflight makes no changes. Use `--json` when retaining a
machine-readable plan.

If preflight reports missing fallback evidence, stop and restore or install a
known-good qcom-x1e kernel first. The CLI deliberately has no option to waive
that guard on the live root.

## 4. Rehearse the installation

```bash
"$LEXR" kernel install "$bundle_dir" \
  --root / \
  --fallback-abi "$fallback_abi" \
  --dry-run
```

This repeats complete preflight through the installation entry point without
running package-manager or bootloader commands.

## 5. Install the reviewed bundle

Run the same request with explicit confirmation and the privilege already
obtained by the caller:

```bash
sudo "$LEXR" kernel install "$bundle_dir" \
  --root / \
  --fallback-abi "$fallback_abi" \
  --yes
```

The manager stages immutable package copies, installs the coherent set,
verifies the packaged Denali device trees, updates initramfs and GRUB through
fixed argument-separated commands, and rechecks the fallback. A failed
transaction returns rollback evidence. It does not select the new kernel as
the default and does not reboot.

## 6. Reboot manually and diagnose

Keep the fallback selected until the new ABI has been exercised. When ready:

```bash
sudo reboot
```

After boot, record the active ABI and run the read-only hardware checks:

```bash
uname -r
lexr doctor hardware
lexr doctor userspace
```

Structural success does not prove cold boot, suspend, pen, touch, Wi-Fi,
Bluetooth, camera, or audio behaviour. Retain the fallback kernel and recovery
media until those checks pass on the actual Surface. These device exercises are
an intentional physical qualification boundary and are not capabilities
claimed by the CLI.

## Alternate roots

For an offline mounted Linux root, pass its absolute path with `--root`. The
optional `--running-abi` flag is accepted only for an alternate-root fixture;
it cannot override live `uname` evidence for `/`.

## Related Documents

- [Prepare and validate kernel release artefacts](how-to-release-kernel-artifacts.md)
- [Build a patched qcom-x1e kernel](how-to-build-patched-qcom-x1e-kernel.md)
- [ADR016: Native kernel release preparation and v3 retirement](https://github.com/ooaklee/lexr.sh/blob/main/docs/adr/adr-016-native-kernel-release-preparation.md)
