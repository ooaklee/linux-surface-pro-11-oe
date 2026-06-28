---
id: adr-0037-jglathe-qcom-7-1-1-stubble-paths
title: "ADR0037: Packaged Stubble Paths for Johan G. qcom-x1e 7.1.1"
# prettier-ignore
description: Architecture Decision Record (ADR) for patching Johan G.'s qcom-x1e 7.1.1 Ubuntu packaging to use the stubble paths provided by Ubuntu 26.04 packages.
---

# ADR0037: Packaged Stubble Paths for Johan G. qcom-x1e 7.1.1

## Status

Accepted — required for the `jg/ubuntu-qcom-x1e-7.1.1-jg-0` Docker build
path (2026-06-27).

## Context

The Surface Pro 11 bring-up can build Johan G.'s qcom-x1e 7.1.1 kernel tree
using this repository's Docker kernel builder:

```bash
./scripts/build-sp11-qcom-x1e-kernel-docker.sh \
  --source git \
  --git-url https://github.com/jglathe/linux_ms_dev_kit.git \
  --git-branch jg/ubuntu-qcom-x1e-7.1.1-jg-0 \
  --image ubuntu:26.04 \
  --patch-dir patches/jglathe-qcom-x1e-7.1.1 \
  --work-dir build/docker-sp11-qcom-x1e-kernel-jg-7.1.1 \
  --copy-to-payload \
  --reset-source
```

That source tag already carries the Surface Pro 11 `disable-rfkill` kernel
and Denali DTB changes, so the normal rfkill patches are not needed for this
path.

The qcom-x1e 7.1.1 packaging enables `do_stubble=true` for ARM64. During
`stamp-install-qcom-x1e`, the packaging calls `ukify` to assemble a
kernel-plus-stub EFI image with Stubble device-tree metadata.

The upstream packaging hardcodes:

```text
--stub=/usr/local/lib/stubble/stubble.efi
--hwids=/usr/local/share/stubble/hwids
--sbat=@/usr/share/stubble/sbat
```

In the Ubuntu 26.04 Docker container, the `stubble` package provides:

```text
/usr/lib/stubble/stubble.efi
/usr/share/stubble/hwids
/usr/share/stubble/sbat
```

The build therefore failed late in package assembly with:

```text
FileNotFoundError: [Errno 2] No such file or directory:
'/usr/local/share/stubble/hwids'
```

## Decision

Carry a Johan G. qcom-x1e 7.1.1-specific packaging patch:

```text
patches/jglathe-qcom-x1e-7.1.1/0002-debian-qcom-x1e-use-packaged-stubble-paths.patch
```

The patch changes only the Stubble paths in `debian/rules.d/2-binary-arch.mk`:

```diff
--- --stub=/usr/local/lib/stubble/stubble.efi
+++ --stub=/usr/lib/stubble/stubble.efi
--- --hwids=/usr/local/share/stubble/hwids
+++ --hwids=/usr/share/stubble/hwids
```

The SBAT path already points at `/usr/share/stubble/sbat`, so it remains
unchanged.

## Consequences

The Docker build uses the files installed by Ubuntu's `stubble` package
instead of relying on locally installed `/usr/local` copies.

This keeps the fix scoped to the Johan G. 7.1.1 path through `--patch-dir
patches/jglathe-qcom-x1e-7.1.1`; it does not change the default Ubuntu concept
git fallback or apt-source kernel builds.

If a future Johan G. tag updates its packaging to use distro Stubble paths, the
patch will become either already applied or unnecessary. The build helper's
patch application should then report the patch as already applied or fail in a
way that prompts review of the version-specific patch directory.

If Ubuntu changes the `stubble` package layout again, this ADR and the patch
should be revisited rather than adding symlinks in the Docker image.

## Alternatives Considered

### Install symlinks in the Docker container

The build could create compatibility symlinks from `/usr/local` to `/usr`.
This was rejected because it hides an upstream packaging assumption in the
container setup and makes the build less explicit.

### Disable Stubble packaging

Disabling `do_stubble` would avoid the failing `ukify` step. This was rejected
because the qcom-x1e 7.1.1 packaging intentionally builds the Stubble-enabled
EFI image and declares `stubble`/`systemd-ukify` as build dependencies.

### Vendor Stubble files into this repository

Vendoring the EFI stub or hardware-id database was rejected. The files are
already provided by Ubuntu's `stubble` package in the build container.

## Verification

The patch was validated against the checked-out
`jg/ubuntu-qcom-x1e-7.1.1-jg-0` source tree in the Docker work volume. After
applying the patch:

```text
--stub=/usr/lib/stubble/stubble.efi
--hwids=/usr/share/stubble/hwids
--sbat=@/usr/share/stubble/sbat
```

The annotations compatibility patch in the same patch directory was also
validated at the same time:

```text
CONFIG_DRM_MSM_VALIDATE_XML policy<{'arm64': '-'}>
CONFIG_RUST_IS_AVAILABLE    policy<{'arm64': 'y'}>
```

The next full build should proceed past the previous missing
`/usr/local/share/stubble/hwids` failure.

## Related

- [ADR021: Git Fallback Kernel Build Toolchain](adr-0021-git-fallback-kernel-build-toolchain.md)
- [ADR019: Patched qcom-x1e Kernel for Wi-Fi rfkill](adr-0019-patched-qcom-x1e-kernel-for-wifi-rfkill.md)
- [Repeat Patched Kernel Build for a New qcom-x1e Release](../how-to/how-to-repeat-kernel-build-for-new-release.md)
