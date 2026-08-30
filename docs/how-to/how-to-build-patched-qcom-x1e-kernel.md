---
id: how-to-build-patched-qcom-x1e-kernel
title: "Build a Patched qcom-x1e Kernel"
# prettier-ignore
description: Build and inspect the maintained Surface Pro 11 kernel with linux-armer's native ARM64 container policy.
---

# How To: Build a Patched qcom-x1e Kernel

Last reviewed: 2026-08-30

`linux-armer kernel build` is the supported build path. It resolves the exact
source revision, runs the maintained recipe in a Linux ARM64 container and
publishes only a fresh, closed package bundle.

## Before you begin

- Install Docker and confirm that its daemon supports Linux ARM64 containers.
- Allow at least 24 GiB of free workspace storage.
- Run as a regular user with access to the Docker daemon.
- Choose a new output directory; publication refuses stale content.

Check the host and review the plan:

```sh
linux-armer doctor --workspace .
linux-armer kernel build --dry-run
```

The dry run prints the resolved policy without invoking Docker, compiling or
publishing packages. It therefore cannot prove that the daemon can execute an
ARM64 container.

## Build the maintained branch

```sh
linux-armer kernel build \
  --work-dir build/linux-armer/kernel-work \
  --output-dir build/linux-armer/kernel-20260830
```

The default URL and branch identify the maintained custom kernel. To test an
intentional alternative, state both inputs explicitly:

```sh
linux-armer kernel build \
  --git-url https://github.com/ooaklee/linux_ms_dev_kit-sp11.git \
  --git-branch <reviewed-branch-or-tag> \
  --work-dir build/linux-armer/kernel-work-next \
  --output-dir build/linux-armer/kernel-next
```

Use `--jobs <count>` to bound compilation. Use `--reset-source` only when the
CLI-owned cached source is invalid or intentionally changing lineage. It
resets the source in the labelled build volume, not a host checkout.

## Inspect the closed output

```sh
linux-armer kernel inspect build/linux-armer/kernel-20260830
```

Inspection must identify one ABI-bound runtime set with matching image and
modules packages. Do not add files to that directory or combine packages from
different builds.

For release preparation, retain the corresponding source closure and explicit
licence files, then follow
[Prepare Kernel Release Artefacts](how-to-release-kernel-artifacts.md).

## Use the bundle in an image

```sh
linux-armer image create \
  --source <ubuntu-concept-iso> \
  --source-sha256 <sha256> \
  --kernel-dir build/linux-armer/kernel-20260830 \
  --output build/linux-armer/linux-armer-ubuntu-sp11.iso
linux-armer image validate build/linux-armer/linux-armer-ubuntu-sp11.iso
```

The implemented Ubuntu adapter preserves the source image's Casper contract
while replacing the kernel-facing module set. Validation checks the finished
media rather than assuming a successful build produced a bootable image.

## Qualify and recover

Keep a known-good GRUB entry. After booting the candidate, run:

```sh
linux-armer doctor userspace
linux-armer doctor hardware wifi bluetooth audio
```

Then qualify boot, display, storage, Wi-Fi, Bluetooth, audio, pen and
suspend/resume on the physical device. Static validation is not a hardware
qualification claim. If the candidate fails, select the retained fallback and
use the kernel recovery guide rather than removing the fallback ABI.
